#!/usr/bin/env bash
# =================================================================
# Docker Cleanup
# =================================================================
# Cleans up unused Docker resources.
# Designed to be run via cron or manually.
#
# Usage:
#   ./docker-cleanup.sh                    # Standard cleanup
#   ./docker-cleanup.sh --full             # Full cleanup (interactive prompt)
#   ./docker-cleanup.sh --full --force     # Full cleanup (no prompt, for cron)
#   ./docker-cleanup.sh --dry-run          # Preview what would be removed
# =================================================================

set -euo pipefail

# Log file with fallback if /var/log not writable
LOG_FILE="/var/log/docker-cleanup.log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="${HOME}/.docker-cleanup.log"
fi
FULL_CLEANUP=false
DRY_RUN=false
FORCE=false

# Check if running in non-interactive mode (cron, pipe, etc.)
INTERACTIVE=false
if [ -t 0 ] && [ -t 1 ]; then
  INTERACTIVE=true
fi

# Parse arguments
for arg in "$@"; do
  case $arg in
    --full)
      FULL_CLEANUP=true
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --force|-f)
      FORCE=true
      ;;
  esac
done

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

if [ "$DRY_RUN" = true ]; then
  echo "=== DRY RUN: Preview of what would be cleaned ==="
  echo ""
fi

log "=== Docker Cleanup Started ==="

# Prefer a security-first model: humans are not in the docker group.
# If docker isn't directly accessible, fall back to sudo.
if ! command -v docker &> /dev/null; then
  log "ERROR: Docker not installed"
  exit 1
fi

DOCKER=(docker)
if ! docker info &>/dev/null; then
  if [ "$INTERACTIVE" = true ]; then
    DOCKER=(sudo docker)
  else
    DOCKER=(sudo -n docker)
  fi
fi

if ! "${DOCKER[@]}" info &>/dev/null; then
  log "ERROR: Docker not accessible as this user (run with sudo)"
  exit 1
fi

# Show current usage
log "Current Docker disk usage:"
"${DOCKER[@]}" system df 2>&1 | while IFS= read -r line; do log "  $line"; done

# Cleanup stopped containers
STOPPED=$("${DOCKER[@]}" ps -a -f "status=exited" -q 2>/dev/null | wc -l)
if [ "$STOPPED" -gt 0 ]; then
  if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would remove $STOPPED stopped containers:"
    "${DOCKER[@]}" ps -a -f "status=exited" --format "  - {{.Names}} ({{.Image}}, exited {{.Status}})" 2>/dev/null | head -10
    [ "$STOPPED" -gt 10 ] && echo "  ... and $((STOPPED - 10)) more"
  else
    log "Removing $STOPPED stopped containers..."
    "${DOCKER[@]}" container prune -f >> "$LOG_FILE" 2>&1
  fi
fi

# Cleanup dangling images
DANGLING=$("${DOCKER[@]}" images -f "dangling=true" -q 2>/dev/null | wc -l)
if [ "$DANGLING" -gt 0 ]; then
  if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would remove $DANGLING dangling images"
  else
    log "Removing $DANGLING dangling images..."
    "${DOCKER[@]}" image prune -f >> "$LOG_FILE" 2>&1
  fi
fi

# Cleanup unused networks
UNUSED_NETS=$("${DOCKER[@]}" network ls --filter "dangling=true" -q 2>/dev/null | wc -l)
if [ "$DRY_RUN" = true ]; then
  log "[DRY-RUN] Would clean up unused networks (approx $UNUSED_NETS)"
else
  log "Cleaning up unused networks..."
  "${DOCKER[@]}" network prune -f >> "$LOG_FILE" 2>&1
fi

# Full cleanup includes unused volumes and all unused images
if [ "$FULL_CLEANUP" = true ]; then
  if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] FULL CLEANUP would also remove:"
    log "  - All unused images (not just dangling)"
    log "  - All unused volumes (INCLUDING DATA!)"
    log "  - Build cache"
    echo ""
    echo "Unused images that would be removed:"
    "${DOCKER[@]}" images --filter "dangling=false" --format "  {{.Repository}}:{{.Tag}} ({{.Size}})" | head -10
  else
    # Warn user about destructive operation
    if [ "$INTERACTIVE" = true ] && [ "$FORCE" = false ]; then
      echo ""
      echo "=================================================================="
      echo " WARNING: FULL CLEANUP IS DESTRUCTIVE"
      echo "=================================================================="
      echo ""
      echo "This will permanently delete:"
      echo "  - ALL unused Docker images (including tagged images)"
      echo "  - ALL unused Docker volumes (may include application data!)"
      echo "  - ALL build cache"
      echo ""
      echo "This operation CANNOT be undone."
      echo ""
      read -rp "Are you sure you want to proceed? (yes/no): " CONFIRM
      if [ "$CONFIRM" != "yes" ]; then
        log "Full cleanup cancelled by user."
        exit 0
      fi
      echo ""
    elif [ "$INTERACTIVE" = false ] && [ "$FORCE" = false ]; then
      # Non-interactive mode without --force flag
      log "ERROR: --full cleanup requires --force flag in non-interactive mode (cron)"
      log "Use: $0 --full --force"
      exit 1
    fi
    # If --force is set, proceed without confirmation

    log "FULL CLEANUP: Removing all unused images..."
    "${DOCKER[@]}" image prune -a -f >> "$LOG_FILE" 2>&1

    log "FULL CLEANUP: Removing unused volumes..."
    "${DOCKER[@]}" volume prune -f >> "$LOG_FILE" 2>&1

    log "FULL CLEANUP: Removing build cache..."
    "${DOCKER[@]}" builder prune -f >> "$LOG_FILE" 2>&1
  fi
fi

# Show new usage
if [ "$DRY_RUN" = true ]; then
  echo ""
  log "=== DRY RUN Complete (no changes made) ==="
  echo ""
  echo "To perform actual cleanup, run without --dry-run flag"
else
  log "Docker disk usage after cleanup:"
  "${DOCKER[@]}" system df 2>&1 | while IFS= read -r line; do log "  $line"; done
  log "=== Docker Cleanup Complete ==="
fi
