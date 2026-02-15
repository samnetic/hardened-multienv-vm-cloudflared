#!/usr/bin/env bash
# =================================================================
# Create Secret File
# =================================================================
# Creates a secret file with proper permissions for Docker Compose
# file-based secrets pattern.
#
# Usage:
#   ./create-secret.sh <environment> <secret_name>
#   ./create-secret.sh dev db_password
#   ./create-secret.sh staging api_key
#   echo "myvalue" | ./create-secret.sh production jwt_secret
# =================================================================

set -euo pipefail

# Configuration
# Default to system secrets on servers. Override for local/dev with:
#   SECRETS_DIR=./secrets ./scripts/secrets/create-secret.sh dev api_key
SECRETS_DIR="${SECRETS_DIR:-/var/secrets}"
SECRETS_GROUP="${SECRETS_GROUP:-hosting-secrets}"
SECRETS_GID="${SECRETS_GID:-1999}"
SYSTEM_SECRETS=false
if [ "$SECRETS_DIR" = "/var/secrets" ]; then
  SYSTEM_SECRETS=true
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Re-exec with sudo when managing system secrets (recommended)
if [ "$SYSTEM_SECRETS" = true ] && [ "${EUID:-0}" -ne 0 ]; then
  exec sudo SECRETS_DIR="$SECRETS_DIR" SECRETS_GROUP="$SECRETS_GROUP" SECRETS_GID="$SECRETS_GID" "$0" "$@"
fi

# Validate arguments
if [ $# -lt 2 ]; then
  echo "Usage: $0 <environment> <secret_name>"
  echo ""
  echo "Environments: dev, staging, production (alias: prod)"
  echo ""
  echo "Examples:"
  echo "  $0 dev db_password           # Interactive prompt"
  echo "  $0 staging api_key           # Interactive prompt"
  echo "  echo 'myvalue' | $0 production jwt_secret  # Pipe value"
  echo "  $0 production jwt_secret --generate 32     # Generate random 32 bytes"
  exit 1
fi

ENVIRONMENT="$1"
SECRET_NAME="$2"
GENERATE_LENGTH="32"

# Normalize environment aliases
if [ "$ENVIRONMENT" = "prod" ]; then
  ENVIRONMENT="production"
fi

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|production)$ ]]; then
  echo -e "${RED}Error: Invalid environment '$ENVIRONMENT'${NC}"
  echo "Valid environments: dev, staging, production (alias: prod)"
  exit 1
fi

