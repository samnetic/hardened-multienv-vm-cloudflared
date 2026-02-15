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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Prefer a security-first model: humans are not in the docker group.
# If docker isn't directly accessible, fall back to sudo.
DOCKER=(docker)
if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  fi
fi

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
      print_warning "User '$APPMGR_USER' is in docker group (not recommended; docker group is root-equivalent)"
    else
      print_success "User '$APPMGR_USER' is NOT in docker group (security-first)"
    fi

    # Verify CI restriction tooling is installed (best-effort).
    if [ -x /usr/local/sbin/hosting-ci-ssh ] && [ -x /usr/local/sbin/hosting-deploy ]; then
      print_success "CI deploy toolchain installed (/usr/local/sbin/hosting-*)"
    else
      print_warning "CI deploy toolchain not found (expected /usr/local/sbin/hosting-ci-ssh and /usr/local/sbin/hosting-deploy)"
    fi

    if [ -f /etc/ssh/sshd_config.d/99-appmgr-ci.conf ] && grep -q "ForceCommand /usr/local/sbin/hosting-ci-ssh" /etc/ssh/sshd_config.d/99-appmgr-ci.conf 2>/dev/null; then
      print_success "SSHD Match block installed for $APPMGR_USER (ForceCommand enabled)"
    else
      print_warning "SSHD Match block missing for $APPMGR_USER (expected /etc/ssh/sshd_config.d/99-appmgr-ci.conf)"
    fi

    if [ -f /etc/sudoers.d/appmgr-hosting-deploy ] && sudo visudo -cf /etc/sudoers.d/appmgr-hosting-deploy >/dev/null 2>&1; then
      print_success "Sudoers allowlist installed for $APPMGR_USER (/etc/sudoers.d/appmgr-hosting-deploy)"
    else
      print_warning "Sudoers allowlist missing or invalid (expected /etc/sudoers.d/appmgr-hosting-deploy)"
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

  local all_good=true

  # Check kernel hardening
  local ptrace=$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || echo "0")
  if [ "$ptrace" = "2" ]; then
    print_success "Kernel hardening: ptrace_scope = 2"
  else
    print_warning "Kernel hardening incomplete: ptrace_scope = $ptrace (expected: 2)"
  fi

  # Check ASLR
  local aslr=$(sysctl -n kernel.randomize_va_space 2>/dev/null || echo "0")
  if [ "$aslr" = "2" ]; then
    print_success "ASLR enabled: randomize_va_space = 2"
  else
    print_warning "ASLR not fully enabled: randomize_va_space = $aslr (expected: 2)"
  fi

  # Check fail2ban
  if systemctl is-active --quiet fail2ban; then
    print_success "fail2ban is running"
    local ban_count=$(sudo fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $4}' || echo "0")
    echo "   Currently banned IPs: $ban_count"
  else
    print_warning "fail2ban is not running"
    all_good=false
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
      # Check if no ports are open (zero trust)
      local open_ports=$(sudo ufw status numbered | grep -c "ALLOW" || echo "0")
      if [ "$open_ports" -eq 0 ]; then
        print_success "No ports exposed (zero trust achieved!)"
      else
        print_warning "$open_ports port rule(s) found - review if needed after tunnel setup"
      fi
    else
      print_warning "UFW firewall is not active"
      all_good=false
    fi
  fi

  # Check Docker
  if command -v docker &> /dev/null; then
    local docker_version=$("${DOCKER[@]}" --version | awk '{print $3}' | tr -d ',')
    print_success "Docker is installed ($docker_version)"

    # Check docker compose
    if "${DOCKER[@]}" compose version &>/dev/null; then
      local compose_version=$("${DOCKER[@]}" compose version | awk '{print $4}')
      print_success "Docker Compose is installed ($compose_version)"
    else
      print_warning "Docker Compose not found"
    fi

    # Check for dangerous port publishing (0.0.0.0/::)
    if [ -x "${SCRIPT_DIR}/security/check-docker-exposed-ports.sh" ]; then
      if ! "${SCRIPT_DIR}/security/check-docker-exposed-ports.sh"; then
        all_good=false
      fi
    fi
  else
    print_error "Docker is not installed"
    all_good=false
  fi

  # Check password authentication disabled
  if sudo sshd -T 2>/dev/null | grep -q "^passwordauthentication no"; then
    print_success "SSH password authentication disabled"
  else
    print_warning "SSH password authentication may be enabled"
  fi

  echo ""
  return 0
}

