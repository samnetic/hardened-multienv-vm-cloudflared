#!/usr/bin/env bash
# =================================================================
# Infrastructure Repository Initialization
# =================================================================
# Run this script after cloning the infrastructure repository
# to set up the server environment properly
#
# What this does:
#   1. Verifies user is sysadmin (not root)
#   2. Creates Docker networks for all environments
#   3. Sets proper file permissions
#   4. Creates application directories
#   5. Starts reverse proxy (Caddy)
#   6. Verifies setup
#
# Usage:
#   cd /srv/infrastructure
#   ./.deploy/init-infrastructure.sh
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

# Prefer sudo for Docker access (security-first). We detect the right invocation in verify_docker().
DOCKER=(docker)

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

# =================================================================
# Verification
# =================================================================

verify_user() {
  print_step "Verifying user..."

  local current_user=$(whoami)

  if [ "$current_user" = "root" ]; then
    print_error "Do not run this as root!"
    echo ""
    echo "This script should be run as sysadmin:"
    echo "  su - sysadmin"
    echo "  cd /srv/infrastructure"
    echo "  ./.deploy/init-infrastructure.sh"
    exit 1
  fi

  if [ "$current_user" != "sysadmin" ]; then
    print_error "Current user: $current_user (expected: sysadmin)"
    echo ""
    echo "Run:"
    echo "  su - sysadmin"
    exit 1
  fi

  print_success "Running as sysadmin"
}

verify_location() {
  print_step "Verifying repository location..."

  local current_dir=$(pwd)

  if [[ "$current_dir" != "/srv/infrastructure"* ]]; then
    print_warning "Not in /srv/infrastructure (currently: $current_dir)"
    echo ""
    print_info "Recommended location: /srv/infrastructure"
    echo ""
    read -rp "Continue anyway? (yes/no): " continue_location
    if [ "$continue_location" != "yes" ]; then
      echo "Exiting."
      exit 1
    fi
  else
    print_success "Repository in correct location"
  fi
}

verify_docker() {
  print_step "Verifying Docker access..."

  if docker ps &> /dev/null; then
    DOCKER=(docker)
  elif sudo docker ps &> /dev/null; then
    DOCKER=(sudo docker)
  else
    print_error "Cannot access Docker (docker ps and sudo docker ps both failed)"
    echo ""
    echo "Make sure:"
    echo "  1. Docker is installed and running: sudo systemctl status docker"
    echo "  2. Your user has sudo access"
    echo ""
    echo "Note:"
    echo "  Adding users to the docker group is not recommended (docker group is root-equivalent)."
    exit 1
  fi

  print_success "Docker access confirmed"
}

# =================================================================
# Docker Networks
# =================================================================

create_networks() {
  print_header "Step 1/5: Create Docker Networks"

  local networks=(
    "hosting-caddy-origin:Reverse proxy origin enforcement network (tunnel-only)"
    "dev-web:Development web network (apps via Caddy)"
    "dev-backend:Development backend network (DBs reachable from host for local dev)"
    "staging-web:Staging web network (apps via Caddy)"
    "staging-backend:Staging backend network (internal only)"
    "prod-web:Production web network (apps via Caddy)"
    "prod-backend:Production backend network (internal only)"
    "monitoring:Monitoring stack network"
  )

  for network_info in "${networks[@]}"; do
    IFS=':' read -r network_name network_desc <<< "$network_info"

    if "${DOCKER[@]}" network ls --format '{{.Name}}' | grep -q "^${network_name}$"; then
      print_success "Network '$network_name' already exists"
    else
      print_step "Creating network: $network_name"
      if [ "$network_name" = "hosting-caddy-origin" ]; then
        # Fixed-subnet internal network used so Caddy can reliably detect host->published-localhost
        # traffic (Docker NAT shows up as the bridge gateway inside the container).
        "${DOCKER[@]}" network create "$network_name" --internal --subnet 10.250.0.0/24 --gateway 10.250.0.1 --label "description=$network_desc"
      elif [[ "$network_name" =~ ^(staging-backend|prod-backend)$ ]]; then
        "${DOCKER[@]}" network create "$network_name" --internal --label "description=$network_desc"
      else
        "${DOCKER[@]}" network create "$network_name" --label "description=$network_desc"
      fi
      print_success "Created network: $network_name"
    fi
  done

  echo ""
  print_info "Docker networks ready"
  "${DOCKER[@]}" network ls | grep -E "dev-|staging-|prod-|monitoring|hosting-caddy-origin" || true
}

