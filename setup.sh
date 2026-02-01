#!/usr/bin/env bash
# =================================================================
# Hardened Multi-Environment VPS Setup
# =================================================================
# Interactive setup script for Ubuntu 22.04/24.04 servers
#
# This script will:
#   1. Check prerequisites (OS, RAM, disk)
#   2. Collect configuration (domain, SSH keys)
#   3. Run all hardening and setup scripts
#   4. Save configuration for future reference
#
# Usage:
#   sudo ./setup.sh
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

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/opt/vm-config"
CONFIG_FILE="${CONFIG_DIR}/setup.conf"

# Detect original user (who invoked sudo)
if [ -n "${SUDO_USER:-}" ]; then
  ORIGINAL_USER="$SUDO_USER"
else
  ORIGINAL_USER="$(whoami)"
fi

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

# Validate SSH public key format
validate_ssh_key() {
  local key="$1"
  # Must start with a valid key type followed by space
  if [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-dss)[[:space:]] ]]; then
    return 0
  fi
  return 1
}

# Validate timezone exists
validate_timezone() {
  local tz="$1"
  if [ -f "/usr/share/zoneinfo/${tz}" ]; then
    return 0
  fi
  return 1
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
# Prerequisite Checks
# =================================================================

check_root() {
  if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    echo "Run: sudo ./setup.sh"
    exit 1
  fi
}

check_os() {
  print_step "Checking operating system..."

  if [ ! -f /etc/os-release ]; then
    print_error "Cannot detect operating system"
    exit 1
  fi

  . /etc/os-release

  if [ "$ID" != "ubuntu" ]; then
    print_error "This script is designed for Ubuntu. Detected: $ID"
    exit 1
  fi

  case "$VERSION_ID" in
    "22.04"|"24.04")
      print_success "Ubuntu $VERSION_ID detected"
      ;;
    *)
      print_warning "Ubuntu $VERSION_ID detected. Tested on 22.04 and 24.04 only."
      if ! confirm "Continue anyway?"; then
        exit 1
      fi
      ;;
  esac
}

check_resources() {
  print_step "Checking system resources..."

  # Check RAM (minimum 2GB, recommended 4GB)
  local ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local ram_gb=$((ram_kb / 1024 / 1024))

  if [ "$ram_gb" -lt 2 ]; then
    print_error "Minimum 2GB RAM required. Detected: ${ram_gb}GB"
    exit 1
  elif [ "$ram_gb" -lt 4 ]; then
    print_warning "4GB RAM recommended for production. Detected: ${ram_gb}GB"
  else
    print_success "RAM: ${ram_gb}GB"
  fi

  # Check disk (minimum 20GB, recommended 40GB)
  local disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')

  if [ "$disk_gb" -lt 20 ]; then
    print_error "Minimum 20GB free disk space required. Available: ${disk_gb}GB"
    exit 1
  elif [ "$disk_gb" -lt 40 ]; then
    print_warning "40GB recommended for production. Available: ${disk_gb}GB"
  else
    print_success "Disk: ${disk_gb}GB available"
  fi
}

check_network() {
  print_step "Checking network connectivity..."

  # Try multiple endpoints (using curl instead of ping for Oracle Cloud compatibility)
  local TEST_URLS=("https://www.cloudflare.com" "https://www.google.com" "https://www.github.com")
  local CONNECTED=false

  for url in "${TEST_URLS[@]}"; do
    if curl -s --connect-timeout 5 "$url" > /dev/null 2>&1; then
      CONNECTED=true
      break
    fi
  done

  if [ "$CONNECTED" != "true" ]; then
    print_error "No internet connectivity (tried ${TEST_URLS[*]})"
    exit 1
  fi
  print_success "Network connected"
}

fix_repo_ownership() {
  print_step "Fixing repository ownership..."

  # Fix ownership if this is a git repo and we know the original user
  if [ -d "${SCRIPT_DIR}/.git" ] && [ -n "${ORIGINAL_USER:-}" ] && [ "$ORIGINAL_USER" != "root" ]; then
    chown -R "${ORIGINAL_USER}:${ORIGINAL_USER}" "${SCRIPT_DIR}"
    print_success "Repository ownership set to $ORIGINAL_USER"
  fi
}

