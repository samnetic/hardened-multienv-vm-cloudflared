#!/usr/bin/env bash
# =================================================================
# Local Machine SSH Setup for Cloudflare Tunnel
# =================================================================
# Run this on YOUR LOCAL MACHINE to set up SSH via tunnel
#
# What this does:
#   1. Detects your OS (macOS, Ubuntu, Debian, Arch, other)
#   2. Installs cloudflared
#   3. Configures ~/.ssh/config for tunnel access
#   4. Tests SSH connection
#
# Usage:
#   # Download and run directly:
#   curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/master/scripts/setup-local-ssh.sh | bash -s -- ssh.codeagen.com sysadmin ~/.ssh/id_rsa
#
#   # Or download, review, then run:
#   wget https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/master/scripts/setup-local-ssh.sh
#   chmod +x setup-local-ssh.sh
#   ./setup-local-ssh.sh ssh.yourdomain.com sysadmin ~/.ssh/id_rsa
#
#   # Auto-detect identity file (will search for common SSH keys):
#   ./setup-local-ssh.sh ssh.yourdomain.com sysadmin
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
# Parse Arguments
# =================================================================

if [ $# -lt 2 ]; then
  print_error "Missing required arguments"
  echo "Usage: $0 ssh.yourdomain.com username [identity_file]"
  echo ""
  echo "Example:"
  echo "  $0 ssh.codeagen.com sysadmin ~/.ssh/id_rsa"
  echo "  $0 ssh.codeagen.com sysadmin  # Auto-detect identity file"
  exit 1
fi

SSH_HOSTNAME="$1"
SSH_USER="$2"
IDENTITY_FILE="${3:-}"

# Extract domain from hostname (remove 'ssh.' prefix if present)
DOMAIN="${SSH_HOSTNAME#ssh.}"

# Default alias: domain name, plus user suffix if not sysadmin
# Example: "codeagen" for sysadmin, "codeagen-appmgr" for appmgr
BASE_ALIAS="${DOMAIN%%.*}"
if [ "$SSH_USER" = "sysadmin" ]; then
  SSH_ALIAS="$BASE_ALIAS"
else
  SSH_ALIAS="${BASE_ALIAS}-${SSH_USER}"
fi

# Auto-detect or select identity file if not provided
if [ -z "$IDENTITY_FILE" ]; then
  # Find all private keys in ~/.ssh/
  mapfile -t AVAILABLE_KEYS < <(find ~/.ssh/ -maxdepth 1 -type f \( -name "id_*" -o -name "*key" -o -name "*_rsa" \) ! -name "*.pub" 2>/dev/null)

  if [ ${#AVAILABLE_KEYS[@]} -eq 0 ]; then
    print_error "No SSH private keys found in ~/.ssh/"
    echo ""
    read -rp "Enter path to your SSH private key: " IDENTITY_FILE

    if [ ! -f "$IDENTITY_FILE" ]; then
      print_error "Identity file not found: $IDENTITY_FILE"
      exit 1
    fi
  elif [ ${#AVAILABLE_KEYS[@]} -eq 1 ]; then
    # Only one key found, use it automatically
    IDENTITY_FILE="${AVAILABLE_KEYS[0]}"
    print_info "Found SSH key: $IDENTITY_FILE"
  else
    # Multiple keys found, let user choose
    echo ""
    print_info "Multiple SSH keys found. Please select which one to use:"
    echo ""

    for i in "${!AVAILABLE_KEYS[@]}"; do
      key="${AVAILABLE_KEYS[$i]}"
      # Show key type and fingerprint if possible
      key_type=$(ssh-keygen -l -f "$key" 2>/dev/null | awk '{print $4}' | tr -d '()')
      if [ -n "$key_type" ]; then
        echo "  $((i+1))) $(basename "$key") [$key_type]"
      else
        echo "  $((i+1))) $(basename "$key")"
      fi
    done

    echo ""
    read -rp "Select key (1-${#AVAILABLE_KEYS[@]}): " key_selection

    # Validate selection
    if ! [[ "$key_selection" =~ ^[0-9]+$ ]] || [ "$key_selection" -lt 1 ] || [ "$key_selection" -gt ${#AVAILABLE_KEYS[@]} ]; then
      print_error "Invalid selection"
      exit 1
    fi

    IDENTITY_FILE="${AVAILABLE_KEYS[$((key_selection-1))]}"
    echo ""
    print_success "Selected: $IDENTITY_FILE"
  fi
fi

# Expand tilde to home directory
IDENTITY_FILE="${IDENTITY_FILE/#\~/$HOME}"

# Verify identity file exists
if [ ! -f "$IDENTITY_FILE" ]; then
  print_error "Identity file not found: $IDENTITY_FILE"
  exit 1
fi

# Verify it's actually a private key (not a .pub file)
if [[ "$IDENTITY_FILE" == *.pub ]]; then
  print_error "You selected a PUBLIC key (.pub file)"
  echo "You need the PRIVATE key (without .pub extension)"
  exit 1
fi

# =================================================================
# Detect OS
# =================================================================

detect_os() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="macos"
  elif [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "$ID" in
      ubuntu|debian)
        OS="debian"
        ;;
      arch|manjaro)
        OS="arch"
        ;;
      fedora|rhel|centos)
        OS="fedora"
        ;;
      *)
        OS="linux-generic"
        ;;
    esac
  else
    OS="unknown"
  fi

  print_info "Detected OS: $OS"
}

# =================================================================
# Install cloudflared
# =================================================================

install_cloudflared() {
  print_header "Step 1/3: Install cloudflared"

  if command -v cloudflared &> /dev/null; then
    print_success "cloudflared already installed ($(cloudflared --version | head -1))"
    return 0
  fi

  print_step "Installing cloudflared..."

  case "$OS" in
    macos)
      if command -v brew &> /dev/null; then
        brew install cloudflared
      else
        print_error "Homebrew not found. Install from: https://brew.sh"
        print_info "Or download manually: https://github.com/cloudflare/cloudflared/releases"
        exit 1
      fi
      ;;

    debian)
      print_step "Adding Cloudflare apt repository..."

      # Need sudo for system changes
      if [ "$EUID" -eq 0 ]; then
        SUDO=""
      else
        SUDO="sudo"
      fi

      # Download GPG key
      $SUDO mkdir -p --mode=0755 /usr/share/keyrings
      curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | $SUDO tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

      # Add repository
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | $SUDO tee /etc/apt/sources.list.d/cloudflared.list

      # Install
      $SUDO apt update
      $SUDO apt install -y cloudflared
      ;;

    arch)
      sudo pacman -S cloudflared
      ;;

    fedora)
      print_warning "Fedora/RHEL not directly supported by Cloudflare apt repo"
      print_info "Downloading binary directly..."

      ARCH=$(uname -m)
      case "$ARCH" in
        x86_64)
          BINARY_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
          ;;
        aarch64|arm64)
          BINARY_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
          ;;
        *)
          print_error "Unsupported architecture: $ARCH"
          exit 1
          ;;
      esac

      curl -L "$BINARY_URL" -o cloudflared
      chmod +x cloudflared
      sudo mv cloudflared /usr/local/bin/
      ;;

    linux-generic|unknown)
      print_warning "Generic Linux installation"
      print_info "Downloading binary directly..."

      ARCH=$(uname -m)
      case "$ARCH" in
        x86_64)
          BINARY_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
          ;;
        aarch64|arm64)
          BINARY_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
          ;;
        *)
          print_error "Unsupported architecture: $ARCH"
          exit 1
          ;;
      esac

      curl -L "$BINARY_URL" -o cloudflared
      chmod +x cloudflared

      if [ -w /usr/local/bin ]; then
        mv cloudflared /usr/local/bin/
      else
        sudo mv cloudflared /usr/local/bin/
      fi
      ;;
  esac

  if command -v cloudflared &> /dev/null; then
    print_success "cloudflared installed successfully"
    cloudflared --version | head -1
  else
    print_error "cloudflared installation failed"
    exit 1
  fi
}