# =================================================================
# Directory Structure
# =================================================================

create_directories() {
  print_header "Step 2/5: Create Application Directories"

  local app_dirs=(
    "/srv/apps/dev"
    "/srv/apps/staging"
    "/srv/apps/production"
    "/srv/backups"
  )

  for dir in "${app_dirs[@]}"; do
    if [ -d "$dir" ]; then
      print_success "Directory exists: $dir"
    else
      print_step "Creating: $dir"
      sudo mkdir -p "$dir"
      if [[ "$dir" == "/srv/apps/"* ]]; then
        sudo chown -R sysadmin:sysadmin "$dir" 2>/dev/null || true
      else
        sudo chown -R sysadmin:sysadmin "$dir" 2>/dev/null || true
      fi
      print_success "Created: $dir"
    fi
  done

  # Secrets directory (not in git)
  if [ ! -d "/var/secrets" ]; then
    print_step "Creating: /var/secrets/{dev,staging,production}"
    sudo mkdir -p /var/secrets/{dev,staging,production}
  fi
  local secrets_group="hosting-secrets"
  if getent group "$secrets_group" >/dev/null 2>&1; then
    sudo chown -R root:"$secrets_group" /var/secrets
    sudo chmod 750 /var/secrets
    sudo find /var/secrets -type d -exec chmod 750 {} \;
    sudo find /var/secrets -type f -name '*.txt' -exec chmod 640 {} \; 2>/dev/null || true
    print_success "Secured /var/secrets (root:${secrets_group}, 750 dirs, 640 files)"
  else
    sudo chown -R root:root /var/secrets
    sudo chmod 700 /var/secrets
    sudo find /var/secrets -type d -exec chmod 700 {} \;
    print_warning "Group '$secrets_group' not found; secured /var/secrets as root-only (700)"
  fi
}

# =================================================================
# File Permissions
# =================================================================

