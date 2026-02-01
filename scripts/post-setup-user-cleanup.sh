#!/usr/bin/env bash
# =================================================================
# Post-Setup User Management
# =================================================================
# Manages default cloud provider users after hardening setup
#
# After creating sysadmin and appmgr users, this script helps you
# decide what to do with the original default user (ubuntu, debian,
# admin, etc.)
#
# Options:
#   1. Keep & Lock (recommended) - Keeps user for console access
#   2. Delete - More secure but removes emergency access
#   3. Keep Active - Leave as-is (not recommended)
#
# Usage:
#   sudo ./scripts/post-setup-user-cleanup.sh
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
# Check Prerequisites
# =================================================================

check_root() {
  if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    echo "Run: sudo ./scripts/post-setup-user-cleanup.sh"
    exit 1
  fi
}

# =================================================================
# Detect Default Users
# =================================================================

detect_default_users() {
  # Common default users from cloud providers
  local DEFAULT_USERS=("ubuntu" "debian" "admin" "centos" "ec2-user" "fedora" "root")
  local FOUND_USERS=()

  print_step "Detecting default cloud provider users..."

  for user in "${DEFAULT_USERS[@]}"; do
    if id "$user" &>/dev/null; then
      # Check if this user is not sysadmin or appmgr (our new users)
      if [ "$user" != "sysadmin" ] && [ "$user" != "appmgr" ] && [ "$user" != "root" ]; then
        FOUND_USERS+=("$user")
      fi
    fi
  done

  if [ ${#FOUND_USERS[@]} -eq 0 ]; then
    print_info "No default cloud provider users found (only sysadmin, appmgr, root)"
    exit 0
  fi

  echo ""
  echo -e "${YELLOW}Found default users:${NC}"
  for user in "${FOUND_USERS[@]}"; do
    echo "  - $user"
  done
  echo ""
}

# =================================================================
# User Management Options
# =================================================================

show_options() {
  print_header "User Management Options"

  echo "What would you like to do with default cloud provider users?"
  echo ""
  echo -e "${GREEN}1. Lock User (Recommended)${NC}"
  echo "   - Disables SSH login"
  echo "   - Keeps user for cloud console access (VNC/Serial)"
  echo "   - Most secure while maintaining emergency access"
  echo ""
  echo -e "${YELLOW}2. Delete User${NC}"
  echo "   - Completely removes the user"
  echo "   - More secure but removes console access"
  echo "   - ⚠️  Use only if you're confident in tunnel SSH!"
  echo ""
  echo -e "${CYAN}3. Keep Active${NC}"
  echo "   - Leave user unchanged"
  echo "   - Not recommended for production"
  echo ""
  read -rp "Choose option (1/2/3): " CHOICE

  case $CHOICE in
    1)
      lock_users
      ;;
    2)
      delete_users
      ;;
    3)
      keep_users
      ;;
    *)
      print_error "Invalid choice. Exiting."
      exit 1
      ;;
  esac
}

lock_users() {
  print_header "Locking Default Users"

  for user in "${FOUND_USERS[@]}"; do
    print_step "Locking user: $user"

    # Lock password
    if passwd -l "$user" 2>/dev/null; then
      echo "  ✓ Password locked"
    else
      print_warning "  Failed to lock password (may already be locked)"
    fi

    # Disable SSH (but keep for console)
    if [ -d "/home/$user/.ssh" ]; then
      if [ -f "/home/$user/.ssh/authorized_keys" ]; then
        if mv "/home/$user/.ssh/authorized_keys" "/home/$user/.ssh/authorized_keys.disabled" 2>/dev/null; then
          echo "  ✓ SSH keys disabled"
        else
          print_warning "  Failed to disable SSH keys"
        fi
      else
        echo "  ℹ No SSH keys to disable (may already be disabled)"
      fi
    fi

    # Remove from sudo group if present
    if groups "$user" | grep -q sudo; then
      if deluser "$user" sudo 2>/dev/null; then
        echo "  ✓ Removed from sudo group"
      else
        print_warning "  Failed to remove from sudo group"
      fi
    else
      echo "  ℹ Not in sudo group (already removed)"
    fi

    print_success "User $user locked (console access still works)"
  done

  echo ""
  print_info "Users are locked for SSH but can still access via cloud console"
  print_info "To unlock later: sudo passwd -u <username>"
}

delete_users() {
  print_header "Deleting Default Users"

  print_warning "⚠️  WARNING: Deleting users removes cloud console access!"
  print_warning "⚠️  Ensure SSH via tunnel is working before proceeding!"
  echo ""

  if ! confirm "Are you SURE you want to delete these users?" "n"; then
    print_info "Cancelled. Users not deleted."
    exit 0
  fi

  for user in "${FOUND_USERS[@]}"; do
    print_step "Deleting user: $user"

    # Remove user and home directory
    if userdel -r "$user" 2>/dev/null; then
      print_success "User $user deleted (with home directory)"
    elif userdel "$user" 2>/dev/null; then
      print_success "User $user deleted (home directory kept)"
    else
      print_error "Failed to delete user $user"
    fi
  done

  echo ""
  print_success "Default users deleted successfully"
  print_warning "Cloud console access is no longer available"
}

keep_users() {
  print_header "Keeping Default Users Active"

  print_warning "Default users will remain active and can SSH to this server"
  print_warning "This is NOT recommended for production environments"
  echo ""

  for user in "${FOUND_USERS[@]}"; do
    echo "  - $user (active)"
  done

  echo ""
  print_info "No changes made to default users"
}

# =================================================================
# Main
# =================================================================

main() {
  clear
  print_header "Post-Setup User Management"

  echo "This script helps you manage default cloud provider users"
  echo "after creating your new hardened users (sysadmin, appmgr)."
  echo ""

  check_root
  detect_default_users
  show_options

  echo ""
  print_success "User management complete!"
}

# Run main function
main "$@"
