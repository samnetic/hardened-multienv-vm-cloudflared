#!/usr/bin/env bash
# =================================================================
# Configure Domain
# =================================================================
# Sets the primary domain across all configuration files.
#
# Usage:
#   ./configure-domain.sh yourdomain.com
#   ./configure-domain.sh yourdomain.com --hostname myserver
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

# Server profile (inherited from setup.sh or set via env var)
SETUP_PROFILE="${SETUP_PROFILE:-full-stack}"

# Arguments
DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
  echo "Usage: $0 <domain> [--hostname <name>]"
  echo ""
  echo "Examples:"
  echo "  $0 yourdomain.com"
  echo "  $0 yourdomain.com --hostname prod-server"
  echo "  $0 monitoring.yourdomain.com --hostname monitoring"
  exit 1
fi

# Validate domain format (requires at least one dot, no consecutive dots/hyphens)
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
  echo -e "${RED}Error: Invalid domain format '${DOMAIN}'${NC}"
  echo "Domain must be a valid format like 'yourdomain.com' or 'monitoring.yourdomain.com'"
  echo "  - Must contain at least one dot"
  echo "  - Can only contain letters, numbers, dots, and hyphens"
  echo "  - Cannot start or end with a hyphen or dot"
  exit 1
fi

# Escape special characters for sed (/, &, \)
escape_sed() {
  # Escape for sed replacement: backslash, slash, ampersand.
  printf '%s\n' "$1" | sed -e 's/[\\/&]/\\&/g'
}
DOMAIN_ESCAPED=$(escape_sed "$DOMAIN")

# Parse --hostname flag
if [ "${2:-}" = "--hostname" ] && [ -n "${3:-}" ]; then
  HOSTNAME="$3"
else
  # Default hostname: first part of domain
  HOSTNAME="${DOMAIN%%.*}"
fi

# Target root selection:
# - Prefer /srv/infrastructure when present (keeps /opt/hosting-blueprint clean/updatable)
# - Fall back to editing the blueprint template (useful for local testing)
INFRA_ROOT="${INFRA_ROOT:-}"
if [ -z "${INFRA_ROOT:-}" ]; then
  if [ -d "/srv/infrastructure/reverse-proxy" ]; then
    INFRA_ROOT="/srv/infrastructure"
  else
    INFRA_ROOT="${REPO_DIR}/infra"
  fi
fi

echo ""
echo -e "${CYAN}Configuring domain: ${DOMAIN}${NC}"
echo -e "${CYAN}Hostname: ${HOSTNAME}${NC}"
echo -e "${CYAN}Target: ${INFRA_ROOT}${NC}"
echo ""

# =================================================================
# Update Caddyfile
# =================================================================
CADDYFILE="${INFRA_ROOT}/reverse-proxy/Caddyfile"
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
CLOUDFLARED_CONFIG="${INFRA_ROOT}/cloudflared/config.yml"
CLOUDFLARED_EXAMPLE="${INFRA_ROOT}/cloudflared/config.yml.example"

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

# =================================================================
# Update Netdata .env
# =================================================================
NETDATA_ENV="${INFRA_ROOT}/monitoring/.env"
NETDATA_EXAMPLE="${INFRA_ROOT}/monitoring/.env.example"

# Create .env from example if missing, then update HOSTNAME there.
if [ ! -f "$NETDATA_ENV" ]; then
  if [ -f "$NETDATA_EXAMPLE" ]; then
    cp "$NETDATA_EXAMPLE" "$NETDATA_ENV"
    echo -e "${GREEN}✓${NC} Created Netdata .env from example"
  else
    mkdir -p "$(dirname "$NETDATA_ENV")"
    echo "HOSTNAME=${HOSTNAME}" > "$NETDATA_ENV"
    echo -e "${GREEN}✓${NC} Created Netdata .env"
  fi
fi

if [ -f "$NETDATA_ENV" ]; then
  if grep -q "^HOSTNAME=" "$NETDATA_ENV"; then
    sed -i "s/^HOSTNAME=.*/HOSTNAME=${HOSTNAME}/" "$NETDATA_ENV"
  else
    echo "HOSTNAME=${HOSTNAME}" >> "$NETDATA_ENV"
  fi
  chmod 600 "$NETDATA_ENV" 2>/dev/null || true
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
echo -e "${GREEN}Domain configured! (profile: ${SETUP_PROFILE})${NC}"
echo ""

if [ "$SETUP_PROFILE" = "full-stack" ]; then
  echo "Your subdomains:"
  echo "  • app.${DOMAIN}           → Production app"
  echo "  • staging-app.${DOMAIN}   → Staging app"
  echo "  • dev-app.${DOMAIN}       → Dev app"
  echo "  • monitoring.${DOMAIN}    → Netdata (if enabled)"
  echo "  • ssh.${DOMAIN}           → SSH via tunnel"
elif [ "$SETUP_PROFILE" = "monitoring" ]; then
  echo "Your domain:"
  echo "  • ${DOMAIN}               → Main monitoring page"
  echo "  • ssh.${DOMAIN}           → SSH via tunnel"
  echo ""
  echo "Add subdomain routes with:"
  echo "  sudo /opt/hosting-blueprint/scripts/add-subdomain.sh"
else
  echo "Your domain:"
  echo "  • ${DOMAIN}               → Main page"
  echo "  • ssh.${DOMAIN}           → SSH via tunnel"
  echo ""
  echo "Add subdomain routes with:"
  echo "  sudo /opt/hosting-blueprint/scripts/add-subdomain.sh"
fi

echo ""
echo "Next steps:"
echo "  1. Add DNS records in Cloudflare (CNAME to tunnel)"
echo "  2. Reload Caddy: sudo docker compose -f ${INFRA_ROOT}/reverse-proxy/compose.yml restart"
echo ""
