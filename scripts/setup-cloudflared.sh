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

  CERT_FILE="/home/$ORIGINAL_USER/.cloudflared/cert.pem"
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

  # Check if tunnel already exists
  EXISTING_TUNNEL=$(su - "$ORIGINAL_USER" -c "cloudflared tunnel list" 2>/dev/null | grep "$TUNNEL_NAME" || true)

  if [ -n "$EXISTING_TUNNEL" ]; then
    print_warning "Tunnel '$TUNNEL_NAME' already exists"
    TUNNEL_ID=$(echo "$EXISTING_TUNNEL" | awk '{print $1}')
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
  # Step 3: Copy Credentials to Root
  # =================================================================
  print_header "Step 3/7: Copy Credentials"

  CREDS_FILE="/home/$ORIGINAL_USER/.cloudflared/${TUNNEL_ID}.json"
  ROOT_CREDS_FILE="/root/.cloudflared/${TUNNEL_ID}.json"

  if [ ! -f "$CREDS_FILE" ]; then
    print_error "Credentials file not found: $CREDS_FILE"
    exit 1
  fi

  mkdir -p /root/.cloudflared
  cp "$CREDS_FILE" "$ROOT_CREDS_FILE"
  chmod 600 "$ROOT_CREDS_FILE"
  print_success "Credentials copied to $ROOT_CREDS_FILE"

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
credentials-file: $ROOT_CREDS_FILE

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
  if su - "$ORIGINAL_USER" -c "cloudflared tunnel route dns $TUNNEL_NAME ssh.$DOMAIN" 2>&1 | grep -q "already exists"; then
    print_warning "DNS route for ssh.$DOMAIN already exists"
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
  # Step 6: Install and Start Service
  # =================================================================
  print_header "Step 6/7: Install and Start Service"

  print_step "Installing cloudflared service..."
  cloudflared service install 2>/dev/null || print_warning "Service already installed"

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
  echo -e "1. ${BOLD}Configure DNS in Cloudflare Dashboard${NC}"
  echo "   Go to: https://dash.cloudflare.com"
  echo "   DNS → Records → Add these CNAME records:"
  echo ""
  echo "   Type    Name           Target                              Proxy"
  echo "   ────────────────────────────────────────────────────────────────"
  echo "   CNAME   @              ${TUNNEL_ID}.cfargotunnel.com      ✅"
  echo "   CNAME   www            ${TUNNEL_ID}.cfargotunnel.com      ✅"
  echo "   CNAME   *              ${TUNNEL_ID}.cfargotunnel.com      ✅"
  echo "   CNAME   ssh            ${TUNNEL_ID}.cfargotunnel.com      ✅ (already created)"
  echo ""
  echo -e "2. ${BOLD}Set SSL/TLS Mode to Flexible${NC}"
  echo "   SSL/TLS → Overview → Encryption mode: Flexible"
  echo ""
  echo -e "3. ${BOLD}Install cloudflared on Your Local Machine${NC}"
  echo "   macOS: brew install cloudflared"
  echo "   Ubuntu: See scripts/install-cloudflared.sh"
  echo ""
  echo -e "4. ${BOLD}Configure Local SSH Config${NC}"
  echo "   Edit ~/.ssh/config:"
  echo ""
  echo "   Host $DOMAIN"
  echo "     HostName ssh.$DOMAIN"
  echo "     User sysadmin"
  echo "     ProxyCommand cloudflared access ssh --hostname ssh.$DOMAIN"
  echo ""
  echo -e "5. ${BOLD}Test SSH via Tunnel${NC}"
  echo "   ssh $DOMAIN"
  echo ""
  echo -e "6. ${BOLD}Start Caddy Reverse Proxy${NC}"
  echo "   cd /opt/hosting-blueprint/infra/reverse-proxy"
  echo "   docker compose up -d"
  echo ""
  echo -e "7. ${BOLD}Lock Down Firewall (After Testing!)${NC}"
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
