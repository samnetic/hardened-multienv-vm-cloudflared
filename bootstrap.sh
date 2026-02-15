#!/usr/bin/env bash
# =================================================================
# Bootstrap Script for Hardened VM Setup
# =================================================================
# One-liner installation script for fresh Ubuntu VMs
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/HEAD/bootstrap.sh | sudo bash
#
# What this does:
#   1. Checks prerequisites (OS, root, resources, network)
#   2. Installs git if missing
#   3. Clones repository to /opt/hosting-blueprint
#   4. Sets permissions correctly
#   5. Launches setup.sh
#
# Requirements:
#   - Ubuntu 22.04 or 24.04 LTS
#   - Root access
#   - 2GB+ RAM (4GB+ recommended)
#   - 20GB+ disk (40GB+ recommended)
#   - Internet connectivity
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

# Repository configuration
REPO_URL="https://github.com/samnetic/hardened-multienv-vm-cloudflared.git"
REPO_DIR="/opt/hosting-blueprint"

# For interactive prompts when the script is run via a pipe (curl | sudo bash),
# stdin is the script body. Read prompts from /dev/tty instead.
TTY_FD=""
if [ -r /dev/tty ]; then
  exec 3</dev/tty
  TTY_FD="3"
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

show_progress() {
  local message="$1"
  echo -ne "${CYAN}${message}...${NC}"
}

hide_progress() {
  echo -e "\r\033[K"
}

read_prompt() {
  local __var="$1"
  local __prompt="$2"
  local __default="${3:-}"
  local __value=""

  if [ -n "${TTY_FD:-}" ]; then
    printf "%s" "$__prompt" > /dev/tty
    IFS= read -r -u "$TTY_FD" __value || true
  else
    # Best-effort fallback (non-interactive installs should avoid prompts).
    IFS= read -r -p "$__prompt" __value || true
  fi

  if [ -z "$__value" ] && [ -n "$__default" ]; then
    __value="$__default"
  fi

  printf -v "$__var" "%s" "$__value"
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local suffix="[y/N]"
  local response=""

  if [ "$default" = "y" ]; then
    suffix="[Y/n]"
  fi

  read_prompt response "${prompt} ${suffix}: " ""
  response="${response:-$default}"

  [[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
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
      print_info "Try: sudo systemctl stop apt-daily.service apt-daily-upgrade.service"
      exit 1
    fi

    print_info "Waiting for apt/dpkg locks... (${elapsed}s)"
    sleep 5
  done
}

# =================================================================
# Prerequisite Checks
# =================================================================

check_root() {
  if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    echo ""
    echo "Please run:"
    echo "  curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/HEAD/bootstrap.sh | sudo bash"
    echo ""
    exit 1
  fi
  print_success "Running as root"
}

check_os() {
  print_step "Checking operating system..."

  if [ ! -f /etc/os-release ]; then
    print_error "Cannot detect OS (missing /etc/os-release)"
    exit 1
  fi

  . /etc/os-release

  if [ "$ID" != "ubuntu" ]; then
    print_error "This script only supports Ubuntu (detected: $ID)"
    echo ""
    echo "Supported OS:"
    echo "  - Ubuntu 22.04 LTS (Jammy)"
    echo "  - Ubuntu 24.04 LTS (Noble)"
    echo ""
    exit 1
  fi

  # Check version
  local version_ok=false
  if [ "$VERSION_ID" = "22.04" ] || [ "$VERSION_ID" = "24.04" ]; then
    version_ok=true
  fi

  if [ "$version_ok" = false ]; then
    print_error "Ubuntu $VERSION_ID is not supported"
    echo ""
    echo "Supported versions:"
    echo "  - Ubuntu 22.04 LTS (Jammy)"
    echo "  - Ubuntu 24.04 LTS (Noble)"
    echo ""
    echo "Your version: Ubuntu $VERSION_ID ($VERSION_CODENAME)"
    exit 1
  fi

  print_success "Ubuntu $VERSION_ID LTS detected"
}

check_resources() {
  print_step "Checking system resources..."

  # RAM check
  local ram_mb=$(free -m | awk '/^Mem:/{print $2}')
  local ram_gb=$((ram_mb / 1024))

  if [ "$ram_mb" -lt 2048 ]; then
    print_warning "Only ${ram_gb}GB RAM available (2GB minimum)"
    echo ""
    if ! confirm "Continue anyway?" "n"; then
      echo "Exiting."
      exit 1
    fi
  elif [ "$ram_mb" -lt 4096 ]; then
    print_warning "${ram_gb}GB RAM (4GB+ recommended for AI agents)"
  else
    print_success "${ram_gb}GB RAM available"
  fi

  # Disk check
  local disk_gb=$(df -BG /opt 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')

  if [ -z "$disk_gb" ]; then
    # Fallback to root partition if /opt doesn't exist
    disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
  fi

  if [ "$disk_gb" -lt 20 ]; then
    print_warning "Only ${disk_gb}GB disk space available (20GB minimum)"
    echo ""
    if ! confirm "Continue anyway?" "n"; then
      echo "Exiting."
      exit 1
    fi
  elif [ "$disk_gb" -lt 40 ]; then
    print_warning "${disk_gb}GB disk space (40GB+ recommended)"
  else
    print_success "${disk_gb}GB disk space available"
  fi
}

check_network() {
  print_step "Checking internet connectivity..."

  local TEST_URLS=("https://1.1.1.1" "https://www.cloudflare.com" "https://github.com")
  local connected=false

  for url in "${TEST_URLS[@]}"; do
    if curl -fsS --connect-timeout 5 --max-time 10 "$url" >/dev/null 2>&1; then
      connected=true
      break
    fi
  done

  if [ "$connected" != "true" ]; then
    print_error "No internet connectivity (tried: ${TEST_URLS[*]})"
    echo ""
    echo "This script requires internet access to:"
    echo "  - Download the repository"
    echo "  - Install packages"
    echo "  - Configure Cloudflare Tunnel"
    echo ""
    exit 1
  fi

  print_success "Internet connectivity verified"
}

# =================================================================
# Installation
# =================================================================

install_git() {
  if command -v git &> /dev/null; then
    print_success "git is already installed ($(git --version | head -1))"
    return 0
  fi

  print_step "Installing git..."

  show_progress "Updating package list"
  wait_for_apt
  apt-get update -qq > /dev/null 2>&1
  hide_progress

  show_progress "Installing git"
  wait_for_apt
  apt-get install -y git -qq > /dev/null 2>&1
  hide_progress

  if command -v git &> /dev/null; then
    print_success "git installed successfully"
  else
    print_error "git installation failed"
    exit 1
  fi
}

clone_repository() {
  print_header "Repository Setup"

  # Check if repository already exists
  if [ -d "$REPO_DIR" ]; then
    # Ensure root owns it before any git operations to avoid "dubious ownership".
    chown -R root:root "$REPO_DIR" 2>/dev/null || true
    chmod -R go-w "$REPO_DIR" 2>/dev/null || true

    print_warning "Repository already exists at $REPO_DIR"
    echo ""
    echo "Options:"
    echo "  1) Update existing repository (git pull)"
    echo "  2) Remove and re-clone"
    echo "  3) Skip and use existing"
    echo "  4) Exit"
    echo ""
    read_prompt repo_choice "Choice (1-4) [1]: " "1"

    case $repo_choice in
      1)
        print_step "Updating repository..."
        cd "$REPO_DIR"
        if [ ! -d "$REPO_DIR/.git" ]; then
          print_error "Directory exists but is not a git repository: $REPO_DIR"
          print_info "Choose option 2 to remove + re-clone."
          exit 1
        fi
        git pull
        print_success "Repository updated"
        ;;
      2)
        print_step "Removing existing repository..."
        rm -rf "$REPO_DIR"
        print_step "Cloning fresh copy..."
        git clone "$REPO_URL" "$REPO_DIR"
        print_success "Repository cloned"
        ;;
      3)
        print_info "Using existing repository"
        ;;
      4)
        echo "Exiting."
        exit 0
        ;;
      *)
        print_error "Invalid choice"
        exit 1
        ;;
    esac
  else
    print_step "Cloning repository to $REPO_DIR..."
    git clone "$REPO_URL" "$REPO_DIR"
    print_success "Repository cloned"
  fi

  cd "$REPO_DIR"
}

