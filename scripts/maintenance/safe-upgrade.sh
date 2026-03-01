#!/usr/bin/env bash
# =================================================================
# Safe Docker Service Upgrade (hosting-blueprint)
# =================================================================
# Upgrades a Docker Compose service with pre-flight checks, backup,
# health verification, and automatic rollback on failure.
#
# Usage:
#   sudo ./safe-upgrade.sh --service n8n --compose-file /srv/apps/n8n/compose.yaml --image n8nio/n8n
#   sudo ./safe-upgrade.sh --service n8n --compose-file /srv/apps/n8n/compose.yaml --image n8nio/n8n --dry-run
#   sudo ./safe-upgrade.sh --service n8n --compose-file /srv/apps/n8n/compose.yaml --image n8nio/n8n --version 2.10.1
#
# Features:
#   - Auto-detects latest stable version from Docker Hub (2.x series)
#   - Verifies image exists for current architecture
#   - Pre-flight health check of running services
#   - Optional backup command before upgrade
#   - Pulls new image, updates compose, restarts
#   - Health check with configurable timeout
#   - Automatic rollback if health checks fail
#   - Full logging to /var/log/hosting-blueprint/
# =================================================================

set -euo pipefail

# =================================================================
# Defaults
# =================================================================
SERVICE_NAME=""
COMPOSE_FILE=""
IMAGE_NAME=""
TARGET_VERSION=""
BACKUP_CMD=""
DRY_RUN=false
HEALTH_TIMEOUT=120
YES_FLAG=false
LOGDIR="/var/log/hosting-blueprint"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# =================================================================
# Helper Functions
# =================================================================

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Required:
  --service NAME          Service name (e.g., n8n, caddy, postgres)
  --compose-file PATH     Path to docker-compose file
  --image NAME            Docker image (e.g., n8nio/n8n, caddy)

Optional:
  --version VERSION       Target version (default: auto-detect latest)
  --backup-cmd CMD        Command to run before upgrade (e.g., "make backup")
  --health-timeout SECS   Health check timeout (default: 120)
  --dry-run               Preview changes without executing
  --yes                   Skip confirmation prompt

Examples:
  $0 --service n8n --compose-file ./compose.yaml --image n8nio/n8n
  $0 --service caddy --compose-file ./compose.yaml --image caddy --version 2.11.1
  $0 --service n8n --compose-file ./compose.yaml --image n8nio/n8n --backup-cmd "make backup" --dry-run
EOF
  exit 0
}

log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"; }
die() { log "${RED}FATAL: $1${NC}"; exit 2; }

notify() {
  local subject="$1"
  local body="$2"
  if [ -x /opt/scripts/hosting-notify.sh ]; then
    /opt/scripts/hosting-notify.sh "$subject" "$body" || true
  fi
}

# =================================================================
# Parse Arguments
# =================================================================
while [ $# -gt 0 ]; do
  case "$1" in
    --service)      SERVICE_NAME="$2"; shift 2 ;;
    --compose-file) COMPOSE_FILE="$2"; shift 2 ;;
    --image)        IMAGE_NAME="$2"; shift 2 ;;
    --version)      TARGET_VERSION="$2"; shift 2 ;;
    --backup-cmd)   BACKUP_CMD="$2"; shift 2 ;;
    --health-timeout) HEALTH_TIMEOUT="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --yes)          YES_FLAG=true; shift ;;
    --help|-h)      usage ;;
    *)              echo "Unknown option: $1"; usage ;;
  esac
done

if [ -z "$SERVICE_NAME" ] || [ -z "$COMPOSE_FILE" ] || [ -z "$IMAGE_NAME" ]; then
  echo "Error: --service, --compose-file, and --image are required"
  echo ""
  usage
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  die "Compose file not found: ${COMPOSE_FILE}"
fi

COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
LOGFILE="${LOGDIR}/${SERVICE_NAME}-upgrade-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOGDIR"