verify_docker_networks() {
  print_header "Step 4: Verify Docker Networks"

  local expected_networks=("hosting-caddy-origin" "dev-web" "dev-backend" "staging-web" "staging-backend" "prod-web" "prod-backend" "monitoring")
  local all_good=true

  for network in "${expected_networks[@]}"; do
    if "${DOCKER[@]}" network inspect "$network" &>/dev/null; then
      print_success "Network '$network' exists"
    else
      print_warning "Network '$network' not found"
      all_good=false
    fi
  done

  if [ "$all_good" = false ]; then
    echo ""
    print_info "Create networks with: sudo ./scripts/create-networks.sh"
  fi

  echo ""
  return 0
}

verify_services() {
  print_header "Step 5: Verify Services"

  # Check Caddy reverse proxy
  if "${DOCKER[@]}" ps | grep -q caddy; then
    print_success "Caddy reverse proxy is running"
    local caddy_status=$("${DOCKER[@]}" ps --filter "name=caddy" --format "{{.Status}}")
    echo "   Status: $caddy_status"
  else
    print_warning "Caddy reverse proxy not running"
    if [ -d "/srv/infrastructure/reverse-proxy" ]; then
      print_info "Start with: cd /srv/infrastructure/reverse-proxy && sudo docker compose --compatibility up -d"
    else
      print_info "Start with: cd infra/reverse-proxy && sudo docker compose --compatibility up -d"
      print_info "(Recommended: initialize /srv/infrastructure first)"
    fi
  fi

  # Check Cloudflared tunnel
  if systemctl is-active --quiet cloudflared 2>/dev/null || "${DOCKER[@]}" ps | grep -q cloudflared; then
    print_success "Cloudflare Tunnel is running"
  else
    print_info "Cloudflare Tunnel not detected (optional)"
    print_info "Set up with: ./scripts/install-cloudflared.sh"
  fi

  # Check timezone
  local current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "unknown")
  if [ "$current_tz" != "unknown" ]; then
    print_success "Timezone configured: $current_tz"
  else
    print_warning "Timezone not configured"
  fi

  echo ""
  return 0
}

verify_system_resources() {
  print_header "Step 6: Verify System Resources"

  # Check disk space
  local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
  local disk_avail=$(df -h / | awk 'NR==2 {print $4}')

  if [ "$disk_usage" -lt 80 ]; then
    print_success "Disk usage: ${disk_usage}% (${disk_avail} available)"
  else
    print_warning "Disk usage: ${disk_usage}% (${disk_avail} available)"
    print_info "Consider cleanup: sudo docker system prune -a"
  fi

  # Check memory
  local mem_total=$(free -h | awk '/^Mem:/ {print $2}')
  local mem_used=$(free -h | awk '/^Mem:/ {print $3}')
  local mem_percent=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2 * 100}')

  print_info "Memory: ${mem_used}/${mem_total} used (${mem_percent}%)"

  # Check load average
  local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
  print_info "Load average (1min): $load_avg"

  echo ""
  return 0
}

verify_configuration() {
  print_header "Step 7: Verify Configuration Files"

  # Check main config
  if [ -f "/opt/vm-config/setup.conf" ]; then
    print_success "Setup configuration found"
    local domain=$(grep "^DOMAIN=" /opt/vm-config/setup.conf | cut -d'=' -f2 | tr -d '"' || echo "")
    if [ -n "$domain" ]; then
      echo "   Domain: $domain"
    fi
  else
    print_warning "Setup configuration not found"
  fi

  # Check if repository exists
  if [ -d "/opt/hosting-blueprint" ]; then
    print_success "Repository installed at /opt/hosting-blueprint"
    if [ -d "/opt/hosting-blueprint/.git" ]; then
      local branch=$(cd /opt/hosting-blueprint && git branch --show-current 2>/dev/null || echo "unknown")
      echo "   Git branch: $branch"
    fi
  else
    print_warning "Repository not found at expected location"
  fi

  echo ""
  return 0
}

