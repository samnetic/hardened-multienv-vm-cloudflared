#!/usr/bin/env bash
#
# Set Up Infrastructure Repository
# Creates /srv/infrastructure from template and optionally pushes to GitHub
#
# Usage:
#   sudo ./scripts/setup-infrastructure-repo.sh [domain] [github-repo-name]
#   sudo ./scripts/setup-infrastructure-repo.sh yourdomain.com myproject-infrastructure
#
# This script (run once on VM):
# 1. Creates /srv directory structure
# 2. Copies templates from hosting-blueprint
# 3. Updates domain in Caddyfile
# 4. Initializes git repository
# 5. Optionally creates GitHub repo and pushes
# 6. Starts Caddy reverse proxy
# 7. Validates setup

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Print functions
print_header() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

print_step() { echo -e "${GREEN}➜${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }

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

# Check root
if [ "$EUID" -ne 0 ]; then
  print_error "This script must be run as root"
  echo "Run: sudo $0"
  exit 1
fi

# Detect original user
if [ -n "${SUDO_USER:-}" ]; then
  ORIGINAL_USER="$SUDO_USER"
else
  ORIGINAL_USER="root"
fi

clear
print_header "Infrastructure Repository Setup"
echo -e "${CYAN}This script will:${NC}"
echo "  • Create /srv/infrastructure directory"
echo "  • Copy infrastructure templates from /opt/hosting-blueprint"
echo "  • Configure for your domain"
echo "  • Initialize git repository"
echo "  • Optionally create GitHub repo"
echo "  • Start Caddy reverse proxy"
echo ""

# Get domain
if [ -n "${1:-}" ]; then
  DOMAIN="$1"
elif [ -f "/opt/vm-config/setup.conf" ]; then
  DOMAIN=$(grep "^DOMAIN=" /opt/vm-config/setup.conf 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
fi

if [ -z "${DOMAIN:-}" ]; then
  read -rp "Enter your domain (e.g., yourdomain.com): " DOMAIN
  while [ -z "$DOMAIN" ]; do
    print_warning "Domain is required"
    read -rp "Domain: " DOMAIN
  done
fi

print_info "Domain: $DOMAIN"

# Get GitHub repo name
if [ -n "${2:-}" ]; then
  GITHUB_REPO="$2"
else
  DEFAULT_REPO="${DOMAIN%%.*}-infrastructure"
  read -rp "GitHub repository name [$DEFAULT_REPO]: " GITHUB_REPO
  GITHUB_REPO=${GITHUB_REPO:-$DEFAULT_REPO}
fi

print_info "GitHub repo: $GITHUB_REPO"
echo ""

if ! confirm "Continue with setup?" "y"; then
  echo "Setup cancelled"
  exit 0
fi

# Check if exists
INFRA_MODE="new"
if [ -d "/srv/infrastructure" ]; then
  print_warning "/srv/infrastructure already exists!"
  echo ""
  echo "Options:"
  echo "  1) Reuse existing (Recommended) - keep current infra repo and continue"
  echo "  2) Backup and overwrite - replace with fresh template"
  echo "  3) Exit"
  echo ""
  read -rp "Choice [1]: " infra_choice
  infra_choice="${infra_choice:-1}"

  case "$infra_choice" in
    1)
      INFRA_MODE="reuse"
      print_info "Reusing existing /srv/infrastructure"
      ;;
    2)
      INFRA_MODE="overwrite"
      BACKUP="/srv/infrastructure.backup.$(date +%s)"
      print_step "Backing up to $BACKUP"
      mv /srv/infrastructure "$BACKUP"
      print_success "Backup created"
      ;;
    3)
      print_info "Exiting."
      exit 0
      ;;
    *)
      print_error "Invalid choice: $infra_choice"
      exit 1
      ;;
  esac
fi

# Step 1: Create directories
print_header "Step 1/7: Create Directory Structure"
print_step "Creating directories..."
mkdir -p /srv/infrastructure /srv/static /srv/apps/{dev,staging,production} /var/secrets/{dev,staging,production}
print_success "Directories created"
echo "  /srv/infrastructure"
echo "  /srv/apps/{dev,staging,production}"
echo "  /srv/static"
echo "  /var/secrets/{dev,staging,production}"

# Step 2: Set permissions
print_header "Step 2/7: Set Permissions"
print_step "Setting ownership..."

SYSADMIN_USER="sysadmin"
APPMGR_USER="appmgr"

