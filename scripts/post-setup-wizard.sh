#!/usr/bin/env bash
# =================================================================
# Post-Setup Wizard - Interactive First-Time User Guide
# =================================================================
# This wizard runs after main setup completes and guides users
# through deploying their first application and configuring
# infrastructure.
#
# Usage:
#   ./scripts/post-setup-wizard.sh
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="/opt/vm-config/setup.conf"

# sudo helper (wizard should run as sysadmin; root works too)
SUDO="sudo"
if [ "${EUID:-0}" -eq 0 ]; then
  SUDO=""
fi

# =================================================================
# Helper Functions
# =================================================================

print_header() {
  clear
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}  ${BOLD}$1${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

print_step() {
  echo -e "${CYAN}▶ $1${NC}"
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

print_command() {
  echo -e "${MAGENTA}  $ $1${NC}"
}

pause() {
  echo ""
  read -rp "Press Enter to continue..."
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

ensure_docker_access() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
    return 0
  fi
  print_error "Docker is not accessible for this user."
  print_info "Run as 'sysadmin' (recommended) or use sudo privileges."
  print_info "Adding users to the docker group is not recommended (docker group is root-equivalent)."
  exit 1
}

run_compose() {
  local dir="$1"
  shift
  if (cd "$dir" && docker compose "$@"); then
    return 0
  fi
  if [ -n "$SUDO" ] && (cd "$dir" && $SUDO docker compose "$@"); then
    return 0
  fi
  return 1
}

create_app_dir() {
  local app_dir="$1"
  $SUDO mkdir -p "$app_dir"
  # Keep app deployments owned by sysadmin (humans). CI deploys via a root-owned wrapper.
  if id sysadmin >/dev/null 2>&1; then
    $SUDO chown -R sysadmin:sysadmin "$app_dir" 2>/dev/null || true
  fi
  $SUDO chmod 755 "$app_dir" 2>/dev/null || true
}

prompt_image() {
  local default_image="$1"
  local label="$2"

  echo ""
  echo "Docker image for ${label}:"
  read -rp "Image [${default_image}]: " image
  image="${image:-$default_image}"
  if [[ "$image" =~ :latest$ ]]; then
    print_warning "Using ':latest' is non-deterministic. Prefer pinning a version tag for reproducible deploys."
  fi
  echo "$image"
}

show_menu() {
  local title="$1"
  shift
  local options=("$@")

  echo -e "${CYAN}${BOLD}${title}${NC}"
  echo ""

  local i=1
  for option in "${options[@]}"; do
    echo -e "${GREEN}${i})${NC} ${option}"
    ((i++))
  done
  echo -e "${GREEN}0)${NC} Exit wizard"
  echo ""
}

get_choice() {
  local max="$1"
  local choice

  while true; do
    read -rp "Enter choice (0-${max}): " choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 0 ] && [ "$choice" -le "$max" ]; then
      echo "$choice"
      return 0
    else
      print_error "Invalid choice. Please enter a number between 0 and ${max}."
    fi
  done
}

# Load configuration
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    set +u
    source "$CONFIG_FILE"
    set -u
    SETUP_PROFILE="${SETUP_PROFILE:-full-stack}"
  else
    print_error "Configuration file not found: $CONFIG_FILE"
    print_info "Please run ./setup.sh first"
    exit 1
  fi
}

# =================================================================
# Wizard Steps
# =================================================================

welcome() {
  print_header "Welcome to Your Hardened VM!"

  echo -e "${GREEN}${BOLD}🎉 Setup Complete!${NC}"
  echo ""
  echo "Your VM is now:"
  echo "  ✓ Hardened with enterprise security"
  echo "  ✓ Protected by zero-port architecture"
  echo "  ✓ Ready for application deployment"
  echo ""
  echo -e "${CYAN}This wizard will help you:${NC}"
  echo "  1. Initialize /srv infrastructure"
  echo "  2. Deploy your first application"
  echo "  3. Configure Cloudflare tunnel routing"
  echo "  4. Set up monitoring dashboards"
  echo ""
  echo -e "${YELLOW}Estimated time: 10-15 minutes${NC}"
  echo ""

  pause
}