# =================================================================
# Configuration Collection
# =================================================================

collect_config() {
  print_header "Configuration"

  # Domain
  echo ""
  echo "Enter your domain name (e.g., example.com)"
  echo "This will be used for app subdomains like app.example.com"
  read -rp "Domain: " DOMAIN
  while [ -z "$DOMAIN" ]; do
    print_warning "Domain is required"
    read -rp "Domain: " DOMAIN
  done

  # SSH Public Key
  echo ""
  echo "Paste your SSH public key for the sysadmin user"
  echo "(The key starting with 'ssh-ed25519' or 'ssh-rsa')"
  read -rp "SSH Public Key: " SYSADMIN_SSH_KEY
  while [ -z "$SYSADMIN_SSH_KEY" ]; do
    print_warning "SSH key is required for secure access"
    read -rp "SSH Public Key: " SYSADMIN_SSH_KEY
  done
  # Validate SSH key format
  if ! validate_ssh_key "$SYSADMIN_SSH_KEY"; then
    print_error "Invalid SSH key format. Key must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*"
    echo "Example: ssh-ed25519 AAAAC3NzaC1... user@host"
    exit 1
  fi
  print_success "SSH key format validated"

  # Appmgr SSH Key (optional)
  echo ""
  echo "SSH key for appmgr user (for CI/CD deployments)"
  echo "Leave empty to skip (you can add later)"
  read -rp "Appmgr SSH Key (optional): " APPMGR_SSH_KEY
  # Validate if provided
  if [ -n "$APPMGR_SSH_KEY" ]; then
    if ! validate_ssh_key "$APPMGR_SSH_KEY"; then
      print_error "Invalid SSH key format for appmgr. Key must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-*"
      exit 1
    fi
    print_success "Appmgr SSH key format validated"
  fi

  # Timezone
  echo ""
  echo "Enter your timezone (e.g., UTC, America/New_York, Europe/London)"
  echo "Run 'timedatectl list-timezones' to see all valid options."
  read -rp "Timezone [UTC]: " TIMEZONE
  TIMEZONE=${TIMEZONE:-UTC}
  # Validate timezone exists
  if ! validate_timezone "$TIMEZONE"; then
    print_error "Invalid timezone: $TIMEZONE"
    echo "Run 'timedatectl list-timezones' to see valid options."
    exit 1
  fi
  print_success "Timezone validated: $TIMEZONE"

  # Cloudflared setup
  echo ""
  echo "Do you want to set up Cloudflare Tunnel now?"
  echo "You'll need a Cloudflare account and a domain configured there."
  if confirm "Set up Cloudflare Tunnel?"; then
    SETUP_CLOUDFLARED="yes"
  else
    SETUP_CLOUDFLARED="no"
  fi

  # Cloudflare Access (Zero Trust) info
  echo ""
  echo "Cloudflare Access (Zero Trust) can protect admin panels with a login screen."
  echo "This is configured in the Cloudflare dashboard after setup."
  echo "See docs/14-cloudflare-zero-trust.md for the guide."
  SETUP_ACCESS_INFO="shown"

  # Confirmation
  print_header "Configuration Summary"
  echo "  Domain:            $DOMAIN"
  echo "  Sysadmin SSH Key:  ${SYSADMIN_SSH_KEY:0:40}..."
  echo "  Appmgr SSH Key:    ${APPMGR_SSH_KEY:+${APPMGR_SSH_KEY:0:40}...}"
  echo "  Timezone:          $TIMEZONE"
  echo "  Cloudflared:       $SETUP_CLOUDFLARED"
  echo ""

  if ! confirm "Proceed with this configuration?" "y"; then
    print_error "Setup cancelled"
    exit 1
  fi

  # Save configuration
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" << EOF
# VM Configuration - Generated $(date)
DOMAIN="$DOMAIN"
TIMEZONE="$TIMEZONE"
SETUP_CLOUDFLARED="$SETUP_CLOUDFLARED"
SYSADMIN_SSH_KEY="$SYSADMIN_SSH_KEY"
APPMGR_SSH_KEY="$APPMGR_SSH_KEY"
SETUP_DATE="$(date -Iseconds)"
EOF

  chmod 600 "$CONFIG_FILE"
  print_success "Configuration saved to $CONFIG_FILE"
}

