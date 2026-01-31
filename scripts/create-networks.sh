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

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE} Creating Docker Networks for Multi-Environment Setup${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
  echo -e "${RED}Error: Docker is not installed${NC}"
  exit 1
fi

if ! docker info &> /dev/null; then
  echo -e "${RED}Error: Docker daemon is not running${NC}"
  echo "Start Docker with: sudo systemctl start docker"
  exit 1
fi

# Function to create network if it doesn't exist
create_network() {
  local network_name=$1
  local network_type=${2:-bridge}  # Default to bridge
  local description=${3:-""}

  if docker network ls --format '{{.Name}}' | grep -qx "$network_name"; then
    echo -e "${YELLOW}⚠  Network '$network_name' already exists${NC}"
  else
    echo -n "Creating network '$network_name'"
    [ -n "$description" ] && echo -n " ($description)"
    echo -n "... "

    local create_cmd="docker network create $network_name"
    [ "$network_type" = "internal" ] && create_cmd="$create_cmd --internal"

    if $create_cmd > /dev/null 2>&1; then
      echo -e "${GREEN}✓${NC}"
    else
      echo -e "${RED}FAILED${NC}"
      echo "  Error: Failed to create network '$network_name'" >&2
      echo "  Check if Docker daemon is running: docker info" >&2
      return 1
    fi
  fi
}

# Track failures for summary
FAILURES=0

# =================================================================
# Development Environment Networks
# =================================================================
echo "Development networks (accessible from host):"
create_network "dev-web" "bridge" "apps accessible via Caddy" || ((FAILURES++))
create_network "dev-backend" "bridge" "databases accessible from host for local dev" || ((FAILURES++))
echo ""

# =================================================================
# Staging Environment Networks
# =================================================================
echo "Staging networks (internal backend):"
create_network "staging-web" "bridge" "apps accessible via Caddy" || ((FAILURES++))
create_network "staging-backend" "internal" "databases internal only" || ((FAILURES++))
echo ""

# =================================================================
# Production Environment Networks
# =================================================================
echo "Production networks (most secure):"
create_network "prod-web" "bridge" "apps accessible via Caddy" || ((FAILURES++))
create_network "prod-backend" "internal" "databases internal only" || ((FAILURES++))
echo ""

# =================================================================
# Shared Networks
# =================================================================
echo "Shared networks:"
create_network "monitoring" "bridge" "optional monitoring stack" || ((FAILURES++))
echo ""

# Check for failures
if [ "$FAILURES" -gt 0 ]; then
  echo -e "${RED}Error: $FAILURES network(s) failed to create${NC}" >&2
  exit 1
fi

# =================================================================
# Summary
# =================================================================

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE} Network Creation Complete!${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo ""
echo "Created networks:"
docker network ls --format "  {{.Name}}" | grep -E "dev-|staging-|prod-|monitoring" || echo "  (none found)"
echo ""
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
echo "  SHARED:"
echo "    • monitoring    - Optional Netdata monitoring"
echo ""
echo -e "${GREEN}✓ All networks ready!${NC}"
echo ""
echo "Next: Update Caddyfile to route to each environment"
echo ""
