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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
SECRETS_DIR="${REPO_DIR}/secrets"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
ENCRYPTION_KEY_FILE="${ENCRYPTION_KEY_FILE:-$HOME/.secrets-key}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

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
SECRET_FILE="${SECRETS_DIR}/${ENVIRONMENT}/${SECRET_NAME}.txt"
BACKUP_DIR="${SECRETS_DIR}/${ENVIRONMENT}/.backups"
TIMESTAMP=$(date +%Y%m%d%H%M%S)

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|production)$ ]]; then
  echo -e "${RED}Error: Invalid environment '$ENVIRONMENT'${NC}"
  exit 1
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
mkdir -p "$BACKUP_DIR"

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
  chmod 600 "$BACKUP_FILE"
  echo -e "${GREEN}✓ Encrypted backup created: ${BACKUP_FILE}${NC}"
else
  BACKUP_FILE="${BACKUP_DIR}/${SECRET_NAME}.${TIMESTAMP}.txt"
  cp "$SECRET_FILE" "$BACKUP_FILE"
  chmod 600 "$BACKUP_FILE"
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
echo -n "$NEW_VALUE" > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"

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
echo "     docker compose -f apps/<your-app>/compose.yml up -d"
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