INFRA_OWNER="$ORIGINAL_USER"
APPS_OWNER="$ORIGINAL_USER"
if id "$SYSADMIN_USER" >/dev/null 2>&1; then
  INFRA_OWNER="$SYSADMIN_USER"
  # Keep /srv/apps owned by sysadmin. The CI user (appmgr) is restricted and should
  # not own application directories.
  APPS_OWNER="$SYSADMIN_USER"
fi

chown -R "$INFRA_OWNER:$INFRA_OWNER" /srv/infrastructure /srv/static
chown -R "$APPS_OWNER:$APPS_OWNER" /srv/apps
chmod 755 /srv/infrastructure /srv/static /srv/apps 2>/dev/null || true
chmod 755 /srv/apps/dev /srv/apps/staging /srv/apps/production 2>/dev/null || true

# Secrets are stored in /var/secrets (never in git). Keep them owned by root,
# but group-readable for containers via a dedicated host group (see setup-vm.sh).
SECRETS_GROUP="hosting-secrets"
if ! getent group "$SECRETS_GROUP" >/dev/null 2>&1; then
  print_error "Required group '$SECRETS_GROUP' not found"
  print_info "Run first: sudo ./scripts/setup-vm.sh"
  exit 1
fi
chown -R root:"$SECRETS_GROUP" /var/secrets
chmod 750 /var/secrets
find /var/secrets -type d -exec chmod 750 {} \;
find /var/secrets -type f -name '*.txt' -exec chmod 640 {} \; 2>/dev/null || true
print_success "Permissions set"

# Step 3: Copy templates
print_header "Step 3/7: Copy Templates"
if [ ! -d "/opt/hosting-blueprint/infra" ]; then
  print_error "Template not found at /opt/hosting-blueprint"
  print_info "Run: cd /opt/hosting-blueprint && git pull"
  exit 1
fi

