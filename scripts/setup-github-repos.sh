#!/usr/bin/env bash
# =================================================================
# GitHub Repository Setup
# =================================================================
# Guided sub-menu wizard to:
#   1. Install GitHub CLI (gh)
#   2. Authenticate with GitHub
#   3. Push /srv/infrastructure as a private repo
#   4. Create a private deployments repo at /srv/deployments
#
# Usage:
#   sudo ./scripts/setup-github-repos.sh
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

# Paths
CONFIG_DIR="/opt/vm-config"
CONFIG_FILE="${CONFIG_DIR}/setup.conf"
AGE_KEY_FILE="/etc/sops/age/keys.txt"
INFRA_DIR="/srv/infrastructure"
DEPLOY_DIR="/srv/deployments"

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

print_step() { echo -e "${CYAN}>>> $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ $1${NC}"; }

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

# Wait for apt/dpkg locks (same pattern as install-cloudflared.sh)
wait_for_apt() {
  local timeout="${APT_LOCK_TIMEOUT:-300}"
  local start now elapsed
  start="$(date +%s)"

  while true; do
    local locked=false

    if command -v fuser >/dev/null 2>&1; then
      if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
         fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
         fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
         fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
        locked=true
      fi
    else
      if pgrep -x apt-get >/dev/null 2>&1 || \
         pgrep -x apt >/dev/null 2>&1 || \
         pgrep -x dpkg >/dev/null 2>&1 || \
         pgrep -f unattended-upgrade >/dev/null 2>&1; then
        locked=true
      fi
    fi

    if [ "$locked" = false ]; then
      return 0
    fi

    now="$(date +%s)"
    elapsed=$((now - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      print_error "Timed out waiting for apt/dpkg locks after ${timeout}s"
      echo "Try: sudo systemctl stop apt-daily.service apt-daily-upgrade.service"
      return 1
    fi

    echo "Waiting for apt/dpkg locks... (${elapsed}s)"
    sleep 5
  done
}

# Check root
if [ "$EUID" -ne 0 ]; then
  print_error "This script must be run as root"
  echo "Run: sudo $0"
  exit 1
fi

# Detect original user (who invoked sudo)
if [ -n "${SUDO_USER:-}" ]; then
  ORIGINAL_USER="$SUDO_USER"
else
  ORIGINAL_USER="root"
fi

# Load saved configuration
DOMAIN=""
SETUP_PROFILE=""
if [ -f "$CONFIG_FILE" ]; then
  set +u
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  set -u
fi

# =================================================================
# Status Detection Helpers
# =================================================================

is_gh_installed() {
  command -v gh &>/dev/null
}

get_gh_version() {
  gh --version 2>/dev/null | head -1 | sed 's/gh version //' | cut -d' ' -f1
}

is_gh_authenticated() {
  su - "$ORIGINAL_USER" -c "gh auth status" &>/dev/null
}

get_gh_user() {
  su - "$ORIGINAL_USER" -c "gh api user -q .login" 2>/dev/null || echo ""
}

get_infra_remote_url() {
  if [ -d "$INFRA_DIR/.git" ]; then
    su - "$ORIGINAL_USER" -c "cd $INFRA_DIR && git remote get-url origin" 2>/dev/null || echo ""
  fi
}

get_deployments_remote_url() {
  if [ -d "$DEPLOY_DIR/.git" ]; then
    su - "$ORIGINAL_USER" -c "cd $DEPLOY_DIR && git remote get-url origin" 2>/dev/null || echo ""
  fi
}

derive_repo_slug() {
  # monitoring.trenkwalder.digital → monitoring-trenkwalder-digital
  echo "$1" | tr '.' '-'
}

get_age_public_key() {
  if [ -f "$AGE_KEY_FILE" ]; then
    age-keygen -y "$AGE_KEY_FILE" 2>/dev/null || echo ""
  fi
}

# =================================================================
# Step 1: Install GitHub CLI
# =================================================================

install_gh_cli() {
  print_header "Install GitHub CLI"

  if is_gh_installed; then
    local ver
    ver="$(get_gh_version)"
    print_success "GitHub CLI already installed: gh $ver"
    return 0
  fi

  print_step "Installing GitHub CLI from official apt repository..."
  echo ""

  # Ensure prerequisites
  export DEBIAN_FRONTEND=noninteractive
  if ! command -v curl >/dev/null 2>&1; then
    print_step "Installing curl..."
    wait_for_apt
    apt-get update -qq
    wait_for_apt
    apt-get install -y -qq curl ca-certificates
  fi

  # Add GitHub GPG key
  print_step "Adding GitHub GPG key..."
  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg

  # Add apt repository
  print_step "Adding GitHub CLI apt repository..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list

  # Install
  print_step "Updating package list..."
  wait_for_apt
  apt-get update -qq

  print_step "Installing gh..."
  wait_for_apt
  apt-get install -y -qq gh

  # Verify
  if is_gh_installed; then
    local ver
    ver="$(get_gh_version)"
    print_success "GitHub CLI installed: gh $ver"
  else
    print_error "GitHub CLI installation failed"
    return 1
  fi
}

# =================================================================
# Step 2: Authenticate with GitHub
# =================================================================

authenticate_gh() {
  print_header "Authenticate with GitHub"

  if ! is_gh_installed; then
    print_error "GitHub CLI is not installed. Run step 1 first."
    return 1
  fi

  if is_gh_authenticated; then
    local user
    user="$(get_gh_user)"
    print_success "Already authenticated as: $user"
    if ! confirm "Re-authenticate with a different account?"; then
      return 0
    fi
  fi

  print_step "Launching GitHub authentication..."
  echo ""
  print_info "This uses the device code flow (works on headless servers)."
  print_info "You'll see a one-time code below."
  print_info "Open ${BOLD}https://github.com/login/device${NC} in your browser and enter the code."
  echo ""

  # Run auth as the original user (not root)
  su - "$ORIGINAL_USER" -c "gh auth login --git-protocol https --web"

  # Verify
  if is_gh_authenticated; then
    local user
    user="$(get_gh_user)"
    echo ""
    print_success "Authenticated as: $user"
  else
    print_error "Authentication failed or was cancelled."
    return 1
  fi
}

# =================================================================
# Choose GitHub Owner (user or org)
# =================================================================

choose_github_owner() {
  local __result_var="${1:-GITHUB_OWNER}"

  # Get authenticated user
  local auth_user
  auth_user="$(get_gh_user)"
  if [ -z "$auth_user" ]; then
    print_error "Cannot detect authenticated GitHub user."
    return 1
  fi

  # List orgs
  local orgs
  orgs="$(su - "$ORIGINAL_USER" -c "gh api user/orgs -q '.[].login'" 2>/dev/null || echo "")"

  # Build options list
  local options=("$auth_user (personal)")
  local owners=("$auth_user")
  if [ -n "$orgs" ]; then
    while IFS= read -r org; do
      options+=("$org (organization)")
      owners+=("$org")
    done <<< "$orgs"
  fi

  if [ "${#owners[@]}" -eq 1 ]; then
    print_info "GitHub owner: $auth_user"
    eval "$__result_var='$auth_user'"
    return 0
  fi

  echo ""
  echo "Select the GitHub owner for this repository:"
  echo ""
  local i
  for i in "${!options[@]}"; do
    echo "  $((i + 1))) ${options[$i]}"
  done
  echo ""
  read -rp "Choose [1]: " owner_choice
  owner_choice="${owner_choice:-1}"

  local idx=$((owner_choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#owners[@]}" ]; then
    print_error "Invalid choice: $owner_choice"
    return 1
  fi

  eval "$__result_var='${owners[$idx]}'"
  print_info "Selected owner: ${owners[$idx]}"
}

# =================================================================
# Step 3: Push Infrastructure Repo to GitHub
# =================================================================

push_infra_repo() {
  print_header "Push Infrastructure Repo to GitHub"

  # Verify prerequisites
  if ! is_gh_installed; then
    print_error "GitHub CLI is not installed. Run step 1 first."
    return 1
  fi
  if ! is_gh_authenticated; then
    print_error "Not authenticated with GitHub. Run step 2 first."
    return 1
  fi

  # Verify infra repo exists
  if [ ! -d "$INFRA_DIR" ]; then
    print_error "$INFRA_DIR does not exist."
    print_info "Run the main setup first to create the infrastructure directory."
    return 1
  fi
  if [ ! -d "$INFRA_DIR/.git" ]; then
    print_warning "$INFRA_DIR exists but is not a git repository."
    if confirm "Initialize git repo now?" "y"; then
      # Fix ownership so the user can read all files
      chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$INFRA_DIR"
      # Ensure .gitignore exists to exclude secrets
      if [ ! -f "$INFRA_DIR/.gitignore" ]; then
        cat > "$INFRA_DIR/.gitignore" << 'GIEOF'
.env
.env.*
!.env.*.enc
!.env.example
*.pem
*.key
GIEOF
        chown "$ORIGINAL_USER:$ORIGINAL_USER" "$INFRA_DIR/.gitignore"
      fi
      print_step "Initializing git repository in $INFRA_DIR..."
      if ! su - "$ORIGINAL_USER" -c "cd $INFRA_DIR && git init && git add . && git commit -m 'Initial infrastructure for ${DOMAIN:-unknown}'"; then
        print_error "Git initialization failed. Check permissions: ls -la $INFRA_DIR"
        return 1
      fi
      print_success "Git repository initialized"
    else
      print_info "Skipping. Initialize manually: cd $INFRA_DIR && git init && git add . && git commit -m 'Initial commit'"
      return 1
    fi
  fi

  # Check if origin remote already set
  local existing_remote
  existing_remote="$(get_infra_remote_url)"
  if [ -n "$existing_remote" ]; then
    print_info "Origin remote already set: $existing_remote"
    echo ""
    if ! confirm "Reconfigure and push to a new repository?"; then
      print_info "Skipping. Existing remote unchanged."
      return 0
    fi
    # Remove old remote
    su - "$ORIGINAL_USER" -c "cd $INFRA_DIR && git remote remove origin" 2>/dev/null || true
  fi

  # Auto-derive repo name from domain
  local slug
  slug="$(derive_repo_slug "${DOMAIN:-unknown}")"
  local default_name="${slug}-infra"

  echo ""
  read -rp "Repository name [$default_name]: " repo_name
  repo_name="${repo_name:-$default_name}"

  # Choose owner
  local owner
  choose_github_owner owner || return 1

  # Check if repo already exists on GitHub
  if su - "$ORIGINAL_USER" -c "gh repo view '$owner/$repo_name'" &>/dev/null; then
    print_warning "Repository $owner/$repo_name already exists on GitHub."
    if confirm "Add it as origin and push?" "y"; then
      su - "$ORIGINAL_USER" -c "cd $INFRA_DIR && git remote add origin 'https://github.com/$owner/$repo_name.git'"
      print_step "Pushing to existing repository..."
      su - "$ORIGINAL_USER" -c "cd $INFRA_DIR && git push -u origin HEAD"
      print_success "Pushed to https://github.com/$owner/$repo_name"
      return 0
    else
      print_info "Skipping."
      return 0
    fi
  fi

  # Offer to generate Makefile if missing
  if [ ! -f "$INFRA_DIR/Makefile" ]; then
    echo ""
    if confirm "Generate a Makefile for $INFRA_DIR? (status, proxy up/down, encrypt/decrypt)" "y"; then
      generate_infra_makefile
    fi
  fi

  # Commit any uncommitted changes
  local has_changes
  has_changes="$(su - "$ORIGINAL_USER" -c "cd $INFRA_DIR && git status --porcelain" 2>/dev/null || echo "")"
  if [ -n "$has_changes" ]; then
    print_step "Committing uncommitted changes..."
    su - "$ORIGINAL_USER" -c "cd $INFRA_DIR && git add -A && git commit -m 'Pre-push snapshot'"
  fi

  # Sync gh-account-switcher if available
  if su - "$ORIGINAL_USER" -c "command -v gh-account-switcher" &>/dev/null; then
    print_step "Syncing GitHub account (gh-account-switcher)..."
    su - "$ORIGINAL_USER" -c "gh-account-switcher sync" >/dev/null 2>&1 || print_warning "gh-account-switcher sync failed (continuing)"
  fi

  # Create and push
  print_step "Creating private GitHub repository: $owner/$repo_name"
  if su - "$ORIGINAL_USER" -c "cd $INFRA_DIR && gh repo create '$owner/$repo_name' --private --source=. --remote=origin --push" 2>&1; then
    echo ""
    print_success "Infrastructure repo pushed!"
    print_info "URL: https://github.com/$owner/$repo_name"
  else
    print_error "Failed to create GitHub repository."
    print_info "You can try manually: cd $INFRA_DIR && gh repo create $owner/$repo_name --private --source=. --remote=origin --push"
    return 1
  fi
}

# =================================================================
# Step 4: Scaffold Deployments Repo
# =================================================================

scaffold_deployments_repo() {
  print_header "Create Deployments Repo"

  # Check profile
  if [ "${SETUP_PROFILE:-}" = "minimal" ]; then
    print_info "Skipping deployments repo for 'minimal' profile."
    print_info "The deployments repo is for managing per-app compose manifests."
    print_info "You can re-run this after switching to a full-stack or monitoring profile."
    return 0
  fi

  # Verify prerequisites
  if ! is_gh_installed; then
    print_error "GitHub CLI is not installed. Run step 1 first."
    return 1
  fi
  if ! is_gh_authenticated; then
    print_error "Not authenticated with GitHub. Run step 2 first."
    return 1
  fi

  # Check if /srv/deployments exists
  if [ -d "$DEPLOY_DIR" ]; then
    print_warning "$DEPLOY_DIR already exists!"
    echo ""
    echo "Options:"
    echo "  1) Reuse existing (keep current files)"
    echo "  2) Backup and overwrite"
    echo "  3) Skip"
    echo ""
    read -rp "Choice [1]: " deploy_choice
    deploy_choice="${deploy_choice:-1}"

    case "$deploy_choice" in
      1)
        print_info "Reusing existing $DEPLOY_DIR"
        ;;
      2)
        local backup="$DEPLOY_DIR.backup.$(date +%s)"
        print_step "Backing up to $backup"
        mv "$DEPLOY_DIR" "$backup"
        print_success "Backup created"
        ;;
      3)
        print_info "Skipping."
        return 0
        ;;
      *)
        print_error "Invalid choice: $deploy_choice"
        return 1
        ;;
    esac
  fi

  # Create directory and scaffold files
  print_step "Scaffolding $DEPLOY_DIR..."
  mkdir -p "$DEPLOY_DIR"

  # .gitignore
  if [ ! -f "$DEPLOY_DIR/.gitignore" ]; then
    cat > "$DEPLOY_DIR/.gitignore" << 'GITIGNORE_EOF'
# Plaintext secrets (SOPS-encrypted .enc files are tracked)
.env
.env.*
!.env.*.enc
!.env.example

# Private keys
*.pem
*.key

# Editor files
*.swp
*.swo
*~
.idea/
.vscode/

# OS files
.DS_Store
Thumbs.db

# Logs
*.log
GITIGNORE_EOF
    print_success "Created .gitignore"
  fi

  # .sops.yaml
  if [ ! -f "$DEPLOY_DIR/.sops.yaml" ]; then
    local age_pub
    age_pub="$(get_age_public_key)"
    if [ -z "$age_pub" ]; then
      age_pub="# TODO: Replace with your age public key (run: age-keygen -y $AGE_KEY_FILE)"
    fi
    cat > "$DEPLOY_DIR/.sops.yaml" << SOPS_EOF
# SOPS configuration for encrypted environment files
# Encrypt:  sops --encrypt --in-place .env.production.enc
# Decrypt:  sops --decrypt .env.production.enc > .env.production
creation_rules:
  - path_regex: \.env(\.\w+)?\.enc$
    age: >-
      $age_pub
SOPS_EOF
    print_success "Created .sops.yaml"
  fi

  # Makefile
  if [ ! -f "$DEPLOY_DIR/Makefile" ]; then
    cat > "$DEPLOY_DIR/Makefile" << 'MAKEFILE_EOF'
.DEFAULT_GOAL := help
SHELL := /bin/bash

##@ General
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

##@ Status
status: ## Show deployment status for all apps
	@echo "=== App Deployments ==="
	@for dir in */; do \
		if [ -f "$${dir}compose.yml" ] || [ -f "$${dir}docker-compose.yml" ]; then \
			echo ""; \
			echo "--- $${dir%/} ---"; \
			(cd "$$dir" && docker compose ps 2>/dev/null) || echo "  (not running)"; \
		fi; \
	done

##@ Secrets
decrypt: ## Decrypt all .env.*.enc files in place
	@find . -name '*.enc' -type f | while read -r f; do \
		out="$${f%.enc}"; \
		echo "Decrypting $$f → $$out"; \
		sops --decrypt "$$f" > "$$out"; \
	done
	@echo "Done. Remember: plaintext .env files are git-ignored."

encrypt: ## Encrypt all matching .env.* files (creates .enc copies)
	@find . -name '.env.*' ! -name '*.enc' ! -name '*.example' -type f | while read -r f; do \
		enc="$${f}.enc"; \
		echo "Encrypting $$f → $$enc"; \
		sops --encrypt "$$f" > "$$enc"; \
	done
	@echo "Done. Commit the .enc files."
MAKEFILE_EOF
    print_success "Created Makefile"
  fi

  # README.md
  if [ ! -f "$DEPLOY_DIR/README.md" ]; then
    local domain_display="${DOMAIN:-yourdomain.com}"
    cat > "$DEPLOY_DIR/README.md" << README_EOF
# App Deployments — ${domain_display}

Per-app deployment manifests managed with Docker Compose and SOPS-encrypted secrets.

## Directory Structure

\`\`\`
/srv/deployments/
├── .sops.yaml            # SOPS age encryption config
├── Makefile              # Common operations
├── myapp/
│   ├── compose.yml       # Docker Compose manifest
│   ├── .env.example      # Template (committed)
│   ├── .env.production.enc  # Encrypted secrets (committed)
│   └── .env.production   # Decrypted secrets (git-ignored)
└── anotherapp/
    └── ...
\`\`\`

## Quick Start

\`\`\`bash
# Create a new app directory
mkdir -p myapp && cd myapp

# Add compose.yml and .env.example
# Then encrypt secrets:
cp .env.example .env.production
# Edit .env.production with real values
sops --encrypt .env.production > .env.production.enc
rm .env.production

# Commit
git add compose.yml .env.example .env.production.enc
git commit -m "Add myapp deployment"
\`\`\`

## Makefile Commands

Run \`make help\` to see available commands:

- \`make status\` — Show running containers for all apps
- \`make decrypt\` — Decrypt all .enc files
- \`make encrypt\` — Encrypt all .env.* files
README_EOF
    print_success "Created README.md"
  fi

  # Set ownership
  chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$DEPLOY_DIR"
  chmod 755 "$DEPLOY_DIR"
  # Also try sysadmin if it exists
  if id sysadmin &>/dev/null; then
    chown -R sysadmin:sysadmin "$DEPLOY_DIR"
  fi

  # Init git if needed
  if [ ! -d "$DEPLOY_DIR/.git" ]; then
    print_step "Initializing git repository..."
    su - "$ORIGINAL_USER" -c "cd $DEPLOY_DIR && git init && git add . && git commit -m 'Initial deployments scaffold for ${DOMAIN:-unknown}'"
    print_success "Git repository initialized"
  fi

  # Push to GitHub
  local existing_remote
  existing_remote="$(get_deployments_remote_url)"
  if [ -n "$existing_remote" ]; then
    print_info "Origin remote already set: $existing_remote"
    if ! confirm "Reconfigure and push to a new repository?"; then
      print_info "Skipping push. Existing remote unchanged."
      return 0
    fi
    su - "$ORIGINAL_USER" -c "cd $DEPLOY_DIR && git remote remove origin" 2>/dev/null || true
  fi

  # Auto-derive repo name
  local slug
  slug="$(derive_repo_slug "${DOMAIN:-unknown}")"
  local default_name="${slug}-deployments"

  echo ""
  read -rp "Repository name [$default_name]: " repo_name
  repo_name="${repo_name:-$default_name}"

  # Choose owner
  local owner
  choose_github_owner owner || return 1

  # Check if repo already exists
  if su - "$ORIGINAL_USER" -c "gh repo view '$owner/$repo_name'" &>/dev/null; then
    print_warning "Repository $owner/$repo_name already exists on GitHub."
    if confirm "Add it as origin and push?" "y"; then
      su - "$ORIGINAL_USER" -c "cd $DEPLOY_DIR && git remote add origin 'https://github.com/$owner/$repo_name.git'"
      print_step "Pushing to existing repository..."
      su - "$ORIGINAL_USER" -c "cd $DEPLOY_DIR && git push -u origin HEAD"
      print_success "Pushed to https://github.com/$owner/$repo_name"
      return 0
    else
      print_info "Skipping push."
      return 0
    fi
  fi

  # Commit any uncommitted changes
  local has_changes
  has_changes="$(su - "$ORIGINAL_USER" -c "cd $DEPLOY_DIR && git status --porcelain" 2>/dev/null || echo "")"
  if [ -n "$has_changes" ]; then
    print_step "Committing uncommitted changes..."
    su - "$ORIGINAL_USER" -c "cd $DEPLOY_DIR && git add -A && git commit -m 'Pre-push snapshot'"
  fi

  # Sync gh-account-switcher if available
  if su - "$ORIGINAL_USER" -c "command -v gh-account-switcher" &>/dev/null; then
    print_step "Syncing GitHub account (gh-account-switcher)..."
    su - "$ORIGINAL_USER" -c "gh-account-switcher sync" >/dev/null 2>&1 || print_warning "gh-account-switcher sync failed (continuing)"
  fi

  # Create and push
  print_step "Creating private GitHub repository: $owner/$repo_name"
  if su - "$ORIGINAL_USER" -c "cd $DEPLOY_DIR && gh repo create '$owner/$repo_name' --private --source=. --remote=origin --push" 2>&1; then
    echo ""
    print_success "Deployments repo pushed!"
    print_info "URL: https://github.com/$owner/$repo_name"
  else
    print_error "Failed to create GitHub repository."
    print_info "You can try manually: cd $DEPLOY_DIR && gh repo create $owner/$repo_name --private --source=. --remote=origin --push"
    return 1
  fi
}

# =================================================================
# Generate Infrastructure Makefile (optional)
# =================================================================

generate_infra_makefile() {
  local domain_display="${DOMAIN:-yourdomain.com}"

  cat > "$INFRA_DIR/Makefile" << 'MAKEFILE_EOF'
.DEFAULT_GOAL := help
SHELL := /bin/bash

PROXY_DIR := reverse-proxy

##@ General
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

##@ Status
status: ## Show infrastructure status
	@echo "=== Reverse Proxy ==="
	@cd $(PROXY_DIR) && docker compose ps 2>/dev/null || echo "  (not running)"

##@ Reverse Proxy
up-proxy: ## Start Caddy reverse proxy
	cd $(PROXY_DIR) && docker compose --compatibility up -d

down-proxy: ## Stop Caddy reverse proxy
	cd $(PROXY_DIR) && docker compose down

logs-proxy: ## Follow Caddy logs
	cd $(PROXY_DIR) && docker compose logs -f

reload-proxy: ## Reload Caddy configuration
	docker exec caddy caddy reload --config /etc/caddy/Caddyfile

##@ Secrets
decrypt: ## Decrypt all .env.*.enc files
	@find . -name '*.enc' -type f | while read -r f; do \
		out="$${f%.enc}"; \
		echo "Decrypting $$f → $$out"; \
		sops --decrypt "$$f" > "$$out"; \
	done

encrypt: ## Encrypt all .env.* files (creates .enc copies)
	@find . -name '.env.*' ! -name '*.enc' ! -name '*.example' -type f | while read -r f; do \
		enc="$${f}.enc"; \
		echo "Encrypting $$f → $$enc"; \
		sops --encrypt "$$f" > "$$enc"; \
	done
MAKEFILE_EOF

  chown "$ORIGINAL_USER:$ORIGINAL_USER" "$INFRA_DIR/Makefile"
  print_success "Generated $INFRA_DIR/Makefile"
}

# =================================================================
# Run All Steps
# =================================================================

run_all_steps() {
  print_header "Run All Steps"
  print_info "Running all GitHub setup steps sequentially..."
  echo ""

  install_gh_cli || { print_error "Step 1 failed. Stopping."; return 1; }
  echo ""

  authenticate_gh || { print_error "Step 2 failed. Stopping."; return 1; }
  echo ""

  push_infra_repo || { print_warning "Step 3 had issues (continuing)."; }
  echo ""

  scaffold_deployments_repo || { print_warning "Step 4 had issues."; }
  echo ""

  print_success "All steps complete!"
}

# =================================================================
# Main Menu
# =================================================================

github_repos_menu() {
  while true; do
    # Refresh status for each item
    local gh_label auth_label infra_label deploy_label

    if is_gh_installed; then
      local ver
      ver="$(get_gh_version)"
      gh_label="${GREEN}installed: gh $ver${NC}"
    else
      gh_label="${YELLOW}not installed${NC}"
    fi

    if is_gh_installed && is_gh_authenticated; then
      local user
      user="$(get_gh_user)"
      auth_label="${GREEN}authenticated as: $user${NC}"
    elif is_gh_installed; then
      auth_label="${YELLOW}not authenticated${NC}"
    else
      auth_label="${YELLOW}requires gh${NC}"
    fi

    local infra_remote
    infra_remote="$(get_infra_remote_url)"
    if [ -n "$infra_remote" ]; then
      # Show shortened URL
      local short_remote="${infra_remote##*/}"
      infra_label="${GREEN}pushed: $short_remote${NC}"
    elif [ -d "$INFRA_DIR/.git" ]; then
      infra_label="${YELLOW}local only (no remote)${NC}"
    elif [ -d "$INFRA_DIR" ]; then
      infra_label="${YELLOW}not a git repo${NC}"
    else
      infra_label="${RED}$INFRA_DIR missing${NC}"
    fi

    local deploy_remote
    deploy_remote="$(get_deployments_remote_url)"
    if [ -n "$deploy_remote" ]; then
      local short_deploy="${deploy_remote##*/}"
      deploy_label="${GREEN}pushed: $short_deploy${NC}"
    elif [ -d "$DEPLOY_DIR/.git" ]; then
      deploy_label="${YELLOW}local only (no remote)${NC}"
    elif [ -d "$DEPLOY_DIR" ]; then
      deploy_label="${YELLOW}not initialized${NC}"
    else
      deploy_label="${YELLOW}not created${NC}"
    fi

    echo ""
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${BLUE}${BOLD} GitHub Repository Setup${NC}"
    echo -e "${BLUE}======================================================================${NC}"
    echo ""
    echo -e "  1) Install GitHub CLI          [$gh_label]"
    echo -e "  2) Authenticate (gh auth)      [$auth_label]"
    echo -e "  3) Push infra repo to GitHub   [$infra_label]"
    if [ "${SETUP_PROFILE:-}" != "minimal" ]; then
      echo -e "  4) Create deployments repo     [$deploy_label]"
    fi
    echo -e "  5) Run all steps"
    echo -e "  0) Back"
    echo ""
    read -rp "Choose [0]: " choice
    choice="${choice:-0}"

    case "$choice" in
      1) install_gh_cli || true ;;
      2) authenticate_gh || true ;;
      3) push_infra_repo || true ;;
      4)
        if [ "${SETUP_PROFILE:-}" = "minimal" ]; then
          print_warning "Invalid choice: $choice"
        else
          scaffold_deployments_repo || true
        fi
        ;;
      5) run_all_steps || true ;;
      0)
        echo ""
        return 0
        ;;
      *)
        print_warning "Invalid choice: $choice"
        ;;
    esac
  done
}

# =================================================================
# Entry Point
# =================================================================

github_repos_menu
