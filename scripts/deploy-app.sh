#!/usr/bin/env bash
# =================================================================
# Generic App Deployment Script
# =================================================================
# Deploy or update Docker applications with logging
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Configuration
APP_DIR="${1:-.}"
LOG_FILE="/var/log/deployments.log"

# Fall back to user-writable log if /var/log is not writable
if [ ! -w "$(dirname "$LOG_FILE")" ] && [ ! -w "$LOG_FILE" ] 2>/dev/null; then
  LOG_FILE="${HOME}/.local/share/deployments.log"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
fi

# Prefer a security-first model: humans are not in the docker group.
# If docker isn't directly accessible, fall back to sudo.
DOCKER=(docker)
if ! command -v docker >/dev/null 2>&1; then
  echo -e "${RED}✗ Docker is not installed${NC}" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
fi

compose() {
  "${DOCKER[@]}" compose "$@"
}

# =================================================================
# Functions
# =================================================================

log_message() {
  local message=$1
  echo "[$(date -Iseconds)] $message" | tee -a "$LOG_FILE"
}

print_header() {
  echo ""
  echo "======================================================================"
  echo " $1"
  echo "======================================================================"
  echo ""
}

check_compose_file() {
  if [ ! -f "compose.yml" ] && [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}✗ No compose.yml or docker-compose.yml found${NC}"
    echo ""
    echo "All applications MUST be containerized using Docker Compose."
    echo "Create a compose.yml file to define your application services."
    echo ""
    echo "See apps/_template/compose.yml for a secure template."
    exit 1
  fi
}

validate_docker_config() {
  local COMPOSE_FILE
  if [ -f "compose.yml" ]; then
    COMPOSE_FILE="compose.yml"
  else
    COMPOSE_FILE="docker-compose.yml"
  fi

  echo "Validating Docker configuration..."

  # Check if compose file is valid YAML
  if ! compose config > /dev/null 2>&1; then
    echo -e "${RED}✗ Invalid compose.yml syntax${NC}"
    compose config 2>&1 | head -5
    exit 1
  fi
  echo -e "${GREEN}  ✓ Compose file syntax valid${NC}"

  # Check for security best practices
  local WARNINGS=0

  # Check for no-new-privileges (must be set to true, not false)
  if ! grep -qE 'no-new-privileges[:\s]*true' "$COMPOSE_FILE"; then
    echo -e "${YELLOW}  ⚠ Missing security_opt: no-new-privileges:true${NC}"
    WARNINGS=$((WARNINGS + 1))
  fi

  # Check for resource limits (look for limits: under deploy.resources or legacy mem_limit)
  if ! grep -qE '^\s*(limits:|mem_limit:)' "$COMPOSE_FILE"; then
    echo -e "${YELLOW}  ⚠ No resource limits defined (deploy.resources.limits)${NC}"
    WARNINGS=$((WARNINGS + 1))
  fi

  # Check for healthcheck
  if ! grep -qE '^\s*healthcheck:' "$COMPOSE_FILE"; then
    echo -e "${YELLOW}  ⚠ No healthcheck defined${NC}"
    WARNINGS=$((WARNINGS + 1))
  fi

  # Check for restart policy
  if ! grep -qE '^\s*restart:' "$COMPOSE_FILE"; then
    echo -e "${YELLOW}  ⚠ No restart policy defined (use restart: unless-stopped)${NC}"
    WARNINGS=$((WARNINGS + 1))
  fi

  if [ $WARNINGS -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}Found $WARNINGS security/reliability warnings.${NC}"
    echo "See apps/_template/compose.yml for recommended configuration."
    echo ""
    read -rp "Continue anyway? (yes/no): " CONTINUE
    if [ "$CONTINUE" != "yes" ]; then
      echo "Deployment cancelled."
      exit 1
    fi
  else
    echo -e "${GREEN}  ✓ Security best practices followed${NC}"
  fi
}

# =================================================================
# Main Script
# =================================================================

print_header "Docker Application Deployment"

# Verify app directory exists
if [ ! -d "$APP_DIR" ]; then
  echo -e "${RED}Error: Directory '$APP_DIR' does not exist${NC}"
  echo ""
  echo "Usage: $0 [app-directory]"
  echo "  If no directory specified, uses current directory"
  exit 1
fi

# Change to app directory
cd "$APP_DIR"
APP_NAME=$(basename "$(pwd)")
echo "Application: $APP_NAME"
echo "Directory: $(pwd)"
echo ""

# Check for compose file (all apps MUST be Dockerized)
check_compose_file

# Validate Docker security configuration
validate_docker_config

# Check for .env file
if [ ! -f ".env" ]; then
  echo -e "${YELLOW}⚠️  No .env file found${NC}"
  if [ -f ".env.example" ]; then
    echo "Hint: Copy .env.example to .env and configure it"
    echo "  cp .env.example .env"
    exit 1
  fi
fi

# Log deployment start
log_message "DEPLOY_START | APP: $APP_NAME | USER: $(whoami)"

# Pull latest images (if not building)
echo "Pulling latest images..."
if compose pull 2>/dev/null; then
  echo -e "${GREEN}✓ Images pulled${NC}"
else
  echo -e "${YELLOW}⚠️  Pull failed or building locally${NC}"
fi

# Build if Dockerfile exists
if [ -f "Dockerfile" ]; then
  echo ""
  echo "Building image..."
  compose build --pull
  echo -e "${GREEN}✓ Build complete${NC}"
fi

# Deploy containers
echo ""
echo "Deploying containers..."
compose up -d --remove-orphans

# Wait for healthiness
echo ""
echo "Waiting for containers to be healthy (max 30s)..."
sleep 5

# Check container status with retries
MAX_RETRIES=6
RETRY_INTERVAL=5
HEALTHY=false

for i in $(seq 1 $MAX_RETRIES); do
  # Check if any containers are unhealthy or exited
  if compose ps | grep -qE "unhealthy|exited"; then
    echo "  Attempt $i/$MAX_RETRIES: Some containers not healthy yet..."
    if [ "$i" -eq "$MAX_RETRIES" ]; then
      echo -e "${RED}✗ Containers unhealthy after 30s${NC}"
      compose ps
      log_message "DEPLOY_FAILED | APP: $APP_NAME | REASON: unhealthy"
      exit 1
    fi
    sleep $RETRY_INTERVAL
  else
    # All containers are healthy or running
    echo -e "${GREEN}✓ Containers healthy${NC}"
    HEALTHY=true
    break
  fi
done

if [ "$HEALTHY" != "true" ]; then
  echo -e "${RED}✗ Health check did not complete successfully${NC}"
  exit 1
fi

# Show status
echo ""
echo "Container status:"
compose ps

# Show recent logs
echo ""
echo "Recent logs (last 20 lines):"
compose logs --tail=20

# Log successful deployment
log_message "DEPLOY_SUCCESS | APP: $APP_NAME"

print_header "Deployment Complete!"

echo -e "${GREEN}✓ $APP_NAME deployed successfully${NC}"
echo ""
echo "Useful commands:"
echo "  sudo docker compose ps             - View status"
echo "  sudo docker compose logs -f        - Follow logs"
echo "  sudo docker compose restart        - Restart app"
echo "  sudo docker compose down           - Stop app"
echo ""