# Validate secret name (avoid path traversal and weird characters)
if [[ ! "$SECRET_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo -e "${RED}Error: Invalid secret name '$SECRET_NAME'${NC}"
  echo "Use only letters, numbers, dot (.), underscore (_), and dash (-)."
  exit 1
fi

SECRET_FILE="${SECRETS_DIR}/${ENVIRONMENT}/${SECRET_NAME}.txt"

# Ensure system secrets prerequisites
if [ "$SYSTEM_SECRETS" = true ]; then
  if ! getent group "$SECRETS_GROUP" >/dev/null 2>&1; then
    echo -e "${RED}Error: Required group '$SECRETS_GROUP' not found${NC}"
    echo "Run: sudo ./scripts/setup-vm.sh"
    echo "Or create it: sudo groupadd --gid $SECRETS_GID $SECRETS_GROUP"
    exit 1
  fi

  # Create secrets directory structure with secure permissions
  install -d -m 0750 -o root -g "$SECRETS_GROUP" "$SECRETS_DIR" "${SECRETS_DIR}/${ENVIRONMENT}"
fi

# Check if secret already exists
if [ -f "$SECRET_FILE" ]; then
  echo -e "${YELLOW}Warning: Secret '$SECRET_NAME' already exists for $ENVIRONMENT${NC}"
  read -p "Overwrite? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi

  # Backup existing secret (keep backups out of the main directory listing)
  if [ "$SYSTEM_SECRETS" = true ]; then
    BACKUP_DIR="${SECRETS_DIR}/${ENVIRONMENT}/.backups"
    install -d -m 0750 -o root -g "$SECRETS_GROUP" "$BACKUP_DIR"
    BACKUP_FILE="${BACKUP_DIR}/${SECRET_NAME}.$(date +%Y%m%d%H%M%S).txt"
    cp "$SECRET_FILE" "$BACKUP_FILE"
    chown root:"$SECRETS_GROUP" "$BACKUP_FILE"
    chmod 0640 "$BACKUP_FILE"
  else
    BACKUP_FILE="${SECRET_FILE}.backup.$(date +%Y%m%d%H%M%S)"
    cp "$SECRET_FILE" "$BACKUP_FILE"
    chmod 0600 "$BACKUP_FILE"
  fi
  echo "  Backed up existing secret: $BACKUP_FILE"
fi

# Get secret value
if [ "${3:-}" = "--generate" ]; then
  if [ -n "${4:-}" ]; then
    GENERATE_LENGTH="$4"
  fi
  if [[ ! "$GENERATE_LENGTH" =~ ^[0-9]+$ ]] || [ "$GENERATE_LENGTH" -lt 16 ]; then
    echo -e "${RED}Error: --generate length must be a number >= 16${NC}"
    exit 1
  fi
  # Generate random secret
  SECRET_VALUE="$(openssl rand -base64 "$GENERATE_LENGTH" | tr -d '\r\n')"
  echo "Generated random secret (${GENERATE_LENGTH} bytes, base64-encoded)"
elif [ -t 0 ]; then
  # Interactive - prompt for value
  echo ""
  read -sp "Enter secret value for ${ENVIRONMENT}/${SECRET_NAME}: " SECRET_VALUE
  echo ""
  read -sp "Confirm secret value: " SECRET_CONFIRM
  echo ""

  if [ "$SECRET_VALUE" != "$SECRET_CONFIRM" ]; then
    echo -e "${RED}Error: Values don't match${NC}"
    exit 1
  fi
else
  # Piped input
  SECRET_VALUE="$(cat | tr -d '\r\n')"
fi

# Validate secret is not empty
if [ -z "$SECRET_VALUE" ]; then
  echo -e "${RED}Error: Secret value cannot be empty${NC}"
  exit 1
fi

# Write secret to file with secure permissions
if [ "$SYSTEM_SECRETS" = true ]; then
  # Create file with correct owner/mode first, then overwrite contents (preserves mode/owner)
  install -m 0640 -o root -g "$SECRETS_GROUP" /dev/null "$SECRET_FILE"
  printf "%s" "$SECRET_VALUE" > "$SECRET_FILE"
  chown root:"$SECRETS_GROUP" "$SECRET_FILE"
  chmod 0640 "$SECRET_FILE"
else
  install -d -m 0700 "${SECRETS_DIR}/${ENVIRONMENT}"
  printf "%s" "$SECRET_VALUE" > "$SECRET_FILE"
  chmod 0600 "$SECRET_FILE"
fi

echo ""
echo -e "${GREEN}✓ Secret created: ${ENVIRONMENT}/${SECRET_NAME}${NC}"
echo "  File: $SECRET_FILE"
if [ "$SYSTEM_SECRETS" = true ]; then
  echo "  Permissions: 640 (root:${SECRETS_GROUP}, group-readable for containers)"
  echo "  Compose tip: add group_add: [\"${SECRETS_GID}\"] if your container runs non-root"
else
  echo "  Permissions: 600 (owner read/write only)"
fi
echo ""
echo "Usage in compose.yml:"
echo "  volumes:"
if [ "$SYSTEM_SECRETS" = true ]; then
  echo "    - /var/secrets/${ENVIRONMENT}/${SECRET_NAME}.txt:/run/secrets/${SECRET_NAME}:ro"
else
  echo "    - ./secrets/${ENVIRONMENT}/${SECRET_NAME}.txt:/run/secrets/${SECRET_NAME}:ro"
fi
echo "  environment:"
echo "    - ${SECRET_NAME^^}_FILE=/run/secrets/${SECRET_NAME}"
echo ""
