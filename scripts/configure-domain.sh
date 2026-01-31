#!/usr/bin/env bash
# =================================================================
# Configure Domain
# =================================================================
# Sets the primary domain across all configuration files.
#
# Usage:
#   ./configure-domain.sh example.com
#   ./configure-domain.sh example.com --hostname myserver
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Arguments
DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 <domain> [--hostname <name>]"
  echo ""
  echo "Examples:"
  echo "  $0 example.com"
  echo "  $0 example.com --hostname prod-server"
  exit 1
fi

# Validate domain format (requires at least one dot, no consecutive dots/hyphens)
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
  echo -e "${RED}Error: Invalid domain format '${DOMAIN}'${NC}"
  echo "Domain must be a valid format like 'example.com' or 'sub.example.com'"
  echo "  - Must contain at least one dot"
  echo "  - Can only contain letters, numbers, dots, and hyphens"
  echo "  - Cannot start or end with a hyphen or dot"
  exit 1
fi

# Escape special characters for sed (/, &, \)
escape_sed() {
  printf '%s\n' "$1" | sed 's/[&/\]/\\&/g'
}
DOMAIN_ESCAPED=$(escape_sed "$DOMAIN")

# Parse --hostname flag
if [ "${2:-}" = "--hostname" ] && [ -n "${3:-}" ]; then
  HOSTNAME="$3"
else
  # Default hostname: first part of domain
  HOSTNAME="${DOMAIN%%.*}"
fi

echo ""
echo -e "${CYAN}Configuring domain: ${DOMAIN}${NC}"
echo -e "${CYAN}Hostname: ${HOSTNAME}${NC}"
echo ""

# =================================================================
# Update Caddyfile
# =================================================================
CADDYFILE="${REPO_DIR}/infra/reverse-proxy/Caddyfile"
if [ -f "$CADDYFILE" ]; then
  if grep -q "yourdomain.com" "$CADDYFILE"; then
    sed -i "s/yourdomain\.com/${DOMAIN_ESCAPED}/g" "$CADDYFILE"
    echo -e "${GREEN}✓${NC} Updated Caddyfile"
  else
    echo -e "${YELLOW}⚠${NC} Caddyfile already configured (no yourdomain.com found)"
  fi
else
  echo -e "${YELLOW}⚠${NC} Caddyfile not found"
fi

# =================================================================
# Update Cloudflared Config (if exists)
# =================================================================
CLOUDFLARED_CONFIG="${REPO_DIR}/infra/cloudflared/config.yml"
CLOUDFLARED_EXAMPLE="${REPO_DIR}/infra/cloudflared/config.yml.example"

# Create config.yml from example if it doesn't exist
if [ ! -f "$CLOUDFLARED_CONFIG" ] && [ -f "$CLOUDFLARED_EXAMPLE" ]; then
  cp "$CLOUDFLARED_EXAMPLE" "$CLOUDFLARED_CONFIG"
  echo -e "${GREEN}✓${NC} Created cloudflared config from example"
fi

if [ -f "$CLOUDFLARED_CONFIG" ]; then
  if grep -q "yourdomain.com" "$CLOUDFLARED_CONFIG"; then
    sed -i "s/yourdomain\.com/${DOMAIN_ESCAPED}/g" "$CLOUDFLARED_CONFIG"
    echo -e "${GREEN}✓${NC} Updated cloudflared config"
  fi
fi

if [ -f "$CLOUDFLARED_EXAMPLE" ]; then
  if grep -q "yourdomain.com" "$CLOUDFLARED_EXAMPLE"; then
    sed -i "s/yourdomain\.com/${DOMAIN_ESCAPED}/g" "$CLOUDFLARED_EXAMPLE"
    echo -e "${GREEN}✓${NC} Updated cloudflared config example"
  fi
fi

# =================================================================
# Update Netdata .env
# =================================================================
NETDATA_ENV="${REPO_DIR}/infra/monitoring/.env"
NETDATA_EXAMPLE="${REPO_DIR}/infra/monitoring/.env.example"

if [ -f "$NETDATA_EXAMPLE" ]; then
  sed -i "s/HOSTNAME=.*/HOSTNAME=${HOSTNAME}/" "$NETDATA_EXAMPLE"
  echo -e "${GREEN}✓${NC} Updated Netdata .env.example"
fi

if [ -f "$NETDATA_ENV" ]; then
  sed -i "s/HOSTNAME=.*/HOSTNAME=${HOSTNAME}/" "$NETDATA_ENV"
  echo -e "${GREEN}✓${NC} Updated Netdata .env"
fi

# =================================================================
# Update VM Hostname (requires root)
# =================================================================
if [ "$EUID" -eq 0 ]; then
  # Set hostname
  hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || hostname "$HOSTNAME"

  # Update /etc/hosts (anchored pattern to avoid matching wrong lines)
  if ! grep -q "$HOSTNAME" /etc/hosts; then
    sed -i "s/^127\.0\.0\.1[[:space:]].*/127.0.0.1 localhost ${HOSTNAME}/" /etc/hosts
  fi

  echo -e "${GREEN}✓${NC} Set VM hostname to: ${HOSTNAME}"
else
  echo -e "${YELLOW}⚠${NC} Run as root to set VM hostname"
  echo "  sudo hostnamectl set-hostname ${HOSTNAME}"
fi

# =================================================================
# Save Domain Config
# =================================================================
CONFIG_DIR="/opt/vm-config"
if [ "$EUID" -eq 0 ]; then
  mkdir -p "$CONFIG_DIR"
  cat > "${CONFIG_DIR}/domain.conf" << EOF
# Domain configuration - Generated $(date)
DOMAIN="${DOMAIN}"
HOSTNAME="${HOSTNAME}"
EOF
  chmod 600 "${CONFIG_DIR}/domain.conf"
  echo -e "${GREEN}✓${NC} Saved config to ${CONFIG_DIR}/domain.conf"
fi

# =================================================================
# Summary
# =================================================================
echo ""
echo -e "${GREEN}Domain configured!${NC}"
echo ""
echo "Your subdomains:"
echo "  • app.${DOMAIN}           → Production app"
echo "  • staging-app.${DOMAIN}   → Staging app"
echo "  • dev-app.${DOMAIN}       → Dev app"
echo "  • monitoring.${DOMAIN}    → Netdata (if enabled)"
echo "  • ssh.${DOMAIN}           → SSH via tunnel"
echo ""
echo "Next steps:"
echo "  1. Add DNS records in Cloudflare (CNAME to tunnel)"
echo "  2. Reload Caddy: docker compose -f infra/reverse-proxy/compose.yml restart"
echo ""
