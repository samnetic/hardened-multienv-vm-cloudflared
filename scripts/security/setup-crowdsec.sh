#!/usr/bin/env bash
# =================================================================
# CrowdSec Installation & Configuration
# =================================================================
# Installs CrowdSec + firewall bouncer for collaborative intrusion
# detection and prevention. Optionally configures Caddy log
# acquisition for web traffic analysis.
#
# What this does:
#   - Installs CrowdSec from official apt repo
#   - Installs cs-firewall-bouncer-iptables
#   - Registers the bouncer with CrowdSec API
#   - Configures Caddy access log acquisition (optional)
#   - Enables deny logging for blocked IP visibility
#   - Installs SSH and Linux acquisition (auto-detected)
#
# Usage:
#   sudo ./scripts/security/setup-crowdsec.sh
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

print_step() { echo -e "${BLUE}->${NC} $1"; }
print_success() { echo -e "${GREEN}ok${NC} $1"; }
print_warning() { echo -e "${YELLOW}!!${NC} $1"; }
print_error() { echo -e "${RED}xx${NC} $1"; }
print_info() { echo -e "${BLUE}--${NC} $1"; }

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

print_header "CrowdSec Setup"

echo "This will install and configure:"
echo "  - CrowdSec (collaborative intrusion detection)"
echo "  - Firewall bouncer (automatic IP blocking via iptables)"
echo "  - Caddy log acquisition (optional, for web traffic analysis)"
echo ""
echo "CrowdSec analyzes logs (SSH, web, system) and blocks attack"
echo "IPs using shared threat intelligence from the community."
echo ""

if ! confirm "Continue?" "y"; then
  echo "Cancelled."
  exit 0
fi

# =================================================================
# Step 1: Install CrowdSec
# =================================================================
print_header "Step 1/4: Install CrowdSec"

if command -v cscli >/dev/null 2>&1; then
  print_success "CrowdSec is already installed ($(cscli version 2>/dev/null | head -1 || echo 'unknown'))"
else
  print_step "Adding CrowdSec repository..."
  curl -fsSL https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash

  print_step "Installing CrowdSec..."
  wait_for_apt
  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    crowdsec

  if command -v cscli >/dev/null 2>&1; then
    print_success "CrowdSec installed"
  else
    print_error "CrowdSec installation failed"
    exit 1
  fi
fi

# Ensure CrowdSec is running
systemctl enable crowdsec
systemctl start crowdsec
print_success "CrowdSec service enabled and running"

# =================================================================
# Step 2: Install Firewall Bouncer
# =================================================================
print_header "Step 2/4: Install Firewall Bouncer"

if dpkg -l cs-firewall-bouncer-iptables 2>/dev/null | grep -q '^ii'; then
  print_success "Firewall bouncer already installed"
else
  print_step "Installing cs-firewall-bouncer-iptables..."
  wait_for_apt
  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    cs-firewall-bouncer-iptables

  print_success "Firewall bouncer installed"
fi

# Configure deny logging for visibility
BOUNCER_CONFIG="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
if [ -f "$BOUNCER_CONFIG" ]; then
  print_step "Configuring deny logging..."

  # Enable deny_log and set prefix for easy identification in logs
  if grep -q "deny_log:" "$BOUNCER_CONFIG"; then
    sed -i 's/^deny_log:.*/deny_log: true/' "$BOUNCER_CONFIG"
  else
    echo "deny_log: true" >> "$BOUNCER_CONFIG"
  fi

  if grep -q "deny_log_prefix:" "$BOUNCER_CONFIG"; then
    sed -i 's/^deny_log_prefix:.*/deny_log_prefix: "crowdsec: "/' "$BOUNCER_CONFIG"
  else
    echo 'deny_log_prefix: "crowdsec: "' >> "$BOUNCER_CONFIG"
  fi

  print_success "Deny logging enabled (prefix: 'crowdsec: ')"
fi

# Restart bouncer to apply config
systemctl enable crowdsec-firewall-bouncer
systemctl restart crowdsec-firewall-bouncer
print_success "Firewall bouncer enabled and running"

# =================================================================
# Step 3: Install Collections & Parsers
# =================================================================
print_header "Step 3/4: Install Scenarios & Collections"

print_step "Installing SSH protection collection..."
cscli collections install crowdsecurity/sshd 2>/dev/null || true
print_success "SSH collection installed"

print_step "Installing Linux collection..."
cscli collections install crowdsecurity/linux 2>/dev/null || true
print_success "Linux collection installed"

print_step "Installing base HTTP scenarios..."
cscli collections install crowdsecurity/base-http-scenarios 2>/dev/null || true
print_success "Base HTTP scenarios installed"

# =================================================================
# Step 4: Caddy Log Acquisition (Optional)
# =================================================================
print_header "Step 4/4: Caddy Log Acquisition (Optional)"

echo "If you use Caddy as a reverse proxy with JSON access logging,"
echo "CrowdSec can parse those logs to detect web attacks (SQL injection,"
echo "path traversal, scanners, etc.)."
echo ""