init_infrastructure() {
  print_header "Step 1: Initialize Infrastructure"

  echo "Creating /srv directory structure for your applications..."
  echo ""
  echo -e "${CYAN}What will be created:${NC}"
  echo "  /srv/infrastructure/    - Reverse proxy, monitoring (git tracked)"
  if [ "$SETUP_PROFILE" = "full-stack" ]; then
    echo "  /srv/apps/              - Your applications (dev/staging/prod)"
  else
    echo "  /srv/services/          - Your services"
  fi
  echo "  /srv/static/            - Static files (images, assets)"
  echo "  /var/secrets/           - Secrets (NOT in git)"
  echo ""

  if [ -d "/srv/infrastructure" ]; then
    print_warning "/srv/infrastructure already exists"
    if ! confirm "Re-initialize infrastructure?"; then
      print_info "Skipping infrastructure initialization"
      return 0
    fi
  fi

  if confirm "Initialize /srv infrastructure now?" "y"; then
    print_step "Creating directory structure..."

    local infra_root="/srv/infrastructure"

    # Base directories
    $SUDO mkdir -p "$infra_root" /srv/static
    if [ "$SETUP_PROFILE" = "full-stack" ]; then
      $SUDO mkdir -p /var/secrets/{dev,staging,production}
    else
      $SUDO mkdir -p /var/secrets/production
    fi

    # Permissions
    $SUDO chown -R sysadmin:sysadmin "$infra_root" /srv/static 2>/dev/null || true
    $SUDO chmod 755 "$infra_root" /srv/static 2>/dev/null || true

    local secrets_group="hosting-secrets"
    if getent group "$secrets_group" >/dev/null 2>&1; then
      $SUDO chown -R root:"$secrets_group" /var/secrets
      $SUDO chmod 750 /var/secrets
      $SUDO find /var/secrets -type d -exec chmod 750 {} \;
      $SUDO find /var/secrets -type f -name '*.txt' -exec chmod 640 {} \; 2>/dev/null || true
    else
      print_warning "Group '$secrets_group' not found; securing /var/secrets as root-only (700)"
      $SUDO chown -R root:root /var/secrets
      $SUDO chmod 700 /var/secrets
      $SUDO find /var/secrets -type d -exec chmod 700 {} \;
    fi

	    # Copy templates (idempotent: only if reverse-proxy is missing)
	    if [ ! -f "${infra_root}/reverse-proxy/compose.yml" ]; then
	      print_step "Copying infrastructure templates..."
	      # Copy the whole infra tree (including dotfiles) without deleting existing state.
	      $SUDO cp -a "$PROJECT_ROOT/infra/." "$infra_root/"
	      $SUDO chown -R sysadmin:sysadmin "$infra_root" 2>/dev/null || true
	      print_success "Templates copied to $infra_root"
	    else
	      print_info "Infrastructure templates already present (skipping copy)"
	    fi

    # Start reverse proxy (Caddy)
    if [ -f "${infra_root}/reverse-proxy/compose.yml" ]; then
      ensure_docker_access
      print_step "Ensuring Docker networks exist..."
      if [ -x "$PROJECT_ROOT/scripts/create-networks.sh" ]; then
        $SUDO "$PROJECT_ROOT/scripts/create-networks.sh" || print_warning "Network creation reported an error (continuing)"
      else
        print_warning "Missing script: $PROJECT_ROOT/scripts/create-networks.sh"
	      fi
	      print_step "Starting reverse proxy..."
	      if run_compose "${infra_root}/reverse-proxy" --compatibility up -d; then
	        print_success "Reverse proxy started"
	      else
	        print_error "Failed to start reverse proxy (sudo docker compose --compatibility up -d)"
	      fi
	    else
      print_warning "Reverse proxy compose.yml not found at ${infra_root}/reverse-proxy/compose.yml"
    fi

    print_success "Infrastructure initialized!"
    echo ""
    pause
  else
    print_info "Skipped infrastructure initialization"
  fi
}

