#!/usr/bin/env bash
# =================================================================
# Install Cloudflare Tunnel (cloudflared)
# =================================================================
# Installs latest cloudflared via apt repository (2024/2025 method)
#
# Usage:
#   sudo ./install-cloudflared.sh              # Interactive mode
#   sudo ./install-cloudflared.sh --force-jammy  # Non-interactive, use jammy repo
# =================================================================

set -euo pipefail

# Repo paths (for optional unit installation)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="${REPO_DIR}/config"

# Parse arguments
FORCE_JAMMY=false
SKIP_GPG_CHECK=false
for arg in "$@"; do
  case $arg in
    --force-jammy)
      FORCE_JAMMY=true
      ;;
    --skip-gpg-check)
      SKIP_GPG_CHECK=true
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --force-jammy      Use Ubuntu 22.04 (jammy) repo if current distro repo unavailable"
      echo "  --skip-gpg-check   Skip GPG key fingerprint verification (not recommended)"
      exit 0
      ;;
  esac
done

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "======================================================================"
echo " Installing Cloudflare Tunnel (cloudflared)"
echo "======================================================================"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}✗ This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Ensure required tools exist (this script may be run standalone on a fresh VM).
export DEBIAN_FRONTEND=noninteractive

# apt-daily/apt-daily-upgrade can hold locks on fresh Ubuntu installs.
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
      echo -e "${RED}✗ Timed out waiting for apt/dpkg locks after ${timeout}s${NC}"
      echo "Try: sudo systemctl stop apt-daily.service apt-daily-upgrade.service"
      exit 1
    fi

    echo "Waiting for apt/dpkg locks... (${elapsed}s)"
    sleep 5
  done
}

if ! command -v curl >/dev/null 2>&1; then
  echo "Installing curl..."
  wait_for_apt
  apt-get update
  wait_for_apt
  apt-get install -y curl ca-certificates
fi
if ! command -v gpg >/dev/null 2>&1; then
  echo "Installing gnupg..."
  wait_for_apt
  apt-get update
  wait_for_apt
  apt-get install -y gnupg
fi

# Detect distribution
if command -v lsb_release >/dev/null 2>&1; then
  CODENAME="$(lsb_release -cs)"
else
  # Fallback if lsb-release isn't installed.
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-}"
  fi
fi
if [ -z "${CODENAME:-}" ]; then
  echo -e "${RED}✗ Could not detect Ubuntu codename${NC}"
  echo "Install lsb-release or verify /etc/os-release has VERSION_CODENAME."
  exit 1
fi
echo "Detected Ubuntu codename: $CODENAME"
echo ""

# Create keyrings directory
echo "Creating keyrings directory..."
mkdir -p --mode=0755 /usr/share/keyrings

# Add Cloudflare GPG key
echo "Adding Cloudflare GPG key..."
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg

# Verify Cloudflare GPG key fingerprint
# Multiple fingerprints supported for key rotation transitions
# Userid: "CloudFlare Software Packaging <help@cloudflare.com>"
if [ "$SKIP_GPG_CHECK" = true ]; then
  echo -e "${YELLOW}⚠ Skipping GPG key verification (--skip-gpg-check)${NC}"
else
  echo "Verifying Cloudflare GPG key fingerprint..."
  CLOUDFLARE_GPG_FINGERPRINT=$(gpg --show-keys --with-fingerprint /usr/share/keyrings/cloudflare-main.gpg 2>/dev/null | grep -oiP '([a-f0-9]{4}\s*){10}' | tr -d ' ' | tr '[:lower:]' '[:upper:]' | head -1)

  # Known valid Cloudflare GPG fingerprints
  # Add new fingerprints here when Cloudflare rotates keys
  KNOWN_FINGERPRINTS=(
    "CC94B39C77AE7342A68B89628A682D308D4E5E73"  # Current (Oct 2025)
    "FBA8C0EE63617C5EED695C43254B391D8CACCBF8"  # Legacy (pre-Oct 2025)
  )

  # Check if fingerprint matches any known good fingerprint
  FINGERPRINT_VALID=false
  for known_fp in "${KNOWN_FINGERPRINTS[@]}"; do
    if [ "$CLOUDFLARE_GPG_FINGERPRINT" = "$known_fp" ]; then
      FINGERPRINT_VALID=true
      break
    fi
  done

  if [ "$FINGERPRINT_VALID" = true ]; then
    echo -e "${GREEN}✓ Cloudflare GPG key verified${NC}"
    echo "  Fingerprint: $CLOUDFLARE_GPG_FINGERPRINT"
  else
    echo -e "${YELLOW}⚠ Unknown Cloudflare GPG key fingerprint!${NC}"
    echo -e "${YELLOW}  Got: $CLOUDFLARE_GPG_FINGERPRINT${NC}"
    echo ""
    echo "This could be:"
    echo "  1. A new key rotation by Cloudflare"
    echo "  2. A supply chain attack (unlikely but possible)"
    echo ""
    echo "Known valid fingerprints:"
    for known_fp in "${KNOWN_FINGERPRINTS[@]}"; do
      echo "  - $known_fp"
    done
    echo ""
    echo "Please verify the fingerprint at: https://pkg.cloudflare.com/"
    echo "If this is a legitimate new key, update this script with the new fingerprint."
    echo ""
    read -rp "Do you want to proceed anyway? (yes/no): " PROCEED_ANYWAY
    if [ "$PROCEED_ANYWAY" != "yes" ]; then
      echo -e "${RED}✗ Installation cancelled${NC}"
      rm -f /usr/share/keyrings/cloudflare-main.gpg
      exit 1
    fi
    echo -e "${YELLOW}⚠ Proceeding with unknown GPG key (user confirmed)${NC}"
  fi
