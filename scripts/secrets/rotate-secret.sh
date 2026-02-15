#!/usr/bin/env bash
# =================================================================
# Rotate Secret File
# =================================================================
# Rotates a secret by backing up the old one and creating a new one.
#
# Usage:
#   ./rotate-secret.sh <environment> <secret_name>
#   ./rotate-secret.sh staging db_password
#   ./rotate-secret.sh staging db_password --encrypt
#
# Options:
#   --encrypt    Encrypt the backup using openssl (recommended for production)
#   --cleanup    Also clean up old backups (older than BACKUP_RETENTION_DAYS)
#
# Environment variables:
#   BACKUP_RETENTION_DAYS  Number of days to keep backups (default: 30)
#   ENCRYPTION_KEY_FILE    Path to encryption key file (default: ~/.secrets-key)
# =================================================================

set -euo pipefail

# Configuration
# Default to system secrets on servers. Override for local/dev with:
#   SECRETS_DIR=./secrets ./scripts/secrets/rotate-secret.sh dev api_key
SECRETS_DIR="${SECRETS_DIR:-/var/secrets}"
SECRETS_GROUP="${SECRETS_GROUP:-hosting-secrets}"
SECRETS_GID="${SECRETS_GID:-1999}"
SYSTEM_SECRETS=false
if [ "$SECRETS_DIR" = "/var/secrets" ]; then
  SYSTEM_SECRETS=true
fi
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
ENCRYPTION_KEY_FILE="${ENCRYPTION_KEY_FILE:-$HOME/.secrets-key}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Re-exec with sudo when rotating system secrets
if [ "$SYSTEM_SECRETS" = true ] && [ "${EUID:-0}" -ne 0 ]; then
  exec sudo SECRETS_DIR="$SECRETS_DIR" SECRETS_GROUP="$SECRETS_GROUP" SECRETS_GID="$SECRETS_GID" BACKUP_RETENTION_DAYS="$BACKUP_RETENTION_DAYS" ENCRYPTION_KEY_FILE="$ENCRYPTION_KEY_FILE" "$0" "$@"
fi

# Parse arguments
ENCRYPT=false
CLEANUP=false
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --encrypt)
      ENCRYPT=true
      shift
      ;;
    --cleanup)
      CLEANUP=true
      shift
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

set -- "${POSITIONAL_ARGS[@]}"

# Validate arguments
if [ $# -lt 2 ]; then
  echo "Usage: $0 <environment> <secret_name> [--encrypt] [--cleanup]"
  echo ""
  echo "Examples:"
  echo "  $0 staging db_password"
  echo "  $0 production api_key --encrypt"
  echo "  $0 staging db_password --encrypt --cleanup"
  echo ""
  echo "Options:"
  echo "  --encrypt    Encrypt backup file (recommended for production)"
  echo "  --cleanup    Remove backups older than $BACKUP_RETENTION_DAYS days"
  exit 1
fi

ENVIRONMENT="$1"
SECRET_NAME="$2"

# Normalize environment aliases
if [ "$ENVIRONMENT" = "prod" ]; then
  ENVIRONMENT="production"
fi

SECRET_FILE="${SECRETS_DIR}/${ENVIRONMENT}/${SECRET_NAME}.txt"
BACKUP_DIR="${SECRETS_DIR}/${ENVIRONMENT}/.backups"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|production)$ ]]; then
  echo -e "${RED}Error: Invalid environment '$ENVIRONMENT'${NC}"
  exit 1
fi