# =================================================================
# Main Setup
# =================================================================

run_setup() {
  print_header "Running Setup"

  # Export variables for scripts
  export DOMAIN
  export TIMEZONE
  export SYSADMIN_SSH_KEY
  export APPMGR_SSH_KEY

  # Step 1: VM Setup (hardening, users, Docker)
  print_step "Step 1/5: VM Hardening & Docker Setup"
  if [ -x "${SCRIPT_DIR}/scripts/setup-vm.sh" ]; then
    bash "${SCRIPT_DIR}/scripts/setup-vm.sh"
    print_success "VM setup complete"
  else
    print_error "setup-vm.sh not found or not executable"
    exit 1
  fi

  # Step 2: Configure Domain
  print_step "Step 2/5: Configuring Domain"
  if [ -x "${SCRIPT_DIR}/scripts/configure-domain.sh" ]; then
    bash "${SCRIPT_DIR}/scripts/configure-domain.sh" "$DOMAIN"
    print_success "Domain configured: $DOMAIN"
  else
    # Fallback: manual sed replacement
    if [ -f "${SCRIPT_DIR}/infra/reverse-proxy/Caddyfile" ]; then
      if grep -q "yourdomain.com" "${SCRIPT_DIR}/infra/reverse-proxy/Caddyfile"; then
        sed -i "s/yourdomain.com/${DOMAIN}/g" "${SCRIPT_DIR}/infra/reverse-proxy/Caddyfile"
        print_success "Updated Caddyfile with domain: $DOMAIN"
      else
        print_warning "Caddyfile doesn't contain 'yourdomain.com' placeholder - may already be configured"
      fi
    else
      print_warning "Caddyfile not found at ${SCRIPT_DIR}/infra/reverse-proxy/Caddyfile"
    fi
  fi

  # Step 3: Docker Networks
  print_step "Step 3/5: Creating Docker Networks"
  if [ -x "${SCRIPT_DIR}/scripts/create-networks.sh" ]; then
    bash "${SCRIPT_DIR}/scripts/create-networks.sh"
    print_success "Networks created"
  else
    print_warning "create-networks.sh not found, skipping"
  fi

  # Step 4: Cloudflared (optional)
  if [ "$SETUP_CLOUDFLARED" = "yes" ]; then
    print_step "Step 4/5: Cloudflare Tunnel Setup"
    if [ -x "${SCRIPT_DIR}/scripts/install-cloudflared.sh" ]; then
      echo ""
      echo "The cloudflared setup will guide you through authentication."
      echo "You'll need to log in to Cloudflare in your browser."
      echo ""
      if confirm "Ready to set up cloudflared?"; then
        bash "${SCRIPT_DIR}/scripts/install-cloudflared.sh"
        print_success "Cloudflared setup complete"
      else
        print_warning "Cloudflared setup skipped"
      fi
    else
      print_warning "install-cloudflared.sh not found, skipping"
    fi
  else
    print_step "Step 4/5: Cloudflared Setup (skipped)"
  fi

  # Step 5: Reverse Proxy
  print_step "Step 5/5: Starting Reverse Proxy"

  # Start Caddy if compose file exists
  if [ -f "${SCRIPT_DIR}/infra/reverse-proxy/compose.yml" ]; then
    cd "${SCRIPT_DIR}/infra/reverse-proxy"
    docker compose up -d
    print_success "Caddy reverse proxy started"
    cd "$SCRIPT_DIR"
  else
    print_warning "Reverse proxy compose.yml not found"
  fi
}

# =================================================================
# Post-Setup Instructions
# =================================================================