# =================================================================
# Configure SSH
# =================================================================

configure_ssh() {
  print_header "Step 2/3: Configure SSH"

  SSH_CONFIG="$HOME/.ssh/config"

  # Create .ssh directory if it doesn't exist
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  # Check if config already exists
  if [ -f "$SSH_CONFIG" ] && grep -q "Host $SSH_ALIAS" "$SSH_CONFIG"; then
    print_warning "SSH config for '$SSH_ALIAS' already exists"

    if ! confirm "Overwrite existing config?" "n"; then
      print_info "Skipping SSH config update"
      return 0
    fi

    # Remove existing config block
    print_step "Removing old config..."
    # This is a simple approach - remove from "Host $SSH_ALIAS" to next "Host " or end of file
    sed -i.bak "/^Host $SSH_ALIAS$/,/^Host /{/^Host $SSH_ALIAS$/d; /^Host /!d;}" "$SSH_CONFIG"
  fi

  print_step "Adding SSH config for $SSH_ALIAS..."

  # Append new config
  cat >> "$SSH_CONFIG" << EOF

# Cloudflare Tunnel SSH - Auto-configured by setup-local-ssh.sh
Host $SSH_ALIAS
  HostName $SSH_HOSTNAME
  User $SSH_USER
  IdentityFile $IDENTITY_FILE
  ProxyCommand cloudflared access ssh --hostname $SSH_HOSTNAME
  ServerAliveInterval 60
  ServerAliveCountMax 3
EOF

  chmod 600 "$SSH_CONFIG"
  print_success "SSH config updated"

  echo ""
  print_info "SSH config added:"
  echo ""
  cat >> /dev/stdout << EOF
  Host $SSH_ALIAS
    HostName $SSH_HOSTNAME
    User $SSH_USER
    IdentityFile $IDENTITY_FILE
    ProxyCommand cloudflared access ssh --hostname $SSH_HOSTNAME
EOF
  echo ""
}

