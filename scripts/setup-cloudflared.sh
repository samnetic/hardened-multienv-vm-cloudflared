#!/usr/bin/env bash
# =================================================================
# Automated Cloudflare Tunnel Setup
# =================================================================
# Fully automated tunnel setup with minimal user interaction
#
# What this does:
#   1. Authenticates with Cloudflare (user clicks link)
#   2. Creates tunnel automatically
#   3. Generates config.yml with domain substitution
#   4. Routes DNS records
#   5. Installs and starts tunnel service
#   6. Verifies connectivity
#
# Usage:
#   sudo ./scripts/setup-cloudflared.sh yourdomain.com
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# =================================================================
# Helper Functions
# =================================================================

print_header() {
  echo ""
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BLUE}${BOLD} $1${NC}"
  echo -e "${BLUE}======================================================================${NC}"
  echo ""
}

print_step() {
  echo -e "${CYAN}>>> $1${NC}"
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
  echo -e "${RED}✗ $1${NC}"
}

print_info() {
  echo -e "${BLUE}ℹ $1${NC}"
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"

  if [ "$default" = "y" ]; then
    prompt="$prompt [Y/n]: "
  else
    prompt="$prompt [y/N]: "
  fi

  read -rp "$prompt" response
  response=${response:-$default}

  [[ "$response" =~ ^[Yy]$ ]]
}

# =================================================================
# Prerequisites
# =================================================================

check_root() {
  if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    echo "Run: sudo ./scripts/setup-cloudflared.sh yourdomain.com"
    exit 1
  fi
}

check_cloudflared() {
  if ! command -v cloudflared &> /dev/null; then
    print_error "cloudflared is not installed"
    echo "Run: sudo ./scripts/install-cloudflared.sh"
    exit 1
  fi
  print_success "cloudflared is installed ($(cloudflared --version | head -1))"
}

# =================================================================
# Parse Arguments
# =================================================================

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "Usage:"
  echo "  sudo $0 yourdomain.com [tunnel-name]"
  echo ""
  echo "Examples:"
  echo "  sudo $0 example.com"
  echo "  sudo $0 example.com production-tunnel"
  exit 0
fi

