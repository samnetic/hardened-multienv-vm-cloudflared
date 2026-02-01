#!/usr/bin/env bash
# =================================================================
# Post-Setup Verification & User Transition
# =================================================================
# This script guides you through verifying your setup and
# transitioning from the default user to sysadmin
#
# Run this AFTER setup.sh completes successfully
#
# Usage:
#   ./scripts/verify-setup.sh
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

# Configuration
SYSADMIN_USER="sysadmin"
APPMGR_USER="appmgr"
CURRENT_USER="$(whoami)"

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

# =================================================================
# Verification Steps
# =================================================================

verify_users_created() {
  print_header "Step 1: Verify New Users"

  local all_good=true

  if id "$SYSADMIN_USER" &>/dev/null; then
    print_success "User '$SYSADMIN_USER' exists"

    if groups "$SYSADMIN_USER" | grep -q sudo; then
      print_success "User '$SYSADMIN_USER' has sudo access"
    else
      print_error "User '$SYSADMIN_USER' missing sudo access"
      all_good=false
    fi
  else
    print_error "User '$SYSADMIN_USER' not found"
    all_good=false
  fi

  if id "$APPMGR_USER" &>/dev/null; then
    print_success "User '$APPMGR_USER' exists"

    if groups "$APPMGR_USER" | grep -q docker; then
      print_success "User '$APPMGR_USER' has docker access"
    else
      print_warning "User '$APPMGR_USER' not in docker group (will be added when Docker installs)"
    fi
  else
    print_error "User '$APPMGR_USER' not found"
    all_good=false
  fi

  if [ "$all_good" = true ]; then
    echo ""
    print_info "All users created successfully!"
    return 0
  else
    echo ""
    print_error "User creation incomplete. Re-run setup.sh"
    return 1
  fi
}

verify_ssh_keys() {
  print_header "Step 2: Verify SSH Keys"

  local all_good=true

  for user in "$SYSADMIN_USER" "$APPMGR_USER"; do
    if [ -f "/home/$user/.ssh/authorized_keys" ]; then
      local key_count=$(wc -l < "/home/$user/.ssh/authorized_keys")
      print_success "SSH keys for $user: $key_count key(s)"

      # Show fingerprint
      if command -v ssh-keygen &> /dev/null; then
        local fingerprint=$(ssh-keygen -lf "/home/$user/.ssh/authorized_keys" 2>/dev/null | awk '{print $2}')
        echo "   Fingerprint: $fingerprint"
      fi
    else
      print_error "No SSH keys found for $user"
      all_good=false
    fi
  done

  if [ "$all_good" = false ]; then
    echo ""
    print_warning "SSH keys missing. You won't be able to login as new users!"
    print_info "Add keys manually:"
    echo "  sudo -u $SYSADMIN_USER mkdir -p /home/$SYSADMIN_USER/.ssh"
    echo "  sudo -u $SYSADMIN_USER sh -c 'echo \"YOUR_PUBLIC_KEY\" > /home/$SYSADMIN_USER/.ssh/authorized_keys'"
    echo "  sudo chmod 600 /home/$SYSADMIN_USER/.ssh/authorized_keys"
    return 1
  fi

  echo ""
  print_info "SSH keys configured correctly!"
  return 0
}

verify_security_hardening() {
  print_header "Step 3: Verify Security Hardening"

  # Check kernel hardening
  local ptrace=$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || echo "0")
  if [ "$ptrace" = "2" ]; then
    print_success "Kernel hardening: ptrace_scope = 2"
  else
    print_warning "Kernel hardening incomplete: ptrace_scope = $ptrace (expected: 2)"
  fi

  # Check fail2ban
  if systemctl is-active --quiet fail2ban; then
    print_success "fail2ban is running"
  else
    print_warning "fail2ban is not running"
  fi

  # Check auditd
  if systemctl is-active --quiet auditd; then
    print_success "auditd is running"
  else
    print_warning "auditd is not running"
  fi

  # Check UFW
  if command -v ufw &> /dev/null; then
    if sudo ufw status | grep -q "Status: active"; then
      print_success "UFW firewall is active"
    else
      print_warning "UFW firewall is not active"
    fi
  fi

  # Check Docker
  if command -v docker &> /dev/null; then
    print_success "Docker is installed ($(docker --version | awk '{print $3}' | tr -d ','))"
  else
    print_warning "Docker is not installed"
  fi

  echo ""
}

