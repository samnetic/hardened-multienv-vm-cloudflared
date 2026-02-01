#!/usr/bin/env bash
#
# Set Up Infrastructure Repository
# Creates /srv/infrastructure from template and optionally pushes to GitHub
#
# Usage:
#   sudo ./scripts/setup-infrastructure-repo.sh [domain] [github-repo-name]
#   sudo ./scripts/setup-infrastructure-repo.sh codeagen.com codeagen-infrastructure
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
echo "  • Copy templates from /opt/hosting-blueprint"
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
  read -rp "Enter your domain (e.g., codeagen.com): " DOMAIN
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
if [ -d "/srv/infrastructure" ]; then
  print_warning "/srv/infrastructure already exists!"
  if ! confirm "Backup and overwrite?"; then
    print_error "Setup cancelled"
    exit 1
  fi
  BACKUP="/srv/infrastructure.backup.$(date +%s)"
  print_step "Backing up to $BACKUP"
  mv /srv/infrastructure "$BACKUP"
  print_success "Backup created"
fi

# Step 1: Create directories
print_header "Step 1/7: Create Directory Structure"
print_step "Creating directories..."
mkdir -p /srv/infrastructure /srv/apps /var/secrets/{dev,staging,production}
print_success "Directories created"
echo "  /srv/infrastructure"
echo "  /srv/apps"
echo "  /var/secrets/{dev,staging,production}"

# Step 2: Set permissions
print_header "Step 2/7: Set Permissions"
print_step "Setting ownership to $ORIGINAL_USER..."
chown -R $ORIGINAL_USER:$ORIGINAL_USER /srv/infrastructure /srv/apps /var/secrets
chmod 700 /var/secrets
find /var/secrets -type d -exec chmod 700 {} \;
print_success "Permissions set"

# Step 3: Copy templates
print_header "Step 3/7: Copy Templates"
if [ ! -d "/opt/hosting-blueprint/infra" ]; then
  print_error "Template not found at /opt/hosting-blueprint"
  print_info "Run: cd /opt/hosting-blueprint && git pull"
  exit 1
fi

print_step "Copying infrastructure templates..."
cp -r /opt/hosting-blueprint/infra/* /srv/infrastructure/
print_step "Copying app templates..."
cp -r /opt/hosting-blueprint/apps/* /srv/apps/
print_step "Copying config files..."
[ -f "/opt/hosting-blueprint/.gitignore" ] && cp /opt/hosting-blueprint/.gitignore /srv/infrastructure/
print_success "Templates copied"

# Step 4: Configure domain
print_header "Step 4/7: Configure Domain"
print_step "Updating Caddyfile: yourdomain.com → $DOMAIN"
sed -i "s/yourdomain.com/$DOMAIN/g" /srv/infrastructure/reverse-proxy/Caddyfile
print_success "Caddyfile updated"
echo ""
print_info "Configured subdomains:"
grep -o "http://[^{]*$DOMAIN" /srv/infrastructure/reverse-proxy/Caddyfile | sed 's/http:\/\//  - /' | sort -u

# Step 5: Initialize git
print_header "Step 5/7: Initialize Git Repository"
cd /srv/infrastructure
print_step "Initializing git..."
su - $ORIGINAL_USER -c "cd /srv/infrastructure && git init && git add . && git commit -m 'Initial infrastructure for $DOMAIN'"
print_success "Git repository initialized"

# Step 6: Create GitHub repo
print_header "Step 6/7: Create GitHub Repository (Optional)"
SKIP_GITHUB=false
if ! command -v gh &> /dev/null; then
  print_warning "GitHub CLI not installed"
  print_info "Install: https://cli.github.com/"
  SKIP_GITHUB=true
elif ! su - $ORIGINAL_USER -c "gh auth status" &>/dev/null; then
  print_warning "GitHub CLI not authenticated"
  print_info "Run: gh auth login"
  SKIP_GITHUB=true
fi

if [ "$SKIP_GITHUB" = false ] && confirm "Create GitHub repo and push?" "y"; then
  print_step "Creating private GitHub repository..."
  if su - $ORIGINAL_USER -c "cd /srv/infrastructure && gh repo create $GITHUB_REPO --private --source=. --remote=origin --push" 2>&1; then
    REPO_URL=$(su - $ORIGINAL_USER -c "cd /srv/infrastructure && gh repo view --json url -q .url" 2>/dev/null || echo "")
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
  print_step "Validating Caddyfile..."
  if docker run --rm -v "/srv/infrastructure/reverse-proxy/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:latest caddy validate --config /etc/caddy/Caddyfile 2>&1; then
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
      print_info "Check logs: docker compose -f /srv/infrastructure/reverse-proxy/compose.yml logs"
    fi
  else
    print_error "Caddyfile validation failed"
    print_info "Start manually after fixing: cd /srv/infrastructure/reverse-proxy && docker compose up -d"
  fi
else
  print_info "Start Caddy later: cd /srv/infrastructure/reverse-proxy && docker compose up -d"
fi

# Summary
print_header "Setup Complete! 🚀"
echo -e "${GREEN}✓ Infrastructure initialized successfully${NC}"
echo ""
echo -e "${CYAN}Directory Structure:${NC}"
echo "  /srv/infrastructure/  → Infrastructure code (Caddy, configs)"
echo "  /srv/apps/            → Your applications"
echo "  /var/secrets/         → Encrypted secrets"
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
echo "   docker compose up -d"
echo ""
echo "4. Check DNS Exposure"
echo "   sudo /opt/hosting-blueprint/scripts/check-dns-exposure.sh $DOMAIN"
echo ""
echo "5. Set Up CI/CD (Optional)"
echo "   /opt/hosting-blueprint/scripts/init-gitops.sh"
echo ""
print_success "Ready to deploy!"
