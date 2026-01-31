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

# Parse arguments
FORCE_JAMMY=false
for arg in "$@"; do
  case $arg in
    --force-jammy)
      FORCE_JAMMY=true
      ;;
    --help|-h)
      echo "Usage: $0 [--force-jammy]"
      echo ""
      echo "Options:"
      echo "  --force-jammy   Use Ubuntu 22.04 (jammy) repo if current distro repo unavailable"
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

# Detect distribution
CODENAME=$(lsb_release -cs)
echo "Detected Ubuntu codename: $CODENAME"
echo ""

# Create keyrings directory
echo "Creating keyrings directory..."
mkdir -p --mode=0755 /usr/share/keyrings

# Add Cloudflare GPG key
echo "Adding Cloudflare GPG key..."
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg

# Verify Cloudflare GPG key fingerprint (official fingerprint from pkg.cloudflare.com)
# Userid: "CloudFlare Software Packaging <help@cloudflare.com>"
# Note: Using case-insensitive grep and normalizing to uppercase for comparison
echo "Verifying Cloudflare GPG key fingerprint..."
CLOUDFLARE_GPG_FINGERPRINT=$(gpg --show-keys --with-fingerprint /usr/share/keyrings/cloudflare-main.gpg 2>/dev/null | grep -oiP '([a-f0-9]{4}\s*){10}' | tr -d ' ' | tr '[:lower:]' '[:upper:]' | head -1)
EXPECTED_CF_FINGERPRINT="FBA8C0EE63617C5EED695C43254B391D8CACCBF8"
if [ "$CLOUDFLARE_GPG_FINGERPRINT" != "$EXPECTED_CF_FINGERPRINT" ]; then
  echo -e "${RED}✗ Cloudflare GPG key fingerprint mismatch!${NC}"
  echo -e "${RED}  Expected: $EXPECTED_CF_FINGERPRINT${NC}"
  echo -e "${RED}  Got:      $CLOUDFLARE_GPG_FINGERPRINT${NC}"
  echo ""
  echo "This could indicate a supply chain attack or key rotation."
  echo "Verify the current fingerprint at: https://pkg.cloudflare.com/"
  rm -f /usr/share/keyrings/cloudflare-main.gpg
  exit 1
fi
echo -e "${GREEN}✓ Cloudflare GPG key verified${NC}"

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
apt update

# Install cloudflared
echo "Installing cloudflared..."
apt install -y cloudflared

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
echo "  1. Authenticate: cloudflared tunnel login"
echo "  2. Create tunnel: cloudflared tunnel create production-tunnel"
echo "  3. Configure: /etc/cloudflared/config.yml"
echo "  4. See: infra/cloudflared/tunnel-setup.md for full guide"
echo ""
