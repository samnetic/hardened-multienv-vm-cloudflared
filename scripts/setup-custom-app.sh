#!/usr/bin/env bash
# =================================================================
# Custom Application Setup from Repository
# =================================================================
# Clone and deploy custom applications from separate git repos
#
# What this does:
#   1. Clones custom app repository
#   2. Sets up environment files
#   3. Builds and starts Docker containers
#   4. Connects to infrastructure networks
#   5. Guides you to update Caddyfile
#
# Usage:
#   ./scripts/setup-custom-app.sh \
#     --repo https://github.com/org/my-app \
#     --env production \
#     --subdomain api
#
#   Interactive mode:
#   ./scripts/setup-custom-app.sh
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

# Prefer a security-first model: humans are not in the docker group.
# If docker isn't directly accessible, fall back to sudo.
DOCKER=(docker)
if ! command -v docker >/dev/null 2>&1; then
  print_error "Docker is not installed"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
fi

compose() {
  "${DOCKER[@]}" compose "$@"
}

# =================================================================
# Parse Arguments
# =================================================================

REPO_URL=""
ENVIRONMENT=""
SUBDOMAIN=""
APP_NAME=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --repo)
        REPO_URL="$2"
        shift 2
        ;;
      --env)
        ENVIRONMENT="$2"
        shift 2
        ;;
      --subdomain)
        SUBDOMAIN="$2"
        shift 2
        ;;
      --name)
        APP_NAME="$2"
        shift 2
        ;;
      *)
        print_error "Unknown argument: $1"
        exit 1
        ;;
    esac
  done
}

# =================================================================
# Interactive Mode
# =================================================================

interactive_mode() {
  print_header "Custom Application Setup"

  echo "This script clones and deploys custom applications from git repositories."
  echo ""

  # Get repository URL
  read -rp "Git repository URL (e.g., https://github.com/org/my-app): " REPO_URL

  # Extract app name from repo URL
  if [ -z "$APP_NAME" ]; then
    APP_NAME=$(basename "$REPO_URL" .git)
  fi

  echo ""
  echo "App name: $APP_NAME"
  read -rp "Change app name? (press Enter to keep, or type new name): " new_name
  if [ -n "$new_name" ]; then
    APP_NAME="$new_name"
  fi

  # Environment
  echo ""
  echo "Select environment:"
  echo "  1) dev"
  echo "  2) staging"
  echo "  3) production"
  read -rp "Choice (1-3): " env_choice

  case $env_choice in
    1) ENVIRONMENT="dev" ;;
    2) ENVIRONMENT="staging" ;;
    3) ENVIRONMENT="production" ;;
    *) print_error "Invalid choice"; exit 1 ;;
  esac

  # Subdomain
  echo ""
  read -rp "Subdomain (e.g., 'api' for api.yourdomain.com): " SUBDOMAIN

  # Confirmation
  echo ""
  echo -e "${BOLD}Setup Summary:${NC}"
  echo "  Repository: $REPO_URL"
  echo "  App Name: $APP_NAME"
  echo "  Environment: $ENVIRONMENT"
  echo "  Subdomain: $SUBDOMAIN"
  echo "  Deploy to: /srv/apps/$ENVIRONMENT/$APP_NAME"
  echo ""
  read -rp "Continue? (yes/no): " confirm

  if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 0
  fi
}

# =================================================================
# Setup
# =================================================================