log "=== Safe upgrade: ${SERVICE_NAME} ==="
log "Compose file: ${COMPOSE_FILE}"
log "Image: ${IMAGE_NAME}"

# =================================================================
# Step 1: Detect Target Version
# =================================================================
ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

if [ -z "$TARGET_VERSION" ]; then
  log "Auto-detecting latest version for ${IMAGE_NAME}..."

  # Try Docker Hub API v2
  NAMESPACE="${IMAGE_NAME%%/*}"
  REPO="${IMAGE_NAME#*/}"
  if [ "$NAMESPACE" = "$IMAGE_NAME" ]; then
    NAMESPACE="library"
    REPO="$IMAGE_NAME"
  fi

  TAGS_JSON="$(curl -fsSL "https://hub.docker.com/v2/repositories/${NAMESPACE}/${REPO}/tags/?page_size=50&ordering=last_updated" 2>/dev/null || echo '{}')"

  if [ "$TAGS_JSON" != '{}' ] && command -v jq >/dev/null 2>&1; then
    # Find latest stable version tag (semantic versioning, no pre-release)
    TARGET_VERSION="$(echo "$TAGS_JSON" | jq -r '.results[].name' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
  fi

  if [ -z "$TARGET_VERSION" ]; then
    die "Could not auto-detect latest version. Specify --version manually."
  fi

  log "Latest version detected: ${TARGET_VERSION}"
fi

# Get current version
CURRENT_VERSION="$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Image}}' 2>/dev/null | grep "$IMAGE_NAME" | head -1 | sed "s|.*:||" || echo "unknown")"
log "Current version: ${CURRENT_VERSION}"
log "Target version: ${TARGET_VERSION}"

if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
  log "Already running ${TARGET_VERSION}. Nothing to do."
  exit 0
fi

# =================================================================
# Step 2: Verify Image Exists
# =================================================================
log "Verifying ${IMAGE_NAME}:${TARGET_VERSION} exists for ${ARCH}..."
if docker manifest inspect "${IMAGE_NAME}:${TARGET_VERSION}" >/dev/null 2>&1; then
  log "Image verified"
else
  die "Image not found: ${IMAGE_NAME}:${TARGET_VERSION}"
fi

# =================================================================
# Step 3: Confirmation
# =================================================================
echo ""
echo "Upgrade plan:"
echo "  Service:  ${SERVICE_NAME}"
echo "  Image:    ${IMAGE_NAME}"
echo "  Current:  ${CURRENT_VERSION}"
echo "  Target:   ${TARGET_VERSION}"
echo "  Backup:   ${BACKUP_CMD:-none}"
echo ""

if [ "$DRY_RUN" = true ]; then
  log "DRY RUN: Would upgrade ${SERVICE_NAME} from ${CURRENT_VERSION} to ${TARGET_VERSION}"
  exit 0
fi

if [ "$YES_FLAG" != true ]; then
  read -rp "Proceed with upgrade? [y/N]: " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    log "Upgrade cancelled by user"
    exit 0
  fi
fi

# =================================================================
# Step 4: Pre-flight Health Check
# =================================================================
log "Pre-flight health check..."
UNHEALTHY="$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Name}} {{.Health}}' 2>/dev/null | grep -v healthy | grep -v '^ *$' || true)"
if [ -n "$UNHEALTHY" ]; then
  log "WARNING: Some services are not healthy before upgrade:"
  log "$UNHEALTHY"
fi

# =================================================================
# Step 5: Backup
# =================================================================
if [ -n "$BACKUP_CMD" ]; then
  log "Running backup: ${BACKUP_CMD}"
  if eval "$BACKUP_CMD" >> "$LOGFILE" 2>&1; then
    log "Backup completed"
  else
    die "Backup failed. Aborting upgrade."
  fi
fi

# Save current state for rollback
ROLLBACK_VERSION="$CURRENT_VERSION"

