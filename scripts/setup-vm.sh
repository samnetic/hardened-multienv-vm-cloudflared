#!/usr/bin/env bash
# =================================================================
# Initial VM Setup Script - Production Hardened
# =================================================================
# Sets up Ubuntu VM with comprehensive security hardening:
# - Users with proper permissions
# - SSH hardening with strong ciphers
# - Kernel hardening via sysctl
# - UFW firewall
# - fail2ban intrusion prevention
# - auditd security logging
# - Automatic security updates
# - Docker with security defaults
# - Automated maintenance cron jobs
# - CI/GitOps deploy hardening (appmgr ForceCommand + root-owned deploy tool)
#
# Usage:
#   sudo ./setup-vm.sh              # Normal execution
#   sudo ./setup-vm.sh --dry-run    # Preview changes without executing
#
# Run this script as root on a fresh Ubuntu 22.04/24.04 installation
# =================================================================

set -euo pipefail

# =================================================================
# Parse Arguments
# =================================================================

DRY_RUN=false

for arg in "$@"; do
  case $arg in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--dry-run]"
      echo ""
      echo "Options:"
      echo "  --dry-run    Show what would be done without making changes"
      echo "  --help       Show this help message"
      exit 0
      ;;
  esac
done

# =================================================================
# Configuration
# =================================================================

SYSADMIN_USER="sysadmin"
APPMGR_USER="appmgr"
# Security-first default: require password for sysadmin sudo (SSH stays key-only).
# Override via environment: SYSADMIN_SUDO_MODE=password|nopasswd
SYSADMIN_SUDO_MODE="${SYSADMIN_SUDO_MODE:-password}"
if [ "$SYSADMIN_SUDO_MODE" != "password" ] && [ "$SYSADMIN_SUDO_MODE" != "nopasswd" ]; then
  echo "WARN: Invalid SYSADMIN_SUDO_MODE='$SYSADMIN_SUDO_MODE' (expected: password|nopasswd). Defaulting to 'password'."
  SYSADMIN_SUDO_MODE="password"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="${REPO_DIR}/config"

# Checkpoint system for resumable setup
CHECKPOINT_FILE="/var/run/vm-setup-checkpoints"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# =================================================================
# Dry-Run Support
# =================================================================

# Execute command or print it in dry-run mode
run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}[DRY-RUN] Would execute: $*${NC}"
  else
    "$@"
  fi
}

# Copy file or print what would be copied
copy_file() {
  local src="$1"
  local dst="$2"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}[DRY-RUN] Would copy: $src -> $dst${NC}"
  else
    cp "$src" "$dst"
  fi
}

# Write content or print what would be written
write_file() {
  local dst="$1"
  local content="$2"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${CYAN}[DRY-RUN] Would write to: $dst${NC}"
    echo -e "${CYAN}[DRY-RUN] Content preview (first 5 lines):${NC}"
    echo "$content" | head -5 | sed 's/^/    /'
    echo "    ..."
  else
    echo "$content" > "$dst"
  fi
}

# =================================================================
# Functions
# =================================================================

print_header() {
  echo ""
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BLUE} $1${NC}"
  echo -e "${BLUE}======================================================================${NC}"
  echo ""
}

print_step() {
  echo -e "${CYAN}→ $1${NC}"
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠  $1${NC}"
}

print_info() {
  echo -e "${BLUE}ℹ  $1${NC}"
}

print_error() {
  echo -e "${RED}✗ $1${NC}"
}

# On fresh Ubuntu, apt-daily/apt-daily-upgrade can hold dpkg locks for a few minutes.
# Waiting here prevents a common "Could not get lock ..." first-run failure.
wait_for_apt() {
  local timeout="${APT_LOCK_TIMEOUT:-300}"

  if [ "$DRY_RUN" = true ]; then
    return 0
  fi

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
      # Best-effort fallback if fuser is missing.
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
      print_info "If apt-daily is stuck, try:"
      print_info "  sudo systemctl stop apt-daily.service apt-daily-upgrade.service"
      print_info "  sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer"
      exit 1
    fi

    print_info "Waiting for apt/dpkg locks to be released... (${elapsed}s)"
    sleep 5
  done
}

# =================================================================
# SSH Key Validation
# =================================================================

validate_ssh_key() {
  local key="$1"

  # Remove leading/trailing whitespace
  key=$(echo "$key" | xargs)

  # Check if empty
  if [ -z "$key" ]; then
    return 1
  fi

  # Check if it starts with a valid key type
  if [[ "$key" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]]; then
    return 0
  fi

  return 1
}

add_ssh_key_if_not_exists() {
  local user="$1"
  local key="$2"
  local options="${3:-}"
  local auth_keys_file="/home/$user/.ssh/authorized_keys"

  # Validate key format
  key="$(echo "$key" | xargs)"

  if ! validate_ssh_key "$key"; then
    print_error "Invalid SSH key format for $user"
    return 1
  fi

  local key_type key_b64 key_comment
  key_type="$(echo "$key" | awk '{print $1}')"
  key_b64="$(echo "$key" | awk '{print $2}')"
  key_comment="$(echo "$key" | cut -d' ' -f3-)"

  if [ -z "$key_type" ] || [ -z "$key_b64" ]; then
    print_error "Invalid SSH key format (missing fields) for $user"
    return 1
  fi

  # Create .ssh directory if it doesn't exist
  mkdir -p "/home/$user/.ssh"
  chmod 700 "/home/$user/.ssh"

  # Check if key already exists (match by key material, regardless of options/comment)
  if [ -f "$auth_keys_file" ] && grep -qF "$key_b64" "$auth_keys_file"; then
    print_info "SSH key already exists for $user, skipping duplicate"
    return 0
  fi

  # Add key
  local line="${key_type} ${key_b64}"
  if [ -n "${key_comment:-}" ]; then
    line="${line} ${key_comment}"
  fi
  if [ -n "${options:-}" ]; then
    line="${options} ${line}"
  fi

  echo "$line" >> "$auth_keys_file"
  chmod 600 "$auth_keys_file"
  chown -R "$user:$user" "/home/$user/.ssh"

  return 0
}

# =================================================================
# Checkpoint System (for resumable setup)
# =================================================================

mark_checkpoint() {
  local step="$1"
  if [ "$DRY_RUN" != "true" ]; then
    echo "$step" >> "$CHECKPOINT_FILE"
  fi
}

is_checkpoint_done() {
  local step="$1"
  if [ "$DRY_RUN" = "true" ]; then
    return 1  # In dry-run, never skip
  fi
  if [ -f "$CHECKPOINT_FILE" ] && grep -q "^${step}$" "$CHECKPOINT_FILE"; then
    return 0  # Checkpoint exists, step was completed
  fi
  return 1  # Checkpoint doesn't exist, need to run this step
}