setup_app() {
  print_header "Step 1/4: Clone Repository"

  local deploy_path="/srv/apps/$ENVIRONMENT/$APP_NAME"

  if [ -d "$deploy_path" ]; then
    print_warning "Directory already exists: $deploy_path"
    read -rp "Delete and re-clone? (yes/no): " reclone
    if [ "$reclone" = "yes" ]; then
      rm -rf "$deploy_path"
      print_info "Removed existing directory"
    else
      print_info "Using existing directory"
      cd "$deploy_path"
      git pull
      print_success "Updated from git"
    fi
  fi

  if [ ! -d "$deploy_path" ]; then
    print_step "Cloning repository..."
    git clone "$REPO_URL" "$deploy_path"
    print_success "Repository cloned"
  fi

  cd "$deploy_path"

  # =================================================================
  print_header "Step 2/4: Configure Environment"

  # Check for compose file
  if [ ! -f "docker-compose.yml" ] && [ ! -f "docker-compose.yaml" ] && [ ! -f "compose.yml" ] && [ ! -f "compose.yaml" ]; then
    print_error "No compose file found (expected compose.yaml/compose.yml or docker-compose.yaml/docker-compose.yml)"
    echo ""
    echo "Your custom app repository needs a compose file."
    echo ""
    echo "Example docker-compose.yml:"
    echo ""
    cat << 'EOF'
version: '3.8'

services:
  app:
    build: .
    container_name: my-app-prod
    restart: unless-stopped
    networks:
      - prod-web
    environment:
      - NODE_ENV=production
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:
          cpus: '1'
          memory: 512M
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

networks:
  prod-web:
    external: true
EOF
    echo ""
    exit 1
  fi

  # Set up .env if needed
  if [ -f ".env.example" ] && [ ! -f ".env" ]; then
    print_step "Creating .env from .env.example"
    cp .env.example .env

    echo ""
    print_info "Edit .env file now?"
    read -rp "Press Enter to edit, or 'skip' to configure manually later: " edit_choice
    if [ "$edit_choice" != "skip" ]; then
      nano .env
    fi
  elif [ ! -f ".env" ]; then
    print_warning "No .env or .env.example found"
    echo ""
    read -rp "Create .env file now? (yes/no): " create_env
    if [ "$create_env" = "yes" ]; then
      touch .env
      nano .env
    fi
  else
    print_success ".env file already exists"
  fi

  # =================================================================
  print_header "Step 3/4: Build and Start Application"

  print_step "Building Docker images..."
  compose build

  print_step "Starting containers..."
  compose up -d

  sleep 3

  print_step "Checking container status..."
  if compose ps --services --filter "status=running" | grep -q .; then
    print_success "Application is running"
    echo ""
    compose ps
  else
    print_error "Application failed to start"
    echo ""
    print_info "Check logs:"
    echo "  cd $deploy_path"
    echo "  sudo docker compose logs -f"
    exit 1
  fi

  # =================================================================
  print_header "Step 4/4: Update Routing"

  echo ""
  echo -e "${YELLOW}MANUAL STEP REQUIRED:${NC}"
  echo ""
  echo "Add this route to your Caddyfile:"
  echo ""
  echo -e "${CYAN}# In /srv/infrastructure/reverse-proxy/Caddyfile${NC}"
  echo ""

  # Pick a reasonable default upstream service (prefer "app" if present).
  # In tunnel-only mode, apps SHOULD NOT publish ports. Caddy routes to the
  # container's internal port on the shared Docker network.
  local upstream_service="app"
  local services_list
  services_list="$(compose ps --services 2>/dev/null || true)"
  if ! echo "$services_list" | tr -d '\r' | grep -qx "app"; then
    upstream_service="$(echo "$services_list" | head -1 | tr -d '\r' || true)"
  fi
  if [ -z "${upstream_service:-}" ]; then
    upstream_service="app"
  fi

  local upstream_port="3000"
  echo ""
  read -rp "Internal port your app listens on (e.g., 3000) [${upstream_port}]: " upstream_port_in
  upstream_port="${upstream_port_in:-$upstream_port}"

  echo -e "${BOLD}http://${SUBDOMAIN}.\${DOMAIN} {${NC}"
  echo -e "${BOLD}    reverse_proxy ${upstream_service}:${upstream_port}${NC}"
  echo -e "${BOLD}}${NC}"

  echo ""
  echo "Then reload Caddy:"
  echo ""
  echo "  sudo /opt/hosting-blueprint/scripts/update-caddy.sh /srv/infrastructure/reverse-proxy"
  echo ""

  read -rp "Open Caddyfile in editor now? (yes/no): " open_caddy
  if [ "$open_caddy" = "yes" ]; then
    if [ -f "/srv/infrastructure/reverse-proxy/Caddyfile" ]; then
      nano /srv/infrastructure/reverse-proxy/Caddyfile
      echo ""
      read -rp "Reload Caddy now? (yes/no): " reload_caddy
      if [ "$reload_caddy" = "yes" ]; then
        sudo /opt/hosting-blueprint/scripts/update-caddy.sh /srv/infrastructure/reverse-proxy
        print_success "Caddy reloaded"
      fi
    else
      print_warning "Caddyfile not found at /srv/infrastructure/reverse-proxy/Caddyfile"
      print_info "Initialize /srv/infrastructure first (see scripts/setup-infrastructure-repo.sh)"
    fi
  fi
}

# =================================================================
# Verification
# =================================================================

show_summary() {
  print_header "Setup Complete!"

  echo -e "${GREEN}✓ Application deployed successfully!${NC}"
  echo ""
  echo -e "${CYAN}Deployment Details:${NC}"
  echo "  App Name: $APP_NAME"
  echo "  Environment: $ENVIRONMENT"
  echo "  Location: /srv/apps/$ENVIRONMENT/$APP_NAME"
  echo "  URL: http://${SUBDOMAIN}.<your-domain>"
  echo ""
  echo -e "${CYAN}Useful Commands:${NC}"
  echo ""
  echo "  # View logs"
  echo "  cd /srv/apps/$ENVIRONMENT/$APP_NAME"
  echo "  sudo docker compose logs -f"
  echo ""
  echo "  # Restart application"
  echo "  sudo docker compose restart"
  echo ""
  echo "  # Update from git"
  echo "  git pull && sudo docker compose --compatibility up -d --build"
  echo ""
  echo "  # Stop application"
  echo "  sudo docker compose down"
  echo ""
  echo -e "${CYAN}CI/CD Integration:${NC}"
  echo ""
  echo "To set up GitHub Actions for automatic deployment:"
  echo "  1. Add APPMGR_SSH_KEY secret to your repository"
  echo "  2. Add .github/workflows/deploy.yml (see docs)"
  echo "  3. Push to main branch → auto-deploys"
  echo ""
}

# =================================================================
# Main
# =================================================================

main() {
  parse_args "$@"

  # If no arguments provided, use interactive mode
  if [ -z "$REPO_URL" ]; then
    interactive_mode
  fi

  # Validate required arguments
  if [ -z "$REPO_URL" ] || [ -z "$ENVIRONMENT" ] || [ -z "$SUBDOMAIN" ]; then
    print_error "Missing required arguments"
    echo ""
    echo "Usage:"
    echo "  $0 --repo <git-url> --env <dev|staging|production> --subdomain <name>"
    echo ""
    echo "Or run without arguments for interactive mode."
    exit 1
  fi

  # Extract app name if not provided
  if [ -z "$APP_NAME" ]; then
    APP_NAME=$(basename "$REPO_URL" .git)
  fi

  # Setup
  setup_app
  show_summary
}

# Run main
main "$@"