fi

# Check if cloudflared repo exists for this codename
echo "Checking Cloudflare repository availability..."
if ! curl -fsSL https://pkg.cloudflare.com/cloudflared/dists/$CODENAME/Release >/dev/null 2>&1; then
  echo ""
  echo -e "${YELLOW}⚠️  Cloudflare apt repository not available for '$CODENAME'${NC}"
  echo ""
  echo "Available options:"
  echo "  1. Use 'jammy' (Ubuntu 22.04) repository instead"
  echo "  2. Cancel and install cloudflared manually from:"
  echo "     https://github.com/cloudflare/cloudflared/releases"
  echo ""

  if [ "$FORCE_JAMMY" = true ]; then
    echo "Using jammy repository (--force-jammy flag set)"
    CODENAME="jammy"
  else
    read -rp "Use 'jammy' repository? (yes/no): " USE_JAMMY
    if [ "$USE_JAMMY" = "yes" ]; then
      CODENAME="jammy"
      echo ""
      echo "Using jammy repository..."
    else
      echo ""
      echo "Installation cancelled."
      echo "Install manually from: https://github.com/cloudflare/cloudflared/releases"
      exit 1
    fi
  fi
fi

# Add Cloudflare apt repository
echo "Adding Cloudflare apt repository..."
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $CODENAME main" | tee /etc/apt/sources.list.d/cloudflared.list

# Update package list
echo "Updating package list..."
wait_for_apt
apt-get update

# Install cloudflared
echo "Installing cloudflared..."
wait_for_apt
apt-get install -y cloudflared

# Optional: install and enable automatic cloudflared upgrades (systemd timer)
echo ""
echo "Configuring automatic cloudflared upgrades (recommended)..."
if command -v systemctl >/dev/null 2>&1; then
  if [ -f "${CONFIG_DIR}/bin/hosting-cloudflared-upgrade" ] && \
     [ -f "${CONFIG_DIR}/systemd/hosting-cloudflared-upgrade.service" ] && \
     [ -f "${CONFIG_DIR}/systemd/hosting-cloudflared-upgrade.timer" ]; then
    install -d -m 0755 /usr/local/sbin
    install -m 0755 "${CONFIG_DIR}/bin/hosting-cloudflared-upgrade" /usr/local/sbin/hosting-cloudflared-upgrade
    install -m 0644 "${CONFIG_DIR}/systemd/hosting-cloudflared-upgrade.service" /etc/systemd/system/hosting-cloudflared-upgrade.service
    install -m 0644 "${CONFIG_DIR}/systemd/hosting-cloudflared-upgrade.timer" /etc/systemd/system/hosting-cloudflared-upgrade.timer
    systemctl daemon-reload
    systemctl enable --now hosting-cloudflared-upgrade.timer >/dev/null 2>&1 || true
    echo -e "${GREEN}✓ Automatic cloudflared upgrades enabled (hosting-cloudflared-upgrade.timer)${NC}"
  else
    echo -e "${YELLOW}⚠ Missing upgrade timer templates under ${CONFIG_DIR}/ (skipping)${NC}"
  fi
else
  echo -e "${YELLOW}⚠ systemctl not found (skipping auto-upgrade timer)${NC}"
fi

# Verify installation
echo ""
if ! command -v cloudflared &> /dev/null; then
  echo -e "${RED}✗ cloudflared installation failed - command not found${NC}"
  echo "Try installing manually from: https://github.com/cloudflare/cloudflared/releases"
  exit 1
fi

echo "======================================================================"
echo " Installation Complete!"
echo "======================================================================"
echo ""
cloudflared --version
echo ""
echo -e "${GREEN}✓ cloudflared installed successfully${NC}"
echo ""
echo "Next steps:"
echo ""
echo -e "${CYAN}Option 1: Automated Setup (Recommended)${NC}"
echo "  sudo ./scripts/setup-cloudflared.sh yourdomain.com"
echo "  (Handles authentication, tunnel creation, DNS, and service setup)"
echo ""
echo -e "${CYAN}Option 2: Manual Setup${NC}"
echo "  1. Authenticate: cloudflared tunnel login"
echo "  2. Create tunnel: cloudflared tunnel create production-tunnel"
echo "  3. Configure: /etc/cloudflared/config.yml"
echo "  4. See: infra/cloudflared/tunnel-setup.md for full guide"
echo ""
