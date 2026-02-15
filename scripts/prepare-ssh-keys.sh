#!/usr/bin/env bash
#
# SSH Key Preparation Helper
# Generates SSH keys for sysadmin and appmgr users
#
# Usage: ./scripts/prepare-ssh-keys.sh
#
# This script runs on your LOCAL machine (not the server)
# It will create SSH keys and show you the public keys to use during setup

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Check if running on server
check_not_server() {
  if [ -f "/opt/vm-config/setup.complete" ] || [ -f "/opt/hosting-blueprint/.vm-setup-complete" ]; then
    print_error "This script should run on your LOCAL machine, not the server!"
    print_info "You've already set up this server. If you need to add new keys, use:"
    print_info "  sudo adduser newuser"
    print_info "  sudo usermod -aG sudo newuser   # if they need admin access"
    print_info "  # Avoid adding users to the docker group (docker group is root-equivalent)."
    exit 1
  fi
}

# Check if ssh-keygen is available
check_ssh_keygen() {
  if ! command -v ssh-keygen &> /dev/null; then
    print_error "ssh-keygen not found!"
    print_info "Please install OpenSSH client:"
    print_info "  macOS: Already installed"
    print_info "  Linux: sudo apt install openssh-client"
    print_info "  Windows: Install Git Bash or WSL"
    exit 1
  fi
}

# Get or create SSH directory
setup_ssh_dir() {
  local ssh_dir="$HOME/.ssh"

  if [ ! -d "$ssh_dir" ]; then
    print_step "Creating SSH directory..."
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
  fi

  echo "$ssh_dir"
}

# Generate SSH key
generate_key() {
  local key_name=$1
  local key_comment=$2
  local key_type=$3
  local ssh_dir=$4
  local key_path="$ssh_dir/$key_name"

  # Check if key already exists
  if [ -f "$key_path" ]; then
    print_warning "Key $key_name already exists"
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      print_info "Skipping $key_name generation"
      return 0
    fi
  fi

  print_step "Generating $key_name..."

  if [ "$key_type" = "ed25519" ]; then
    ssh-keygen -t ed25519 -C "$key_comment" -f "$key_path" -N ""
  else
    ssh-keygen -t rsa -b 4096 -C "$key_comment" -f "$key_path" -N ""
  fi

  # Set proper permissions
  chmod 600 "$key_path"
  chmod 644 "$key_path.pub"

  print_success "Generated $key_path"
}

# Display public key
show_public_key() {
  local key_path=$1
  local user_label=$2

  if [ -f "$key_path" ]; then
    echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  $user_label Public Key${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat "$key_path"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
  fi
}

# Create SSH config helper
create_ssh_config_helper() {
  local domain=$1
  local ssh_dir=$2
  local sysadmin_key="$ssh_dir/vm-sysadmin"
  local appmgr_key="$ssh_dir/vm-appmgr"

  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  SSH Config Example${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo
  echo "Add this to your ~/.ssh/config:"
  echo
  echo "# VM Sysadmin (via Cloudflare Tunnel)"
  echo "Host vm-sysadmin"
  echo "  HostName ssh.$domain"
  echo "  User sysadmin"
  echo "  IdentityFile $sysadmin_key"
  echo "  IdentitiesOnly yes"
  echo
  echo "# VM App Manager (via Cloudflare Tunnel)"
  echo "Host vm-appmgr"
  echo "  HostName ssh.$domain"
  echo "  User appmgr"
  echo "  IdentityFile $appmgr_key"
  echo "  IdentitiesOnly yes"
  echo
  echo "Then connect with:"
  echo "  ssh vm-sysadmin"
  echo "  ssh vm-appmgr"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# Main execution
main() {
  clear

  print_header "SSH Key Preparation for Hardened VM"
  echo
  print_info "This will generate SSH keys for:"
  print_info "  • sysadmin (administrative access)"
  print_info "  • appmgr (application deployment)"
  echo

  # Checks
  check_not_server
  check_ssh_keygen

  # Get SSH directory
  ssh_dir=$(setup_ssh_dir)
  print_success "SSH directory: $ssh_dir"
  echo

  # Ask for key type preference
  print_step "Choose key type:"
  echo "  1. Ed25519 (recommended - modern, secure, fast)"
  echo "  2. RSA 4096 (compatible with older systems)"
  read -p "Enter choice (1/2) [1]: " key_choice
  key_choice=${key_choice:-1}

  if [ "$key_choice" = "1" ]; then
    key_type="ed25519"
    print_success "Using Ed25519 (excellent choice!)"
  else
    key_type="rsa"
    print_success "Using RSA 4096"
  fi
  echo

  # Ask for domain (optional, for SSH config helper)
  read -p "Enter your domain (optional, for SSH config example): " domain
  echo

  # Generate keys
  print_header "Generating SSH Keys"
  echo

  generate_key "vm-sysadmin" "sysadmin@vm" "$key_type" "$ssh_dir"
  generate_key "vm-appmgr" "appmgr@vm" "$key_type" "$ssh_dir"

  echo
  print_header "Setup Complete!"
  echo
  print_success "SSH keys generated successfully!"
  echo
  print_info "Keys created at:"
  print_info "  Sysadmin: $ssh_dir/vm-sysadmin"
  print_info "  Appmgr:   $ssh_dir/vm-appmgr"
  echo

  # Show public keys
  print_header "Public Keys (Copy These During Setup)"

  show_public_key "$ssh_dir/vm-sysadmin.pub" "SYSADMIN"
  show_public_key "$ssh_dir/vm-appmgr.pub" "APPMGR"

  print_warning "IMPORTANT: Keep these public keys handy!"
  print_info "You'll need to paste them when running the VM setup script"
  echo

  # Show SSH config helper if domain provided
  if [ -n "$domain" ]; then
    create_ssh_config_helper "$domain" "$ssh_dir"
  else
    print_info "Run this script again with your domain to get SSH config examples"
  fi

  print_header "Next Steps"
  echo
  print_step "1. SSH to your VM (using root or default user):"
  print_info "   ssh root@your-vm-ip"
  echo
  print_step "2. Run the one-liner setup:"
  print_info "   curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/main/bootstrap.sh | sudo bash"
  echo
  print_step "3. When prompted, paste the public keys shown above"
  echo
  print_step "4. After setup completes, configure your local SSH (see above)"
  echo
  print_success "Happy hardening! 🔒"
  echo
}

# Run main
main "$@"
