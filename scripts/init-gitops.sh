#!/usr/bin/env bash
#
# GitOps Initialization Helper
# Sets up GitHub repository and CI/CD integration
#
# Usage: ./scripts/init-gitops.sh
#
# This script runs on your LOCAL machine (not the server)
# It will guide you through:
#   1. Forking/creating your repository
#   2. Setting up GitHub Actions secrets
#   3. Configuring appmgr SSH access for deployments
#   4. Testing the CI/CD pipeline

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print functions
print_header() {
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_step() {
  echo -e "${GREEN}➜${NC} $1"
}

print_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1"
}

print_success() {
  echo -e "${GREEN}✓${NC} $1"
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

# Check prerequisites
check_prerequisites() {
  print_header "Checking Prerequisites"
  echo

  local all_good=true

  # Check gh CLI
  if command -v gh &> /dev/null; then
    local gh_version=$(gh --version | head -1)
    print_success "GitHub CLI installed ($gh_version)"

    # Optional: sync the expected GitHub account for this directory (multi-account setups)
    if command -v gh-account-switcher &>/dev/null; then
      print_step "Syncing GitHub account (gh-account-switcher)..."
      gh-account-switcher sync >/dev/null 2>&1 || print_warning "gh-account-switcher sync failed (continuing)"
    fi
  else
    print_error "GitHub CLI (gh) not found"
    print_info "Install: https://cli.github.com/"
    all_good=false
  fi

  # Check gh auth
  if gh auth status &>/dev/null; then
    print_success "GitHub CLI authenticated"
  else
    print_warning "GitHub CLI not authenticated"
    print_info "Run: gh auth login"
    all_good=false
  fi

  # Check git
  if command -v git &> /dev/null; then
    print_success "Git installed"
  else
    print_error "Git not found"
    all_good=false
  fi

  # Check ssh-keygen
  if command -v ssh-keygen &> /dev/null; then
    print_success "SSH tools available"
  else
    print_error "ssh-keygen not found"
    all_good=false
  fi

  echo

  if [ "$all_good" = false ]; then
    print_error "Please install missing prerequisites and try again"
    exit 1
  fi

  print_success "All prerequisites met!"
  echo
}

# Get repository information
get_repo_info() {
  print_header "Repository Setup"
  echo

  # Check if we're already in a git repository
  if git rev-parse --git-dir > /dev/null 2>&1; then
    local current_repo=$(git config --get remote.origin.url 2>/dev/null || echo "")
    if [ -n "$current_repo" ]; then
      print_info "Current repository: $current_repo"
      echo
      if confirm "Use this repository?"; then
        REPO_PATH="."
        REPO_FULL=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
        if [ -n "$REPO_FULL" ]; then
          print_success "Using repository: $REPO_FULL"
          return 0
        fi
      fi
    fi
  fi

  echo "You have two options:"
  echo "  1. Fork the template repository (recommended for beginners)"
  echo "  2. Use an existing repository"
  echo
  read -p "Choice (1/2): " choice

  case "$choice" in
    1)
      print_step "Creating fork from template..."
      read -p "Enter your repository name [hardened-multienv-vm-cloudflared]: " repo_name
      repo_name=${repo_name:-hardened-multienv-vm-cloudflared}

      if gh repo create "$repo_name" --template samnetic/hardened-multienv-vm-cloudflared --private --clone; then
        REPO_PATH="$repo_name"
        REPO_FULL=$(gh repo view "$repo_name" --json nameWithOwner -q .nameWithOwner)
        cd "$REPO_PATH"
        print_success "Repository created and cloned: $REPO_FULL"
      else
        print_error "Failed to create repository"
        exit 1
      fi
      ;;
    2)
      read -p "Enter repository owner/name (e.g., username/repo): " REPO_FULL
      if gh repo view "$REPO_FULL" &>/dev/null; then
        print_success "Repository found: $REPO_FULL"
        read -p "Clone to local directory? [Y/n]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
          local repo_name=$(basename "$REPO_FULL")
          gh repo clone "$REPO_FULL" "$repo_name"
          REPO_PATH="$repo_name"
          cd "$REPO_PATH"
        else
          REPO_PATH="."
        fi
      else
        print_error "Repository not found: $REPO_FULL"
        exit 1
      fi
      ;;
    *)
      print_error "Invalid choice"
      exit 1
      ;;
  esac

  echo
}

