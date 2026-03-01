#!/usr/bin/env bash
# =================================================================
# Trivy Container CVE Scanner Setup
# =================================================================
# Installs Trivy and configures weekly vulnerability scanning of all
# running Docker container images. Results are exported as:
#   - Prometheus textfile metrics (/var/lib/prometheus/node-exporter/trivy.prom)
#   - Email/webhook alerts via notify.sh (when findings detected)
#
# Usage:
#   sudo ./scripts/security/setup-trivy.sh
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

print_header "Trivy CVE Scanner Setup"

echo "This will:"
echo "  - Install Trivy from the official apt repository"
echo "  - Install a weekly scan script for all running container images"
echo "  - Configure Prometheus metrics export and alerting"
echo ""

if ! confirm "Continue?" "y"; then
  echo "Cancelled."
  exit 0
fi

# =================================================================
# Step 1: Install Trivy
# =================================================================
print_header "Step 1/3: Install Trivy"

if command -v trivy >/dev/null 2>&1; then
  print_success "Trivy is already installed ($(trivy --version 2>/dev/null | head -1 || echo 'unknown'))"
else
  print_step "Adding Trivy repository..."
  wait_for_apt
  env DEBIAN_FRONTEND=noninteractive apt-get install -y wget gnupg lsb-release
  wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg
  echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" \
    | tee /etc/apt/sources.list.d/trivy.list

  print_step "Installing Trivy..."
  wait_for_apt
  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update
  wait_for_apt
  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    trivy

  if command -v trivy >/dev/null 2>&1; then
    print_success "Trivy installed"
  else
    print_error "Trivy installation failed"
    exit 1
  fi
fi

# Install jq for JSON parsing (required by scan script)
if ! command -v jq >/dev/null 2>&1; then
  print_step "Installing jq (required for scan result parsing)..."
  wait_for_apt
  env DEBIAN_FRONTEND=noninteractive apt-get install -y jq
  print_success "jq installed"
fi

# =================================================================
# Step 2: Install Scan Script
# =================================================================
print_header "Step 2/3: Install Scan Script"

install -d -m 0755 /opt/scripts
install -d -m 0755 /var/lib/prometheus/node-exporter
install -d -m 0755 /var/log/hosting-blueprint/security

install -m 0755 "${REPO_DIR}/scripts/security/trivy-scan.sh" /opt/scripts/hosting-trivy-scan.sh
print_success "Installed /opt/scripts/hosting-trivy-scan.sh"

# =================================================================
# Step 3: Install Cron Schedule
# =================================================================
print_header "Step 3/3: Install Cron Schedule"

# The cron entry is added to the existing security-scans file
CRON_FILE="/etc/cron.d/security-scans"
TRIVY_CRON_LINE="45 3 * * 0 root test -x /opt/scripts/hosting-trivy-scan.sh && /opt/scripts/hosting-trivy-scan.sh"

if [ -f "$CRON_FILE" ] && grep -q "trivy" "$CRON_FILE"; then
  print_success "Trivy cron entry already exists in ${CRON_FILE}"
else
  echo "" >> "$CRON_FILE"
  echo "# Weekly Trivy container CVE scan (Sunday 03:45)" >> "$CRON_FILE"
  echo "$TRIVY_CRON_LINE" >> "$CRON_FILE"
  print_success "Added Trivy cron entry to ${CRON_FILE}"
fi

print_info "Schedule: Every Sunday at 03:45 UTC"

# =================================================================
# Test Run (Optional)
# =================================================================
echo ""
if confirm "Run a test scan now? (scans all running container images)" "n"; then
  print_step "Running Trivy scan..."
  /opt/scripts/hosting-trivy-scan.sh || true
  echo ""
  if [ -f /var/lib/prometheus/node-exporter/trivy.prom ]; then
    print_success "Prometheus metrics written:"
    cat /var/lib/prometheus/node-exporter/trivy.prom
  fi
fi

# =================================================================
# Summary
# =================================================================
print_header "Trivy Setup Complete"

echo -e "${GREEN}Trivy is installed and scheduled for weekly scans.${NC}"
echo ""
echo "Scan schedule: Sunday 03:45 UTC"
echo "Metrics: /var/lib/prometheus/node-exporter/trivy.prom"
echo "Logs: /var/log/hosting-blueprint/security/trivy-scan.log"
echo ""
echo "Manual scan:"
echo "  sudo /opt/scripts/hosting-trivy-scan.sh"
echo ""
echo "Scan a specific image:"
echo "  trivy image --severity HIGH,CRITICAL nginx:latest"
echo ""