if confirm "Configure Caddy access log acquisition?" "n"; then
  # Install Caddy parser/collection
  print_step "Installing Caddy collection..."
  cscli collections install crowdsecurity/caddy 2>/dev/null || true
  print_success "Caddy collection installed"

  # Determine Caddy log paths
  DOCKER_DATA_ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '/var/lib/docker')"
  DEFAULT_CADDY_LOGS="${DOCKER_DATA_ROOT}/volumes/*caddy*/_data/logs"

  echo ""
  echo "Enter the glob pattern for Caddy JSON access logs."
  echo "Default: ${DEFAULT_CADDY_LOGS}/*.log"
  echo ""
  read -rp "Caddy log path [${DEFAULT_CADDY_LOGS}/*.log]: " CADDY_LOG_PATH
  CADDY_LOG_PATH="${CADDY_LOG_PATH:-${DEFAULT_CADDY_LOGS}/*.log}"

  # Install acquisition config
  ACQUIS_DIR="/etc/crowdsec/acquis.d"
  mkdir -p "$ACQUIS_DIR"

  if [ -f "${CONFIG_DIR}/crowdsec/caddy-acquis.yaml.template" ]; then
    sed "s|__CADDY_LOG_GLOB__|${CADDY_LOG_PATH}|g" \
      "${CONFIG_DIR}/crowdsec/caddy-acquis.yaml.template" \
      > "${ACQUIS_DIR}/caddy.yaml"
  else
    cat > "${ACQUIS_DIR}/caddy.yaml" <<EOF
# Caddy reverse proxy access logs (CrowdSec acquisition)
filenames:
  - ${CADDY_LOG_PATH}
labels:
  type: caddy
source: file
EOF
  fi

  print_success "Caddy acquisition config installed at ${ACQUIS_DIR}/caddy.yaml"

  # Reload CrowdSec to pick up new acquisition
  systemctl reload crowdsec
  print_success "CrowdSec reloaded with Caddy acquisition"
else
  print_info "Skipping Caddy acquisition (can be configured later)"
fi

# =================================================================
# Email Notifications (Optional)
# =================================================================
echo ""
if confirm "Configure CrowdSec email notifications?" "n"; then
  read -rp "SMTP host (e.g., smtp.office365.com): " SMTP_HOST
  read -rp "SMTP port [587]: " SMTP_PORT
  SMTP_PORT="${SMTP_PORT:-587}"
  read -rp "SMTP user: " SMTP_USER
  read -rsp "SMTP password: " SMTP_PASS
  echo ""
  read -rp "From address: " SMTP_FROM
  read -rp "To address: " SMTP_TO

  mkdir -p /etc/crowdsec/notifications
  cat > /etc/crowdsec/notifications/email.yaml <<EOF
type: email
name: email_default
log_level: info
smtp_host: ${SMTP_HOST}
smtp_port: ${SMTP_PORT}
smtp_username: ${SMTP_USER}
smtp_password: "${SMTP_PASS}"
sender_email: ${SMTP_FROM}
receiver_emails:
  - ${SMTP_TO}
encryption_type: starttls
email_subject: "CrowdSec Alert - \$(hostname)"
format: |
  CrowdSec detected malicious activity:
  {{range . -}}
  - IP: {{.Alert.Source.IP}} | Scenario: {{.Alert.Scenario}} | Country: {{.Alert.Source.Cn}}
  {{end -}}
EOF
  chmod 600 /etc/crowdsec/notifications/email.yaml

  # Enable email in profiles
  PROFILES_FILE="/etc/crowdsec/profiles.yaml"
  if [ -f "$PROFILES_FILE" ] && ! grep -q "email_default" "$PROFILES_FILE"; then
    # Add notification to default profile
    sed -i '/^  decisions:/i\  notifications:\n    - email_default' "$PROFILES_FILE" 2>/dev/null || true
  fi

  systemctl reload crowdsec
  print_success "Email notifications configured"
else
  print_info "Skipping email notifications"
fi

# =================================================================
# Summary
# =================================================================
print_header "CrowdSec Setup Complete"

echo -e "${GREEN}CrowdSec is installed and protecting your server.${NC}"
echo ""
echo "Services:"
echo "  - CrowdSec engine: $(systemctl is-active crowdsec)"
echo "  - Firewall bouncer: $(systemctl is-active crowdsec-firewall-bouncer)"
echo ""
echo "Useful commands:"
echo "  cscli metrics                       # View detection metrics"
echo "  cscli alerts list                   # View recent alerts"
echo "  cscli decisions list                # View active blocks"
echo "  cscli bouncers list                 # View registered bouncers"
echo "  cscli collections list              # View installed collections"
echo ""
echo "Test blocking:"
echo "  cscli decisions add --ip 1.2.3.4 --duration 1m --reason 'test'"
echo "  cscli decisions delete --ip 1.2.3.4"
echo ""
echo "Deny log entries (if UFW logging is enabled):"
echo "  grep 'crowdsec: ' /var/log/kern.log | tail -5"
echo ""
echo "CrowdSec Console (optional - community threat dashboard):"
echo "  cscli console enroll <enrollment-key>"
echo "  Visit: https://app.crowdsec.net"
echo ""