clear_checkpoints() {
  rm -f "$CHECKPOINT_FILE"
}

# =================================================================
# Service Status Helpers (with retry logic)
# =================================================================

wait_for_service() {
  local service="$1"
  local max_attempts="${2:-10}"
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    if systemctl is-active --quiet "$service"; then
      return 0
    fi
    sleep 1
    ((attempt++))
  done
  return 1
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
  fi
}

check_ubuntu() {
  if [ ! -f /etc/os-release ]; then
    print_error "Cannot detect OS. This script requires Ubuntu."
    exit 1
  fi
  source /etc/os-release
  if [ "$ID" != "ubuntu" ]; then
    print_error "This script requires Ubuntu (detected: $ID)"
    exit 1
  fi
  if [ "$VERSION_ID" != "22.04" ] && [ "$VERSION_ID" != "24.04" ]; then
    print_warning "Tested on Ubuntu 22.04 and 24.04. Detected: $VERSION_ID"
  fi
  print_success "Operating System: Ubuntu $VERSION_ID"
}

# =================================================================
# Main Script
# =================================================================

clear
print_header "Production VM Setup - Security Hardened Installation"

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}======================================================================"
  echo -e " DRY-RUN MODE - No changes will be made"
  echo -e "======================================================================${NC}"
  echo ""
  echo "This preview shows what would be configured:"
  echo ""
fi

echo "This script will configure your VM with:"
echo ""
echo "  Security Hardening:"
echo "    • Kernel hardening (sysctl settings)"
echo "    • SSH hardening (key-only, strong ciphers)"
echo "    • fail2ban (brute-force protection)"
echo "    • auditd (security event logging)"
echo "    • UFW firewall"
echo ""
echo "  System Configuration:"
echo "    • Users: sysadmin (sudo), appmgr (CI-only)"
echo "    • Docker with security defaults"
echo "    • Automatic security updates"
echo "    • Automated maintenance cron jobs"
echo ""
echo -e "${YELLOW}⚠  This should be run on a fresh Ubuntu 22.04/24.04 installation${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Skipping confirmation prompt${NC}"
  echo ""
else
	  read -rp "Continue? (yes/no): " CONFIRM

	  if [ "$CONFIRM" != "yes" ]; then
	    echo "Aborted by user."
	    exit 1
	  fi
	fi

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would check: root privileges${NC}"
  echo -e "${CYAN}[DRY-RUN] Would check: Ubuntu version${NC}"
  echo ""
else
  check_root
  check_ubuntu
fi

# =================================================================
# Step 1: System Update & Essential Packages
# =================================================================

if is_checkpoint_done "step1_packages"; then
  print_header "Step 1/10: System Update & Essential Packages (SKIPPED - already done)"