set_permissions() {
  print_step "Setting permissions..."

  # Make scripts executable
  chmod +x "$REPO_DIR/setup.sh" 2>/dev/null || true
  find "$REPO_DIR/scripts" -type f -name '*.sh' -exec chmod +x {} \; 2>/dev/null || true

  # Security: keep the blueprint root-owned.
  # Root will execute these scripts; do not make them writable by non-root.
  print_step "Ensuring repository is root-owned (security)..."
  chown -R root:root "$REPO_DIR" 2>/dev/null || true
  chmod -R go-w "$REPO_DIR" 2>/dev/null || true

  print_success "Permissions configured"
}

# =================================================================
# Main
# =================================================================

main() {
  if [ -t 1 ]; then clear; fi
  print_header "Hardened VM Setup - Bootstrap"

  echo "This script will:"
  echo "  • Check prerequisites (OS, resources, network)"
  echo "  • Install git (if needed)"
  echo "  • Clone setup repository to $REPO_DIR"
  echo "  • Launch interactive setup"
  echo ""
  echo "Requirements:"
  echo "  • Ubuntu 22.04 or 24.04 LTS"
  echo "  • 2GB+ RAM (4GB+ recommended)"
  echo "  • 20GB+ disk (40GB+ recommended)"
  echo "  • Internet connectivity"
  echo ""

  if ! confirm "Continue?" "n"; then
    echo "Exiting."
    exit 0
  fi

  # Pre-flight checks
  print_header "Pre-Flight Checks"
  check_root
  check_os
  check_resources
  check_network

  echo ""
  print_success "All prerequisite checks passed!"

  # Install git
  echo ""
  install_git

  # Clone repository
  echo ""
  clone_repository

  # Set permissions
  echo ""
  set_permissions

  # Launch setup
  print_header "Launching Setup"

  echo ""
  print_info "Repository is ready at: $REPO_DIR"
  echo ""
  print_step "Starting interactive setup..."
  echo ""

  sleep 2

  # Launch setup.sh
  cd "$REPO_DIR"
  if [ -r /dev/tty ]; then
    exec </dev/tty ./setup.sh
  else
    exec ./setup.sh
  fi
}

# Run main function
main "$@"