print_next_steps() {
  print_header "Setup Complete!"

  echo -e "${GREEN}Your hardened VPS is ready!${NC}"
  echo ""
  echo "Configuration saved to: $CONFIG_FILE"
  echo ""

  echo -e "${CYAN}Next Steps:${NC}"
  echo ""
  echo -e "${YELLOW}⚠️  IMPORTANT: Run the verification script!${NC}"
  echo ""
  echo "1. ${BOLD}Verify Setup & Test SSH${NC}"
  echo "   ./scripts/verify-setup.sh"
  echo "   ${CYAN}(This will guide you through SSH testing and user management)${NC}"
  echo ""

  if [ "$SETUP_CLOUDFLARED" = "yes" ]; then
    echo "2. ${BOLD}Configure Cloudflare Tunnel${NC}"
    echo "   - Add DNS CNAME records in Cloudflare dashboard"
    echo "   - Point subdomains to your tunnel"
    echo ""
  else
    echo "2. ${BOLD}Set Up Cloudflare Tunnel${NC}"
    echo "   ./scripts/install-cloudflared.sh"
    echo ""
  fi

  echo "3. ${BOLD}Create Your First App${NC}"
  echo "   cp -r apps/_template apps/myapp"
  echo "   cd apps/myapp"
  echo "   # Edit compose.yml and .env"
  echo "   docker compose up -d"
  echo ""

  echo "4. ${BOLD}Create Secrets${NC}"
  echo "   ./scripts/secrets/create-secret.sh dev db_password"
  echo "   ./scripts/secrets/create-secret.sh staging db_password"
  echo "   ./scripts/secrets/create-secret.sh production db_password"
  echo ""

  echo "5. ${BOLD}Set Up GitHub Actions${NC}"
  echo "   - Fork this repo to your GitHub account"
  echo "   - Add secrets in Settings > Secrets and variables > Actions:"
  echo "     - SSH_PRIVATE_KEY"
  echo "     - SSH_HOST (ssh.${DOMAIN})"
  echo "     - SSH_USER (appmgr)"
  echo "     - CF_SERVICE_TOKEN_ID"
  echo "     - CF_SERVICE_TOKEN_SECRET"
  echo ""

  echo "6. ${BOLD}Protect Admin Panels (Zero Trust)${NC}"
  echo "   - Go to Cloudflare Zero Trust dashboard"
  echo "   - Access > Applications > Add self-hosted app"
  echo "   - Create policies for: monitoring.${DOMAIN}, admin panels"
  echo "   - See docs/14-cloudflare-zero-trust.md for full guide"
  echo ""

  echo -e "${CYAN}Useful Commands:${NC}"
  echo ""
  echo "  # System status"
  echo "  ./scripts/monitoring/status.sh"
  echo ""
  echo "  # View logs"
  echo "  ./scripts/monitoring/logs.sh"
  echo ""
  echo "  # Disk usage"
  echo "  ./scripts/monitoring/disk-usage.sh"
  echo ""
  echo "  # List secrets"
  echo "  ./scripts/secrets/list-secrets.sh"
  echo ""

  echo -e "${CYAN}Documentation:${NC}"
  echo "  See README.md and docs/ folder for detailed guides"
  echo ""
}

# =================================================================
# Main
# =================================================================

main() {
  print_header "Hardened Multi-Environment VPS Setup"

  echo "This script will set up a production-ready, hardened Ubuntu server with:"
  echo "  • Security hardening (SSH, firewall, fail2ban, kernel)"
  echo "  • Docker with secure defaults"
  echo "  • Three environments (dev, staging, production)"
  echo "  • Cloudflare Tunnel for zero exposed ports"
  echo "  • Automated maintenance and updates"
  echo ""

  if ! confirm "Continue with setup?" "y"; then
    echo "Setup cancelled"
    exit 0
  fi

  # Run checks
  check_root
  check_os
  check_resources
  check_network
  fix_repo_ownership

  # Collect configuration
  collect_config

  # Run setup
  run_setup

  # Print next steps
  print_next_steps
}

# Run main function
main "$@"
