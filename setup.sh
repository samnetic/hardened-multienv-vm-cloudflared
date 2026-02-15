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
#   sudo ./setup.sh --force   # re-run (does not delete state; skips completed steps)
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
STATE_FILE="${CONFIG_DIR}/setup.state"
COMPLETE_FILE="${CONFIG_DIR}/setup.complete"
LEGACY_COMPLETE_FILE="/opt/hosting-blueprint/.vm-setup-complete"

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

print_info() {
  echo -e "${BLUE}ℹ $1${NC}"
}

# Validate SSH public key format
validate_ssh_key() {
  local key="$1"
  # Must start with a valid key type followed by space
  if [[ "$key" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]]; then
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

# Validate a DNS zone/domain (base domain) for Cloudflare.
validate_domain() {
  local d="$1"

  # Trim whitespace
  d="$(echo "$d" | xargs)"

  # Reject schemes/paths/spaces
  if [[ "$d" == *"://"* ]] || [[ "$d" == */* ]] || [[ "$d" =~ [[:space:]] ]]; then
    return 1
  fi

  # Must contain at least one dot.
  if [[ "$d" != *.* ]]; then
    return 1
  fi

  # Labels: start/end alnum, allow hyphens in middle.
  if [[ ! "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
    return 1
  fi

  return 0
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

usage() {
  cat <<EOF
Usage:
  sudo ./setup.sh [--force]

Options:
  --force   Re-run setup even if it was marked complete. Uses the saved config/state.
  --help    Show this help.
EOF
}

# =================================================================
# Step Tracking Functions (for resumable setup)
# =================================================================

# Initialize state tracking
init_state() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" << EOF
# Setup State - Generated $(date)
# This file tracks completed steps for resumable setup
EOF
    chmod 600 "$STATE_FILE"
  fi
}

# Check if a step is completed
is_step_completed() {
  local step_name="$1"
  if [ -f "$STATE_FILE" ]; then
    grep -q "^${step_name}=completed" "$STATE_FILE" 2>/dev/null
    return $?
  fi
  return 1
}

# Get step status string (completed|skipped|empty)
get_step_status() {
  local step_name="$1"
  if [ -f "$STATE_FILE" ]; then
    grep -E "^${step_name}=" "$STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2- || true
  fi
}

# Mark a step as completed
mark_step_completed() {
  local step_name="$1"
  init_state
  # Remove any existing entry for this step
  sed -i "/^${step_name}=/d" "$STATE_FILE" 2>/dev/null || true
  # Add completed status
  echo "${step_name}=completed" >> "$STATE_FILE"
  print_success "Step marked complete: $step_name"
}

mark_step_skipped() {
  local step_name="$1"
  init_state
  sed -i "/^${step_name}=/d" "$STATE_FILE" 2>/dev/null || true
  echo "${step_name}=skipped" >> "$STATE_FILE"
  print_warning "Step marked skipped: $step_name"
}

# Get completed steps count
get_completed_steps() {
  if [ -f "$STATE_FILE" ]; then
    grep -c "=completed" "$STATE_FILE" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Load saved configuration
load_saved_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # Source the config file to load variables
    set +u  # Temporarily allow undefined variables
    source "$CONFIG_FILE"
    set -u
    return 0
  fi
  return 1
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
  print_step "Ensuring blueprint permissions..."

  # Security: keep the blueprint root-owned.
  # Root will execute these scripts; do not make them writable by non-root.
  #
  # For local/dev checkouts (not under /opt/hosting-blueprint), we skip to avoid
  # surprising ownership changes.
  if [ -d "${SCRIPT_DIR}/.git" ] && [[ "${SCRIPT_DIR}" == "/opt/hosting-blueprint" ]]; then
    chown -R root:root "${SCRIPT_DIR}" 2>/dev/null || true
    chmod -R go-w "${SCRIPT_DIR}" 2>/dev/null || true
    print_success "Blueprint secured at ${SCRIPT_DIR} (root-owned)"
  else
    print_info "Skipping blueprint permission hardening (not running from /opt/hosting-blueprint)"
  fi
}

# =================================================================
# Configuration Collection
# =================================================================

collect_config() {
  # Check if we're resuming
  local resuming=false
  if load_saved_config; then
    resuming=true
    local completed=$(get_completed_steps)
    print_header "Resuming Setup"
    echo ""
    print_info "Found existing configuration from $(date -d "${SETUP_DATE:-unknown}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 'previous run')"
    print_info "Completed steps: $completed/5"
    echo ""
    print_info "Current configuration:"
    echo "  Domain:       ${DOMAIN:-not set}"
    echo "  Profile:      ${SETUP_PROFILE:-full-stack}"
    echo "  Timezone:     ${TIMEZONE:-not set}"
    echo "  Sysadmin sudo: ${SYSADMIN_SUDO_MODE:-not set}"
    echo "  Cloudflared:  ${SETUP_CLOUDFLARED:-not set}"
    echo ""
    if confirm "Use this configuration and continue?" "y"; then
      print_success "Resuming with saved configuration"
      return 0
    else
      print_warning "Starting fresh configuration..."
      resuming=false
    fi
  fi

  print_header "Configuration"

  # Domain
  echo ""
  echo "Enter your domain name (e.g., yourdomain.com)"
  echo "This will be used for app subdomains like app.yourdomain.com"
  if [ "$resuming" = true ] && [ -n "${DOMAIN:-}" ]; then
    read -rp "Domain [$DOMAIN]: " domain_input
    DOMAIN=${domain_input:-$DOMAIN}
  else
    read -rp "Domain: " DOMAIN
    while [ -z "$DOMAIN" ]; do
      print_warning "Domain is required"
      read -rp "Domain: " DOMAIN
    done
  fi
  DOMAIN="$(echo "$DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')"
  while ! validate_domain "$DOMAIN"; do
    print_error "Invalid domain: '$DOMAIN'"
    print_info "Enter a domain like: example.com or monitoring.example.com (no http://, no paths)"
    read -rp "Domain: " DOMAIN
    DOMAIN="$(echo "$DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')"
  done

  # Domain confirmation (double-check to avoid typos)
  echo ""
  echo -e "${YELLOW}Please re-enter your domain to confirm (typos here are costly!):${NC}"
  read -rp "Confirm domain: " DOMAIN_CONFIRM
  DOMAIN_CONFIRM="$(echo "$DOMAIN_CONFIRM" | xargs | tr '[:upper:]' '[:lower:]')"
  while [ "$DOMAIN_CONFIRM" != "$DOMAIN" ]; do
    print_error "Domains don't match!"
    echo "  You entered:     $DOMAIN"
    echo "  Confirmation:    $DOMAIN_CONFIRM"
    echo ""
    echo "Enter the domain name again:"
    read -rp "Domain: " DOMAIN
    DOMAIN="$(echo "$DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')"
    while ! validate_domain "$DOMAIN"; do
      print_error "Invalid domain: '$DOMAIN'"
      read -rp "Domain: " DOMAIN
      DOMAIN="$(echo "$DOMAIN" | xargs | tr '[:upper:]' '[:lower:]')"
    done
    echo ""
    read -rp "Confirm domain: " DOMAIN_CONFIRM
    DOMAIN_CONFIRM="$(echo "$DOMAIN_CONFIRM" | xargs | tr '[:upper:]' '[:lower:]')"
  done
  print_success "Domain confirmed: $DOMAIN"

  # Server Profile
  echo ""
  echo "What type of server are you setting up?"
  echo ""
  echo "  1) Full Stack  - Multi-environment (dev/staging/prod) with app deployment"
  echo "                   Creates isolated networks and directories for each environment."
  echo ""
  echo "  2) Monitoring  - Prometheus, Grafana, alerting server"
  echo "                   No app environments. Monitors other servers."
  echo ""
  echo "  3) Minimal     - Just hardening + Cloudflare Tunnel"
  echo "                   Add services manually later. Good for single-purpose servers."
  echo ""
  read -rp "Server profile [1]: " profile_choice
  profile_choice="${profile_choice:-1}"
  case "$profile_choice" in
    1) SETUP_PROFILE="full-stack" ;;
    2) SETUP_PROFILE="monitoring" ;;
    3) SETUP_PROFILE="minimal" ;;
    *)
      print_error "Invalid choice: $profile_choice"
      exit 1
      ;;
  esac
  print_success "Server profile: $SETUP_PROFILE"

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
    print_error "Invalid SSH key format."
    echo "Expected prefixes: ssh-ed25519, sk-ssh-ed25519@openssh.com, ssh-rsa, ecdsa-sha2-*, sk-ecdsa-sha2-nistp256@openssh.com"
    echo "Example: ssh-ed25519 AAAAC3NzaC1... user@host"
    exit 1
  fi
  print_success "SSH key format validated"

  # Sysadmin sudo mode
  echo ""
  echo "Sysadmin sudo hardening:"
  echo "  • Recommended: require a password for sudo (SSH remains key-only)"
  echo "  • Convenience: passwordless sudo (faster, but higher risk if key is compromised)"
  echo ""
  if confirm "Require password for sysadmin sudo? (recommended)" "y"; then
    SYSADMIN_SUDO_MODE="password"
  else
    SYSADMIN_SUDO_MODE="nopasswd"
  fi

  # Appmgr SSH Key (CI/CD)
  echo ""
  echo "SSH key for appmgr user (CI/CD deployments)"
  echo ""
  echo -e "${YELLOW}Security note:${NC} appmgr is a CI-only account restricted via SSH ForceCommand."
  echo "Compromise of this key can still trigger deployments, so use a dedicated deploy key for CI."
  echo ""
  echo "Options:"
  echo "  1) Paste a dedicated appmgr key (recommended)"
  echo "  2) Reuse sysadmin key for appmgr (restricted; less secure)"
  echo "  3) Skip for now (add later before enabling GitOps)"
  echo ""
  read -rp "Choice [1]: " APPMGR_KEY_CHOICE
  APPMGR_KEY_CHOICE="${APPMGR_KEY_CHOICE:-1}"

  case "$APPMGR_KEY_CHOICE" in
    1)
      read -rp "Appmgr SSH Key: " APPMGR_SSH_KEY
      while [ -z "$APPMGR_SSH_KEY" ]; do
        print_warning "Appmgr SSH key cannot be empty for this option"
        read -rp "Appmgr SSH Key: " APPMGR_SSH_KEY
      done
      if ! validate_ssh_key "$APPMGR_SSH_KEY"; then
        print_error "Invalid SSH key format for appmgr."
        echo "Expected prefixes: ssh-ed25519, sk-ssh-ed25519@openssh.com, ssh-rsa, ecdsa-sha2-*, sk-ecdsa-sha2-nistp256@openssh.com"
        exit 1
      fi
      print_success "Appmgr SSH key format validated"
      ;;
    2)
      APPMGR_SSH_KEY="$SYSADMIN_SSH_KEY"
      print_warning "Reusing sysadmin key for appmgr (restricted) - consider a dedicated CI key instead"
      ;;
    3)
      APPMGR_SSH_KEY=""
      print_info "Skipping appmgr SSH key for now"
      ;;
    *)
      print_error "Invalid choice: $APPMGR_KEY_CHOICE"
      exit 1
      ;;
  esac

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
  local appmgr_key_summary="(skipped)"
  if [ -n "${APPMGR_SSH_KEY:-}" ]; then
    if [ "$APPMGR_SSH_KEY" = "$SYSADMIN_SSH_KEY" ]; then
      appmgr_key_summary="(reuse sysadmin key)"
    else
      appmgr_key_summary="${APPMGR_SSH_KEY:0:40}..."
    fi
  fi
  echo "  Domain:            $DOMAIN"
  echo "  Server profile:    $SETUP_PROFILE"
  echo "  Sysadmin SSH Key:  ${SYSADMIN_SSH_KEY:0:40}..."
  echo "  Appmgr SSH Key:    $appmgr_key_summary"
  echo "  Timezone:          $TIMEZONE"
  echo "  Sysadmin sudo:     $SYSADMIN_SUDO_MODE"
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
SETUP_PROFILE="$SETUP_PROFILE"
TIMEZONE="$TIMEZONE"
SETUP_CLOUDFLARED="$SETUP_CLOUDFLARED"
SYSADMIN_SUDO_MODE="$SYSADMIN_SUDO_MODE"
SYSADMIN_SSH_KEY="$SYSADMIN_SSH_KEY"
APPMGR_SSH_KEY="$APPMGR_SSH_KEY"
SETUP_DATE="$(date -Iseconds)"
EOF

  chmod 600 "$CONFIG_FILE"
  print_success "Configuration saved to $CONFIG_FILE"
}

# =================================================================
# Profile-Aware Configuration Generators
# =================================================================

generate_minimal_caddyfile() {
  local domain="$1"
  local profile="$2"
  local output_file="$3"

  cat > "$output_file" << CADDYEOF
# =================================================================
# Caddyfile - HTTP Reverse Proxy for Cloudflare Tunnel
# =================================================================
# Profile: ${profile}
# Domain: ${domain}
# Generated: $(date)
#
# Add new subdomain routes with:
#   sudo /opt/hosting-blueprint/scripts/add-subdomain.sh
# =================================================================

# Global Options
{
  auto_https off
  admin off
}

# =================================================================
# Reusable Snippets
# =================================================================

(security_headers) {
  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Frame-Options "DENY"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "strict-origin-when-cross-origin"
    Permissions-Policy "geolocation=(), microphone=(), camera=()"
    -Server
  }
}

(proxy_headers) {
  header_up X-Real-IP {http.request.header.CF-Connecting-IP}
  header_up X-Forwarded-For {http.request.header.CF-Connecting-IP}
  header_up X-Forwarded-Proto https
  header_up X-Forwarded-Host {host}
  header_up -x-middleware-subrequest
  header_up -x-middleware-invoke
  header_up -x-middleware-next
  header_up -x-invoke-path
  header_up -x-invoke-query
  header_up -x-invoke-output
  header_up -x-invoke-status
}

(tunnel_only) {
  @not_tunnel not remote_ip 127.0.0.1 ::1 10.250.0.1
  respond @not_tunnel 403
}

# =================================================================
# BASE DOMAIN
# =================================================================

http://${domain} {
  import tunnel_only
  import security_headers
  respond "Server is running on ${domain}" 200
}

CADDYEOF

  # Add profile-specific commented blocks
  if [ "$profile" = "monitoring" ]; then
    # Extract parent domain for subdomain suggestions
    # e.g., monitoring.example.com -> example.com
    local parent_domain="$domain"
    if [[ "$domain" == *.*.* ]]; then
      parent_domain="${domain#*.}"
    fi

    cat >> "$output_file" << CADDYEOF
# =================================================================
# MONITORING SERVICES
# =================================================================
# Add routes as you deploy services. Use the add-subdomain script:
#   sudo /opt/hosting-blueprint/scripts/add-subdomain.sh
#
# Or uncomment and edit the blocks below:
# =================================================================

# Grafana - Dashboards & Visualization
# http://grafana.${parent_domain} {
#   import tunnel_only
#   import security_headers
#   reverse_proxy grafana:3000 {
#     import proxy_headers
#   }
# }

# Prometheus - Metrics & Alerting
# http://prometheus.${parent_domain} {
#   import tunnel_only
#   import security_headers
#   reverse_proxy prometheus:9090 {
#     import proxy_headers
#   }
# }

# Alertmanager
# http://alertmanager.${parent_domain} {
#   import tunnel_only
#   import security_headers
#   reverse_proxy alertmanager:9093 {
#     import proxy_headers
#   }
# }

CADDYEOF
  fi

  # Always add wildcard catch-all at the end
  cat >> "$output_file" << CADDYEOF
# =================================================================
# WILDCARD CATCH-ALL (404 for unconfigured subdomains)
# =================================================================

http://*.${domain} {
  import tunnel_only
  import security_headers
  respond "This subdomain is not configured yet" 404
}
CADDYEOF

  chmod 644 "$output_file"
}

generate_minimal_compose() {
  local profile="$1"
  local output_file="$2"

  cat > "$output_file" << 'COMPOSEEOF'
# =================================================================
# Caddy Reverse Proxy - Docker Compose Configuration
# =================================================================
# Cloudflare Tunnel handles HTTPS; Caddy runs HTTP only
# =================================================================

services:
  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    init: true
    stop_grace_period: 30s

    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:size=64M,mode=1777

    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 256M
          pids: 100
        reservations:
          cpus: '0.1'
          memory: 64M

    healthcheck:
      test: ["CMD", "caddy", "validate", "--config", "/etc/caddy/Caddyfile"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

    environment:
      - DOMAIN=${DOMAIN:-yourdomain.com}

    ports:
      - "127.0.0.1:80:80"

    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

    networks:
      - caddy-origin
      - monitoring

volumes:
  caddy_data:
    name: caddy_data
  caddy_config:
    name: caddy_config

networks:
  caddy-origin:
    external: true
    name: hosting-caddy-origin
  monitoring:
    external: true
COMPOSEEOF

  chmod 644 "$output_file"
}

# =================================================================
# Main Setup
# =================================================================

run_setup() {
  print_header "Running Setup"

  # Initialize state tracking
  init_state

  # Export variables for scripts
  export DOMAIN
  export SETUP_PROFILE="${SETUP_PROFILE:-full-stack}"
  export TIMEZONE
  export SYSADMIN_SSH_KEY
  export APPMGR_SSH_KEY
  export SYSADMIN_SUDO_MODE

  # Step 1: VM Setup (hardening, users, Docker)
  if is_step_completed "vm_setup"; then
    print_success "Step 1/5: VM Hardening & Docker Setup (already completed)"
  else
    print_step "Step 1/5: VM Hardening & Docker Setup"
    if [ -x "${SCRIPT_DIR}/scripts/setup-vm.sh" ]; then
      bash "${SCRIPT_DIR}/scripts/setup-vm.sh"
      mark_step_completed "vm_setup"
    else
      print_error "setup-vm.sh not found or not executable"
      exit 1
    fi
  fi

  # Step 2: Configure Domain
  if is_step_completed "domain_config"; then
    print_success "Step 2/5: Domain Configuration (already completed)"
  else
    print_step "Step 2/5: Configuring Domain"
    # Prefer a clean FHS layout: keep infrastructure state in /srv/infrastructure,
    # not inside the blueprint repo under /opt/hosting-blueprint.
    # This also avoids dirtying the upstream blueprint git checkout with domain-specific edits.
    INFRA_ROOT="/srv/infrastructure"
    if [ ! -d "$INFRA_ROOT" ]; then
	      print_step "Initializing ${INFRA_ROOT} from template..."
	      mkdir -p "$INFRA_ROOT"
	      if [ -d "${SCRIPT_DIR}/infra" ]; then
	        cp -a "${SCRIPT_DIR}/infra/." "$INFRA_ROOT/"
	        # sysadmin owns infra by default (CI deploys apps via a restricted wrapper).
	        chown -R sysadmin:sysadmin "$INFRA_ROOT" 2>/dev/null || true
	        chmod 755 "$INFRA_ROOT" 2>/dev/null || true
	      else
        print_warning "Template infra directory not found at ${SCRIPT_DIR}/infra (skipping copy)"
      fi
    fi

    if [ -x "${SCRIPT_DIR}/scripts/configure-domain.sh" ]; then
      bash "${SCRIPT_DIR}/scripts/configure-domain.sh" "$DOMAIN"
      mark_step_completed "domain_config"
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
      mark_step_completed "domain_config"
    fi
  fi

  # Step 3: Docker Networks
  if is_step_completed "docker_networks"; then
    print_success "Step 3/5: Docker Networks (already completed)"
  else
    print_step "Step 3/5: Creating Docker Networks"
    if [ -x "${SCRIPT_DIR}/scripts/create-networks.sh" ]; then
      bash "${SCRIPT_DIR}/scripts/create-networks.sh"
      mark_step_completed "docker_networks"
    else
      print_warning "create-networks.sh not found, skipping"
      mark_step_completed "docker_networks"
    fi
  fi

  # Step 3.5: Generate profile-aware Caddyfile and compose for reverse proxy
  local INFRA_CADDY="/srv/infrastructure/reverse-proxy"
  if [ -d "$INFRA_CADDY" ] && [ "$SETUP_PROFILE" != "full-stack" ]; then
    print_step "Generating ${SETUP_PROFILE} Caddyfile and compose.yml..."
    generate_minimal_caddyfile "$DOMAIN" "$SETUP_PROFILE" "${INFRA_CADDY}/Caddyfile"
    generate_minimal_compose "$SETUP_PROFILE" "${INFRA_CADDY}/compose.yml"
    chown -R sysadmin:sysadmin "$INFRA_CADDY" 2>/dev/null || true
    print_success "Generated ${SETUP_PROFILE} reverse proxy configuration"
  fi

  # Step 4: Cloudflared (optional)
  cloudflared_status="$(get_step_status "cloudflared_setup")"
  if [ "$cloudflared_status" = "completed" ]; then
    print_success "Step 4/5: Cloudflare Tunnel (already completed)"
  else
    if [ "$SETUP_CLOUDFLARED" = "yes" ]; then
      print_step "Step 4/5: Cloudflare Tunnel Setup"
      if [ -x "${SCRIPT_DIR}/scripts/install-cloudflared.sh" ] && [ -x "${SCRIPT_DIR}/scripts/setup-cloudflared.sh" ]; then
        echo ""
        echo "The cloudflared setup will guide you through authentication."
        echo "You'll need to log in to Cloudflare in your browser."
        echo ""
        if confirm "Ready to set up cloudflared?"; then
          bash "${SCRIPT_DIR}/scripts/install-cloudflared.sh"
          bash "${SCRIPT_DIR}/scripts/setup-cloudflared.sh" "$DOMAIN"
          mark_step_completed "cloudflared_setup"
        else
          print_warning "Cloudflared setup skipped (can run later with ./scripts/install-cloudflared.sh)"
          print_info "Re-run ./setup.sh when you're ready, or run cloudflared scripts manually."
        fi
      else
        print_warning "cloudflared setup scripts not found, skipping"
        mark_step_skipped "cloudflared_setup"
      fi
    else
      print_step "Step 4/5: Cloudflared Setup (skipped)"
      mark_step_skipped "cloudflared_setup"
    fi
  fi

  # Step 5: Reverse Proxy
  if is_step_completed "reverse_proxy"; then
    print_success "Step 5/5: Reverse Proxy (already completed)"
  else
    print_step "Step 5/5: Starting Reverse Proxy"

    # Prefer running infrastructure from /srv/infrastructure (FHS clean layout).
    # Fall back to the template repo if /srv/infrastructure isn't initialized yet.
    INFRA_ROOT="/srv/infrastructure"

    if [ ! -f "${INFRA_ROOT}/reverse-proxy/compose.yml" ]; then
      if [ -d "${SCRIPT_DIR}/infra/reverse-proxy" ]; then
	        print_step "Initializing ${INFRA_ROOT} from template..."
	        mkdir -p "$INFRA_ROOT"
	        cp -a "${SCRIPT_DIR}/infra/." "$INFRA_ROOT/"

	        # sysadmin owns infra by default (CI deploys apps via a restricted wrapper).
	        chown -R sysadmin:sysadmin "$INFRA_ROOT" 2>/dev/null || true
	        chmod 755 "$INFRA_ROOT" 2>/dev/null || true
      else
        print_warning "Template infra directory not found at ${SCRIPT_DIR}/infra"
      fi
    fi

    if [ -f "${INFRA_ROOT}/reverse-proxy/compose.yml" ]; then
      cd "${INFRA_ROOT}/reverse-proxy"
      docker compose --compatibility up -d
      mark_step_completed "reverse_proxy"
      cd "$SCRIPT_DIR"
    elif [ -f "${SCRIPT_DIR}/infra/reverse-proxy/compose.yml" ]; then
      print_warning "Using template reverse proxy directory (consider initializing /srv/infrastructure)"
      cd "${SCRIPT_DIR}/infra/reverse-proxy"
      docker compose --compatibility up -d
      mark_step_completed "reverse_proxy"
      cd "$SCRIPT_DIR"
    else
      print_warning "Reverse proxy compose.yml not found"
      mark_step_completed "reverse_proxy"
    fi
  fi

  # Optional hardening extras (recommended for security-first deployments)
  print_header "Optional Hardening (Recommended)"

  if confirm "Enable SOPS + age for encrypted .env.*.enc deployments?"; then
    if [ -x "${SCRIPT_DIR}/scripts/security/setup-sops-age.sh" ]; then
      bash "${SCRIPT_DIR}/scripts/security/setup-sops-age.sh"
    else
      print_warning "Missing script: ${SCRIPT_DIR}/scripts/security/setup-sops-age.sh (skipping)"
    fi
  fi

  if confirm "Install optional host security tools (AIDE, Lynis, rkhunter, debsums)?"; then
    if [ -x "${SCRIPT_DIR}/scripts/security/setup-security-tools.sh" ]; then
      bash "${SCRIPT_DIR}/scripts/security/setup-security-tools.sh"
    else
      print_warning "Missing script: ${SCRIPT_DIR}/scripts/security/setup-security-tools.sh (skipping)"
    fi
  fi

  if confirm "Harden /tmp (tmpfs + noexec,nosuid,nodev)?"; then
    if [ -x "${SCRIPT_DIR}/scripts/security/enable-tmpfs-tmp.sh" ]; then
      bash "${SCRIPT_DIR}/scripts/security/enable-tmpfs-tmp.sh"
    else
      print_warning "Missing script: ${SCRIPT_DIR}/scripts/security/enable-tmpfs-tmp.sh (skipping)"
    fi
  fi

  # Mark overall setup as complete only when all required steps are complete.
  # This prevents a common UX footgun where the user selects cloudflared setup,
  # skips it temporarily, and then cannot resume because the VM is marked complete.
  SETUP_ALL_STEPS_DONE="yes"
  MISSING_STEPS=()

  for s in vm_setup domain_config docker_networks reverse_proxy; do
    if ! is_step_completed "$s"; then
      SETUP_ALL_STEPS_DONE="no"
      MISSING_STEPS+=("$s")
    fi
  done

  if [ "${SETUP_CLOUDFLARED:-no}" = "yes" ]; then
    if [ "$(get_step_status "cloudflared_setup")" != "completed" ]; then
      SETUP_ALL_STEPS_DONE="no"
      MISSING_STEPS+=("cloudflared_setup")
    fi
  else
    # Ensure the optional step is explicitly marked (good resume UX).
    st="$(get_step_status "cloudflared_setup")"
    if [ "$st" != "completed" ] && [ "$st" != "skipped" ]; then
      mark_step_skipped "cloudflared_setup"
    fi
  fi

  if [ "$SETUP_ALL_STEPS_DONE" = "yes" ]; then
    touch "$COMPLETE_FILE"
    chmod 600 "$COMPLETE_FILE" 2>/dev/null || true
    # Backward compatibility: older versions used a marker inside /opt/hosting-blueprint.
    if [ -d "/opt/hosting-blueprint" ]; then
      touch "$LEGACY_COMPLETE_FILE" 2>/dev/null || true
    fi
  else
    print_header "Setup Not Fully Complete"
    print_warning "Some steps are still pending. The VM will NOT be marked as complete yet."
    if [ "${#MISSING_STEPS[@]}" -gt 0 ]; then
      print_info "Remaining step(s): ${MISSING_STEPS[*]}"
    fi
    echo ""
    print_info "Re-run to resume:"
    print_info "  sudo ./setup.sh --force"
    echo ""
  fi
}

# =================================================================
# Post-Setup Instructions
# =================================================================

print_next_steps() {
  if [ "${SETUP_ALL_STEPS_DONE:-yes}" = "yes" ]; then
    print_header "Setup Complete!"
  else
    print_header "Setup Paused (Resume Required)"
  fi

  if [ "${SETUP_ALL_STEPS_DONE:-yes}" = "yes" ]; then
    echo -e "${GREEN}Your hardened VPS is ready!${NC}"
  else
    echo -e "${YELLOW}Your VPS is partially set up. Resume the remaining steps before locking anything down.${NC}"
  fi
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

  if [ "${SETUP_PROFILE:-full-stack}" = "full-stack" ]; then
    echo "3. ${BOLD}Create Your First App${NC}"
    echo "   sudo mkdir -p /srv/apps/staging"
    echo "   sudo cp -r /opt/hosting-blueprint/apps/_template /srv/apps/staging/myapp"
    echo "   cd /srv/apps/staging/myapp"
    echo "   # Edit compose.yml and .env"
    echo "   sudo docker compose --compatibility up -d"
    echo ""

    echo "4. ${BOLD}Create Secrets${NC}"
    echo "   ./scripts/secrets/create-secret.sh dev db_password"
    echo "   ./scripts/secrets/create-secret.sh staging db_password"
    echo "   ./scripts/secrets/create-secret.sh production db_password"
    echo ""
  elif [ "${SETUP_PROFILE:-full-stack}" = "monitoring" ]; then
    echo "3. ${BOLD}Deploy Monitoring Stack${NC}"
    echo "   cd /srv/services/monitoring"
    echo "   # Edit .env (set GRAFANA_DOMAIN, etc.)"
    echo "   sudo docker compose --compatibility up -d"
    echo ""

    echo "4. ${BOLD}Add Subdomain Routes${NC}"
    echo "   sudo /opt/hosting-blueprint/scripts/add-subdomain.sh"
    echo "   # Example: route grafana.yourdomain.com to grafana:3000"
    echo ""
  else
    echo "3. ${BOLD}Add Services${NC}"
    echo "   Place compose files in /srv/services/<name>/"
    echo "   sudo docker compose --compatibility up -d"
    echo ""

    echo "4. ${BOLD}Add Subdomain Routes${NC}"
    echo "   sudo /opt/hosting-blueprint/scripts/add-subdomain.sh"
    echo "   # Routes a subdomain to a container through the reverse proxy"
    echo ""
  fi

  echo "5. ${BOLD}Protect Admin Panels (Zero Trust)${NC}"
  echo "   - Go to Cloudflare Zero Trust dashboard"
  echo "   - Access > Applications > Add self-hosted app"
  echo "   - See docs/14-cloudflare-zero-trust.md for full guide"
  echo ""

  echo -e "${CYAN}Useful Commands:${NC}"
  echo ""
  echo "  # System status"
  echo "  ./scripts/monitoring/status.sh"
  echo ""
  echo "  # Add a new subdomain route"
  echo "  sudo /opt/hosting-blueprint/scripts/add-subdomain.sh"
  echo ""
  echo "  # View logs"
  echo "  ./scripts/monitoring/logs.sh"
  echo ""

  echo -e "${CYAN}Documentation:${NC}"
  echo "  See README.md and docs/ folder for detailed guides"
  echo ""

  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  if [ "${SETUP_ALL_STEPS_DONE:-yes}" != "yes" ]; then
    print_warning "Skipping post-setup wizard because setup is not fully complete yet."
    print_info "After finishing pending steps, you can run:"
    print_info "  ./scripts/post-setup-wizard.sh"
    echo ""
    return 0
  fi

  echo -e "${YELLOW}Would you like to run the interactive setup wizard?${NC}"
  echo ""
  echo "The wizard will guide you through:"
  echo "  • Initializing /srv infrastructure"
  echo "  • Deploying your first application"
  echo "  • Configuring reverse proxy and DNS"
  echo ""

  if confirm "Launch post-setup wizard now?" "y"; then
    echo ""
    print_step "Launching post-setup wizard..."
    echo ""
    sleep 2

    # Launch wizard
    if [ -f "$SCRIPT_DIR/scripts/post-setup-wizard.sh" ]; then
      exec "$SCRIPT_DIR/scripts/post-setup-wizard.sh"
    else
      print_error "Wizard script not found: $SCRIPT_DIR/scripts/post-setup-wizard.sh"
      echo ""
      print_info "You can run it manually later:"
      print_info "  ./scripts/post-setup-wizard.sh"
      echo ""
    fi
  else
    echo ""
    print_info "You can run the wizard anytime:"
    echo "  ./scripts/post-setup-wizard.sh"
    echo ""
  fi
}

# =================================================================
# Main
# =================================================================

main() {
  local FORCE=false
  for arg in "$@"; do
    case "$arg" in
      --force)
        FORCE=true
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        print_error "Unknown argument: $arg"
        usage
        exit 1
        ;;
    esac
  done

  # Check if setup is already complete
  if [ "$FORCE" = false ] && { [ -f "$COMPLETE_FILE" ] || [ -f "$LEGACY_COMPLETE_FILE" ]; }; then
    # Migrate legacy marker to the new location (config dir) if needed.
    if [ ! -f "$COMPLETE_FILE" ]; then
      mkdir -p "$CONFIG_DIR"
      touch "$COMPLETE_FILE"
      chmod 600 "$COMPLETE_FILE" 2>/dev/null || true
    fi
    print_header "Setup Already Complete"
    echo ""
    print_warning "This VM has already been set up."
    print_info "Configuration: $CONFIG_FILE"
    print_info "State: $STATE_FILE"
    echo ""
    print_info "If you want to:"
    echo "  • Re-run specific steps: Check scripts/ directory"
    echo "  • Verify setup: ./scripts/verify-setup.sh"
    echo "  • Start fresh: Delete $CONFIG_DIR (includes state + completion marker)"
    echo ""
    exit 0
  fi

  print_header "Hardened Multi-Environment VPS Setup"

  # Check if resuming
  local resuming_msg=""
  if [ -f "$STATE_FILE" ]; then
    local completed=$(get_completed_steps)
    if [ "$completed" -gt 0 ]; then
      resuming_msg=" (Resuming - $completed/5 steps completed)"
    fi
  fi

  echo "This script will set up a production-ready, hardened Ubuntu server with:"
  echo "  • Security hardening (SSH, firewall, fail2ban, kernel)"
  echo "  • Docker with secure defaults"
  echo "  • Cloudflare Tunnel for zero exposed ports"
  echo "  • Automated maintenance and updates"
  echo ""
  echo "You'll choose a server profile:"
  echo "  • Full Stack  - Multi-environment (dev/staging/prod) app hosting"
  echo "  • Monitoring  - Prometheus, Grafana, alerting (no app environments)"
  echo "  • Minimal     - Just hardening + tunnel (add services later)"
  echo ""

  if [ -n "$resuming_msg" ]; then
    print_info "$resuming_msg"
    echo ""
  fi

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