# Set up GitHub Actions secrets
setup_github_secrets() {
  print_header "GitHub Actions Secrets"
  echo

  print_info "GitHub Actions needs these secrets for deployment:"
  echo "  • SSH_PRIVATE_KEY - appmgr user's private SSH key"
  echo "  • SSH_HOST - Your VM's SSH hostname (ssh.yourdomain.com)"
  echo "  • SSH_USER - Usually 'appmgr'"
  echo "  • SSH_KNOWN_HOSTS - known_hosts entries for SSH_HOST (pin host key)"
  echo "  • CF_SERVICE_TOKEN_ID - Cloudflare Access service token ID (CI)"
  echo "  • CF_SERVICE_TOKEN_SECRET - Cloudflare Access service token secret (CI)"
  echo

  if ! confirm "Set up GitHub Actions secrets now?"; then
    print_info "Skipping secrets setup"
    print_info "Set manually later in: Settings → Secrets and variables → Actions"
    return 0
  fi

  echo

  # SSH_HOST
  read -p "Enter your VM's SSH hostname (e.g., ssh.yourdomain.com): " ssh_host
  if [ -n "$ssh_host" ]; then
    if gh secret set SSH_HOST --body "$ssh_host" 2>/dev/null; then
      print_success "SSH_HOST set to: $ssh_host"
    else
      print_warning "Failed to set SSH_HOST (may need repo push access)"
    fi
  fi

  # SSH_USER
  read -p "Enter SSH username [appmgr]: " ssh_user
  ssh_user=${ssh_user:-appmgr}
  if gh secret set SSH_USER --body "$ssh_user" 2>/dev/null; then
    print_success "SSH_USER set to: $ssh_user"
  else
    print_warning "Failed to set SSH_USER"
  fi

  # SSH_PRIVATE_KEY
  echo
  print_info "SSH Private Key for $ssh_user user"
  echo
  echo "Paste the PRIVATE key file content (from ~/.ssh/vm-appmgr or similar):"
  echo -e "${YELLOW}Press Ctrl+D when done${NC}"
  echo

  if ssh_key=$(cat); then
    if [ -n "$ssh_key" ]; then
      if echo "$ssh_key" | gh secret set SSH_PRIVATE_KEY 2>/dev/null; then
        print_success "SSH_PRIVATE_KEY set"
      else
        print_warning "Failed to set SSH_PRIVATE_KEY"
      fi
    fi
  fi

  # SSH_KNOWN_HOSTS (recommended)
  echo
  print_info "SSH known_hosts pinning (prevents MITM)"
  echo "Generate on the VM with:"
  echo "  ./scripts/ssh/print-known-hosts.sh ssh.yourdomain.com"
  echo ""
  echo "Paste the known_hosts line(s) below."
  echo -e "${YELLOW}Press Ctrl+D when done${NC}"
  echo
  if ssh_known_hosts=$(cat); then
    if [ -n "$ssh_known_hosts" ]; then
      if echo "$ssh_known_hosts" | gh secret set SSH_KNOWN_HOSTS 2>/dev/null; then
        print_success "SSH_KNOWN_HOSTS set"
      else
        print_warning "Failed to set SSH_KNOWN_HOSTS"
      fi
    fi
  fi

  # Cloudflare Access service token for CI (required)
  echo
  print_info "Cloudflare Access Service Token (CI/CD)"
  echo "Create in: Cloudflare Zero Trust → Access → Service Auth → Service Tokens"
  echo "Then paste the Client ID and Client Secret."
  echo ""
  read -rp "Service Token Client ID: " cf_service_token_id
  read -sp "Service Token Client Secret (hidden): " cf_service_token_secret
  echo

  if [ -n "${cf_service_token_id:-}" ]; then
    if gh secret set CF_SERVICE_TOKEN_ID --body "$cf_service_token_id" 2>/dev/null; then
      print_success "CF_SERVICE_TOKEN_ID set"
    else
      print_warning "Failed to set CF_SERVICE_TOKEN_ID"
    fi
  fi

  if [ -n "${cf_service_token_secret:-}" ]; then
    if gh secret set CF_SERVICE_TOKEN_SECRET --body "$cf_service_token_secret" 2>/dev/null; then
      print_success "CF_SERVICE_TOKEN_SECRET set"
    else
      print_warning "Failed to set CF_SERVICE_TOKEN_SECRET"
    fi
  fi

  echo
  print_success "Secrets configured!"
  print_info "View secrets: gh secret list"
  echo
}

