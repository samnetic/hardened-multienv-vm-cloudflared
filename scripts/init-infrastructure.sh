#!/usr/bin/env bash
# =================================================================
# Infrastructure Repository Initialization
# =================================================================
# Run this script after cloning the infrastructure repository
# to set up the server environment properly
#
# What this does:
#   1. Verifies user is appmgr (not root)
#   2. Creates Docker networks for all environments
#   3. Sets proper file permissions
#   4. Creates application directories
#   5. Starts reverse proxy (Caddy)
#   6. Verifies setup
#
# Usage:
#   cd /opt/infrastructure
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
    echo "This script should be run as appmgr:"
    echo "  sudo su - appmgr"
    echo "  cd /opt/infrastructure"
    echo "  ./.deploy/init-infrastructure.sh"
    exit 1
  fi

  if [ "$current_user" != "appmgr" ]; then
    print_warning "Current user: $current_user (expected: appmgr)"
    echo ""
    read -rp "Continue anyway? (yes/no): " continue_anyway
    if [ "$continue_anyway" != "yes" ]; then
      echo "Exiting."
      exit 1
    fi
  else
    print_success "Running as appmgr"
  fi
}

verify_location() {
  print_step "Verifying repository location..."

  local current_dir=$(pwd)

  if [[ "$current_dir" != "/opt/infrastructure"* ]]; then
    print_warning "Not in /opt/infrastructure (currently: $current_dir)"
    echo ""
    print_info "Recommended location: /opt/infrastructure"
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

  if ! docker ps &> /dev/null; then
    print_error "Cannot access Docker"
    echo ""
    echo "Make sure:"
    echo "  1. Docker is installed"
    echo "  2. User is in docker group: sudo usermod -aG docker appmgr"
    echo "  3. You've logged out and back in after adding to group"
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
    "dev-web:Development environment web network"
    "dev-db:Development environment database network"
    "staging-web:Staging environment web network"
    "staging-db:Staging environment database network"
    "prod-web:Production environment web network"
    "prod-db:Production environment database network"
    "monitoring:Monitoring stack network (Grafana, Prometheus)"
  )

  for network_info in "${networks[@]}"; do
    IFS=':' read -r network_name network_desc <<< "$network_info"

    if docker network ls --format '{{.Name}}' | grep -q "^${network_name}$"; then
      print_success "Network '$network_name' already exists"
    else
      print_step "Creating network: $network_name"
      docker network create "$network_name" --label "description=$network_desc"
      print_success "Created network: $network_name"
    fi
  done

  echo ""
  print_info "Docker networks ready"
  docker network ls | grep -E "dev-|staging-|prod-|monitoring" || true
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
    "/srv/secrets"
  )

  for dir in "${app_dirs[@]}"; do
    if [ -d "$dir" ]; then
      print_success "Directory exists: $dir"
    else
      print_step "Creating: $dir"
      sudo mkdir -p "$dir"
      sudo chown -R appmgr:appmgr "$dir"
      print_success "Created: $dir"
    fi
  done

  # Secure secrets directory
  if [ -d "/srv/secrets" ]; then
    sudo chmod 700 /srv/secrets
    print_success "Secured /srv/secrets (700 permissions)"
  fi
}

# =================================================================
# File Permissions
# =================================================================

set_permissions() {
  print_header "Step 3/5: Set File Permissions"

  print_step "Setting ownership to appmgr..."

  local current_dir=$(pwd)

  # Make sure appmgr owns the infrastructure repo
  if [ -w "$current_dir" ]; then
    print_success "Already have write access to $current_dir"
  else
    print_warning "Need sudo to fix ownership"
    sudo chown -R appmgr:appmgr "$current_dir"
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

  local caddy_dir="$PWD/infra/reverse-proxy"

  if [ ! -d "$caddy_dir" ]; then
    print_warning "Caddy directory not found: $caddy_dir"
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

  if docker compose ps --services --filter "status=running" | grep -q caddy; then
    print_info "Caddy already running - restarting"
    docker compose restart
  else
    docker compose up -d
  fi

  sleep 2

  if docker compose ps --services --filter "status=running" | grep -q caddy; then
    print_success "Caddy is running"
    echo ""
    print_info "View logs: docker compose logs -f caddy"
  else
    print_error "Caddy failed to start"
    echo ""
    print_info "Check logs:"
    echo "  cd $caddy_dir"
    echo "  docker compose logs caddy"
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
  local network_count=$(docker network ls | grep -cE "dev-|staging-|prod-|monitoring" || echo "0")
  if [ "$network_count" -ge 7 ]; then
    print_success "All Docker networks created ($network_count networks)"
  else
    print_warning "Expected 7 networks, found $network_count"
  fi

  echo ""
  print_step "Checking directories..."
  if [ -d "/srv/apps/production" ] && [ -d "/srv/secrets" ]; then
    print_success "Application directories created"
  else
    print_warning "Some directories missing"
  fi

  echo ""
  print_step "Checking Caddy..."
  if docker ps --filter "name=caddy" --filter "status=running" | grep -q caddy; then
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
  echo -e "1. ${BOLD}Deploy Third-Party Apps${NC}"
  echo "   cd apps/n8n && docker compose up -d"
  echo "   cd apps/portainer && docker compose up -d"
  echo "   cd apps/grafana && docker compose up -d"
  echo ""
  echo -e "2. ${BOLD}Update Caddyfile${NC}"
  echo "   nano infra/reverse-proxy/Caddyfile"
  echo "   Add routes for your apps"
  echo ""
  echo -e "3. ${BOLD}Reload Caddy${NC}"
  echo "   cd infra/reverse-proxy"
  echo "   docker compose restart"
  echo ""
  echo -e "4. ${BOLD}Deploy Custom Apps${NC}"
  echo "   Clone your custom app repos to /srv/apps/production/"
  echo "   Or use GitHub Actions for automated deployment"
  echo ""
  echo -e "${BLUE}Documentation:${NC}"
  echo "  • docs/repository-structure.md"
  echo "  • docs/deployment-workflow.md"
  echo ""
}

# Run main function
main "$@"