choose_first_app() {
  print_header "Step 2: Choose Your First Application"

  echo "Select what you'd like to deploy first:"
  echo ""

  local options=(
    "n8n - Workflow Automation (no-code automation platform)"
    "NocoDB - Airtable Alternative (spreadsheet as database)"
    "Plausible - Privacy-friendly Analytics"
    "Uptime Kuma - Uptime Monitoring Dashboard"
    "Custom Application (I have my own Docker app)"
    "Skip (I'll deploy manually later)"
  )

  show_menu "Available Applications:" "${options[@]}"

  local choice
  choice=$(get_choice "${#options[@]}")

  case $choice in
    0)
      print_info "Exiting wizard"
      exit 0
      ;;
    1)
      deploy_n8n
      ;;
    2)
      deploy_nocodb
      ;;
    3)
      deploy_plausible
      ;;
    4)
      deploy_uptime_kuma
      ;;
    5)
      deploy_custom_app
      ;;
    6)
      print_info "Skipping application deployment"
      ;;
  esac
}

deploy_n8n() {
  print_header "Deploying n8n Workflow Automation"

  echo "n8n is a powerful workflow automation tool (like Zapier, but self-hosted)."
  echo ""
  echo -e "${CYAN}What you'll get:${NC}"
  echo "  • Workflow builder with 400+ integrations"
  echo "  • Visual flow designer"
  echo "  • Webhooks and scheduled triggers"
  echo "  • Data transformation and processing"
  echo ""

  if ! confirm "Deploy n8n now?" "y"; then
    return 0
  fi

  local subdomain
  read -rp "Subdomain for n8n (e.g., 'n8n' for n8n.${DOMAIN}): " subdomain
  subdomain=${subdomain:-n8n}

  ensure_docker_access

  local image
  image="$(prompt_image "n8nio/n8n:latest" "n8n")"

  print_step "Creating n8n configuration..."

  # Create app directory
  local app_dir="/srv/apps/production/n8n"
  create_app_dir "$app_dir"

  # Create compose.yml
  $SUDO tee "$app_dir/compose.yml" >/dev/null << EOF
services:
  n8n:
    image: ${image}
    container_name: n8n-production
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    environment:
      - N8N_HOST=${subdomain}.${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=http  # Cloudflare handles HTTPS
      - N8N_EDITOR_BASE_URL=https://${subdomain}.${DOMAIN}/
      - WEBHOOK_URL=https://${subdomain}.${DOMAIN}/
    volumes:
      - n8n_data:/home/node/.n8n
    networks:
      - prod-web
    security_opt:
      - no-new-privileges:true
	    cap_drop:
	      - ALL
	    read_only: true
	    tmpfs:
	      - /tmp:size=64M,mode=1777
	    deploy:
	      resources:
	        limits:
	          cpus: '1.0'
	          memory: 1G
	          pids: 200
	        reservations:
	          cpus: '0.25'
	          memory: 256M

volumes:
  n8n_data:

networks:
  prod-web:
    external: true
EOF

	  print_success "Configuration created"

	  print_step "Starting n8n..."
	  if ! run_compose "$app_dir" --compatibility up -d; then
	    print_error "Failed to start n8n (sudo docker compose --compatibility up -d)"
	    return 1
	  fi

  print_success "n8n deployed!"
  echo ""
  echo -e "${CYAN}Next Steps:${NC}"
  echo "  1. Add Caddy route for ${subdomain}.${DOMAIN}"
  echo "  2. Add DNS CNAME in Cloudflare"
  echo "  3. Access https://${subdomain}.${DOMAIN}"
  echo ""

  pause

  # Offer to configure Caddy
  configure_caddy "$subdomain" "n8n-production" "5678"
}

deploy_nocodb() {
  print_header "Deploying NocoDB"

  echo "NocoDB turns any MySQL, PostgreSQL, SQL Server, SQLite & MariaDB into a"
  echo "smart spreadsheet (like Airtable)."
  echo ""
  echo -e "${CYAN}What you'll get:${NC}"
  echo "  • Spreadsheet interface for your database"
  echo "  • REST & GraphQL APIs"
  echo "  • Collaboration features"
  echo "  • Forms and views"
  echo ""

  if ! confirm "Deploy NocoDB now?" "y"; then
    return 0
  fi

  local subdomain
  read -rp "Subdomain for NocoDB (e.g., 'nocodb' for nocodb.${DOMAIN}): " subdomain
  subdomain=${subdomain:-nocodb}

  ensure_docker_access

  local image
  image="$(prompt_image "nocodb/nocodb:latest" "NocoDB")"

  print_step "Creating NocoDB configuration..."

  local app_dir="/srv/apps/production/nocodb"
  create_app_dir "$app_dir"

  $SUDO tee "$app_dir/compose.yml" >/dev/null << EOF
services:
  nocodb:
    image: ${image}
    container_name: nocodb-production
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    environment:
      - NC_PUBLIC_URL=https://${subdomain}.${DOMAIN}
    volumes:
      - nocodb_data:/usr/app/data
    networks:
      - prod-web
    security_opt:
      - no-new-privileges:true
	    cap_drop:
	      - ALL
	    read_only: true
	    tmpfs:
	      - /tmp:size=64M,mode=1777
	    deploy:
	      resources:
	        limits:
	          cpus: '1.0'
	          memory: 1G
	          pids: 200
	        reservations:
	          cpus: '0.25'
	          memory: 256M

volumes:
  nocodb_data:

networks:
  prod-web:
    external: true
EOF

	  print_success "Configuration created"

	  print_step "Starting NocoDB..."
	  if ! run_compose "$app_dir" --compatibility up -d; then
	    print_error "Failed to start NocoDB (sudo docker compose --compatibility up -d)"
	    return 1
	  fi

  print_success "NocoDB deployed!"
  echo ""

  pause
  configure_caddy "$subdomain" "nocodb-production" "8080"
}

deploy_plausible() {
  print_header "Deploying Plausible Analytics"

  echo "Plausible is a lightweight, privacy-friendly Google Analytics alternative."
  echo ""
  echo -e "${YELLOW}Note: Plausible requires PostgreSQL and ClickHouse (uses more resources)${NC}"
  echo ""

  if ! confirm "Deploy Plausible Analytics?" "y"; then
    return 0
  fi

  print_warning "Plausible is more complex - it requires:"
  print_info "  • PostgreSQL database"
  print_info "  • ClickHouse analytics database"
  print_info "  • ~2GB RAM minimum"
  echo ""
  print_info "For a simpler setup, consider Umami instead."
  echo ""

  if ! confirm "Continue with Plausible deployment?"; then
    return 0
  fi

  # Provide manual instructions
  echo ""
  print_info "Plausible deployment guide:"
  print_command "git clone https://github.com/plausible/hosting /srv/apps/production/plausible"
  print_command "cd /srv/apps/production/plausible"
  print_command "vim docker-compose.yml  # Configure your domain"
  print_command "sudo docker compose --compatibility up -d"
  echo ""
  print_info "See: https://plausible.io/docs/self-hosting"
  echo ""

  pause
}

deploy_uptime_kuma() {
  print_header "Deploying Uptime Kuma"

  echo "Uptime Kuma is a self-hosted monitoring tool (like UptimeRobot)."
  echo ""
  echo -e "${CYAN}What you'll get:${NC}"
  echo "  • Website uptime monitoring"
  echo "  • Status pages"
  echo "  • Notifications (email, Slack, Discord)"
  echo "  • Beautiful dashboards"
  echo ""

  if ! confirm "Deploy Uptime Kuma now?" "y"; then
    return 0
  fi

  local subdomain
  read -rp "Subdomain for Uptime Kuma (e.g., 'status' for status.${DOMAIN}): " subdomain
  subdomain=${subdomain:-status}

  ensure_docker_access

  local image
  image="$(prompt_image "louislam/uptime-kuma:latest" "Uptime Kuma")"

  print_step "Creating Uptime Kuma configuration..."

  local app_dir="/srv/apps/production/uptime-kuma"
  create_app_dir "$app_dir"

  $SUDO tee "$app_dir/compose.yml" >/dev/null << EOF
services:
  uptime-kuma:
    image: ${image}
    container_name: uptime-kuma-production
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    volumes:
      - uptime_kuma_data:/app/data
    networks:
      - prod-web
    security_opt:
      - no-new-privileges:true
	    cap_drop:
	      - ALL
	    read_only: true
	    tmpfs:
	      - /tmp:size=64M,mode=1777
	    deploy:
	      resources:
	        limits:
	          cpus: '0.5'
	          memory: 512M
	          pids: 200
	        reservations:
	          cpus: '0.1'
	          memory: 128M

volumes:
  uptime_kuma_data:

networks:
  prod-web:
    external: true
EOF

	  print_success "Configuration created"

	  print_step "Starting Uptime Kuma..."
	  if ! run_compose "$app_dir" --compatibility up -d; then
	    print_error "Failed to start Uptime Kuma (sudo docker compose --compatibility up -d)"
	    return 1
	  fi

  print_success "Uptime Kuma deployed!"
  echo ""

  pause
  configure_caddy "$subdomain" "uptime-kuma-production" "3001"
}

deploy_custom_app() {
  print_header "Deploy Custom Application"

  echo "Let's set up your custom Docker application."
  echo ""

  read -rp "Application name (lowercase, no spaces): " app_name
  read -rp "Subdomain (e.g., 'api' for api.${DOMAIN}): " subdomain
  read -rp "Container name (e.g., myapp-production): " container_name
  read -rp "Internal port (e.g., 3000): " port

  local app_dir="/srv/apps/production/${app_name}"
  create_app_dir "$app_dir"

  print_info "Created directory: $app_dir"
  echo ""
  print_info "Next steps:"
  echo "  1. Place your compose.yml in $app_dir"
  echo "  2. Ensure container name matches: ${container_name}"
  echo "  3. Ensure it connects to 'prod-web' network"
  echo "  4. Start with: sudo docker compose --compatibility up -d"
  echo ""

  pause
  configure_caddy "$subdomain" "$container_name" "$port"
}

configure_caddy() {
  local subdomain="$1"
  local container_name="$2"
  local port="$3"

  print_header "Step 3: Configure Reverse Proxy"

  echo "To make ${subdomain}.${DOMAIN} accessible, we need to:"
  echo "  1. Add a route in Caddy (reverse proxy)"
  echo "  2. Add a DNS CNAME in Cloudflare"
  echo ""

  if ! confirm "Configure Caddy routing now?" "y"; then
    print_info "Skipped Caddy configuration"
    echo ""
    print_warning "Manual Caddy setup required:"
    print_command "vim /srv/infrastructure/reverse-proxy/Caddyfile"
    echo ""
    print_info "Add this block:"
    echo ""
    echo "http://${subdomain}.${DOMAIN} {"
    echo "  import tunnel_only"
    echo "  import security_headers"
    echo "  reverse_proxy ${container_name}:${port} {"
    echo "    import proxy_headers"
    echo "  }"
    echo "}"
    echo ""
    pause
    return 0
  fi

  if ! add_caddy_route_only "$subdomain" "$container_name" "$port"; then
    return 1
  fi

  configure_dns "$subdomain"
}

add_caddy_route_only() {
  local subdomain="$1"
  local container_name="$2"
  local port="$3"

  local caddyfile="/srv/infrastructure/reverse-proxy/Caddyfile"

  if [ ! -f "$caddyfile" ]; then
    print_error "Caddyfile not found: $caddyfile"
    print_info "Please initialize infrastructure first"
    return 1
  fi

  print_step "Adding route to Caddyfile..."

  if grep -qF "http://${subdomain}.${DOMAIN}" "$caddyfile"; then
    print_warning "A route for ${subdomain}.${DOMAIN} already exists in the Caddyfile."
    if ! confirm "Append another block anyway?"; then
      return 0
    fi
  fi

  # Add route to Caddyfile
  $SUDO tee -a "$caddyfile" >/dev/null << EOF

# ${subdomain} - Added by wizard $(date)
http://${subdomain}.${DOMAIN} {
  import tunnel_only
  import security_headers
  reverse_proxy ${container_name}:${port} {
    import proxy_headers
  }
}
EOF

  print_success "Route added to Caddyfile"

  # Reload Caddy
  print_step "Reloading Caddy..."
  if [ -f "$SCRIPT_DIR/update-caddy.sh" ]; then
    $SUDO "$SCRIPT_DIR/update-caddy.sh"
  else
    $SUDO docker compose -f /srv/infrastructure/reverse-proxy/compose.yml restart caddy
  fi

  print_success "Caddy reloaded!"
  return 0
}