set_permissions() {
  print_header "Step 3/5: Set File Permissions"

  print_step "Setting ownership to sysadmin..."

  local current_dir=$(pwd)

  # Make sure appmgr owns the infrastructure repo
  if [ -w "$current_dir" ]; then
    print_success "Already have write access to $current_dir"
  else
    print_warning "Need sudo to fix ownership"
    sudo chown -R sysadmin:sysadmin "$current_dir"
    print_success "Fixed ownership"
  fi

  # Make deploy scripts executable
  if [ -d "$current_dir/.deploy" ]; then
    chmod +x "$current_dir/.deploy"/*.sh 2>/dev/null || true
    print_success "Deploy scripts are executable"
  fi
}

# =================================================================
# Reverse Proxy
# =================================================================

start_reverse_proxy() {
  print_header "Step 4/5: Start Reverse Proxy (Caddy)"

  local caddy_dir=""
  if [ -d "$PWD/reverse-proxy" ]; then
    caddy_dir="$PWD/reverse-proxy"
  elif [ -d "$PWD/infra/reverse-proxy" ]; then
    caddy_dir="$PWD/infra/reverse-proxy"
  elif [ -d "/srv/infrastructure/reverse-proxy" ]; then
    caddy_dir="/srv/infrastructure/reverse-proxy"
  fi

  if [ -z "$caddy_dir" ] || [ ! -d "$caddy_dir" ]; then
    print_warning "Caddy directory not found"
    print_info "Skipping Caddy setup"
    return 0
  fi

  cd "$caddy_dir"

  # Check if .env exists
  if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
      print_step "Creating .env from .env.example"
      cp .env.example .env
      print_warning "Please edit .env and set your DOMAIN"
      nano .env
    else
      print_warning ".env not found - you'll need to create it"
      return 0
    fi
  fi

  # Start Caddy
  print_step "Starting Caddy..."

  if "${DOCKER[@]}" compose ps --services --filter "status=running" | grep -q caddy; then
    print_info "Caddy already running - restarting"
    "${DOCKER[@]}" compose restart
  else
    "${DOCKER[@]}" compose up -d
  fi

  sleep 2

  if "${DOCKER[@]}" compose ps --services --filter "status=running" | grep -q caddy; then
    print_success "Caddy is running"
    echo ""
    print_info "View logs: ${DOCKER[*]} compose logs -f caddy"
  else
    print_error "Caddy failed to start"
    echo ""
    print_info "Check logs:"
    echo "  cd $caddy_dir"
    echo "  ${DOCKER[*]} compose logs caddy"
    return 1
  fi
}

# =================================================================
# Verification
# =================================================================

verify_setup() {
  print_header "Step 5/5: Verify Setup"

  echo ""
  print_step "Checking Docker networks..."
  local network_count=$("${DOCKER[@]}" network ls | grep -cE "dev-|staging-|prod-|monitoring" || echo "0")
  if [ "$network_count" -ge 7 ]; then
    print_success "All Docker networks created ($network_count networks)"
  else
    print_warning "Expected 7 networks, found $network_count"
  fi

  echo ""
  print_step "Checking directories..."
  if [ -d "/srv/apps/production" ] && [ -d "/var/secrets" ]; then
    print_success "Application directories created"
  else
    print_warning "Some directories missing"
  fi

  echo ""
  print_step "Checking Caddy..."
  if "${DOCKER[@]}" ps --filter "name=caddy" --filter "status=running" | grep -q caddy; then
    print_success "Caddy reverse proxy is running"
  else
    print_warning "Caddy not running (may need manual start)"
  fi

  echo ""
  print_step "Checking file permissions..."
  if [ -w "$(pwd)" ]; then
    print_success "Have write access to infrastructure repo"
  else
    print_warning "No write access - may need to fix permissions"
  fi
}

# =================================================================
# Main
# =================================================================

main() {
  clear
  print_header "Infrastructure Repository Initialization"

  echo "This script will set up your server environment for the infrastructure repository."
  echo ""
  echo "What this does:"
  echo "  • Create Docker networks (dev, staging, prod)"
  echo "  • Create application directories (/srv/apps/*)"
  echo "  • Set proper file permissions"
  echo "  • Start reverse proxy (Caddy)"
  echo ""

  read -rp "Continue? (yes/no): " continue_setup
  if [ "$continue_setup" != "yes" ]; then
    echo "Exiting."
    exit 0
  fi

  # Run all steps
  verify_user
  verify_location
  verify_docker
  create_networks
  create_directories
  set_permissions
  start_reverse_proxy
  verify_setup

  # =================================================================
  # Next Steps
  # =================================================================
  print_header "Initialization Complete!"

  echo -e "${GREEN}✓ Infrastructure repository is ready!${NC}"
  echo ""
  echo -e "${CYAN}Next Steps:${NC}"
  echo ""
  echo -e "1. ${BOLD}Deploy Apps${NC}"
  echo "   • Use the post-setup wizard:"
  echo "     /opt/hosting-blueprint/scripts/post-setup-wizard.sh"
  echo "   • Or copy from template into /srv/apps/<env>/<app>/"
  echo ""
  echo -e "2. ${BOLD}Update Caddy Routing${NC}"
  echo "   • Edit: /srv/infrastructure/reverse-proxy/Caddyfile"
  echo "   • Apply safely: /opt/hosting-blueprint/scripts/update-caddy.sh"
  echo ""
  echo -e "3. ${BOLD}Protect Admin Panels (Recommended)${NC}"
  echo "   • Enable Cloudflare Zero Trust Access (SSO)"
  echo "   • Protect: monitoring.<domain>, n8n.<domain>, admin tools"
  echo "   • Use Service Tokens for CI/webhooks where needed"
  echo ""
  echo -e "4. ${BOLD}Set Up GitOps (Optional)${NC}"
  echo "   • docs/07-gitops-workflow.md"
  echo ""
  echo -e "${BLUE}Documentation:${NC}"
  echo "  • docs/repository-structure.md"
  echo "  • docs/07-gitops-workflow.md"
  echo "  • docs/14-cloudflare-zero-trust.md"
  echo ""
}

# Run main function
main "$@"