print_step "Copying infrastructure templates..."
if [ "$INFRA_MODE" = "reuse" ]; then
  print_info "Reuse mode: not overwriting existing infra files. Copying missing template components only..."
  for entry in /opt/hosting-blueprint/infra/*; do
    name="$(basename "$entry")"
    if [ ! -e "/srv/infrastructure/$name" ]; then
      cp -r "$entry" /srv/infrastructure/
      print_success "Copied missing template: $name"
    fi
  done
  if [ -f "/opt/hosting-blueprint/.gitignore" ] && [ ! -f "/srv/infrastructure/.gitignore" ]; then
    cp /opt/hosting-blueprint/.gitignore /srv/infrastructure/
    print_success "Copied missing .gitignore"
  fi
else
  cp -r /opt/hosting-blueprint/infra/* /srv/infrastructure/
  print_step "Copying repo files..."
  [ -f "/opt/hosting-blueprint/.gitignore" ] && cp /opt/hosting-blueprint/.gitignore /srv/infrastructure/ || true
  print_success "Templates copied"
fi

# Step 4: Configure domain
print_header "Step 4/7: Configure Domain"
print_step "Updating Caddyfile: yourdomain.com → $DOMAIN"
CADDYFILE="/srv/infrastructure/reverse-proxy/Caddyfile"
if [ -f "$CADDYFILE" ]; then
  sed -i "s/yourdomain.com/$DOMAIN/g" "$CADDYFILE"
  print_success "Caddyfile updated"
  echo ""
  print_info "Configured subdomains:"
  grep -o "http://[^{]*$DOMAIN" "$CADDYFILE" | sed 's/http:\/\//  - /' | sort -u
else
  print_warning "Caddyfile not found at: $CADDYFILE (skipping domain replacement)"
fi

# Step 5: Initialize git
print_header "Step 5/7: Initialize Git Repository"
cd /srv/infrastructure
if [ -d "/srv/infrastructure/.git" ]; then
  print_success "Git repository already initialized (skipping git init/commit)"
else
  print_step "Initializing git..."
  su - "$ORIGINAL_USER" -c "cd /srv/infrastructure && git init && git add . && git commit -m 'Initial infrastructure for $DOMAIN'"
  print_success "Git repository initialized"
fi

# Step 6: Create GitHub repo
print_header "Step 6/7: Create GitHub Repository (Optional)"
SKIP_GITHUB=false
if ! command -v gh &> /dev/null; then
  print_warning "GitHub CLI not installed"
  print_info "Install: https://cli.github.com/"
  SKIP_GITHUB=true
elif ! su - "$ORIGINAL_USER" -c "gh auth status" &>/dev/null; then
  print_warning "GitHub CLI not authenticated"
  print_info "Run: gh auth login"
  SKIP_GITHUB=true
fi

if [ "$SKIP_GITHUB" = false ] && confirm "Create GitHub repo and push?" "y"; then
  # Optional: keep gh CLI synced to the expected account (useful if you manage multiple GH identities).
  if su - "$ORIGINAL_USER" -c "command -v gh-account-switcher" &>/dev/null; then
    print_step "Syncing GitHub account (gh-account-switcher)..."
    su - "$ORIGINAL_USER" -c "gh-account-switcher sync" >/dev/null 2>&1 || print_warning "gh-account-switcher sync failed (continuing)"
  fi

  print_step "Creating private GitHub repository..."
  if su - "$ORIGINAL_USER" -c "cd /srv/infrastructure && gh repo create $GITHUB_REPO --private --source=. --remote=origin --push" 2>&1; then
    REPO_URL=$(su - "$ORIGINAL_USER" -c "cd /srv/infrastructure && gh repo view --json url -q .url" 2>/dev/null || echo "")
    print_success "GitHub repository created!"
    [ -n "$REPO_URL" ] && print_info "URL: $REPO_URL"
  else
    print_warning "Failed to create GitHub repo (you can do this manually later)"
  fi
else
  print_info "Skipped GitHub repo creation"
  print_info "To create later: cd /srv/infrastructure && gh repo create $GITHUB_REPO --private --source=. --remote=origin --push"
fi

# Step 7: Start Caddy
print_header "Step 7/7: Start Caddy Reverse Proxy"
if confirm "Start Caddy now?" "y"; then
  print_step "Ensuring required Docker networks exist..."
  if [ -x /opt/hosting-blueprint/scripts/create-networks.sh ]; then
    /opt/hosting-blueprint/scripts/create-networks.sh || print_warning "Network creation script reported an error (continuing)"
  else
    print_warning "Missing /opt/hosting-blueprint/scripts/create-networks.sh"
    print_warning "Reverse proxy requires: hosting-caddy-origin, dev-web, staging-web, prod-web"
  fi

  print_step "Validating Caddyfile..."
  if docker run --rm --network none -v "/srv/infrastructure/reverse-proxy/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2-alpine caddy validate --config /etc/caddy/Caddyfile 2>&1; then
    print_success "Caddyfile is valid"
    print_step "Starting Caddy..."
    cd /srv/infrastructure/reverse-proxy
    docker compose up -d
    sleep 2
    if docker compose ps | grep -q "caddy.*Up"; then
      print_success "Caddy is running!"
      docker compose ps
    else
      print_error "Caddy failed to start"
      print_info "Check logs: sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml logs"
    fi
  else
    print_error "Caddyfile validation failed"
    print_info "Start manually after fixing: cd /srv/infrastructure/reverse-proxy && sudo docker compose up -d"
  fi
else
  print_info "Start Caddy later: cd /srv/infrastructure/reverse-proxy && sudo docker compose up -d"
fi

# Summary
print_header "Setup Complete! 🚀"
echo -e "${GREEN}✓ Infrastructure initialized successfully${NC}"
echo ""
echo -e "${CYAN}Directory Structure:${NC}"
echo "  /srv/infrastructure/  → Infrastructure code (Caddy, configs)"
echo "  /srv/apps/{env}/      → Your application deployments"
echo "  /var/secrets/         → Application secrets (NOT in git)"
echo ""
echo -e "${CYAN}Configuration:${NC}"
echo "  Domain: $DOMAIN"
[ -n "${REPO_URL:-}" ] && echo "  GitHub: $REPO_URL"
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo ""
echo "1. Configure DNS in Cloudflare Dashboard"
echo "   Add CNAME records pointing to your tunnel:"
for subdomain in $(grep -o "[a-z-]*\.$DOMAIN" /srv/infrastructure/reverse-proxy/Caddyfile | cut -d'.' -f1 | sort -u); do
  echo "   - $subdomain.$DOMAIN → <tunnel-id>.cfargotunnel.com (Orange cloud)"
done
echo ""
echo "2. Edit Caddy Configuration"
echo "   vim /srv/infrastructure/reverse-proxy/Caddyfile"
echo "   sudo /opt/hosting-blueprint/scripts/update-caddy.sh"
echo ""
echo "3. Deploy Your First App"
echo "   cd /srv/apps"
echo "   cp -r _template myapp && cd myapp"
echo "   vim compose.yml  # Configure"
echo "   sudo docker compose up -d"
echo ""
echo "4. Check DNS Exposure"
echo "   sudo /opt/hosting-blueprint/scripts/check-dns-exposure.sh $DOMAIN"
echo ""
echo "5. Set Up CI/CD (Optional)"
echo "   /opt/hosting-blueprint/scripts/init-gitops.sh"
echo ""
print_success "Ready to deploy!"
