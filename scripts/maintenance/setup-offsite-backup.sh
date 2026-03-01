#!/usr/bin/env bash
# =================================================================
# Off-Site Backup Setup (hosting-blueprint)
# =================================================================
# Interactive setup for restic off-site backups. Supports:
#   - SFTP (Hetzner Storage Box, any SSH target)
#   - S3 (AWS, MinIO, Backblaze B2, Wasabi)
#   - Local (additional disk/mount)
#
# What this does:
#   1. Installs restic
#   2. Initializes the backup repository
#   3. Stores the restic password securely (SOPS or file)
#   4. Installs the backup script and cron schedule
#
# Usage:
#   sudo ./scripts/maintenance/setup-offsite-backup.sh
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

if [ "${EUID:-0}" -ne 0 ]; then
  print_error "This script must be run as root (use sudo)"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

print_header "Off-Site Backup Setup"

echo "This will configure restic for off-site backups of:"
echo "  - Database dumps (/srv/backups/)"
echo "  - Docker volumes (configurable)"
echo "  - Any additional paths you specify"
echo ""

if ! confirm "Continue?" "y"; then
  echo "Cancelled."
  exit 0
fi

# =================================================================
# Step 1: Install restic
# =================================================================
print_header "Step 1/4: Install restic"

if command -v restic >/dev/null 2>&1; then
  print_success "restic is already installed ($(restic version 2>/dev/null | head -1 || echo 'unknown'))"
else
  print_step "Installing restic..."
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y restic >/dev/null 2>&1
  if command -v restic >/dev/null 2>&1; then
    print_success "restic installed"
  else
    print_error "restic installation failed"
    exit 1
  fi
fi

# =================================================================
# Step 2: Configure Backend
# =================================================================
print_header "Step 2/4: Configure Backup Backend"

echo "Select backup backend:"
echo "  1) SFTP (Hetzner Storage Box, any SSH host)"
echo "  2) S3 (AWS, MinIO, Backblaze B2, Wasabi)"
echo "  3) Local path (additional disk/mount)"
echo ""
read -rp "Choice [1]: " BACKEND_CHOICE
BACKEND_CHOICE="${BACKEND_CHOICE:-1}"

case "$BACKEND_CHOICE" in
  1)
    BACKEND_TYPE="sftp"
    read -rp "SSH host (e.g., u123456.your-storagebox.de): " SFTP_HOST
    read -rp "SSH port [23]: " SFTP_PORT
    SFTP_PORT="${SFTP_PORT:-23}"
    read -rp "SSH user [u123456]: " SFTP_USER
    read -rp "Remote path [backups]: " SFTP_PATH
    SFTP_PATH="${SFTP_PATH:-backups}"
    RESTIC_REPO="sftp:${SFTP_USER}@${SFTP_HOST}:${SFTP_PATH}"

    echo ""
    print_info "SSH key setup:"
    echo "  Ensure you have an SSH key configured for ${SFTP_USER}@${SFTP_HOST}:${SFTP_PORT}"
    echo "  For Hetzner Storage Box: ssh-copy-id -p ${SFTP_PORT} ${SFTP_USER}@${SFTP_HOST}"
    echo ""

    # Create SSH config entry if not exists
    SSH_CONFIG="/root/.ssh/config"
    mkdir -p /root/.ssh
    if ! grep -q "$SFTP_HOST" "$SSH_CONFIG" 2>/dev/null; then
      cat >> "$SSH_CONFIG" <<EOF

Host storagebox
  HostName ${SFTP_HOST}
  User ${SFTP_USER}
  Port ${SFTP_PORT}
  IdentityFile ~/.ssh/id_ed25519_storagebox
EOF
      chmod 600 "$SSH_CONFIG"
      print_success "Added SSH config entry for storagebox"
    fi
    ;;
  2)
    BACKEND_TYPE="s3"
    read -rp "S3 endpoint (e.g., s3.amazonaws.com): " S3_ENDPOINT
    read -rp "Bucket name: " S3_BUCKET
    read -rp "AWS_ACCESS_KEY_ID: " AWS_KEY
    read -rsp "AWS_SECRET_ACCESS_KEY: " AWS_SECRET
    echo ""
    RESTIC_REPO="s3:https://${S3_ENDPOINT}/${S3_BUCKET}"
    export AWS_ACCESS_KEY_ID="$AWS_KEY"
    export AWS_SECRET_ACCESS_KEY="$AWS_SECRET"
    ;;
  3)
    BACKEND_TYPE="local"
    read -rp "Local backup path (e.g., /mnt/backup): " LOCAL_PATH
    RESTIC_REPO="$LOCAL_PATH"
    mkdir -p "$LOCAL_PATH"
    ;;
  *)
    print_error "Invalid choice"
    exit 1
    ;;