# Validate secret name
if [[ ! "$SECRET_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo -e "${RED}Error: Invalid secret name '$SECRET_NAME'${NC}"
  exit 1
fi

# Ensure system secrets prerequisites
if [ "$SYSTEM_SECRETS" = true ]; then
  if ! getent group "$SECRETS_GROUP" >/dev/null 2>&1; then
    echo -e "${RED}Error: Required group '$SECRETS_GROUP' not found${NC}"
    echo "Run: sudo ./scripts/setup-vm.sh"
    exit 1
  fi
  install -d -m 0750 -o root -g "$SECRETS_GROUP" "$SECRETS_DIR" "${SECRETS_DIR}/${ENVIRONMENT}"
fi

# Check if secret exists
if [ ! -f "$SECRET_FILE" ]; then
  echo -e "${RED}Error: Secret '$SECRET_NAME' does not exist for $ENVIRONMENT${NC}"
  echo "Create it first with: ./create-secret.sh $ENVIRONMENT $SECRET_NAME"
  exit 1
fi

echo ""
echo "Rotating secret: ${ENVIRONMENT}/${SECRET_NAME}"
echo ""

# Create backup directory
if [ "$SYSTEM_SECRETS" = true ]; then
  install -d -m 0750 -o root -g "$SECRETS_GROUP" "$BACKUP_DIR"
else
  mkdir -p "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR" 2>/dev/null || true
fi

# Setup encryption if requested
setup_encryption() {
  if [ ! -f "$ENCRYPTION_KEY_FILE" ]; then
    echo ""
    echo -e "${YELLOW}Encryption key not found at: $ENCRYPTION_KEY_FILE${NC}"
    echo ""
    echo "Options:"
    echo "  1. Generate a new encryption key (will be saved to $ENCRYPTION_KEY_FILE)"
    echo "  2. Cancel and create key manually"
    echo ""
    read -rp "Generate new encryption key? (yes/no): " GENERATE_KEY
    if [ "$GENERATE_KEY" = "yes" ]; then
      openssl rand -base64 32 > "$ENCRYPTION_KEY_FILE"
      chmod 600 "$ENCRYPTION_KEY_FILE"
      echo -e "${GREEN}✓ Encryption key generated at: $ENCRYPTION_KEY_FILE${NC}"
      echo ""
      echo -e "${RED}=====================================================================${NC}"
      echo -e "${RED} CRITICAL: BACK UP THIS KEY IMMEDIATELY!${NC}"
      echo -e "${RED}=====================================================================${NC}"
      echo -e "${YELLOW}Without this key, your encrypted backups CANNOT be decrypted.${NC}"
      echo -e "${YELLOW}Copy the key to a secure location outside this server.${NC}"
      echo ""
      echo "Key location: $ENCRYPTION_KEY_FILE"
      echo ""
    else
      echo "Cancelled. Create key with: openssl rand -base64 32 > $ENCRYPTION_KEY_FILE"
      exit 1
    fi
  fi
}

# Backup current secret
if [ "$ENCRYPT" = true ]; then
  setup_encryption
  BACKUP_FILE="${BACKUP_DIR}/${SECRET_NAME}.${TIMESTAMP}.txt.enc"
  openssl enc -aes-256-cbc -salt -pbkdf2 \
    -in "$SECRET_FILE" \
    -out "$BACKUP_FILE" \
    -pass file:"$ENCRYPTION_KEY_FILE"
  if [ "$SYSTEM_SECRETS" = true ]; then
    chown root:"$SECRETS_GROUP" "$BACKUP_FILE"
    chmod 0640 "$BACKUP_FILE"
  else
    chmod 0600 "$BACKUP_FILE"
  fi
  echo -e "${GREEN}✓ Encrypted backup created: ${BACKUP_FILE}${NC}"
else
  BACKUP_FILE="${BACKUP_DIR}/${SECRET_NAME}.${TIMESTAMP}.txt"
  cp "$SECRET_FILE" "$BACKUP_FILE"
  if [ "$SYSTEM_SECRETS" = true ]; then
    chown root:"$SECRETS_GROUP" "$BACKUP_FILE"
    chmod 0640 "$BACKUP_FILE"
  else
    chmod 0600 "$BACKUP_FILE"
  fi
  echo -e "${GREEN}✓ Backup created: ${BACKUP_FILE}${NC}"

  # Warn about plaintext backup for production
  if [ "$ENVIRONMENT" = "production" ]; then
    echo ""
    echo -e "${YELLOW}⚠️  WARNING: Production backup is stored in plaintext!${NC}"
    echo -e "${YELLOW}   Consider using --encrypt for sensitive production secrets.${NC}"
  fi
fi

# Get new secret value
echo ""
echo "Enter the new secret value:"
read -sp "New value: " NEW_VALUE
echo ""
read -sp "Confirm: " CONFIRM_VALUE
echo ""

if [ "$NEW_VALUE" != "$CONFIRM_VALUE" ]; then
  echo -e "${RED}Error: Values don't match${NC}"
  exit 1
fi

if [ -z "$NEW_VALUE" ]; then
  echo -e "${RED}Error: Secret value cannot be empty${NC}"
  exit 1
fi

# Write new secret
if [ "$SYSTEM_SECRETS" = true ]; then
  install -m 0640 -o root -g "$SECRETS_GROUP" /dev/null "$SECRET_FILE"
  printf "%s" "$NEW_VALUE" > "$SECRET_FILE"
  chown root:"$SECRETS_GROUP" "$SECRET_FILE"
  chmod 0640 "$SECRET_FILE"
else
  printf "%s" "$NEW_VALUE" > "$SECRET_FILE"
  chmod 0600 "$SECRET_FILE"
fi

echo ""
echo -e "${GREEN}✓ Secret rotated successfully${NC}"

# Cleanup old backups if requested
if [ "$CLEANUP" = true ]; then
  echo ""
  echo "Cleaning up backups older than $BACKUP_RETENTION_DAYS days..."
  DELETED_COUNT=0
  while IFS= read -r -d '' file; do
    rm -f "$file"
    ((DELETED_COUNT++))
  done < <(find "$BACKUP_DIR" -name "${SECRET_NAME}.*" -mtime +"$BACKUP_RETENTION_DAYS" -type f -print0 2>/dev/null)
  if [ "$DELETED_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Removed $DELETED_COUNT old backup(s)${NC}"
  else
    echo "No old backups to clean up."
  fi
fi

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Redeploy the application to pick up the new secret:"
echo "     sudo docker compose --compatibility -f apps/<your-app>/compose.yml up -d"
echo ""
echo "  2. Verify the application works with the new secret"
echo ""
if [ "$ENCRYPT" = true ]; then
  echo "  3. To restore from encrypted backup:"
  echo "     openssl enc -aes-256-cbc -d -pbkdf2 -in $BACKUP_FILE -out $SECRET_FILE -pass file:$ENCRYPTION_KEY_FILE"
else
  echo "  3. If something goes wrong, restore from backup:"
  echo "     cp $BACKUP_FILE $SECRET_FILE"
fi
echo ""