else
	  print_header "Step 1/10: System Update & Essential Packages"

	  print_step "Updating package lists..."
	  wait_for_apt
	  run_cmd env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update

	  print_step "Upgrading system packages..."
	  wait_for_apt
	  run_cmd env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get upgrade -y \
	    -o Dpkg::Options::=--force-confdef \
	    -o Dpkg::Options::=--force-confold

	  print_step "Installing essential packages..."
	  wait_for_apt
		  run_cmd env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
		    -o Dpkg::Options::=--force-confdef \
		    -o Dpkg::Options::=--force-confold \
		    curl \
	    wget \
	    git \
	    sudo \
	    openssh-server \
	    rsync \
	    vim \
	    nano \
	    htop \
    net-tools \
    ufw \
    fail2ban \
    unattended-upgrades \
    apt-listchanges \
	    auditd \
	    audispd-plugins \
	    chrony \
	    apparmor-utils \
	    cron \
	    logrotate \
	    dnsutils \
	    openssl \
	    python3 \
	    python3-yaml \
	    ca-certificates \
	    gnupg \
    lsb-release \
    jq \
    tree

	  print_success "Essential packages installed"

	  # Apply timezone if provided by the top-level setup.sh (optional).
	  if [ -n "${TIMEZONE:-}" ]; then
	    print_step "Configuring timezone (${TIMEZONE})..."
	    if [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
	      if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$TIMEZONE" >/dev/null 2>&1; then
	        print_success "Timezone set to ${TIMEZONE}"
	      else
	        print_warning "Failed to set timezone via timedatectl (continuing)"
	      fi
	    else
	      print_warning "Invalid TIMEZONE '${TIMEZONE}' (file not found under /usr/share/zoneinfo); skipping"
	    fi
	  fi

	  mark_checkpoint "step1_packages"
	fi

# =================================================================
# Step 2: Create Users
# =================================================================

print_header "Step 2/10: Creating Users"

# Create sysadmin user (full sudo access)
if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would create user '$SYSADMIN_USER' with sudo access${NC}"
  echo -e "${CYAN}[DRY-RUN] Would create user '$APPMGR_USER' (CI-only, restricted SSH)${NC}"
else
  sysadmin_created=false
  if id "$SYSADMIN_USER" &>/dev/null; then
    print_warning "User '$SYSADMIN_USER' already exists"
  else
    # Create user with SSH key access (SSH passwords remain disabled by SSH hardening)
    adduser --disabled-password --gecos "System Administrator" "$SYSADMIN_USER"
    sysadmin_created=true
  fi

  # Ensure sysadmin has sudo access (idempotent).
  usermod -aG sudo "$SYSADMIN_USER"

  if [ "$SYSADMIN_SUDO_MODE" = "nopasswd" ]; then
    # Convenience mode: passwordless sudo.
    echo "${SYSADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${SYSADMIN_USER}"
    chmod 440 "/etc/sudoers.d/${SYSADMIN_USER}"
    print_success "sysadmin sudo mode: passwordless (SYSADMIN_SUDO_MODE=nopasswd)"
  else
    # Security-first mode: require a local password for sudo.
    rm -f "/etc/sudoers.d/${SYSADMIN_USER}" 2>/dev/null || true

    # Ensure a local password is set so sudo works. Avoid prompting repeatedly.
    pass_state="$(passwd -S "$SYSADMIN_USER" 2>/dev/null | awk '{print $2}' || echo "")"
    if [ "$pass_state" = "NP" ] || [ "$pass_state" = "L" ] || [ -z "$pass_state" ]; then
      print_step "Setting a sudo password for '$SYSADMIN_USER' (used for sudo/console only; SSH remains key-only)..."
      if [ -t 0 ]; then
        passwd "$SYSADMIN_USER"
        print_success "sysadmin sudo mode: password required"
      else
        if [ "$sysadmin_created" = true ]; then
          print_error "No TTY available to set a sudo password for a newly created sysadmin user."
          print_error "Re-run interactively, or set SYSADMIN_SUDO_MODE=nopasswd for passwordless sudo."
          exit 1
        fi
        print_warning "No TTY available to set sysadmin password; sudo may not work if a password is required."
      fi
    else
      print_success "sysadmin password already set (sudo will prompt)"
    fi
  fi

  # Create appmgr user (CI/CD only; restricted SSH via ForceCommand)
  if id "$APPMGR_USER" &>/dev/null; then
    print_warning "User '$APPMGR_USER' already exists"
  else
    # Create without password (SSH key only)
    adduser --disabled-password --gecos "Application Manager" "$APPMGR_USER"
    print_success "Created user '$APPMGR_USER' (CI/CD user; restricted SSH via ForceCommand)"
  fi

  # Ensure appmgr stays least-privilege even if it existed already.
  passwd -l "$APPMGR_USER" >/dev/null 2>&1 || true
  gpasswd -d "$APPMGR_USER" sudo >/dev/null 2>&1 || true

  # Dedicated host group for secrets. This enables mounting secrets from /var/secrets
  # with strict permissions while still allowing non-root containers to read them via
  # `group_add: ["1999"]` (see app templates/docs).
  SECRETS_GROUP="hosting-secrets"
  SECRETS_GID="1999"
  if ! getent group "$SECRETS_GROUP" >/dev/null 2>&1; then
    if getent group | awk -F: -v gid="$SECRETS_GID" '$3==gid {found=1} END {exit found?0:1}'; then
      existing_group="$(getent group | awk -F: -v gid="$SECRETS_GID" '$3==gid {print $1; exit}')"
      print_error "Cannot create group '$SECRETS_GROUP' with GID $SECRETS_GID (already used by '$existing_group')"
      print_error "Edit SECRETS_GID in scripts/setup-vm.sh and rerun"
      exit 1
    fi
    groupadd --gid "$SECRETS_GID" "$SECRETS_GROUP"
    print_success "Created group '$SECRETS_GROUP' (GID $SECRETS_GID)"
  else
    print_success "Group '$SECRETS_GROUP' already exists"
  fi

  usermod -aG "$SECRETS_GROUP" "$SYSADMIN_USER"
  print_success "Added $SYSADMIN_USER to '$SECRETS_GROUP' group"
  print_info "Note: $APPMGR_USER is intentionally NOT in '$SECRETS_GROUP' (least privilege)."

  # Create system secrets directory (not in git)
  print_step "Creating system secrets directories..."
  SETUP_PROFILE="${SETUP_PROFILE:-full-stack}"
  if [ "$SETUP_PROFILE" = "full-stack" ]; then
    mkdir -p /var/secrets/{dev,staging,production}
  else
    mkdir -p /var/secrets/production
  fi
  chown -R root:"$SECRETS_GROUP" /var/secrets
  chmod 750 /var/secrets
  find /var/secrets -type d -exec chmod 750 {} \;
  find /var/secrets -type f -name '*.txt' -exec chmod 640 {} \; 2>/dev/null || true
  print_success "Secured /var/secrets (root:${SECRETS_GROUP}, 750 dirs, 640 files)"

  # Security: keep the blueprint root-owned.
  # Root will execute these scripts; do not make them writable by non-root.
  # (Admins can still update it using sudo git pull.)
  if [ -d "${REPO_DIR}/.git" ] && [[ "${REPO_DIR}" == "/opt/hosting-blueprint" ]]; then
    print_step "Securing blueprint permissions (root-owned)..."
    chown -R root:root "${REPO_DIR}" 2>/dev/null || true
    chmod -R go-w "${REPO_DIR}" 2>/dev/null || true
    print_success "Blueprint secured at ${REPO_DIR}"
  fi
fi

# =================================================================
# Step 3: SSH Key Setup
# =================================================================

print_header "Step 3/10: SSH Key Setup"

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would prompt for SSH keys for $SYSADMIN_USER and $APPMGR_USER${NC}"
  echo -e "${CYAN}[DRY-RUN] Would create ~/.ssh directories and authorized_keys files${NC}"
else
  # Check if SSH keys are provided via environment variables (from setup.sh)
  if [ -n "${SYSADMIN_SSH_KEY:-}" ]; then
    echo "Using SSH key from environment variable for $SYSADMIN_USER"
    if add_ssh_key_if_not_exists "$SYSADMIN_USER" "$SYSADMIN_SSH_KEY"; then
      print_success "SSH key added for $SYSADMIN_USER (from environment)"
    else
      print_error "Failed to add SSH key for $SYSADMIN_USER"
    fi

    # Setup appmgr with same key or specific key if provided
    if [ -n "${APPMGR_SSH_KEY:-}" ]; then
      # Harden the appmgr key by default: disable pty/forwarding/user-rc/etc.
      if add_ssh_key_if_not_exists "$APPMGR_USER" "$APPMGR_SSH_KEY" "restrict"; then
        print_success "SSH key added for $APPMGR_USER (from environment)"
      fi
    else
      print_warning "No SSH key provided for $APPMGR_USER (skipping)."
      print_info "Add a dedicated deploy key later if you enable GitOps CI/CD."
    fi
  else
    # Interactive mode - prompt for keys
    echo "SSH public keys are required for both users."
    echo "You can add them now or manually later."
    echo ""
    read -rp "Add SSH keys now? (yes/no): " ADD_KEYS

    if [ "$ADD_KEYS" = "yes" ]; then
      # Setup for sysadmin
      echo ""
      echo "Paste the SSH public key for $SYSADMIN_USER:"
      read -r SYSADMIN_KEY_INPUT

      # Validate and add key
      if add_ssh_key_if_not_exists "$SYSADMIN_USER" "$SYSADMIN_KEY_INPUT"; then
        print_success "SSH key added for $SYSADMIN_USER"
      else
        print_error "Invalid SSH key format. Please add manually later."
      fi

      # Setup for appmgr
      echo ""
      echo "Paste the SSH public key for $APPMGR_USER:"
      echo "(Or press Enter to use the same key as $SYSADMIN_USER)"
      read -r APPMGR_KEY_INPUT

      # Use sysadmin key if no input provided
      if [ -z "$APPMGR_KEY_INPUT" ]; then
        if add_ssh_key_if_not_exists "$APPMGR_USER" "$SYSADMIN_KEY_INPUT" "restrict"; then
          print_success "SSH key added for $APPMGR_USER (same as sysadmin)"
        fi
      else
        if add_ssh_key_if_not_exists "$APPMGR_USER" "$APPMGR_KEY_INPUT" "restrict"; then
          print_success "SSH key added for $APPMGR_USER"
        else
          print_error "Invalid SSH key format. Please add manually later."
        fi
      fi
    else
      print_warning "Remember to add SSH keys before disabling password auth!"
    fi
  fi
fi

# =================================================================
# Step 4: Kernel Hardening (sysctl)
# =================================================================

print_header "Step 4/10: Kernel Hardening"

print_step "Applying kernel security parameters..."

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would copy sysctl hardening config to /etc/sysctl.d/99-hardening.conf${NC}"
  echo -e "${CYAN}[DRY-RUN] Would apply sysctl settings with: sysctl --system${NC}"
else
  if [ -f "${CONFIG_DIR}/sysctl.d/99-hardening.conf" ]; then
    cp "${CONFIG_DIR}/sysctl.d/99-hardening.conf" /etc/sysctl.d/99-hardening.conf
    print_success "Copied sysctl hardening config"
  else
    print_warning "sysctl config not found, creating inline..."
    cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# Network Security
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Kernel Hardening
kernel.yama.ptrace_scope = 2
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.sysrq = 0

# Filesystem
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
EOF
  fi

  sysctl --system > /dev/null
  print_success "Kernel hardening applied"

  # Verify key settings
  echo "  Verifying:"
  echo "    ptrace_scope = $(sysctl -n kernel.yama.ptrace_scope)"
  echo "    randomize_va_space = $(sysctl -n kernel.randomize_va_space)"
  echo "    tcp_syncookies = $(sysctl -n net.ipv4.tcp_syncookies)"
fi

# =================================================================
# Step 5: SSH Hardening
# =================================================================

print_header "Step 5/10: SSH Hardening"

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would harden OpenSSH:${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install CI/GitOps wrapper + deploy tool under /usr/local/sbin/${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install sudoers allowlist: /etc/sudoers.d/appmgr-hosting-deploy${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install ssh hardening config: /etc/ssh/sshd_config.d/hardening.conf${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install appmgr ForceCommand Match block: /etc/ssh/sshd_config.d/99-appmgr-ci.conf${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Validate sshd config (sshd -t) and reload sshd${NC}"
	else
	  # Prevent lockout: refuse to harden SSH unless sysadmin has a key installed.
	  SYSADMIN_AUTH_KEYS="/home/${SYSADMIN_USER}/.ssh/authorized_keys"
	  if [ ! -s "$SYSADMIN_AUTH_KEYS" ]; then
	    print_error "No SSH key found for '$SYSADMIN_USER' at: $SYSADMIN_AUTH_KEYS"
	    print_error "Refusing to apply SSH hardening (PasswordAuthentication will be disabled)."
	    print_info "Fix: add your public key to sysadmin, then re-run:"
	    print_info "  sudo mkdir -p /home/${SYSADMIN_USER}/.ssh && sudo chmod 700 /home/${SYSADMIN_USER}/.ssh"
	    print_info "  echo \"ssh-ed25519 AAAA...\" | sudo tee -a \"$SYSADMIN_AUTH_KEYS\" >/dev/null"
	    print_info "  sudo chown -R ${SYSADMIN_USER}:${SYSADMIN_USER} /home/${SYSADMIN_USER}/.ssh && sudo chmod 600 \"$SYSADMIN_AUTH_KEYS\""
	    exit 1
	  fi

	  print_step "Installing CI/GitOps SSH restrictions for '$APPMGR_USER'..."

  install -d -m 0755 /usr/local/sbin
  install -d -m 0755 /etc/hosting-blueprint
  install -d -m 0755 /var/lib/hosting-blueprint
  install -d -m 0755 /var/log/hosting-blueprint

  if [ -f "${CONFIG_DIR}/bin/hosting-ci-ssh" ] && [ -f "${CONFIG_DIR}/bin/hosting-deploy" ]; then
    install -m 0755 "${CONFIG_DIR}/bin/hosting-ci-ssh" /usr/local/sbin/hosting-ci-ssh
    install -m 0750 "${CONFIG_DIR}/bin/hosting-deploy" /usr/local/sbin/hosting-deploy
    print_success "Installed hosting deploy toolchain under /usr/local/sbin/"
  else
    print_error "Missing deploy toolchain templates under ${CONFIG_DIR}/bin/"
    print_error "Expected: ${CONFIG_DIR}/bin/hosting-ci-ssh and ${CONFIG_DIR}/bin/hosting-deploy"
    exit 1
  fi

  if [ -f "${CONFIG_DIR}/sudoers.d/appmgr-hosting-deploy" ]; then
    install -d -m 0755 /etc/sudoers.d
    install -m 0440 "${CONFIG_DIR}/sudoers.d/appmgr-hosting-deploy" /etc/sudoers.d/appmgr-hosting-deploy
    if ! visudo -cf /etc/sudoers.d/appmgr-hosting-deploy >/dev/null 2>&1; then
      print_error "sudoers validation failed for /etc/sudoers.d/appmgr-hosting-deploy"
      exit 1
    fi
    print_success "Installed sudoers allowlist for $APPMGR_USER"
  else
    print_error "Missing sudoers template: ${CONFIG_DIR}/sudoers.d/appmgr-hosting-deploy"
    exit 1
  fi

  print_step "Backing up SSH config..."
  BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.${BACKUP_TIMESTAMP}"

  print_step "Applying SSH hardening..."
  mkdir -p /etc/ssh/sshd_config.d

  if [ -f "${CONFIG_DIR}/ssh/sshd_config.d/hardening.conf" ]; then
    cp "${CONFIG_DIR}/ssh/sshd_config.d/hardening.conf" /etc/ssh/sshd_config.d/hardening.conf
    # Update AllowUsers with actual usernames (handles both commented and uncommented).
    sed -i "s/^#\\?[[:space:]]*AllowUsers.*/AllowUsers $SYSADMIN_USER $APPMGR_USER/" /etc/ssh/sshd_config.d/hardening.conf

    # Verify AllowUsers was set correctly
    if ! grep -q "^AllowUsers $SYSADMIN_USER $APPMGR_USER" /etc/ssh/sshd_config.d/hardening.conf; then
      print_error "Failed to set AllowUsers in SSH config!"
      exit 1
    fi
    print_success "SSH AllowUsers configured for: $SYSADMIN_USER $APPMGR_USER"
  else
    cat > /etc/ssh/sshd_config.d/hardening.conf <<EOF
# SSH Hardening
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowTcpForwarding local
AllowAgentForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 60
AllowUsers $SYSADMIN_USER $APPMGR_USER

# Strong ciphers
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Logging
LogLevel VERBOSE
EOF
  fi

  # Install the Match block that restricts appmgr to the hosting CI wrapper.
  if [ -f "${CONFIG_DIR}/ssh/sshd_config.d/99-appmgr-ci.conf" ]; then
    cp "${CONFIG_DIR}/ssh/sshd_config.d/99-appmgr-ci.conf" /etc/ssh/sshd_config.d/99-appmgr-ci.conf
    chmod 644 /etc/ssh/sshd_config.d/99-appmgr-ci.conf
    print_success "Installed sshd Match block for $APPMGR_USER (ForceCommand)"
  else
    print_error "Missing sshd Match template: ${CONFIG_DIR}/ssh/sshd_config.d/99-appmgr-ci.conf"
    exit 1
  fi

  # Test SSH config before applying
  if sshd -t; then
    print_success "SSH configuration validated"
  else
    print_error "SSH configuration has errors! Restoring backup..."
    cp "/etc/ssh/sshd_config.backup.${BACKUP_TIMESTAMP}" /etc/ssh/sshd_config
    rm -f /etc/ssh/sshd_config.d/hardening.conf
    rm -f /etc/ssh/sshd_config.d/99-appmgr-ci.conf
    exit 1
  fi

  print_step "Reloading SSH service to apply changes..."
  if systemctl reload ssh >/dev/null 2>&1; then
    print_success "SSH service reloaded"
  elif systemctl reload sshd >/dev/null 2>&1; then
    print_success "SSHD service reloaded"
  else
    systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
    print_warning "Could not reload SSH cleanly; attempted restart (verify: sudo sshd -t && systemctl status ssh)"
  fi
fi

# =================================================================
# Step 6: Firewall (UFW)
# =================================================================

print_header "Step 6/10: Firewall Configuration"

TUNNEL_ONLY_MARKER="/etc/hosting-blueprint/tunnel-only.enabled"
TUNNEL_ONLY=false
if [ -f "$TUNNEL_ONLY_MARKER" ]; then
  TUNNEL_ONLY=true
fi

print_step "Configuring UFW..."

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would configure UFW firewall:${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Default deny incoming${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Default allow outgoing${NC}"
  if [ "$TUNNEL_ONLY" = true ]; then
    echo -e "${CYAN}[DRY-RUN]   - Tunnel-only mode detected (${TUNNEL_ONLY_MARKER})${NC}"
    echo -e "${CYAN}[DRY-RUN]   - Ensure SSH/HTTP(S) are denied (22/80/443)${NC}"
  else
    echo -e "${CYAN}[DRY-RUN]   - Allow OpenSSH temporarily${NC}"
    echo -e "${CYAN}[DRY-RUN]   - Rate limit SSH${NC}"
  fi
  echo -e "${CYAN}[DRY-RUN]   - Enable firewall${NC}"
else
  ufw default deny incoming
  ufw default allow outgoing

  if [ "$TUNNEL_ONLY" = true ]; then
    # Tunnel-only: never open inbound SSH/HTTP(S). Enforce explicit denies for clarity.
    print_info "Tunnel-only marker detected: ${TUNNEL_ONLY_MARKER}"

    # Remove any existing allow/limit rules (best-effort).
    printf "y\n" | ufw delete allow OpenSSH >/dev/null 2>&1 || true
    printf "y\n" | ufw delete limit OpenSSH >/dev/null 2>&1 || true
    printf "y\n" | ufw delete allow 22/tcp >/dev/null 2>&1 || true
    printf "y\n" | ufw delete allow 22 >/dev/null 2>&1 || true

    printf "y\n" | ufw delete allow 80/tcp >/dev/null 2>&1 || true
    printf "y\n" | ufw delete allow 80 >/dev/null 2>&1 || true
    printf "y\n" | ufw delete limit 80/tcp >/dev/null 2>&1 || true
    printf "y\n" | ufw delete allow 443/tcp >/dev/null 2>&1 || true
    printf "y\n" | ufw delete allow 443 >/dev/null 2>&1 || true
    printf "y\n" | ufw delete limit 443/tcp >/dev/null 2>&1 || true

    ufw deny 22/tcp comment "SSH blocked - use Cloudflare Tunnel only" 2>/dev/null || true
    ufw deny 80/tcp comment "HTTP blocked - use Cloudflare Tunnel only" 2>/dev/null || true
    ufw deny 443/tcp comment "HTTPS blocked - use Cloudflare Tunnel only" 2>/dev/null || true
  else
    # Allow SSH temporarily (will be removed after Cloudflare Tunnel setup)
    ufw allow OpenSSH comment "SSH - REMOVE AFTER TUNNEL SETUP"

    # Rate limit SSH
    ufw limit OpenSSH comment "SSH rate limiting"
  fi

  # Enable firewall
  echo "y" | ufw enable

  print_success "Firewall enabled"
  if [ "$TUNNEL_ONLY" = true ]; then
    print_success "Tunnel-only mode: inbound SSH/HTTP(S) blocked (22/80/443)"
  else
    print_warning "SSH is allowed temporarily. Remove after Cloudflare Tunnel setup!"
  fi

  ufw status
fi

# =================================================================
# Step 7: fail2ban
# =================================================================

print_header "Step 7/10: fail2ban Configuration"

print_step "Configuring fail2ban..."

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would configure fail2ban:${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install jail config: /etc/fail2ban/jail.local${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Enable + restart service: fail2ban${NC}"
else
  if [ -f "${CONFIG_DIR}/fail2ban/jail.local" ]; then
    cp "${CONFIG_DIR}/fail2ban/jail.local" /etc/fail2ban/jail.local
    print_success "Copied fail2ban config"
  else
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
banaction = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 300
bantime = 86400
EOF
  fi

  systemctl enable fail2ban
  systemctl restart fail2ban

  # Wait for fail2ban to fully start
  if wait_for_service fail2ban; then
    print_success "fail2ban configured and started"
    # Give it one more second for socket to be ready
    sleep 1
    fail2ban-client status 2>/dev/null || print_warning "fail2ban is starting (socket not ready yet, but service is running)"
  else
    print_warning "fail2ban service taking longer to start, but will be ready shortly"
  fi
fi

# =================================================================
# Step 8: auditd
# =================================================================

print_header "Step 8/10: Audit Logging (auditd)"

print_step "Configuring auditd..."

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would configure auditd:${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install audit rules: /etc/audit/rules.d/hardening.rules${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Enable + restart service: auditd${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Load rules: augenrules --load${NC}"
else
  mkdir -p /etc/audit/rules.d

  if [ -f "${CONFIG_DIR}/audit/rules.d/hardening.rules" ]; then
    cp "${CONFIG_DIR}/audit/rules.d/hardening.rules" /etc/audit/rules.d/hardening.rules
    print_success "Copied audit rules"
  else
    cat > /etc/audit/rules.d/hardening.rules <<'EOF'
-D
-b 8192
-f 1
-w /etc/sudoers -p wa -k sudoers_changes
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/passwd -p wa -k passwd_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/docker/daemon.json -p wa -k docker_config
EOF
  fi

  systemctl enable auditd
  systemctl restart auditd
  augenrules --load 2>/dev/null || true

  print_success "auditd configured and started"
fi

# =================================================================
# Step 9: Docker Installation
# =================================================================

print_header "Step 9/10: Docker Installation"

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would install and harden Docker:${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Add Docker apt repo + verify GPG fingerprint${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install packages: docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Remove sysadmin/appmgr from docker group (root-equivalent)${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Write daemon config: /etc/docker/daemon.json${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Enable + restart docker${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Create /srv/apps/{dev,staging,production}${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install optional systemd template: /etc/systemd/system/docker-compose@.service${NC}"
else
  print_step "Removing old Docker versions..."
  env DEBIAN_FRONTEND=noninteractive apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

  print_step "Adding Docker repository..."
  mkdir -p /etc/apt/keyrings
  rm -f /etc/apt/keyrings/docker.gpg
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  # Verify Docker GPG key fingerprint (official: 9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88)
  EXPECTED_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
  DOCKER_GPG_FINGERPRINT="$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.gpg 2>/dev/null | grep '^fpr' | head -1 | cut -d: -f10)"
  if [ "$DOCKER_GPG_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]; then
    print_error "Docker GPG key fingerprint mismatch!"
    print_error "Expected: $EXPECTED_FINGERPRINT"
    print_error "Got: $DOCKER_GPG_FINGERPRINT"
    rm -f /etc/apt/keyrings/docker.gpg
    exit 1
  fi
  print_success "Docker GPG key verified"

  DOCKER_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if [ -z "${DOCKER_CODENAME:-}" ]; then
    DOCKER_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
  fi
  if [ -z "${DOCKER_CODENAME:-}" ]; then
    print_error "Could not detect Ubuntu codename for Docker repository"
    exit 1
  fi

	  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $DOCKER_CODENAME stable" \
	    | tee /etc/apt/sources.list.d/docker.list > /dev/null

	  print_step "Installing Docker..."
	  wait_for_apt
	  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get update
	  wait_for_apt
	  env DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none apt-get install -y \
	    -o Dpkg::Options::=--force-confdef \
	    -o Dpkg::Options::=--force-confold \
	    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  print_info "Security-first: not adding users to the docker group (docker group is root-equivalent)."
  # Ensure neither user can escalate to root via the Docker socket without sudo password.
  gpasswd -d "$SYSADMIN_USER" docker >/dev/null 2>&1 || true
  gpasswd -d "$APPMGR_USER" docker >/dev/null 2>&1 || true

  print_step "Configuring Docker daemon..."
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "20m",
    "max-file": "5"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true,
  "icc": false,
  "ip": "127.0.0.1",
  "metrics-addr": "0.0.0.0:9323",
  "default-address-pools": [
    {
      "base": "10.200.0.0/16",
      "size": 24
    },
    {
      "base": "10.210.0.0/16",
      "size": 24
    }
  ]
}
EOF

	  systemctl daemon-reload
	  systemctl enable docker
	  systemctl restart docker

	  if ! systemctl is-active --quiet docker; then
	    print_error "Docker service failed to start after configuration."
	    print_info "Inspect logs: sudo journalctl -u docker -n 100 --no-pager"
	    journalctl -u docker -n 50 --no-pager 2>/dev/null || true
	    exit 1
	  fi
	  if ! docker info >/dev/null 2>&1; then
	    print_error "Docker daemon is not responding (docker info failed)."
	    print_info "Inspect logs: sudo journalctl -u docker -n 100 --no-pager"
	    exit 1
	  fi

	  print_success "Docker installed and configured"
	  docker --version
	  docker compose version

  # Create deployment directories based on server profile
  SETUP_PROFILE="${SETUP_PROFILE:-full-stack}"
  print_step "Creating deployment directories (profile: ${SETUP_PROFILE})..."

  if [ "$SETUP_PROFILE" = "full-stack" ]; then
    mkdir -p /srv/apps/{dev,staging,production}
    chown -R "$SYSADMIN_USER:$SYSADMIN_USER" /srv/apps
    chmod 755 /srv/apps
    chmod 755 /srv/apps/{dev,staging,production}
    print_success "App directories created at /srv/apps/{dev,staging,production}"
  else
    # For monitoring/minimal profiles, create a services directory
    mkdir -p /srv/services
    chown -R "$SYSADMIN_USER:$SYSADMIN_USER" /srv/services
    chmod 755 /srv/services
    print_success "Services directory created at /srv/services/"
  fi

  # Install systemd service for auto-starting Docker Compose apps
  print_step "Installing Docker Compose auto-start service..."
  if [ -f "${CONFIG_DIR}/systemd/docker-compose@.service" ]; then
    cp "${CONFIG_DIR}/systemd/docker-compose@.service" /etc/systemd/system/
    systemctl daemon-reload
    print_success "Docker Compose auto-start service installed (not enabled by default)"
    print_info "Note: Most apps use 'restart: unless-stopped' so Docker restarts containers after reboot."
    print_info "If you want the systemd fan-out behavior, enable explicitly:"
    print_info "  sudo systemctl enable --now docker-compose@production.service"
  else
    print_warning "docker-compose@.service not found, skipping auto-start setup"
  fi
fi

# =================================================================
# Step 10: Automatic Updates & Maintenance
# =================================================================

print_header "Step 10/10: Automatic Updates & Maintenance"

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would configure system maintenance:${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Enable unattended-upgrades + apt periodic${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Configure journald retention (30 days, 500M)${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install logrotate rules: /etc/logrotate.d/hosting-blueprint${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install cron jobs: /etc/cron.d/vm-maintenance${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Install helper scripts under /opt/scripts (disk usage, docker port exposure, notifier)${NC}"
else
  # Configure unattended-upgrades
  print_step "Configuring automatic security updates..."
  if [ -f "${CONFIG_DIR}/apt/apt.conf.d/50unattended-upgrades" ]; then
    cp "${CONFIG_DIR}/apt/apt.conf.d/50unattended-upgrades" /etc/apt/apt.conf.d/50unattended-upgrades
  fi

  # Enable unattended-upgrades
  echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
  echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades

  systemctl enable unattended-upgrades
  systemctl restart unattended-upgrades

  print_success "Automatic security updates enabled"

  # Configure journald
  print_step "Configuring log retention..."
  mkdir -p /etc/systemd/journald.conf.d
  if [ -f "${CONFIG_DIR}/systemd/journald.conf.d/retention.conf" ]; then
    cp "${CONFIG_DIR}/systemd/journald.conf.d/retention.conf" /etc/systemd/journald.conf.d/retention.conf
  else
    cat > /etc/systemd/journald.conf.d/retention.conf <<'EOF'
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=500M
MaxRetentionSec=30day
EOF
  fi
  systemctl restart systemd-journald

  print_success "Log retention configured"

  # Install logrotate rules for blueprint-generated logs
  print_step "Installing logrotate rules..."
  if [ -f "${CONFIG_DIR}/logrotate.d/hosting-blueprint" ]; then
    cp "${CONFIG_DIR}/logrotate.d/hosting-blueprint" /etc/logrotate.d/hosting-blueprint
    chmod 644 /etc/logrotate.d/hosting-blueprint
    print_success "Logrotate rules installed: /etc/logrotate.d/hosting-blueprint"
  else
    print_warning "Logrotate rules not found (skipping)"
  fi

	  # Install cron jobs
	  print_step "Installing maintenance cron jobs..."
	  mkdir -p /opt/scripts
	  if [ -f "${CONFIG_DIR}/cron.d/vm-maintenance" ]; then
	    cp "${CONFIG_DIR}/cron.d/vm-maintenance" /etc/cron.d/vm-maintenance
	    chmod 644 /etc/cron.d/vm-maintenance
	    print_success "Maintenance cron jobs installed"
	  fi

	  # Ensure cron is enabled/running (some minimal images may not have it started).
	  if command -v systemctl >/dev/null 2>&1; then
	    systemctl enable --now cron >/dev/null 2>&1 || \
	      systemctl enable --now cron.service >/dev/null 2>&1 || true
	  fi

	  # Install notifier helper (safe default: logs locally; optional webhook/email via /etc/hosting-blueprint/alerting.env)
	  if [ -f "${REPO_DIR}/scripts/security/notify.sh" ]; then
	    cp "${REPO_DIR}/scripts/security/notify.sh" /opt/scripts/hosting-notify.sh
	    chmod +x /opt/scripts/hosting-notify.sh
    print_success "Installed notifier helper: /opt/scripts/hosting-notify.sh"
  else
    print_warning "Notifier helper not found (skipping)"
  fi

  # Copy disk check script from repo or create basic version
  if [ -f "${REPO_DIR}/scripts/maintenance/check-disk-usage.sh" ]; then
    cp "${REPO_DIR}/scripts/maintenance/check-disk-usage.sh" /opt/scripts/check-disk-usage.sh
    print_success "Copied disk check script from repo"
  else
    # Create basic version as fallback
    cat > /opt/scripts/check-disk-usage.sh <<'EOF'
#!/bin/bash
THRESHOLD=85
USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [ "$USAGE" -gt "$THRESHOLD" ]; then
  echo "WARNING: Disk usage at ${USAGE}%" | logger -t disk-check
fi
EOF
  fi
  chmod +x /opt/scripts/check-disk-usage.sh

  # Copy Docker port exposure check script (defense against accidental public ports)
  if [ -f "${REPO_DIR}/scripts/security/check-docker-exposed-ports.sh" ]; then
    cp "${REPO_DIR}/scripts/security/check-docker-exposed-ports.sh" /opt/scripts/check-docker-exposed-ports.sh
    chmod +x /opt/scripts/check-docker-exposed-ports.sh
    print_success "Copied Docker port exposure check script to /opt/scripts/check-docker-exposed-ports.sh"
  else
    print_warning "Docker port exposure check script not found (skipping)"
  fi
fi

# =================================================================
# Step 11: Verify SSH Access & Manage Original User
# =================================================================

if [ "$DRY_RUN" != "true" ]; then
  print_header "Step 11/11: Verify SSH Access (CRITICAL!)"

  # Detect original invoking user (default cloud user) for cleanup/locking.
  # Prefer SUDO_USER, fall back to the login user, then UID 1000 if present.
  ORIGINAL_INVOKING_USER="${SUDO_USER:-}"
  if [ -z "${ORIGINAL_INVOKING_USER:-}" ]; then
    ORIGINAL_INVOKING_USER="$(logname 2>/dev/null || true)"
  fi
  if [ -z "${ORIGINAL_INVOKING_USER:-}" ] || [ "$ORIGINAL_INVOKING_USER" = "root" ]; then
    ORIGINAL_INVOKING_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)"
  fi
  ORIGINAL_INVOKING_USER="${ORIGINAL_INVOKING_USER:-root}"

  echo -e "${YELLOW}⚠️  CRITICAL: You MUST verify SSH access before continuing!${NC}"
  echo ""
  TUNNEL_ONLY_MARKER="/etc/hosting-blueprint/tunnel-only.enabled"
  SSH_TEST_CMD=""
  if [ -f "$TUNNEL_ONLY_MARKER" ]; then
    tunnel_domain="$(grep -E '^domain=' "$TUNNEL_ONLY_MARKER" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    if [ -z "${tunnel_domain:-}" ] && [ -f /opt/vm-config/setup.conf ]; then
      tunnel_domain="$(grep -E '^DOMAIN=' /opt/vm-config/setup.conf 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\"' || true)"
    fi
    base_alias="${tunnel_domain%%.*}"
    echo "Tunnel-only mode detected (direct SSH may be blocked)."
    echo "From your LOCAL machine, open a NEW terminal and test SSH via tunnel:"
    echo ""
    if [ -n "${tunnel_domain:-}" ]; then
      SSH_TEST_CMD="ssh ${base_alias}"
      echo -e "${CYAN}  ${SSH_TEST_CMD}${NC}"
      echo -e "${CYAN}  # (connects to ssh.${tunnel_domain} as ${SYSADMIN_USER})${NC}"
    else
      SSH_TEST_CMD="ssh <your-ssh-alias>"
      echo -e "${CYAN}  ${SSH_TEST_CMD}${NC}"
    fi
  else
    echo "From your LOCAL machine, open a NEW terminal and test:"
    echo ""
    SSH_TEST_CMD="ssh ${SYSADMIN_USER}@YOUR_SERVER_IP"
    echo -e "${CYAN}  ${SSH_TEST_CMD}${NC}"
  fi
  echo ""
  echo -e "${RED}⚠️  DO NOT close this session until SSH works!${NC}"
  echo ""

  if [ "${SKIP_SSH_VERIFY:-0}" = "1" ] || [ "${SKIP_SSH_VERIFY:-0}" = "true" ]; then
    print_warning "SKIP_SSH_VERIFY is set; skipping SSH verification + original user management."
    print_info "Run later: ./scripts/verify-setup.sh"
    SSH_CONFIRMED="yes"
  else
    if [ ! -t 0 ]; then
      print_error "No interactive TTY available to confirm SSH."
      print_error "Re-run interactively, or set SKIP_SSH_VERIFY=1 to skip (not recommended)."
      exit 1
    fi
    read -rp "Have you successfully logged in as ${SYSADMIN_USER}? (yes/no): " SSH_CONFIRMED
  fi

  if [ "$SSH_CONFIRMED" != "yes" ]; then
    print_error "SSH not confirmed. Please test SSH before proceeding!"
    echo ""
    echo "Troubleshooting:"
    echo "1. Check authorized_keys: cat /home/${SYSADMIN_USER}/.ssh/authorized_keys"
    echo "2. Check SSH logs: sudo tail -f /var/log/auth.log"
    echo "3. Verify firewall: sudo ufw status"
    exit 1
  fi

  print_success "SSH access verified!"

  # Handle original user
  if [ "${SKIP_SSH_VERIFY:-0}" = "1" ] || [ "${SKIP_SSH_VERIFY:-0}" = "true" ]; then
    print_info "Original user management skipped (SKIP_SSH_VERIFY=1). Run: ./scripts/post-setup-user-cleanup.sh"
  elif [ "$ORIGINAL_INVOKING_USER" != "root" ] && [ "$ORIGINAL_INVOKING_USER" != "$SYSADMIN_USER" ] && id "$ORIGINAL_INVOKING_USER" >/dev/null 2>&1; then
    echo ""
    print_step "Managing original user: $ORIGINAL_INVOKING_USER"
    echo ""
    echo "What should we do with the default user '$ORIGINAL_INVOKING_USER'?"
    echo ""
    echo "1) Lock (Recommended) - Disable SSH, keep for console access"
    echo "2) Keep Active - Leave unchanged"
    echo "3) Skip - Decide later"
    echo ""
    read -rp "Choice (1/2/3): " USER_CHOICE

    case $USER_CHOICE in
      1)
        # Lock the user
        passwd -l "$ORIGINAL_INVOKING_USER" 2>/dev/null || true

        # Disable SSH keys
        if [ -d "/home/$ORIGINAL_INVOKING_USER/.ssh" ]; then
          if [ -f "/home/$ORIGINAL_INVOKING_USER/.ssh/authorized_keys" ]; then
            mv "/home/$ORIGINAL_INVOKING_USER/.ssh/authorized_keys" \
               "/home/$ORIGINAL_INVOKING_USER/.ssh/authorized_keys.disabled" 2>/dev/null || true
          fi
        fi

        # Remove from sudo group
        if groups "$ORIGINAL_INVOKING_USER" | grep -q sudo; then
          deluser "$ORIGINAL_INVOKING_USER" sudo 2>/dev/null || true
        fi

        print_success "User '$ORIGINAL_INVOKING_USER' locked (console access still works)"
        ;;
      2)
        print_info "User '$ORIGINAL_INVOKING_USER' remains active"
        ;;
      3)
        print_info "Skipped. Run './scripts/post-setup-user-cleanup.sh' later"
        ;;
      *)
        print_warning "Invalid choice. Skipping."
        ;;
    esac
  elif [ "$ORIGINAL_INVOKING_USER" != "root" ] && [ "$ORIGINAL_INVOKING_USER" != "$SYSADMIN_USER" ]; then
    print_info "Skipping original user management (user not found): $ORIGINAL_INVOKING_USER"
  fi
fi

# =================================================================
# Setup Complete
# =================================================================

print_header "Setup Complete!"

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}======================================================================"
  echo -e " DRY-RUN COMPLETE - No changes were made"
  echo -e "======================================================================${NC}"
  echo ""
  echo "This was a dry-run preview. To execute the setup, run:"
  echo "  sudo $0"
  echo ""
  echo "What would be configured:"
  echo "  • Users: $SYSADMIN_USER (sudo), $APPMGR_USER (CI-only)"
  echo "  • Kernel hardening (sysctl settings)"
  echo "  • SSH hardening (key-only, strong ciphers)"
  echo "  • fail2ban (SSH brute-force protection)"
  echo "  • auditd (security event logging)"
  echo "  • UFW firewall (deny incoming by default)"
  echo "  • Docker with security defaults"
  echo "  • Automatic security updates"
  echo "  • Deployment directories at /srv/apps/"
  echo "  • Optional Docker Compose auto-start service"
  echo ""
  exit 0
fi

echo -e "${GREEN}✓ VM setup finished successfully!${NC}"
echo ""
echo "Security Summary:"
echo "  ✓ Kernel hardening (sysctl) applied"
echo "  ✓ SSH hardened (key-only, strong ciphers)"
echo "  ✓ fail2ban configured (SSH protection)"
echo "  ✓ auditd enabled (security logging)"
echo "  ✓ UFW firewall enabled"
echo "  ✓ Automatic security updates enabled"
echo ""
echo "System Summary:"
echo "  ✓ Users: $SYSADMIN_USER (sudo), $APPMGR_USER (CI-only via SSH ForceCommand)"
echo "  ✓ Docker installed with security defaults"
echo "  ✓ Log rotation configured"
echo "  ✓ Maintenance cron jobs installed"
if [ "$SYSADMIN_SUDO_MODE" = "nopasswd" ]; then
  echo "  ✓ ${SYSADMIN_USER} configured with passwordless sudo (SYSADMIN_SUDO_MODE=nopasswd)"
else
  echo "  ✓ ${SYSADMIN_USER} configured with sudo (password required)"
fi
if [ -n "${ORIGINAL_INVOKING_USER:-}" ] && [ "$ORIGINAL_INVOKING_USER" != "root" ]; then
  echo "  ✓ Original user (${ORIGINAL_INVOKING_USER}) handled"
fi
echo ""
echo -e "${CYAN}Your hardened VPS is ready!${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. Set up Cloudflare Tunnel: sudo ./scripts/install-cloudflared.sh"
echo "  2. Deploy your first app:"
echo "     sudo mkdir -p /srv/apps/staging"
echo "     sudo cp -r /opt/hosting-blueprint/apps/_template /srv/apps/staging/myapp"
echo "     cd /srv/apps/staging/myapp && sudo docker compose --compatibility up -d"
echo "  3. Set up GitOps CI/CD: See .github/workflows/deploy.yml"
echo "  4. Review docs/ for detailed guides"
echo ""
echo -e "${CYAN}Quick verification:${NC}"
echo "  sysctl kernel.yama.ptrace_scope  # Should be 2"
echo "  fail2ban-client status sshd      # Check fail2ban"
echo "  systemctl status auditd          # Check auditd"
echo "  ufw status                       # Check firewall"
echo "  docker --version                 # Verify Docker"
echo ""
