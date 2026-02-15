#!/usr/bin/env bash
# =================================================================
# Create Docker Networks for Multi-Environment Setup
# =================================================================
# Creates isolated Docker networks for dev, staging, production
#
# Network Architecture:
#   dev-web / dev-backend       - Development (accessible from host)
#   staging-web / staging-backend - Staging (internal backend)
#   prod-web / prod-backend     - Production (internal backend)
# =================================================================

set -euo pipefail

# =================================================================
# Configuration
# =================================================================

# Server profile: full-stack | monitoring | minimal
# Inherited from setup.sh or set via environment variable.
SETUP_PROFILE="${SETUP_PROFILE:-full-stack}"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE} Creating Docker Networks (profile: ${SETUP_PROFILE})${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
  echo -e "${RED}Error: Docker is not installed${NC}"
  exit 1
fi

# Prefer a security-first model: humans are not in the docker group.
# If docker isn't directly accessible, fall back to sudo.
DOCKER=(docker)
if ! docker info &> /dev/null; then
  DOCKER=(sudo docker)
  if ! "${DOCKER[@]}" info &> /dev/null; then
    echo -e "${RED}Error: Docker not accessible as this user${NC}"
    echo "Try running:"
    echo "  sudo $0"
    exit 1
  fi
fi

# Function to create network if it doesn't exist
create_network() {
  local network_name=$1
  local network_type=${2:-bridge}  # Default to bridge
  local description=${3:-""}

  if "${DOCKER[@]}" network ls --format '{{.Name}}' | grep -qx "$network_name"; then
    echo -e "${YELLOW}⚠  Network '$network_name' already exists${NC}"
    if [ "$network_name" = "hosting-caddy-origin" ]; then
      local gateway
      local internal
      gateway=$("${DOCKER[@]}" network inspect "$network_name" --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "")
      internal=$("${DOCKER[@]}" network inspect "$network_name" --format '{{.Internal}}' 2>/dev/null || echo "")
      if [ "$gateway" != "10.250.0.1" ] || [ "$internal" != "true" ]; then
        echo -e "${YELLOW}⚠  hosting-caddy-origin settings differ from expected (gateway=$gateway internal=$internal)${NC}"
        echo "    This can break Caddy tunnel-only enforcement."
        echo "    Fix (downtime):"
        echo "      1) cd /srv/infrastructure/reverse-proxy && sudo docker compose down"
        echo "      2) sudo docker network rm hosting-caddy-origin"
        echo "      3) sudo $0"
        echo "      4) cd /srv/infrastructure/reverse-proxy && sudo docker compose --compatibility up -d"
      fi
    fi
  else
    echo -n "Creating network '$network_name'"
    [ -n "$description" ] && echo -n " ($description)"
    echo -n "... "

    # hosting-caddy-origin is a fixed-subnet internal network used for the reverse proxy
    # tunnel-only enforcement (see infra/reverse-proxy/Caddyfile).
    local create_cmd=("${DOCKER[@]}" network create "$network_name")
    if [ "$network_name" = "hosting-caddy-origin" ]; then
      create_cmd+=("--internal" "--subnet" "10.250.0.0/24" "--gateway" "10.250.0.1")
    elif [ "$network_type" = "internal" ]; then
      create_cmd+=("--internal")
    fi

    if "${create_cmd[@]}" > /dev/null 2>&1; then
      echo -e "${GREEN}✓${NC}"
    else
      echo -e "${RED}FAILED${NC}"
      echo "  Error: Failed to create network '$network_name'" >&2
      echo "  Check Docker: sudo systemctl status docker" >&2
      return 1
    fi
  fi
}

# Track failures for summary
FAILURES=0

# =================================================================
# Shared Networks (always created)
# =================================================================
echo "Shared networks:"
create_network "monitoring" "bridge" "monitoring stack" || ((FAILURES++))
create_network "hosting-caddy-origin" "internal" "reverse proxy origin enforcement (tunnel-only)" || ((FAILURES++))
echo ""

# =================================================================
# Environment Networks (full-stack profile only)
# =================================================================
if [ "$SETUP_PROFILE" = "full-stack" ]; then
  echo "Development networks (accessible from host):"
  create_network "dev-web" "bridge" "apps accessible via Caddy" || ((FAILURES++))
  create_network "dev-backend" "bridge" "databases accessible from host for local dev" || ((FAILURES++))
  echo ""

  echo "Staging networks (internal backend):"
  create_network "staging-web" "bridge" "apps accessible via Caddy" || ((FAILURES++))
  create_network "staging-backend" "internal" "databases internal only" || ((FAILURES++))
  echo ""

  echo "Production networks (most secure):"
  create_network "prod-web" "bridge" "apps accessible via Caddy" || ((FAILURES++))
  create_network "prod-backend" "internal" "databases internal only" || ((FAILURES++))
  echo ""
else
  echo -e "${BLUE}ℹ  Skipping environment networks (profile: ${SETUP_PROFILE})${NC}"
  echo "  Use 'full-stack' profile for dev/staging/prod networks."
  echo ""
fi

# Check for failures
if [ "$FAILURES" -gt 0 ]; then
  echo -e "${RED}Error: $FAILURES network(s) failed to create${NC}" >&2
  exit 1
fi

# =================================================================
# Summary
# =================================================================

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE} Network Creation Complete! (profile: ${SETUP_PROFILE})${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo ""
echo "Created networks:"
"${DOCKER[@]}" network ls --format "  {{.Name}}" | grep -E "dev-|staging-|prod-|monitoring|hosting-caddy-origin" || echo "  (none found)"
echo ""

if [ "$SETUP_PROFILE" = "full-stack" ]; then
  echo "Environment Overview:"
  echo ""
  echo "  DEV (playground - local PC can connect to DBs):"
  echo "    • dev-web      - Web-facing containers"
  echo "    • dev-backend  - Backend services (NOT internal, accessible)"
  echo ""
  echo "  STAGING (production-like - auto-deploy, no local access):"
  echo "    • staging-web      - Web-facing containers"
  echo "    • staging-backend  - Backend services (internal only)"
  echo ""
  echo "  PRODUCTION (most secure - manual deploy only):"
  echo "    • prod-web      - Web-facing containers"
  echo "    • prod-backend  - Backend services (internal only)"
  echo ""
fi

echo "  SHARED:"
echo "    • monitoring              - Monitoring stack (Prometheus, Grafana, etc.)"
echo "    • hosting-caddy-origin    - Reverse proxy origin enforcement network"
echo ""
echo -e "${GREEN}✓ All networks ready!${NC}"
echo ""