test_ssh_access() {
  print_header "Step 4: Test SSH Access (Critical!)"

  echo -e "${YELLOW}Before proceeding, you MUST verify SSH access as the new user.${NC}"
  echo ""
  echo "From your LOCAL machine, open a NEW terminal and run:"
  echo ""
  echo -e "${CYAN}  ssh ${SYSADMIN_USER}@YOUR_SERVER_IP${NC}"
  echo ""
  echo "If using a custom key:"
  echo ""
  echo -e "${CYAN}  ssh -i ~/.ssh/your-key ${SYSADMIN_USER}@YOUR_SERVER_IP${NC}"
  echo ""
  echo -e "${RED}⚠️  DO NOT close this session until SSH as ${SYSADMIN_USER} works!${NC}"
  echo ""

  if confirm "Have you successfully logged in as ${SYSADMIN_USER} from another terminal?" "n"; then
    print_success "SSH access verified for ${SYSADMIN_USER}!"

    # Test appmgr access too
    echo ""
    echo -e "${YELLOW}Now test ${APPMGR_USER} access (used for CI/CD):${NC}"
    echo ""
    echo -e "${CYAN}  ssh ${APPMGR_USER}@YOUR_SERVER_IP${NC}"
    echo ""
    echo "Or if using custom key:"
    echo -e "${CYAN}  ssh -i ~/.ssh/your-key ${APPMGR_USER}@YOUR_SERVER_IP${NC}"
    echo ""

    if confirm "Have you successfully logged in as ${APPMGR_USER}?" "n"; then
      print_success "SSH access verified for ${APPMGR_USER}!"
    else
      print_warning "${APPMGR_USER} SSH not verified - you may need it for CI/CD later"
      print_info "Fix: Ensure SSH key exists at /home/${APPMGR_USER}/.ssh/authorized_keys"
    fi

    # Offer to lock passwords now that SSH works
    echo ""
    echo -e "${CYAN}Now that SSH key auth works, lock user passwords?${NC}"
    echo "  • Forces SSH-only authentication (more secure)"
    echo "  • Passwords can still be used via cloud console (emergency access)"
    echo ""

    if confirm "Lock passwords for ${SYSADMIN_USER} and ${APPMGR_USER}?" "y"; then
      sudo passwd -l "$SYSADMIN_USER" 2>/dev/null || true
      sudo passwd -l "$APPMGR_USER" 2>/dev/null || true
      print_success "Passwords locked - SSH-only authentication enforced"
      print_info "To unlock: sudo passwd -u <username>"
    else
      print_info "Passwords remain active - remember to use strong passwords!"
    fi

    return 0
  else
    print_error "Cannot proceed without verified SSH access!"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check SSH key permissions: chmod 600 ~/.ssh/your-key"
    echo "2. Verify key on server: sudo cat /home/${SYSADMIN_USER}/.ssh/authorized_keys"
    echo "3. Check SSH logs: sudo tail -f /var/log/auth.log"
    return 1
  fi
}

handle_default_user() {
  print_header "Step 5: Manage Default User ($CURRENT_USER)"

  echo "Now that ${SYSADMIN_USER} works, what should we do with the default user ($CURRENT_USER)?"
  echo ""
  echo -e "${GREEN}Recommended: Lock the default user${NC}"
  echo "  - Disables SSH login for $CURRENT_USER"
  echo "  - Keeps user for cloud console access (emergency)"
  echo "  - Most secure while maintaining safety net"
  echo ""

  if confirm "Lock the default user $CURRENT_USER?" "y"; then
    print_step "Locking user $CURRENT_USER..."

    # Lock password
    sudo passwd -l "$CURRENT_USER" 2>/dev/null || true

    # Backup and disable SSH keys
    if [ -f "/home/$CURRENT_USER/.ssh/authorized_keys" ]; then
      sudo mv "/home/$CURRENT_USER/.ssh/authorized_keys" "/home/$CURRENT_USER/.ssh/authorized_keys.disabled" 2>/dev/null || true
    fi

    # Remove from sudo group
    if groups "$CURRENT_USER" | grep -q sudo; then
      sudo deluser "$CURRENT_USER" sudo 2>/dev/null || true
    fi

    print_success "User $CURRENT_USER locked for SSH (console access still works)"
    echo ""
    print_info "To unlock later: sudo passwd -u $CURRENT_USER"
    return 0
  else
    print_warning "Default user $CURRENT_USER remains active"
    print_info "You can lock it later with: sudo ./scripts/post-setup-user-cleanup.sh"
    return 0
  fi
}

display_next_steps() {
  print_header "Setup Verification Complete!"

  echo -e "${GREEN}✓ Your hardened VPS is ready and verified!${NC}"
  echo ""
  echo -e "${CYAN}Next Steps:${NC}"
  echo ""
  echo -e "1. ${BOLD}Always use ${SYSADMIN_USER} for system administration${NC}"
  echo "   ssh ${SYSADMIN_USER}@YOUR_SERVER"
  echo ""
  echo -e "2. ${BOLD}Set up Cloudflare Tunnel${NC}"
  echo "   Follow: docs/01-cloudflare-setup.md"
  echo "   Or run: sudo ./scripts/install-cloudflared.sh"
  echo ""
  echo -e "3. ${BOLD}Deploy your first app${NC}"
  echo "   cp -r apps/_template apps/myapp"
  echo "   cd apps/myapp && docker compose up -d"
  echo ""
  echo -e "4. ${BOLD}Set up GitOps CI/CD${NC}"
  echo "   See: .github/workflows/deploy.yml"
  echo ""
  echo -e "${BLUE}Documentation:${NC}"
  echo "  • SETUP.md - Complete setup guide"
  echo "  • RUNBOOK.md - Daily operations"
  echo "  • docs/ - Detailed guides"
  echo ""
}

# =================================================================
# Main
# =================================================================

main() {
  clear
  print_header "Post-Setup Verification"

  echo "This script verifies your hardened VPS setup and helps you"
  echo "transition from the default user to the new sysadmin user."
  echo ""

  # Run verification steps
  verify_users_created || exit 1
  verify_ssh_keys || exit 1
  verify_security_hardening
  test_ssh_access || exit 1

  # Handle default user
  if [ "$CURRENT_USER" != "$SYSADMIN_USER" ] && [ "$CURRENT_USER" != "root" ]; then
    handle_default_user
  fi

  # Display next steps
  display_next_steps
}

# Run main
main "$@"