configure_dns() {
  local subdomain="$1"

  print_header "Step 4: Configure Cloudflare DNS"

  echo "To access your application, add a DNS record in Cloudflare:"
  echo ""
  echo -e "${CYAN}Cloudflare Dashboard:${NC}"
  print_command "https://dash.cloudflare.com"
  echo ""
  echo -e "${CYAN}DNS Record to Add:${NC}"
  echo "  Type:   CNAME"
  echo "  Name:   ${subdomain}"
  echo "  Target: <your-tunnel-id>.cfargotunnel.com"
  echo "  Proxy:  ON (orange cloud)"
  echo ""
  print_info "Find your tunnel ID in Cloudflare Zero Trust dashboard"
  print_command "https://one.dash.cloudflare.com"
  echo ""

  pause

  print_success "Setup Complete!"
  echo ""
  echo -e "${GREEN}Your application is now accessible at:${NC}"
  echo -e "${BOLD}  https://${subdomain}.${DOMAIN}${NC}"
  echo ""
  print_warning "Note: DNS propagation may take 1-2 minutes"
  echo ""

  pause
}

setup_monitoring_agent() {
  print_header "Monitoring Agent (Exporters)"

  echo "Recommended with a separate monitoring VPS (Prometheus/Grafana/alerting)."
  echo ""
  echo "What this enables on this VPS:"
  echo "  • node-exporter (system metrics)"
  echo "  • dockerd-metrics-proxy (Docker daemon metrics; no docker.sock)"
  echo ""
  echo -e "${CYAN}Docs:${NC}"
  print_command "cat docs/18-monitoring-server.md"
  echo ""

  ensure_docker_access

  local infra_root="/srv/infrastructure"
  local agent_dir="${infra_root}/monitoring-agent"
  if [ ! -d "$agent_dir" ]; then
    print_error "Monitoring agent not found at: $agent_dir"
    print_info "Initialize infrastructure first (wizard step 1) or run ./setup.sh"
    pause
    return 1
  fi

  print_step "Ensuring Docker networks exist..."
  if [ -x "$PROJECT_ROOT/scripts/create-networks.sh" ]; then
    $SUDO "$PROJECT_ROOT/scripts/create-networks.sh" || print_warning "Network creation reported an error (continuing)"
  else
    print_warning "Missing script: $PROJECT_ROOT/scripts/create-networks.sh"
  fi

  if [ ! -f "${agent_dir}/.env" ] && [ -f "${agent_dir}/.env.example" ]; then
    print_step "Creating monitoring-agent .env from .env.example..."
    $SUDO cp "${agent_dir}/.env.example" "${agent_dir}/.env"
    $SUDO chown sysadmin:sysadmin "${agent_dir}/.env" 2>/dev/null || true
  fi

  local enable_cadvisor="no"
  if confirm "Enable per-container metrics via cAdvisor? (requires docker.sock; higher privilege)" "n"; then
    enable_cadvisor="yes"
  fi

  print_step "Starting monitoring agent..."
  if [ "$enable_cadvisor" = "yes" ]; then
    if ! run_compose "$agent_dir" --compatibility -f compose.yml -f compose.cadvisor.yml up -d; then
      print_error "Failed to start monitoring agent (cAdvisor enabled)"
      pause
      return 1
    fi
  else
    if ! run_compose "$agent_dir" --compatibility up -d; then
      print_error "Failed to start monitoring agent"
      pause
      return 1
    fi
  fi

  print_success "Monitoring agent started"
  echo ""

  if confirm "Add Caddy routes for scrape endpoints (recommended)?" "y"; then
    local label=""
    echo ""
    echo "Optional label to distinguish this VPS in DNS."
    echo "Cloudflare Free Universal SSL covers one-level names (e.g., metrics-app1.${DOMAIN}), not metrics.app1.${DOMAIN}."
    echo ""
    read -rp "Label [blank for none]: " label
    label="$(echo "$label" | xargs | tr '[:upper:]' '[:lower:]')"

    while [ -n "$label" ] && [[ ! "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; do
      print_error "Invalid label: '$label' (use letters/numbers/hyphens only)"
      read -rp "Label [blank for none]: " label
      label="$(echo "$label" | xargs | tr '[:upper:]' '[:lower:]')"
    done

    local metrics_sub="metrics"
    local docker_metrics_sub="docker-metrics"
    local cadvisor_sub="cadvisor"
    if [ -n "$label" ]; then
      metrics_sub="metrics-${label}"
      docker_metrics_sub="docker-metrics-${label}"
      cadvisor_sub="cadvisor-${label}"
    fi

    add_caddy_route_only "$metrics_sub" "node-exporter" "9100"
    add_caddy_route_only "$docker_metrics_sub" "dockerd-metrics-proxy" "9324"
    if [ "$enable_cadvisor" = "yes" ]; then
      add_caddy_route_only "$cadvisor_sub" "cadvisor" "8080"
    fi

    echo ""
    print_info "DNS note:"
    echo "  If you already have a wildcard CNAME (*.${DOMAIN}) to your tunnel, you're done."
    echo "  Otherwise create CNAME records for:"
    echo "    • ${metrics_sub}.${DOMAIN}"
    echo "    • ${docker_metrics_sub}.${DOMAIN}"
    if [ "$enable_cadvisor" = "yes" ]; then
      echo "    • ${cadvisor_sub}.${DOMAIN}"
    fi
    echo ""

    print_warning "Protect these hostnames in Cloudflare Zero Trust with Access -> Service Auth (service token)."
    print_info "Guide: docs/14-cloudflare-zero-trust.md"
    echo ""
  fi

  pause
  return 0
}

setup_netdata() {
  print_header "Local Netdata (Dashboard)"

  echo "Netdata is convenient for quick visibility, but requires elevated host visibility"
  echo "(extra capabilities, relaxed AppArmor, and docker.sock)."
  echo ""
  print_warning "Only enable Netdata if you will protect it with Cloudflare Access (SSO/OTP)."
  echo ""

  if ! confirm "Start local Netdata now?"; then
    return 0
  fi

  ensure_docker_access

  local infra_root="/srv/infrastructure"
  local mon_dir="${infra_root}/monitoring"
  if [ ! -d "$mon_dir" ]; then
    print_error "Netdata stack not found at: $mon_dir"
    print_info "Initialize infrastructure first (wizard step 1) or run ./setup.sh"
    pause
    return 1
  fi

  print_step "Ensuring Docker networks exist..."
  if [ -x "$PROJECT_ROOT/scripts/create-networks.sh" ]; then
    $SUDO "$PROJECT_ROOT/scripts/create-networks.sh" || print_warning "Network creation reported an error (continuing)"
  else
    print_warning "Missing script: $PROJECT_ROOT/scripts/create-networks.sh"
  fi

  if [ ! -f "${mon_dir}/.env" ] && [ -f "${mon_dir}/.env.example" ]; then
    print_step "Creating Netdata .env from .env.example..."
    $SUDO cp "${mon_dir}/.env.example" "${mon_dir}/.env"
    $SUDO chown sysadmin:sysadmin "${mon_dir}/.env" 2>/dev/null || true
  fi

  print_step "Starting Netdata..."
  if ! run_compose "$mon_dir" --compatibility up -d; then
    print_error "Failed to start Netdata"
    pause
    return 1
  fi
  print_success "Netdata started"
  echo ""

  if confirm "Add Caddy route monitoring.${DOMAIN} now?" "y"; then
    add_caddy_route_only "monitoring" "netdata" "19999"
    echo ""
    print_warning "Protect monitoring.${DOMAIN} with Cloudflare Access Allow (SSO/OTP)."
    print_info "Guide: docs/14-cloudflare-zero-trust.md"
  else
    echo ""
    print_info "Enable later by editing /srv/infrastructure/reverse-proxy/Caddyfile"
  fi

  pause
  return 0
}

setup_monitoring() {
  print_header "Optional: Set Up Monitoring"

  echo "For an extremely secure setup, prefer a separate monitoring VPS."
  echo ""
  echo "Why separate?"
  echo "  • Your app VPS should not hold credentials to its own monitoring/control plane"
  echo "  • Monitoring UIs should be protected behind Cloudflare Access (SSO/Service Auth)"
  echo ""

  local options=(
    "Enable monitoring-agent exporters (recommended with separate monitoring VPS)"
    "Enable local Netdata dashboard (higher privilege; protect with Access)"
    "Skip monitoring setup"
  )

  show_menu "Monitoring Options:" "${options[@]}"
  local choice
  choice=$(get_choice "${#options[@]}")

  case "$choice" in
    0)
      print_info "Exiting wizard"
      exit 0
      ;;
    1)
      setup_monitoring_agent
      ;;
    2)
      setup_netdata
      ;;
    3)
      print_info "Skipping monitoring setup"
      echo ""
      print_info "Docs:"
      print_command "cat docs/17-monitoring-separate-vps.md"
      print_command "cat docs/18-monitoring-server.md"
      print_command "cat docs/14-cloudflare-zero-trust.md"
      echo ""
      pause
      ;;
  esac
}