test_ssh_access() {
  print_header "Step 8: Test SSH Access (Critical!)"

  echo -e "${YELLOW}Before proceeding, you MUST verify SSH access as the new user.${NC}"
  echo ""
  echo "From your LOCAL machine, open a NEW terminal and run:"
  echo ""
  TUNNEL_ONLY_MARKER="/etc/hosting-blueprint/tunnel-only.enabled"
  tunnel_domain=""
  if [ -f "$TUNNEL_ONLY_MARKER" ]; then
    tunnel_domain="$(grep -E '^domain=' "$TUNNEL_ONLY_MARKER" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    if [ -z "${tunnel_domain:-}" ] && [ -f /opt/vm-config/setup.conf ]; then
      tunnel_domain="$(grep -E '^DOMAIN=' /opt/vm-config/setup.conf 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\"' || true)"
    fi
  fi

  if [ -n "${tunnel_domain:-}" ] && [ -f "$TUNNEL_ONLY_MARKER" ]; then
    base_alias="${tunnel_domain%%.*}"
    echo -e "${CYAN}  ssh ${base_alias}${NC}"
    echo -e "${CYAN}  # (connects to ssh.${tunnel_domain} as ${SYSADMIN_USER})${NC}"
    echo ""
    echo "Tip: if you haven't configured your local SSH alias yet:"
    echo -e "${CYAN}  curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/master/scripts/setup-local-ssh.sh | bash -s -- ssh.${tunnel_domain} ${SYSADMIN_USER}${NC}"
  else
    echo -e "${CYAN}  ssh ${SYSADMIN_USER}@YOUR_SERVER_IP${NC}"
    echo ""
    echo "If using a custom key:"
    echo ""
    echo -e "${CYAN}  ssh -i ~/.ssh/your-key ${SYSADMIN_USER}@YOUR_SERVER_IP${NC}"
  fi
  echo ""
  echo -e "${RED}⚠️  DO NOT close this session until SSH as ${SYSADMIN_USER} works!${NC}"
  echo ""

  if confirm "Have you successfully logged in as ${SYSADMIN_USER} from another terminal?" "n"; then
    print_success "SSH access verified for ${SYSADMIN_USER}!"

    # Test appmgr access too
    echo ""
    echo -e "${YELLOW}Now test ${APPMGR_USER} access (used for CI/CD):${NC}"
    echo ""
    if [ -n "${tunnel_domain:-}" ] && [ -f "$TUNNEL_ONLY_MARKER" ]; then
      base_alias="${tunnel_domain%%.*}"
      echo -e "${CYAN}  ssh ${base_alias}-${APPMGR_USER} \"hosting status dev\"${NC}"
    else
      echo -e "${CYAN}  ssh ${APPMGR_USER}@YOUR_SERVER_IP \"hosting status dev\"${NC}"
      echo ""
      echo "Or if using custom key:"
      echo -e "${CYAN}  ssh -i ~/.ssh/your-key ${APPMGR_USER}@YOUR_SERVER_IP \"hosting status dev\"${NC}"
    fi
    echo ""

    if confirm "Have you successfully logged in as ${APPMGR_USER}?" "n"; then
      print_success "SSH access verified for ${APPMGR_USER}!"
    else
      print_warning "${APPMGR_USER} SSH not verified - you may need it for CI/CD later"
      print_info "Fix: Ensure SSH key exists at /home/${APPMGR_USER}/.ssh/authorized_keys"
    fi

    # Offer to lock passwords now that SSH works
    echo ""
    echo -e "${CYAN}Password hardening:${NC}"
    echo "  • SSH password authentication is already disabled by SSH hardening."
    echo "  • appmgr should stay password-locked (CI-only user)."
    echo ""

    if confirm "Ensure password is locked for ${APPMGR_USER} (recommended)?" "y"; then
      sudo passwd -l "$APPMGR_USER" 2>/dev/null || true
      print_success "${APPMGR_USER} password locked"
    fi

    # sysadmin password is used for sudo when SYSADMIN_SUDO_MODE=password.
    if [ -f "/etc/sudoers.d/${SYSADMIN_USER}" ]; then
      echo ""
      print_info "${SYSADMIN_USER} has passwordless sudo (/etc/sudoers.d/${SYSADMIN_USER} exists)."
      if confirm "Lock password for ${SYSADMIN_USER} too? (optional; affects console login)" "n"; then
        sudo passwd -l "$SYSADMIN_USER" 2>/dev/null || true
        print_success "${SYSADMIN_USER} password locked"
      fi
    else
      print_info "Not locking ${SYSADMIN_USER} password (sudo may require it)."
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
  print_header "Step 9: Manage Default User ($CURRENT_USER)"

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
  echo "   cd apps/myapp && sudo docker compose --compatibility up -d"
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
  verify_docker_networks
  verify_services
  verify_system_resources
  verify_configuration
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
