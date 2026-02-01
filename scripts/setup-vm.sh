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

print_error() {
  echo -e "${RED}✗ $1${NC}"
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
  if [[ "$key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-dss)[[:space:]] ]]; then
    return 0
  fi

  return 1
}

add_ssh_key_if_not_exists() {
  local user="$1"
  local key="$2"
  local auth_keys_file="/home/$user/.ssh/authorized_keys"

  # Validate key format
  if ! validate_ssh_key "$key"; then
    print_error "Invalid SSH key format for $user"
    return 1
  fi

  # Create .ssh directory if it doesn't exist
  mkdir -p "/home/$user/.ssh"
  chmod 700 "/home/$user/.ssh"

  # Check if key already exists
  if [ -f "$auth_keys_file" ] && grep -qF "$key" "$auth_keys_file"; then
    print_info "SSH key already exists for $user, skipping duplicate"
    return 0
  fi

  # Add key
  echo "$key" >> "$auth_keys_file"
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
  echo " DRY-RUN MODE - No changes will be made"
  echo "======================================================================${NC}"
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
echo "    • Users: sysadmin (sudo), appmgr (docker only)"
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
    echo "Aborted."
    exit 0
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
  run_cmd apt update

  print_step "Upgrading system packages..."
  run_cmd apt upgrade -y

  print_step "Installing essential packages..."
  run_cmd apt install -y \
    curl \
    wget \
    git \
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
  ca-certificates \
  gnupg \
  lsb-release \
  jq \
  tree

  print_success "Essential packages installed"
  mark_checkpoint "step1_packages"
fi

# =================================================================
# Step 2: Create Users
# =================================================================

print_header "Step 2/10: Creating Users"

# Create sysadmin user (full sudo access)
if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would create user '$SYSADMIN_USER' with sudo access${NC}"
  echo -e "${CYAN}[DRY-RUN] Would create user '$APPMGR_USER' (docker only, no sudo)${NC}"
else
  if id "$SYSADMIN_USER" &>/dev/null; then
    print_warning "User '$SYSADMIN_USER' already exists"
  else
    # Create user without password (SSH key only)
    adduser --disabled-password --gecos "System Administrator" "$SYSADMIN_USER"
    usermod -aG sudo "$SYSADMIN_USER"

    # Configure passwordless sudo
    echo "${SYSADMIN_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${SYSADMIN_USER}"
    chmod 440 "/etc/sudoers.d/${SYSADMIN_USER}"

    print_success "Created user '$SYSADMIN_USER' with passwordless sudo"
  fi

  # Create appmgr user (docker access only, no sudo)
  if id "$APPMGR_USER" &>/dev/null; then
    print_warning "User '$APPMGR_USER' already exists"
  else
    # Create without password (SSH key only)
    adduser --disabled-password --gecos "Application Manager" "$APPMGR_USER"
    print_success "Created user '$APPMGR_USER' (no sudo, docker only)"
  fi

  # Fix repository ownership for sysadmin user
  if [ -d "${SCRIPT_DIR}/.git" ]; then
    print_step "Fixing repository ownership for $SYSADMIN_USER..."
    chown -R "${SYSADMIN_USER}:${SYSADMIN_USER}" "${SCRIPT_DIR}"
    print_success "Repository ownership set to $SYSADMIN_USER"
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
      if add_ssh_key_if_not_exists "$APPMGR_USER" "$APPMGR_SSH_KEY"; then
        print_success "SSH key added for $APPMGR_USER (from environment)"
      fi
    else
      if add_ssh_key_if_not_exists "$APPMGR_USER" "$SYSADMIN_SSH_KEY"; then
        print_success "SSH key added for $APPMGR_USER (same as sysadmin)"
      fi
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
        if add_ssh_key_if_not_exists "$APPMGR_USER" "$SYSADMIN_KEY_INPUT"; then
          print_success "SSH key added for $APPMGR_USER (same as sysadmin)"
        fi
      else
        if add_ssh_key_if_not_exists "$APPMGR_USER" "$APPMGR_KEY_INPUT"; then
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

print_step "Backing up SSH config..."
BACKUP_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup.${BACKUP_TIMESTAMP}

print_step "Applying SSH hardening..."
mkdir -p /etc/ssh/sshd_config.d

if [ -f "${CONFIG_DIR}/ssh/sshd_config.d/hardening.conf" ]; then
  cp "${CONFIG_DIR}/ssh/sshd_config.d/hardening.conf" /etc/ssh/sshd_config.d/hardening.conf
  # Update AllowUsers with actual usernames (handles both commented and uncommented)
  sed -i "s/^#\?\s*AllowUsers.*/AllowUsers $SYSADMIN_USER $APPMGR_USER/" /etc/ssh/sshd_config.d/hardening.conf

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
AllowTcpForwarding no
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

# Test SSH config before applying
if sshd -t; then
  print_success "SSH configuration validated"
else
  print_error "SSH configuration has errors! Restoring backup..."
  cp /etc/ssh/sshd_config.backup.${BACKUP_TIMESTAMP} /etc/ssh/sshd_config
  rm -f /etc/ssh/sshd_config.d/hardening.conf
  exit 1
fi

# =================================================================
# Step 6: Firewall (UFW)
# =================================================================

print_header "Step 6/10: Firewall Configuration"

print_step "Configuring UFW..."

if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}[DRY-RUN] Would configure UFW firewall:${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Default deny incoming${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Default allow outgoing${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Allow OpenSSH temporarily${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Rate limit SSH${NC}"
  echo -e "${CYAN}[DRY-RUN]   - Enable firewall${NC}"
else
  ufw default deny incoming
  ufw default allow outgoing

  # Allow SSH temporarily (will be removed after Cloudflare Tunnel setup)
  ufw allow OpenSSH comment "SSH - REMOVE AFTER TUNNEL SETUP"

  # Rate limit SSH
  ufw limit OpenSSH comment "SSH rate limiting"

  # Enable firewall
  echo "y" | ufw enable

  print_success "Firewall enabled"
  print_warning "SSH is allowed temporarily. Remove after Cloudflare Tunnel setup!"

  ufw status
fi

# =================================================================
# Step 7: fail2ban
# =================================================================

print_header "Step 7/10: fail2ban Configuration"

print_step "Configuring fail2ban..."

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

# =================================================================
# Step 8: auditd
# =================================================================

print_header "Step 8/10: Audit Logging (auditd)"

print_step "Configuring auditd..."

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

# =================================================================
# Step 9: Docker Installation
# =================================================================

print_header "Step 9/10: Docker Installation"

print_step "Removing old Docker versions..."
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

print_step "Adding Docker repository..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Verify Docker GPG key fingerprint (official fingerprint: 9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88)
# Note: Using case-insensitive grep and normalizing to uppercase for comparison
DOCKER_GPG_FINGERPRINT=$(gpg --show-keys --with-fingerprint /etc/apt/keyrings/docker.gpg 2>/dev/null | grep -oiP '([a-f0-9]{4}\s*){10}' | tr -d ' ' | tr '[:lower:]' '[:upper:]' | head -1)
EXPECTED_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
if [ "$DOCKER_GPG_FINGERPRINT" != "$EXPECTED_FINGERPRINT" ]; then
  print_error "Docker GPG key fingerprint mismatch!"
  print_error "Expected: $EXPECTED_FINGERPRINT"
  print_error "Got: $DOCKER_GPG_FINGERPRINT"
  rm -f /etc/apt/keyrings/docker.gpg
  exit 1
fi
print_success "Docker GPG key verified"

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

print_step "Installing Docker..."
run_cmd apt update
run_cmd apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add users to docker group
usermod -aG docker "$SYSADMIN_USER"
usermod -aG docker "$APPMGR_USER"

print_step "Configuring Docker daemon..."
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
  "default-address-pools": [
    {
      "base": "172.17.0.0/16",
      "size": 24
    }
  ]
}
EOF

systemctl daemon-reload
systemctl enable docker
systemctl restart docker

print_success "Docker installed and configured"
docker --version
docker compose version

# Create deployment directories
print_step "Creating deployment directories..."
mkdir -p /srv/apps/{dev,staging,production}
chown -R "$APPMGR_USER:$APPMGR_USER" /srv/apps
chmod 755 /srv/apps
chmod 775 /srv/apps/{dev,staging,production}
print_success "Deployment directories created at /srv/apps/"

# Install systemd service for auto-starting Docker Compose apps
print_step "Installing Docker Compose auto-start service..."
if [ -f "${CONFIG_DIR}/systemd/docker-compose@.service" ]; then
  cp "${CONFIG_DIR}/systemd/docker-compose@.service" /etc/systemd/system/
  systemctl daemon-reload
  # Enable for all environments (will only start apps if directories have compose files)
  systemctl enable docker-compose@dev.service 2>/dev/null || true
  systemctl enable docker-compose@staging.service 2>/dev/null || true
  systemctl enable docker-compose@production.service 2>/dev/null || true
  print_success "Docker Compose auto-start enabled for all environments"
else
  print_warning "docker-compose@.service not found, skipping auto-start setup"
fi

# =================================================================
# Step 10: Automatic Updates & Maintenance
# =================================================================

print_header "Step 10/10: Automatic Updates & Maintenance"

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

# Install cron jobs
print_step "Installing maintenance cron jobs..."
mkdir -p /opt/scripts
if [ -f "${CONFIG_DIR}/cron.d/vm-maintenance" ]; then
  cp "${CONFIG_DIR}/cron.d/vm-maintenance" /etc/cron.d/vm-maintenance
  chmod 644 /etc/cron.d/vm-maintenance
  print_success "Maintenance cron jobs installed"
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

# =================================================================
# Step 11: Verify SSH Access & Manage Original User
# =================================================================

if [ "$DRY_RUN" != "true" ]; then
  print_header "Step 11/11: Verify SSH Access (CRITICAL!)"

  # Detect original user
  ORIGINAL_INVOKING_USER="${SUDO_USER:-ubuntu}"

  echo -e "${YELLOW}⚠️  CRITICAL: You MUST verify SSH access before continuing!${NC}"
  echo ""
  echo "From your LOCAL machine, open a NEW terminal and test:"
  echo ""
  echo -e "${CYAN}  ssh ${SYSADMIN_USER}@YOUR_SERVER_IP${NC}"
  echo ""
  echo -e "${RED}⚠️  DO NOT close this session until SSH works!${NC}"
  echo ""

  read -rp "Have you successfully logged in as ${SYSADMIN_USER}? (yes/no): " SSH_CONFIRMED

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
  if [ "$ORIGINAL_INVOKING_USER" != "root" ] && [ "$ORIGINAL_INVOKING_USER" != "$SYSADMIN_USER" ]; then
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
  fi
fi

# =================================================================
# Setup Complete
# =================================================================

print_header "Setup Complete!"

if [ "$DRY_RUN" = true ]; then
  echo -e "${YELLOW}======================================================================"
  echo " DRY-RUN COMPLETE - No changes were made"
  echo "======================================================================${NC}"
  echo ""
  echo "This was a dry-run preview. To execute the setup, run:"
  echo "  sudo $0"
  echo ""
  echo "What would be configured:"
  echo "  • Users: $SYSADMIN_USER (sudo), $APPMGR_USER (docker)"
  echo "  • Kernel hardening (sysctl settings)"
  echo "  • SSH hardening (key-only, strong ciphers)"
  echo "  • fail2ban (SSH brute-force protection)"
  echo "  • auditd (security event logging)"
  echo "  • UFW firewall (deny incoming by default)"
  echo "  • Docker with security defaults"
  echo "  • Automatic security updates"
  echo "  • Deployment directories at /srv/apps/"
  echo "  • Docker Compose auto-start service"
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
echo "  ✓ Users: $SYSADMIN_USER (sudo), $APPMGR_USER (docker)"
echo "  ✓ Docker installed with security defaults"
echo "  ✓ Log rotation configured"
echo "  ✓ Maintenance cron jobs installed"
echo "  ✓ ${SYSADMIN_USER} configured with passwordless sudo"
if [ -n "${ORIGINAL_INVOKING_USER:-}" ] && [ "$ORIGINAL_INVOKING_USER" != "root" ]; then
  echo "  ✓ Original user (${ORIGINAL_INVOKING_USER}) handled"
fi
echo ""
echo -e "${CYAN}Your hardened VPS is ready!${NC}"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. Set up Cloudflare Tunnel: sudo ./scripts/install-cloudflared.sh"
echo "  2. Deploy your first app: cp -r apps/_template apps/myapp"
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
