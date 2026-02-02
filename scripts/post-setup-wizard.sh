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
  echo "  /srv/apps/              - Your applications (dev/staging/prod)"
  echo "  /srv/static/            - Static files (images, assets)"
  echo "  /var/secrets/           - Encrypted secrets (NOT in git)"
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

    # Use the init-infrastructure.sh script if it exists
    if [ -f "$SCRIPT_DIR/init-infrastructure.sh" ]; then
      print_command "./scripts/init-infrastructure.sh"
      "$SCRIPT_DIR/init-infrastructure.sh"
    else
      # Fallback to manual creation
      sudo mkdir -p /srv/{infrastructure,apps/{dev,staging,production},static}
      sudo mkdir -p /var/secrets/{dev,staging,production}
      sudo chown -R "$USER:$USER" /srv /var/secrets
      sudo chmod 700 /var/secrets
      sudo find /var/secrets -type d -exec chmod 700 {} \;
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

  print_step "Creating n8n configuration..."

  # Create app directory
  local app_dir="/srv/apps/production/n8n"
  mkdir -p "$app_dir"

  # Create compose.yml
  cat > "$app_dir/compose.yml" << EOF
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n-production
    restart: unless-stopped
    ports:
      - "5678:5678"
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
    cap_add:
      - NET_BIND_SERVICE
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G

volumes:
  n8n_data:

networks:
  prod-web:
    external: true
EOF

  print_success "Configuration created"

  print_step "Starting n8n..."
  cd "$app_dir"
  docker compose up -d

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

  print_step "Creating NocoDB configuration..."

  local app_dir="/srv/apps/production/nocodb"
  mkdir -p "$app_dir"

  cat > "$app_dir/compose.yml" << EOF
services:
  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb-production
    restart: unless-stopped
    ports:
      - "8080:8080"
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
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G

volumes:
  nocodb_data:

networks:
  prod-web:
    external: true
EOF

  print_success "Configuration created"

  print_step "Starting NocoDB..."
  cd "$app_dir"
  docker compose up -d

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
  print_command "docker compose up -d"
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

  print_step "Creating Uptime Kuma configuration..."

  local app_dir="/srv/apps/production/uptime-kuma"
  mkdir -p "$app_dir"

  cat > "$app_dir/compose.yml" << EOF
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma-production
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - uptime_kuma_data:/app/data
    networks:
      - prod-web
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M

volumes:
  uptime_kuma_data:

networks:
  prod-web:
    external: true
EOF

  print_success "Configuration created"

  print_step "Starting Uptime Kuma..."
  cd "$app_dir"
  docker compose up -d

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
  mkdir -p "$app_dir"

  print_info "Created directory: $app_dir"
  echo ""
  print_info "Next steps:"
  echo "  1. Place your docker-compose.yml in $app_dir"
  echo "  2. Ensure container name matches: ${container_name}"
  echo "  3. Ensure it connects to 'prod-web' network"
  echo "  4. Start with: docker compose up -d"
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
    echo "  import security_headers"
    echo "  reverse_proxy ${container_name}:${port} {"
    echo "    import proxy_headers"
    echo "  }"
    echo "}"
    echo ""
    pause
    return 0
  fi

  local caddyfile="/srv/infrastructure/reverse-proxy/Caddyfile"

  if [ ! -f "$caddyfile" ]; then
    print_error "Caddyfile not found: $caddyfile"
    print_info "Please initialize infrastructure first"
    return 1
  fi

  print_step "Adding route to Caddyfile..."

  # Add route to Caddyfile
  cat >> "$caddyfile" << EOF

# ${subdomain} - Added by wizard $(date)
http://${subdomain}.${DOMAIN} {
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
    "$SCRIPT_DIR/update-caddy.sh"
  else
    docker compose -f /srv/infrastructure/reverse-proxy/compose.yml restart caddy
  fi

  print_success "Caddy reloaded!"

  configure_dns "$subdomain"
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

setup_monitoring() {
  print_header "Optional: Set Up Monitoring"

  echo "Would you like to deploy monitoring dashboards?"
  echo ""
  echo -e "${CYAN}Available monitoring tools:${NC}"
  echo "  • Portainer - Docker management UI"
  echo "  • Grafana - Metrics visualization"
  echo "  • Netdata - Real-time system monitoring"
  echo ""

  if ! confirm "Set up monitoring now?"; then
    print_info "Skipped monitoring setup"
    echo ""
    print_info "You can set up monitoring later using:"
    print_command "./scripts/monitoring/deploy-portainer.sh"
    print_command "./scripts/monitoring/deploy-grafana.sh"
    echo ""
    return 0
  fi

  # Deploy Portainer
  if confirm "Deploy Portainer (Docker UI)?" "y"; then
    print_step "Deploying Portainer..."
    # Provide instructions
    echo ""
    print_command "docker volume create portainer_data"
    print_command "docker run -d -p 9000:9000 --name portainer --restart always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce"
    echo ""
    print_info "Then add Caddy route for portainer.${DOMAIN}"
    echo ""
  fi

  pause
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
  echo "1. ${BOLD}Deploy More Applications${NC}"
  echo "   Copy templates from /opt/hosting-blueprint/apps/"
  echo ""
  echo "2. ${BOLD}Set Up Secrets${NC}"
  print_command "./scripts/secrets/create-secret.sh production db_password"
  echo ""
  echo "3. ${BOLD}Enable CI/CD${NC}"
  print_command "./scripts/init-gitops.sh"
  echo ""
  echo "4. ${BOLD}Configure Backups${NC}"
  print_command "crontab -e  # Add backup cron jobs"
  echo ""
  echo "5. ${BOLD}Monitor Your System${NC}"
  echo "   Set up Portainer, Grafana, or Netdata"
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

  # Run wizard steps
  welcome
  init_infrastructure
  choose_first_app
  setup_monitoring
  show_completion
}

# Run main function
main "$@"