esac

# =================================================================
# Step 3: Initialize Repository & Store Password
# =================================================================
print_header "Step 3/4: Initialize Restic Repository"

# Generate or accept password
echo "Restic encrypts all backups with a password."
echo ""
read -rsp "Enter restic password (or press Enter to auto-generate): " RESTIC_PASSWORD
echo ""
if [ -z "$RESTIC_PASSWORD" ]; then
  RESTIC_PASSWORD="$(openssl rand -base64 32)"
  echo ""
  print_warning "Auto-generated password. SAVE THIS IN YOUR PASSWORD MANAGER:"
  echo ""
  echo "  $RESTIC_PASSWORD"
  echo ""
  print_warning "Without this password, your backups are UNRECOVERABLE."
  echo ""
  confirm "I have saved the password" "n" || { print_error "Aborting."; exit 1; }
fi

# Store password
RESTIC_ENV_DIR="/etc/hosting-blueprint"
mkdir -p "$RESTIC_ENV_DIR"

cat > "${RESTIC_ENV_DIR}/restic.env" <<EOF
RESTIC_REPOSITORY=${RESTIC_REPO}
RESTIC_PASSWORD=${RESTIC_PASSWORD}
EOF

if [ "$BACKEND_TYPE" = "s3" ]; then
  echo "AWS_ACCESS_KEY_ID=${AWS_KEY}" >> "${RESTIC_ENV_DIR}/restic.env"
  echo "AWS_SECRET_ACCESS_KEY=${AWS_SECRET}" >> "${RESTIC_ENV_DIR}/restic.env"
fi

chmod 600 "${RESTIC_ENV_DIR}/restic.env"
print_success "Restic credentials stored at ${RESTIC_ENV_DIR}/restic.env"

# Encrypt with SOPS if available
if command -v sops >/dev/null 2>&1 && [ -f /etc/sops/age/keys.txt ]; then
  print_step "Encrypting credentials with SOPS..."
  PUBKEY="$(age-keygen -y /etc/sops/age/keys.txt 2>/dev/null || true)"
  if [ -n "$PUBKEY" ]; then
    sops --encrypt --age "$PUBKEY" \
      --input-type dotenv --output-type dotenv \
      "${RESTIC_ENV_DIR}/restic.env" > "${RESTIC_ENV_DIR}/restic.env.enc"
    print_success "Encrypted copy: ${RESTIC_ENV_DIR}/restic.env.enc"
    print_info "Commit the .enc file; the .env file is gitignored"
  fi
fi

# Initialize restic repo
export RESTIC_REPOSITORY="$RESTIC_REPO"
export RESTIC_PASSWORD

print_step "Initializing restic repository at ${RESTIC_REPO}..."
if restic snapshots >/dev/null 2>&1; then
  print_success "Repository already initialized"
else
  restic init
  print_success "Repository initialized"
fi

# =================================================================
# Step 4: Install Backup Script & Cron
# =================================================================
print_header "Step 4/4: Install Backup Script & Schedule"

install -d -m 0755 /opt/scripts
install -m 0755 "${REPO_DIR}/scripts/maintenance/backup-offsite.sh" /opt/scripts/hosting-backup-offsite.sh
print_success "Installed /opt/scripts/hosting-backup-offsite.sh"

# Add cron entry
CRON_FILE="/etc/cron.d/vm-maintenance"
CRON_LINE="45 2 * * * root test -x /opt/scripts/hosting-backup-offsite.sh && /opt/scripts/hosting-backup-offsite.sh >/dev/null 2>&1"
if ! grep -q "backup-offsite" "$CRON_FILE" 2>/dev/null; then
  echo "" >> "$CRON_FILE"
  echo "# Off-site backup via restic (daily 02:45 AM)" >> "$CRON_FILE"
  echo "$CRON_LINE" >> "$CRON_FILE"
  print_success "Added off-site backup cron entry (02:45 UTC daily)"
fi

# =================================================================
# Summary
# =================================================================
print_header "Off-Site Backup Setup Complete"

echo -e "${GREEN}Restic off-site backups are configured.${NC}"
echo ""
echo "Backend: ${BACKEND_TYPE} (${RESTIC_REPO})"
echo "Schedule: Daily at 02:45 UTC"
echo "Credentials: ${RESTIC_ENV_DIR}/restic.env"
echo ""
echo "Manual commands:"
echo "  source ${RESTIC_ENV_DIR}/restic.env"
echo "  restic snapshots               # List backups"
echo "  restic backup /srv/backups     # Run backup now"
echo "  restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune"
echo ""