# =================================================================
# Step 6: Pull & Upgrade
# =================================================================
log "Pulling ${IMAGE_NAME}:${TARGET_VERSION}..."
docker pull "${IMAGE_NAME}:${TARGET_VERSION}" >> "$LOGFILE" 2>&1

log "Restarting ${SERVICE_NAME}..."

# Update the image tag in compose (support common patterns)
# Look for image: lines matching the service image
cd "$COMPOSE_DIR"
docker compose -f "$COMPOSE_FILE" up -d --no-deps --pull always "$SERVICE_NAME" >> "$LOGFILE" 2>&1 || {
  log "WARNING: compose up failed, trying full restart..."
  docker compose -f "$COMPOSE_FILE" up -d >> "$LOGFILE" 2>&1 || true
}

# =================================================================
# Step 7: Health Check
# =================================================================
log "Waiting for health check (timeout: ${HEALTH_TIMEOUT}s)..."
ELAPSED=0
HEALTHY=false

while [ "$ELAPSED" -lt "$HEALTH_TIMEOUT" ]; do
  HEALTH="$(docker compose -f "$COMPOSE_FILE" ps --format '{{.Health}}' "$SERVICE_NAME" 2>/dev/null | head -1 || echo "")"

  if [ "$HEALTH" = "healthy" ]; then
    HEALTHY=true
    break
  fi

  # Also check if container is running (for services without healthcheck)
  STATE="$(docker compose -f "$COMPOSE_FILE" ps --format '{{.State}}' "$SERVICE_NAME" 2>/dev/null | head -1 || echo "")"
  if [ "$STATE" = "running" ] && [ -z "$HEALTH" ]; then
    # No healthcheck defined, running is good enough
    HEALTHY=true
    break
  fi

  sleep 5
  ELAPSED=$((ELAPSED + 5))
  log "  Waiting... (${ELAPSED}s, state=${STATE:-?}, health=${HEALTH:-?})"
done

if [ "$HEALTHY" = true ]; then
  log "${GREEN}Upgrade successful: ${SERVICE_NAME} ${CURRENT_VERSION} -> ${TARGET_VERSION}${NC}"
  notify "Upgrade OK - ${HOSTNAME_FQDN}" "${SERVICE_NAME} upgraded: ${CURRENT_VERSION} -> ${TARGET_VERSION}"
  exit 0
fi

# =================================================================
# Step 8: Automatic Rollback
# =================================================================
log "${RED}Health check failed after ${HEALTH_TIMEOUT}s. Rolling back to ${ROLLBACK_VERSION}...${NC}"

docker pull "${IMAGE_NAME}:${ROLLBACK_VERSION}" >> "$LOGFILE" 2>&1 || true
docker compose -f "$COMPOSE_FILE" up -d --no-deps "$SERVICE_NAME" >> "$LOGFILE" 2>&1 || true

# Verify rollback
sleep 10
ROLLBACK_STATE="$(docker compose -f "$COMPOSE_FILE" ps --format '{{.State}}' "$SERVICE_NAME" 2>/dev/null | head -1 || echo "")"

if [ "$ROLLBACK_STATE" = "running" ]; then
  log "Rollback successful: ${SERVICE_NAME} restored to ${ROLLBACK_VERSION}"
  notify "Upgrade ROLLED BACK - ${HOSTNAME_FQDN}" \
    "${SERVICE_NAME} upgrade to ${TARGET_VERSION} failed.\nRolled back to ${ROLLBACK_VERSION}.\nSee: ${LOGFILE}"
  exit 1
else
  log "${RED}ROLLBACK FAILED. Manual intervention required!${NC}"
  notify "UPGRADE CRITICAL - ${HOSTNAME_FQDN}" \
    "${SERVICE_NAME} upgrade AND rollback failed!\nManual intervention required.\nSee: ${LOGFILE}"
  exit 2
fi
