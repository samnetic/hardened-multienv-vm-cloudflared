#!/usr/bin/env bash
#
# Safe Caddy Configuration Update
# Validates config before applying, with automatic rollback on failure
#
# Usage:
#   ./scripts/update-caddy.sh                              # Uses /opt/infrastructure
#   ./scripts/update-caddy.sh /opt/infrastructure/infra/reverse-proxy
#   ./scripts/update-caddy.sh /custom/path/to/caddy
#
# This script:
# 1. Backs up current Caddyfile
# 2. Validates new configuration
# 3. Applies changes with zero downtime
# 4. Rolls back if validation fails

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Determine Caddy directory
if [ -n "${1:-}" ]; then
  CADDY_DIR="$1"
elif [ -d "/srv/infrastructure/reverse-proxy" ]; then
  CADDY_DIR="/srv/infrastructure/reverse-proxy"
elif [ -d "/opt/infrastructure/infra/reverse-proxy" ]; then
  CADDY_DIR="/opt/infrastructure/infra/reverse-proxy"
elif [ -d "/opt/hosting-blueprint/infra/reverse-proxy" ]; then
  CADDY_DIR="/opt/hosting-blueprint/infra/reverse-proxy"
  echo -e "${YELLOW}⚠ Using template directory. Consider using /srv/infrastructure instead.${NC}"
else
  echo -e "${RED}✗ Cannot find Caddy directory${NC}"
  echo "Checked:"
  echo "  - /srv/infrastructure/reverse-proxy"
  echo "  - /opt/infrastructure/infra/reverse-proxy"
  echo "  - /opt/hosting-blueprint/infra/reverse-proxy"
  echo ""
  echo "Usage: $0 [CADDY_DIR]"
  exit 1
fi

CADDYFILE="$CADDY_DIR/Caddyfile"
BACKUP_DIR="$CADDY_DIR/backups"

print_step() { echo -e "${BLUE}➜${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Safe Caddy Configuration Update${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "${BLUE}Directory:${NC} $CADDY_DIR"
echo

# Check if Caddyfile exists
if [ ! -f "$CADDYFILE" ]; then
  print_error "Caddyfile not found at $CADDYFILE"
  exit 1
fi

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Create timestamped backup
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/Caddyfile.$TIMESTAMP"

print_step "Backing up current Caddyfile..."
cp "$CADDYFILE" "$BACKUP_FILE"
print_success "Backup saved to: $BACKUP_FILE"

# Validate syntax
print_step "Validating Caddyfile syntax..."

if docker run --rm -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" caddy:latest caddy validate --config /etc/caddy/Caddyfile 2>&1; then
  print_success "Configuration is valid!"
else
  print_error "Configuration has errors!"
  echo
  print_warning "Fix the errors in $CADDYFILE and try again"
  print_warning "Previous working config backed up at: $BACKUP_FILE"
  exit 1
fi

# Check if Caddy container is running
if ! docker compose -f "$CADDY_DIR/compose.yml" ps | grep -q "caddy.*Up"; then
  print_warning "Caddy is not running. Starting it now..."
  cd "$CADDY_DIR"
  docker compose up -d
  print_success "Caddy started"
  exit 0
fi

# Reload Caddy gracefully (zero downtime)
print_step "Reloading Caddy configuration (zero downtime)..."

cd "$CADDY_DIR"
if docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile 2>&1; then
  print_success "Caddy reloaded successfully!"

  # Wait a moment for reload to complete
  sleep 2

  # Verify it's still running
  if docker compose ps | grep -q "caddy.*Up"; then
    print_success "Caddy is running and healthy"

    # Show recent logs
    echo
    print_step "Recent logs:"
    docker compose logs caddy --tail 10

    # Keep only last 10 backups
    print_step "Cleaning old backups (keeping last 10)..."
    cd "$BACKUP_DIR"
    ls -t Caddyfile.* 2>/dev/null | tail -n +11 | xargs -r rm --

    echo
    print_success "Configuration updated successfully!"
    print_warning "Backup available at: $BACKUP_FILE"
  else
    print_error "Caddy stopped after reload!"
    print_warning "Rolling back to previous configuration..."

    # Restore backup
    cp "$BACKUP_FILE" "$CADDYFILE"
    docker compose up -d

    print_error "Rollback complete. Check logs: docker compose logs caddy"
    exit 1
  fi
else
  print_error "Reload failed!"
  print_warning "Caddy is still running with the old configuration"
  print_warning "To rollback: cp $BACKUP_FILE $CADDYFILE && docker compose restart caddy"
  exit 1
fi
