#!/usr/bin/env bash
# =================================================================
# Optional: Install & Configure Security Tools (hosting-blueprint)
# =================================================================
# Installs and configures common host security tools:
# - AIDE     (file integrity)
# - Lynis    (security auditing)
# - rkhunter (rootkit hunter)
# - debsums  (package file integrity)
# - acct     (process accounting)
# - needrestart (restart guidance after upgrades)
# - pam_pwquality policy (password complexity)
#
# Also installs:
# - Cron schedule for scans: /etc/cron.d/security-scans
# - Log rotation: /etc/logrotate.d/security-tools
# - Helper scripts copied to /opt/scripts/
#
# Usage:
#   sudo ./scripts/security/setup-security-tools.sh
# =================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
  echo ""
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BLUE} $1${NC}"
  echo -e "${BLUE}======================================================================${NC}"
  echo ""
}

print_step() { echo -e "${BLUE}→${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }

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
      print_error "Timed out waiting for apt/dpkg locks after ${timeout}s."
      exit 1
    fi
    print_info "Waiting for apt/dpkg locks... (${elapsed}s)"
    sleep 5
  done
}

if [ "${EUID:-0}" -ne 0 ]; then
  print_error "This script must be run as root (use sudo)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_DIR="${REPO_DIR}/config"

print_header "Security Tools Setup (Optional)"

echo "This will install and schedule:"
echo "  • AIDE integrity checks (daily)"
echo "  • rkhunter scan (weekly)"
echo "  • Lynis audit (weekly)"
echo "  • debsums package integrity check (weekly)"
echo "  • acct process accounting (continuous)"
echo ""
echo "It will also configure:"
echo "  • needrestart behavior after updates"
echo "  • password quality policy (pwquality)"
echo ""

if ! confirm "Continue?" "y"; then
  echo "Cancelled."
  exit 0
fi

print_header "Step 1/5: Install Packages"
print_step "Updating apt metadata..."
wait_for_apt
env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update

print_step "Installing security tool packages..."
wait_for_apt
env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  aide \
  lynis \
  rkhunter \
  debsums \
  acct \
  needrestart \
  libpam-pwquality

print_success "Packages installed"

print_header "Step 2/5: Install Configuration Files"

if [ -f "${CONFIG_DIR}/needrestart/50-autorestart.conf" ]; then
  install -d -m 0755 /etc/needrestart/conf.d
  install -m 0644 "${CONFIG_DIR}/needrestart/50-autorestart.conf" /etc/needrestart/conf.d/50-autorestart.conf
  print_success "Installed needrestart config"
else
  print_warning "Missing config: ${CONFIG_DIR}/needrestart/50-autorestart.conf (skipping)"
fi

if [ -f "${CONFIG_DIR}/security/pwquality.conf" ]; then
  install -d -m 0755 /etc/security
  install -m 0644 "${CONFIG_DIR}/security/pwquality.conf" /etc/security/pwquality.conf
  print_success "Installed pwquality policy"
else
  print_warning "Missing config: ${CONFIG_DIR}/security/pwquality.conf (skipping)"
fi

if [ -f "${CONFIG_DIR}/modprobe.d/blacklist-unused.conf" ]; then
  if confirm "Install optional kernel module blacklist (reduces attack surface)?" "n"; then
    install -d -m 0755 /etc/modprobe.d
    install -m 0644 "${CONFIG_DIR}/modprobe.d/blacklist-unused.conf" /etc/modprobe.d/blacklist-unused.conf
    print_success "Installed /etc/modprobe.d/blacklist-unused.conf (reboot required to fully apply)"
  else
    print_info "Skipped kernel module blacklist"
  fi
else
  print_warning "Missing config: ${CONFIG_DIR}/modprobe.d/blacklist-unused.conf (skipping)"
fi

print_header "Step 3/5: Install Scan Scripts + Schedules"