show_completion() {
  print_header "🎉 Wizard Complete!"

  echo -e "${GREEN}${BOLD}Congratulations!${NC} Your hardened VM is ready for production."
  echo ""
  echo -e "${CYAN}What You've Accomplished:${NC}"
  echo "  ✓ Initialized /srv infrastructure"
  echo "  ✓ Deployed your first application"
  echo "  ✓ Configured reverse proxy routing"
  echo "  ✓ Set up Cloudflare DNS"
  echo ""
  echo -e "${CYAN}Next Steps:${NC}"
  echo ""
  echo -e "1. ${BOLD}Deploy More Applications${NC}"
  echo "   Copy templates from /opt/hosting-blueprint/apps/"
  echo ""
  echo -e "2. ${BOLD}Set Up Secrets${NC}"
  print_command "./scripts/secrets/create-secret.sh production db_password"
  echo ""
  echo -e "3. ${BOLD}Enable CI/CD${NC}"
  print_command "./scripts/init-gitops.sh"
  echo ""
  echo -e "4. ${BOLD}Configure Backups${NC}"
  print_command "crontab -e  # Add backup cron jobs"
  echo ""
  echo -e "5. ${BOLD}Monitor Your System${NC}"
  echo "   Prefer a separate monitoring VPS (recommended) or use Netdata locally with Cloudflare Access"
  echo ""
  echo -e "${CYAN}Useful Commands:${NC}"
  echo ""
  print_command "docker ps                  # View running containers"
  print_command "./scripts/monitoring/status.sh    # System status"
  print_command "./scripts/monitoring/logs.sh      # View logs"
  echo ""
  echo -e "${CYAN}Documentation:${NC}"
  echo "  • Full guides: /opt/hosting-blueprint/docs/"
  echo "  • Quick reference: docs/quick-reference.md"
  echo "  • Architecture: docs/04-architecture.md"
  echo ""
  echo -e "${GREEN}Happy Hosting!${NC} 🚀"
  echo ""
}

# =================================================================
# Main
# =================================================================

main() {
  # Load configuration
  load_config

  # Check if running as root
  if [ "$EUID" -eq 0 ]; then
    print_warning "This wizard should be run as a regular user (not root)"
    print_info "Some commands will use sudo when needed"
    echo ""
    if ! confirm "Continue anyway?"; then
      exit 1
    fi
  fi

  # Run wizard steps based on server profile
  welcome

  if [ "$SETUP_PROFILE" = "full-stack" ]; then
    init_infrastructure
    choose_first_app
    setup_monitoring
  elif [ "$SETUP_PROFILE" = "monitoring" ]; then
    init_infrastructure
    echo ""
    print_info "Server profile: monitoring"
    print_info "Skipping app deployment (no environments configured)."
    echo ""
    setup_monitoring
  else
    init_infrastructure
    echo ""
    print_info "Server profile: minimal"
    print_info "Add services manually or use: sudo /opt/hosting-blueprint/scripts/add-subdomain.sh"
    echo ""
    pause
  fi

  show_completion
}

# Run main function
main "$@"