# Configure workflow
configure_workflow() {
  print_header "GitHub Actions Workflow"
  echo

  if [ ! -f ".github/workflows/deploy.yml" ]; then
    print_warning "No deployment workflow found at .github/workflows/deploy.yml"
    print_info "This template may not include GitHub Actions workflows yet"
    echo
    return 0
  fi

  print_info "Deployment workflow found"
  print_info "This workflow will:"
  echo "  • Auto-deploy on push:"
  echo "    - feature/* → DEV"
  echo "    - main      → STAGING"
  echo "  • Manual deploy for PRODUCTION (workflow_dispatch + confirmation)"
  echo "  • Deploy over Cloudflare Access SSH (Service Token)"
  echo

  if confirm "Enable GitHub Actions for this repository?"; then
    # Check if Actions is enabled
    local actions_enabled=$(gh api "repos/$REPO_FULL/actions/permissions" --jq '.enabled' 2>/dev/null || echo "true")

    if [ "$actions_enabled" = "false" ]; then
      print_step "Enabling GitHub Actions..."
      gh api "repos/$REPO_FULL/actions/permissions" -X PUT -f enabled=true
      print_success "GitHub Actions enabled"
    else
      print_success "GitHub Actions already enabled"
    fi
  fi

  echo
}

# Test deployment
test_deployment() {
  print_header "Test Deployment"
  echo

  print_info "To test your CI/CD pipeline:"
  echo
  echo "1. Make a small change to your code"
  echo "2. Commit and push a feature branch (auto-deploys to DEV):"
  echo -e "   ${CYAN}git checkout -b feature/test-deploy${NC}"
  echo -e "   ${CYAN}echo '# Test' >> README.md${NC}"
  echo -e "   ${CYAN}git add README.md${NC}"
  echo -e "   ${CYAN}git commit -m 'Test deployment'${NC}"
  echo -e "   ${CYAN}git push -u origin feature/test-deploy${NC}"
  echo
  echo "3. Watch the deployment in GitHub Actions:"
  echo -e "   ${CYAN}gh run watch${NC}"
  echo
  echo "4. Verify on your VM:"
  echo -e "   ${CYAN}ssh yourdomain-appmgr \"hosting status dev\"${NC}"
  echo

  if confirm "Open GitHub Actions page in browser?"; then
    gh repo view --web --branch "$(git branch --show-current 2>/dev/null || echo main)"
  fi

  echo
}

# Display next steps
display_next_steps() {
  print_header "GitOps Setup Complete!"
  echo

  print_success "Your repository is configured for GitOps!"
  echo
  echo -e "${CYAN}Repository:${NC} $REPO_FULL"
  echo

  print_header "Branching Strategy"
  echo
  echo -e "${BLUE}Feature Branches → Staging (main) → Production (manual)${NC}"
  echo
  echo "  feature/* branches → Auto-deploy to DEV environment"
  echo "  main branch        → Auto-deploy to STAGING environment"
  echo "  production         → Manual Deploy workflow (select version tag + confirm)"
  echo

  print_header "Typical Workflow"
  echo
  echo "1. Create a feature branch:"
  echo -e "   ${CYAN}git checkout -b feature/my-feature${NC}"
  echo
  echo "2. Make changes, commit, and push:"
  echo -e "   ${CYAN}git add .${NC}"
  echo -e "   ${CYAN}git commit -m 'Add new feature'${NC}"
  echo -e "   ${CYAN}git push -u origin feature/my-feature${NC}"
  echo
  echo "3. Open a PR to main:"
  echo -e "   ${CYAN}gh pr create --base main --title 'Add new feature'${NC}"
  echo
  echo "4. Push/merge to feature/* → automatic deployment to DEV"
  echo
  echo "5. Merge to main → automatic deployment to STAGING"
  echo
  echo "6. Deploy to production:"
  echo -e "   ${CYAN}git tag v1.0.0 && git push origin v1.0.0${NC}"
  echo "   Then run the Deploy workflow (Actions → Deploy → Run workflow)"
  echo "   Select environment=production, version=v1.0.0, confirm=DEPLOY"
  echo

  print_header "Useful Commands"
  echo
  echo "View workflow runs:"
  echo -e "  ${CYAN}gh run list${NC}"
  echo
  echo "Watch latest run:"
  echo -e "  ${CYAN}gh run watch${NC}"
  echo
  echo "View secrets:"
  echo -e "  ${CYAN}gh secret list${NC}"
  echo
  echo "Update secret:"
  echo -e "  ${CYAN}gh secret set SECRET_NAME${NC}"
  echo

  print_header "Documentation"
  echo
  echo "  • .github/workflows/ - Workflow definitions"
  echo "  • docs/07-gitops-workflow.md - Full GitOps guide"
  echo "  • README.md - Repository overview"
  echo

  print_success "Happy deploying! 🚀"
  echo
}

# Main execution
main() {
  clear

  print_header "GitOps Initialization for Hardened VM"
  echo
  print_info "This wizard will help you set up GitOps CI/CD for your VM"
  echo

  if ! confirm "Continue with GitOps setup?" "y"; then
    echo "Setup cancelled"
    exit 0
  fi

  echo

  # Run setup steps
  check_prerequisites
  get_repo_info
  setup_github_secrets
  configure_workflow
  test_deployment
  display_next_steps
}

# Run main
main "$@"