print_step "Installing helper scripts to /opt/scripts..."
install -d -m 0755 /opt/scripts
install -d -m 0755 /var/log/hosting-blueprint/security
install -d -m 0755 /var/lib/hosting-blueprint
install -m 0755 "${REPO_DIR}/scripts/security/notify.sh" /opt/scripts/hosting-notify.sh
install -m 0755 "${REPO_DIR}/scripts/security/aide-check.sh" /opt/scripts/hosting-aide-check.sh
install -m 0755 "${REPO_DIR}/scripts/security/rkhunter-check.sh" /opt/scripts/hosting-rkhunter-check.sh
install -m 0755 "${REPO_DIR}/scripts/security/lynis-audit.sh" /opt/scripts/hosting-lynis-audit.sh
install -m 0755 "${REPO_DIR}/scripts/security/debsums-check.sh" /opt/scripts/hosting-debsums-check.sh
print_success "Installed scripts under /opt/scripts"

if [ -f "${CONFIG_DIR}/cron.d/security-scans" ]; then
  install -m 0644 "${CONFIG_DIR}/cron.d/security-scans" /etc/cron.d/security-scans
  print_success "Installed cron schedule: /etc/cron.d/security-scans"
else
  print_warning "Missing config: ${CONFIG_DIR}/cron.d/security-scans (skipping)"
fi

if [ -f "${CONFIG_DIR}/logrotate.d/security-tools" ]; then
  install -m 0644 "${CONFIG_DIR}/logrotate.d/security-tools" /etc/logrotate.d/security-tools
  print_success "Installed logrotate rules: /etc/logrotate.d/security-tools"
else
  print_warning "Missing config: ${CONFIG_DIR}/logrotate.d/security-tools (skipping)"
fi

print_header "Step 4/5: Enable Services"

print_step "Enabling process accounting (acct)..."
systemctl enable --now acct >/dev/null 2>&1 || true
print_success "acct enabled"

print_header "Step 5/5: Initialize Baselines (Optional)"

if confirm "Initialize AIDE baseline now? (can take a while)" "y"; then
  print_step "Running aideinit..."
  aideinit >> /var/log/hosting-blueprint/security/aide-init.log 2>&1 || true
  if [ -f /var/lib/aide/aide.db.new ]; then
    cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    print_success "AIDE baseline initialized"
  else
    print_warning "AIDE baseline file not found at /var/lib/aide/aide.db.new (check logs)"
  fi
else
  print_info "Skipped AIDE baseline initialization"
fi

if confirm "Initialize rkhunter baseline (propupd) now? (recommended after install)" "y"; then
  print_step "Running rkhunter --propupd..."
  rkhunter --propupd >> /var/log/hosting-blueprint/security/rkhunter-propupd.log 2>&1 || true
  print_success "rkhunter baseline updated"
else
  print_info "Skipped rkhunter propupd"
fi

print_header "Complete"

echo -e "${GREEN}Security tools installed and scheduled.${NC}"
echo ""
echo "Logs:"
echo "  /var/log/hosting-blueprint/security/"
echo ""
echo "Alerting (optional):"
echo "  Create /etc/hosting-blueprint/alerting.env with:"
echo "    ALERT_WEBHOOK_URL=\"https://ntfy.sh/<topic>\""
echo "    ALERT_EMAIL=\"you@example.com\"   # requires working mail setup"
echo ""
echo "Verify schedules:"
echo "  sudo ls -la /etc/cron.d/security-scans"
echo "  sudo cat /etc/cron.d/security-scans"
echo "  sudo systemctl status cron || sudo systemctl status crond"
echo ""
echo "Run scans manually:"
echo "  sudo /opt/scripts/hosting-aide-check.sh"
echo "  sudo /opt/scripts/hosting-rkhunter-check.sh"
echo "  sudo /opt/scripts/hosting-lynis-audit.sh"
echo "  sudo /opt/scripts/hosting-debsums-check.sh"
echo ""