if [ $# -lt 1 ]; then
  print_error "Domain name required"
  echo "Usage: sudo $0 yourdomain.com"
  exit 1
fi

DOMAIN="$1"
TUNNEL_NAME="${2:-production-tunnel}"

# Detect original user (who invoked sudo)
if [ -n "${SUDO_USER:-}" ]; then
  ORIGINAL_USER="$SUDO_USER"
else
  ORIGINAL_USER="root"
fi

# Resolve home directory for ORIGINAL_USER (works for root and non-root).
ORIGINAL_HOME="$(getent passwd "$ORIGINAL_USER" 2>/dev/null | cut -d: -f6 || true)"
if [ -z "${ORIGINAL_HOME:-}" ]; then
  if [ "$ORIGINAL_USER" = "root" ]; then
    ORIGINAL_HOME="/root"
  else
    ORIGINAL_HOME="/home/$ORIGINAL_USER"
  fi
fi

# =================================================================
# Main
# =================================================================

main() {
  clear
  print_header "Cloudflare Tunnel Automated Setup"

  echo "  Domain: $DOMAIN"
  echo "  Tunnel Name: $TUNNEL_NAME"
  echo "  Original User: $ORIGINAL_USER"
  echo ""

  check_root
  check_cloudflared

  # =================================================================
  # Step 1: Authenticate with Cloudflare
  # =================================================================
  print_header "Step 1/7: Authenticate with Cloudflare"

  CERT_FILE="${ORIGINAL_HOME}/.cloudflared/cert.pem"
  if [ -f "$CERT_FILE" ]; then
    print_success "Already authenticated (cert.pem exists)"
  else
    echo "Opening browser for Cloudflare authentication..."
    echo ""
    print_warning "You will be prompted to open a URL and authorize this server"
    echo ""

    # Run as original user to save cert in their home
    su - "$ORIGINAL_USER" -c "cloudflared tunnel login"

    if [ -f "$CERT_FILE" ]; then
      print_success "Authentication successful!"
    else
      print_error "Authentication failed - cert.pem not found"
      exit 1
    fi
  fi

  # =================================================================
  # Step 2: Create Tunnel
  # =================================================================
  print_header "Step 2/7: Create Tunnel"

  # Check if tunnel already exists (exact name match; avoid substring collisions).
  TUNNEL_ID="$(su - "$ORIGINAL_USER" -c "cloudflared tunnel list" 2>/dev/null | awk -v name="$TUNNEL_NAME" '$2 == name {print $1; exit}' || true)"
  if [ -n "$TUNNEL_ID" ]; then
    print_warning "Tunnel '$TUNNEL_NAME' already exists"
    print_info "Using existing tunnel ID: $TUNNEL_ID"
  else
    print_step "Creating tunnel '$TUNNEL_NAME'..."

    # Create tunnel as original user
    TUNNEL_OUTPUT=$(su - "$ORIGINAL_USER" -c "cloudflared tunnel create $TUNNEL_NAME" 2>&1)

    # Extract tunnel ID from output
    TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | grep -oP 'Created tunnel .* with id \K[a-f0-9-]+' || true)

    if [ -z "$TUNNEL_ID" ]; then
      print_error "Failed to extract tunnel ID from output"
      echo "$TUNNEL_OUTPUT"
      exit 1
    fi

    print_success "Tunnel created with ID: $TUNNEL_ID"
  fi

  # =================================================================
  # Step 3: Install Credentials for Service
  # =================================================================
  print_header "Step 3/7: Install Tunnel Credentials"

  CREDS_FILE="${ORIGINAL_HOME}/.cloudflared/${TUNNEL_ID}.json"

  if [ ! -f "$CREDS_FILE" ]; then
    print_error "Credentials file not found: $CREDS_FILE"
    exit 1
  fi

  # Run the daemon as a locked-down system user (not root)
  CLOUD_USER="cloudflared"
  CLOUD_GROUP="cloudflared"
  if ! getent group "$CLOUD_GROUP" >/dev/null 2>&1; then
    print_step "Creating system group: $CLOUD_GROUP"
    groupadd --system "$CLOUD_GROUP"
    print_success "Created group: $CLOUD_GROUP"
  fi
  if ! id "$CLOUD_USER" >/dev/null 2>&1; then
    print_step "Creating system user: $CLOUD_USER"
    useradd --system --no-create-home --home-dir /var/lib/cloudflared --shell /usr/sbin/nologin --gid "$CLOUD_GROUP" "$CLOUD_USER"
    print_success "Created user: $CLOUD_USER"
  else
    print_success "System user exists: $CLOUD_USER"
  fi

  # Ensure state directory exists (some cloudflared builds may want a writable HOME).
  install -d -m 0750 -o "$CLOUD_USER" -g "$CLOUD_GROUP" /var/lib/cloudflared

  CONFIG_DIR="/etc/cloudflared"
  mkdir -p "$CONFIG_DIR"
  chown root:"$CLOUD_USER" "$CONFIG_DIR"
  chmod 750 "$CONFIG_DIR"

  SERVICE_CREDS_FILE="${CONFIG_DIR}/${TUNNEL_ID}.json"
  cp "$CREDS_FILE" "$SERVICE_CREDS_FILE"
  chown root:"$CLOUD_USER" "$SERVICE_CREDS_FILE"
  chmod 640 "$SERVICE_CREDS_FILE"
  print_success "Credentials installed at $SERVICE_CREDS_FILE (root:$CLOUD_USER, 640)"

  # =================================================================
  # Step 4: Generate Configuration
  # =================================================================
  print_header "Step 4/7: Generate Configuration"

  CONFIG_FILE="/etc/cloudflared/config.yml"
  mkdir -p /etc/cloudflared

  cat > "$CONFIG_FILE" << EOF
# =================================================================
# Cloudflare Tunnel Configuration
# =================================================================
# Auto-generated by setup-cloudflared.sh
# Domain: $DOMAIN
# Tunnel: $TUNNEL_NAME
# ID: $TUNNEL_ID
# =================================================================

tunnel: $TUNNEL_ID
credentials-file: $SERVICE_CREDS_FILE

ingress:
  # SSH access via tunnel
  - hostname: ssh.$DOMAIN
    service: ssh://localhost:22

  # Route all HTTP traffic to Caddy reverse proxy
  # Caddy handles subdomain routing (dev-app, staging-app, app, etc.)
  - service: http://localhost:80

protocol: quic
loglevel: info
EOF

  chown root:"$CLOUD_USER" "$CONFIG_FILE"
  chmod 640 "$CONFIG_FILE"

  print_success "Configuration created at $CONFIG_FILE"
  echo ""
  echo -e "${BLUE}Configuration:${NC}"
  cat "$CONFIG_FILE" | sed 's/^/  /'
  echo ""

  # =================================================================
  # Step 5: Route DNS Records
  # =================================================================
  print_header "Step 5/7: Route DNS Records"

  print_step "Routing ssh.$DOMAIN to tunnel..."

  # Route SSH subdomain
  route_rc=0
  route_out="$(su - "$ORIGINAL_USER" -c "cloudflared tunnel route dns $TUNNEL_NAME ssh.$DOMAIN" 2>&1)" || route_rc=$?
  if echo "$route_out" | grep -qi "already exists"; then
    print_warning "DNS route for ssh.$DOMAIN already exists"
  elif [ "$route_rc" -ne 0 ]; then
    print_error "Failed to create DNS route for ssh.$DOMAIN (exit code: $route_rc)"
    echo "$route_out"
    exit 1
  else
    print_success "DNS route created: ssh.$DOMAIN → tunnel"
  fi

  echo ""
  print_info "You can add more DNS routes manually:"
  echo "  cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN"
  echo "  cloudflared tunnel route dns $TUNNEL_NAME www.$DOMAIN"
  echo "  cloudflared tunnel route dns $TUNNEL_NAME staging-app.$DOMAIN"
  echo ""

  # =================================================================
  # Step 5.5: Configure Cloudflare SSL/TLS (Optional)
  # =================================================================
  print_header "Step 5.5/7: Configure Cloudflare SSL/TLS (Optional)"

  echo "Cloudflare API configuration allows automatic setup of SSL/TLS settings"
  echo ""
  SSL_CONFIGURED=false
  if confirm "Configure Cloudflare settings via API?" "n"; then
    # Source the Cloudflare API helper
    SCRIPT_DIR_CF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR_CF/cloudflare-api-setup.sh"

    # Setup API token (creates if needed, loads if exists)
    if setup_cloudflare_api "$DOMAIN"; then
      # Token is now in CF_API_TOKEN and Zone ID in CF_ZONE_ID (exported by setup function)

      # Configure SSL/TLS settings
      echo ""
      configure_ssl_settings "$CF_ZONE_ID" "$CF_API_TOKEN"
      SSL_CONFIGURED=true
      echo ""
      print_success "Cloudflare SSL/TLS configuration complete!"
    else
      print_warning "API setup failed, skipping SSL/TLS configuration"
    fi
  else
    print_info "Skipping Cloudflare API configuration"
    echo ""
    print_warning "Remember to set SSL/TLS mode manually:"
    echo "  Cloudflare Dashboard → SSL/TLS → Overview → Encryption mode: Full"
    echo ""
  fi

  # =================================================================
  # Step 6: Install and Start Service
  # =================================================================
  print_header "Step 6/7: Install and Start Service"

  print_step "Installing cloudflared service..."
  cloudflared service install 2>/dev/null || print_warning "Service already installed"

  print_step "Hardening cloudflared systemd unit..."
  OVERRIDE_DIR="/etc/systemd/system/cloudflared.service.d"
  mkdir -p "$OVERRIDE_DIR"
  cat > "$OVERRIDE_DIR/override.conf" <<'EOF'
[Service]
User=cloudflared
Group=cloudflared

NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectClock=yes
ProtectHostname=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
# AF_NETLINK is commonly required for querying interfaces/routes on Linux.
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

# Writable state locations (required when ProtectSystem=strict is used).
StateDirectory=cloudflared
StateDirectoryMode=0750
RuntimeDirectory=cloudflared
RuntimeDirectoryMode=0750
LogsDirectory=cloudflared
LogsDirectoryMode=0750

CapabilityBoundingSet=
AmbientCapabilities=
UMask=0077
EOF

  systemctl daemon-reload
  print_success "systemd hardening override installed"

  print_step "Starting cloudflared service..."
  systemctl enable cloudflared
  systemctl restart cloudflared

  # Wait for service to start
  sleep 3

  if systemctl is-active --quiet cloudflared; then
    print_success "Tunnel service is running"
  else
    print_error "Tunnel service failed to start"
    echo ""
    echo "Check logs:"
    echo "  sudo journalctl -u cloudflared -n 50"
    exit 1
  fi

  # =================================================================
  # Step 7: Verify Connectivity
  # =================================================================
  print_header "Step 7/7: Verify Connectivity"

  print_step "Checking tunnel status..."
  sleep 2

  # Check tunnel connections
  if journalctl -u cloudflared --since "30 seconds ago" | grep -q "registered"; then
    print_success "Tunnel is connected to Cloudflare!"
  else
    print_warning "Tunnel may still be connecting... (this can take up to 60 seconds)"
  fi

  echo ""
  print_info "View tunnel status:"
  echo "  sudo systemctl status cloudflared"
  echo "  sudo journalctl -u cloudflared -f"
  echo ""

  # =================================================================
  # Next Steps
  # =================================================================
  print_header "Setup Complete!"

  echo -e "${GREEN}✓ Cloudflare Tunnel is configured and running!${NC}"
  echo ""
  echo -e "${CYAN}Tunnel Details:${NC}"
  echo "  Name: $TUNNEL_NAME"
  echo "  ID: $TUNNEL_ID"
  echo "  SSH: ssh.$DOMAIN"
  echo ""
  echo -e "${CYAN}Next Steps:${NC}"
  echo ""
  echo -e "1. ${BOLD}Migrate DNS Records to Tunnel${NC}"
  echo "   Go to: https://dash.cloudflare.com → DNS → Records"
  echo ""
  echo -e "   ${YELLOW}⚠ SAFE MIGRATION STRATEGY (if you have existing A records):${NC}"
  echo ""
  echo -e "   ${CYAN}Step 1: Add CNAME records (alongside existing A records)${NC}"
  echo "   Type    Name    Target                              Proxy"
  echo "   ───────────────────────────────────────────────────────────"
  echo "   CNAME   @       ${TUNNEL_ID}.cfargotunnel.com      ✅"
  echo "   CNAME   www     ${TUNNEL_ID}.cfargotunnel.com      ✅"
  echo "   CNAME   *       ${TUNNEL_ID}.cfargotunnel.com      ✅"
  echo "   CNAME   ssh     ${TUNNEL_ID}.cfargotunnel.com      ✅ (already done)"
  echo ""
  echo -e "   ${CYAN}Step 2: Test tunnel access thoroughly${NC}"
  echo "   • Verify SSH via tunnel works: ssh ${DOMAIN%%.*}"
  echo "   • Test HTTP access: curl https://staging-app.$DOMAIN"
  echo "   • Confirm Caddy reverse proxy works"
  echo ""
  echo -e "   ${CYAN}Step 3: Remove old A records (ONLY after verification!)${NC}"
  echo "   • Delete A record: @ → 147.224.142.131 (or your VM IP)"
  echo "   • Delete A record: * → 147.224.142.131"
  echo ""
  echo -e "   ${GREEN}✓ Result: Zero open ports - all traffic via Cloudflare Tunnel!${NC}"
  echo -e "   ${GREEN}✓ The wildcard (*) covers ALL subdomains automatically!${NC}"
  echo -e "   ${CYAN}ℹ Cloudflare provisions FREE SSL certs for *.${DOMAIN}${NC}"
  echo -e "   ${CYAN}ℹ No manual cert management needed!${NC}"
  echo ""
  if [ "$SSL_CONFIGURED" = true ]; then
    echo -e "2. ${BOLD}SSL/TLS Configuration${NC}"
    echo "   ${GREEN}✓ Configured automatically!${NC}"
    echo "     • Full mode enabled"
    echo "     • Always Use HTTPS enabled"
    echo "     • Automatic HTTPS Rewrites enabled"
    echo ""
  else
    echo -e "2. ${BOLD}Set SSL/TLS Mode to Full${NC}"
    echo -e "   ${YELLOW}⚠ MANUAL STEP REQUIRED${NC}"
    echo "   Go to: https://dash.cloudflare.com → $DOMAIN → SSL/TLS"
    echo "   Set Encryption mode to: Full"
    echo ""
  fi
  echo -e "3. ${BOLD}Set Up Local Machine for Tunnel SSH${NC}"
  echo -e "   ${CYAN}Run this on YOUR LOCAL MACHINE (not the server):${NC}"
  echo ""
  echo "   # Automated setup for sysadmin user:"
  echo "   curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/main/scripts/setup-local-ssh.sh | bash -s -- ssh.$DOMAIN sysadmin"
  echo ""
  echo "   # For appmgr user (CI/CD):"
  echo "   curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/main/scripts/setup-local-ssh.sh | bash -s -- ssh.$DOMAIN appmgr"
  echo ""
  echo "   # Or manual installation:"
  echo "   macOS: brew install cloudflared"
  echo "   Debian/Ubuntu: install via official repo (recommended): https://pkg.cloudflare.com/cloudflared"
  echo ""
  echo -e "4. ${BOLD}Test SSH via Tunnel${NC}"
  echo "   ssh ${DOMAIN%%.*}        # Connects as sysadmin"
  echo "   ssh ${DOMAIN%%.*}-appmgr # Connects as appmgr"
  echo ""
  echo -e "5. ${BOLD}Start Caddy Reverse Proxy${NC}"
  echo "   cd /srv/infrastructure/reverse-proxy"
  echo "   sudo docker compose up -d"
  echo ""
  echo -e "6. ${BOLD}Finalize Setup (Automated - Recommended)${NC}"
  echo -e "   ${CYAN}Run the automated finalization script:${NC}"
  echo "   sudo ./scripts/finalize-tunnel.sh $DOMAIN"
  echo ""
  echo -e "   ${GREEN}This script will:${NC}"
  echo "   • Test SSH via tunnel thoroughly"
  echo "   • Migrate DNS from A records to CNAME (via API)"
  echo "   • Lock down firewall (close port 22)"
  echo "   • Verify everything works"
  echo "   • Rollback if any checks fail"
  echo ""
  echo -e "   ${YELLOW}Or manual lockdown (not recommended):${NC}"
  echo "   sudo ufw delete allow OpenSSH"
  echo "   sudo ufw delete allow 22/tcp"
  echo ""
  echo -e "${BLUE}Documentation:${NC}"
  echo "  • infra/cloudflared/tunnel-setup.md - Full setup guide"
  echo "  • docs/01-cloudflare-setup.md - Cloudflare configuration"
  echo ""
}

# Run main function
main "$@"