# =================================================================
# Test SSH
# =================================================================

test_ssh() {
  print_header "Step 3/3: Test SSH Connection"

  echo ""
  print_info "Testing connection to $SSH_ALIAS..."
  echo ""

  if confirm "Test SSH connection now?" "y"; then
    print_step "Connecting via: ssh $SSH_ALIAS"
    echo ""

    # Test with simple command
    if ssh -o ConnectTimeout=10 "$SSH_ALIAS" "echo 'SSH via tunnel works!'" 2>&1; then
      echo ""
      print_success "SSH connection successful!"
    else
      echo ""
      print_error "SSH connection failed"
      echo ""
      print_info "Troubleshooting:"
      echo "  1. Check tunnel is running on server: sudo systemctl status cloudflared"
      echo "  2. Verify DNS: nslookup $SSH_HOSTNAME"
      echo "  3. Check firewall allows SSH: ssh -v $SSH_ALIAS"
      echo "  4. View tunnel logs: ssh $SSH_ALIAS 'sudo journalctl -u cloudflared -n 50'"
    fi
  else
    print_info "Skipping connection test"
  fi
}

# =================================================================
# Main
# =================================================================

main() {
  clear
  print_header "Local SSH Setup for Cloudflare Tunnel"

  echo "  SSH Hostname: $SSH_HOSTNAME"
  echo "  SSH User: $SSH_USER"
  echo "  SSH Alias: $SSH_ALIAS"
  echo "  Identity File: $IDENTITY_FILE"
  echo ""

  detect_os
  install_cloudflared
  configure_ssh
  test_ssh

  # =================================================================
  # Next Steps
  # =================================================================
  print_header "Setup Complete!"

  echo -e "${GREEN}✓ Your local machine is configured for tunnel SSH!${NC}"
  echo ""
  echo -e "${CYAN}Usage:${NC}"
  echo "  ssh $SSH_ALIAS"
  echo ""
  echo -e "${CYAN}Other useful commands:${NC}"
  echo "  # Copy files:"
  echo "  scp file.txt $SSH_ALIAS:/tmp/"
  echo ""
  echo "  # Run remote command:"
  echo "  ssh $SSH_ALIAS 'sudo systemctl status cloudflared'"
  echo ""
  echo "  # SSH tunnel (port forwarding):"
  echo "  ssh -L 8080:localhost:80 $SSH_ALIAS"
  echo ""
}

# Run main function
main "$@"
