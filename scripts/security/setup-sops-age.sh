#!/usr/bin/env bash
# =================================================================
# Optional: Install & Configure SOPS + age (for encrypted .env files)
# =================================================================
# This blueprint supports committing encrypted dotenv files:
#   .env.<env>.enc  (SOPS-encrypted dotenv)
#
# The GitHub Actions deploy workflow can decrypt on the VM if:
# - `sops` is installed
# - An age key exists at: /etc/sops/age/keys.txt
#
# Usage:
#   sudo ./scripts/security/setup-sops-age.sh
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

SOPS_DIR="/etc/sops"
AGE_DIR="${SOPS_DIR}/age"
AGE_KEY_FILE="${AGE_DIR}/keys.txt"

SECRETS_GROUP="${SECRETS_GROUP:-hosting-secrets}"

print_header "SOPS + age Setup (Optional)"

echo "This will:"
echo "  • Install: sops, age"
echo "  • Create:  ${AGE_KEY_FILE}"
echo ""
echo -e "${YELLOW}Security note:${NC} Anyone who can read ${AGE_KEY_FILE} can decrypt your encrypted dotenv files."
echo "Treat this file like a production root key and back it up securely."
echo ""

if ! confirm "Continue?" "y"; then
  echo "Cancelled."
  exit 0
fi

print_header "Step 1/3: Install Packages"

# --- age (available via apt on Ubuntu 22.04+) ---
if command -v age >/dev/null 2>&1; then
  print_success "age is already installed ($(age --version 2>/dev/null || echo 'unknown'))"
else
  print_step "Installing age via apt..."
  wait_for_apt
  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update
  wait_for_apt
  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    age
  print_success "age installed"
fi

# --- sops (not in Ubuntu repos; install from GitHub releases) ---
if command -v sops >/dev/null 2>&1; then
  print_success "sops is already installed ($(sops --version 2>/dev/null | head -1 || echo 'unknown'))"
else
  print_step "Installing sops from GitHub releases..."
  ARCH="$(dpkg --print-architecture)"
  # Map dpkg arch to sops binary naming
  case "$ARCH" in
    amd64) SOPS_ARCH="amd64" ;;
    arm64) SOPS_ARCH="arm64" ;;
    *)
      print_error "Unsupported architecture for sops: $ARCH"
      print_info "Install sops manually: https://github.com/getsops/sops/releases"
      exit 1
      ;;
  esac

  SOPS_VERSION="$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | grep '"tag_name"' | cut -d'"' -f4)"
  if [ -z "$SOPS_VERSION" ]; then
    print_error "Could not determine latest sops version from GitHub API"
    exit 1
  fi
  SOPS_URL="https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${SOPS_ARCH}"

  print_info "Downloading sops ${SOPS_VERSION} for ${SOPS_ARCH}..."
  curl -fsSL -o /usr/local/bin/sops "$SOPS_URL"
  chmod 755 /usr/local/bin/sops
  print_success "sops ${SOPS_VERSION} installed to /usr/local/bin/sops"
fi

print_header "Step 2/3: Create Directories"

print_step "Creating ${AGE_DIR}..."
install -d -m 0755 "$SOPS_DIR"

if getent group "$SECRETS_GROUP" >/dev/null 2>&1; then
  install -d -m 0750 -o root -g "$SECRETS_GROUP" "$AGE_DIR"
  print_success "Created ${AGE_DIR} (root:${SECRETS_GROUP}, 0750)"
else
  install -d -m 0700 -o root -g root "$AGE_DIR"
  print_warning "Group '${SECRETS_GROUP}' not found; created ${AGE_DIR} as root-only (0700)"
fi

print_header "Step 3/3: Configure age Key"

if [ -f "$AGE_KEY_FILE" ]; then
  print_success "Existing age key found: ${AGE_KEY_FILE}"
  if confirm "Show the public key now? (safe to share)" "y"; then
    echo ""
    print_info "Public key (use this in .sops.yaml recipients):"
    age-keygen -y "$AGE_KEY_FILE"
    echo ""
  fi

  if confirm "Rotate/regenerate the age key? (DANGEROUS: breaks decryption of old files)" "n"; then
    print_error "Refusing to rotate automatically."
    print_error "If you rotate, you must re-encrypt all .env.*.enc files with the new recipient."
    exit 1
  fi
else
  echo "No age key file found at ${AGE_KEY_FILE}."
  echo ""
  echo "You have two safe options:"
  echo "  1) Generate a new key pair on this VM (recommended)"
  echo "  2) Restore an existing key from a secure backup"
  echo ""

  if confirm "Generate a new age key now?" "y"; then
    print_step "Generating age key..."
    umask 0077
    age-keygen -o "$AGE_KEY_FILE"
    print_success "Generated key: ${AGE_KEY_FILE}"
  else
    print_info "Skipping generation."
    print_info "Restore your key to: ${AGE_KEY_FILE}"
    print_info "Then run: age-keygen -y ${AGE_KEY_FILE} (to print public key)"
    exit 0
  fi

  if getent group "$SECRETS_GROUP" >/dev/null 2>&1; then
    chown root:"$SECRETS_GROUP" "$AGE_KEY_FILE"
    chmod 0640 "$AGE_KEY_FILE"
    print_success "Permissions set: root:${SECRETS_GROUP} 0640"
  else
    chown root:root "$AGE_KEY_FILE"
    chmod 0600 "$AGE_KEY_FILE"
    print_success "Permissions set: root:root 0600"
  fi

  echo ""
  print_info "Public key (use this in .sops.yaml recipients):"
  age-keygen -y "$AGE_KEY_FILE"
  echo ""
fi

print_header "Complete"

echo -e "${GREEN}SOPS + age are ready.${NC}"
echo ""
echo "Next steps:"
echo "  • Add the public key to your deployments repo .sops.yaml"
echo "  • Encrypt dotenv files with sops:"
echo "      sops --encrypt --input-type dotenv --output-type dotenv .env.production > .env.production.enc"
echo ""
echo "On the VM, the deploy workflow expects:"
echo "  • sops: $(command -v sops >/dev/null 2>&1 && echo 'installed' || echo 'missing')"
echo "  • age key: $AGE_KEY_FILE"
