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
#   echo "myvalue" | ./create-secret.sh prod jwt_secret
# =================================================================

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
SECRETS_DIR="${REPO_DIR}/secrets"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Validate arguments
if [ $# -lt 2 ]; then
  echo "Usage: $0 <environment> <secret_name>"
  echo ""
  echo "Environments: dev, staging, production"
  echo ""
  echo "Examples:"
  echo "  $0 dev db_password           # Interactive prompt"
  echo "  $0 staging api_key           # Interactive prompt"
  echo "  echo 'myvalue' | $0 prod jwt # Pipe value"
  echo "  $0 prod jwt --generate 32    # Generate random 32 bytes"
  exit 1
fi

ENVIRONMENT="$1"
SECRET_NAME="$2"
GENERATE_LENGTH="${4:-32}"  # Default to 32 bytes if --generate is used without length

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|production)$ ]]; then
  echo -e "${RED}Error: Invalid environment '$ENVIRONMENT'${NC}"
  echo "Valid environments: dev, staging, production"
  exit 1
fi

# Create secrets directory if it doesn't exist
mkdir -p "${SECRETS_DIR}/${ENVIRONMENT}"

SECRET_FILE="${SECRETS_DIR}/${ENVIRONMENT}/${SECRET_NAME}.txt"

# Check if secret already exists
if [ -f "$SECRET_FILE" ]; then
  echo -e "${YELLOW}Warning: Secret '$SECRET_NAME' already exists for $ENVIRONMENT${NC}"
  read -p "Overwrite? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
  # Backup existing secret
  cp "$SECRET_FILE" "${SECRET_FILE}.backup.$(date +%Y%m%d%H%M%S)"
  echo "  Backed up existing secret"
fi

# Get secret value
if [ "${3:-}" = "--generate" ]; then
  # Generate random secret
  SECRET_VALUE=$(openssl rand -base64 "$GENERATE_LENGTH" | tr -d '\n')
  echo "Generated random secret (${GENERATE_LENGTH} bytes base64-encoded)"
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
  SECRET_VALUE=$(cat)
fi

# Validate secret is not empty
if [ -z "$SECRET_VALUE" ]; then
  echo -e "${RED}Error: Secret value cannot be empty${NC}"
  exit 1
fi

# Write secret to file
echo -n "$SECRET_VALUE" > "$SECRET_FILE"

# Set secure permissions
chmod 600 "$SECRET_FILE"

echo ""
echo -e "${GREEN}✓ Secret created: ${ENVIRONMENT}/${SECRET_NAME}${NC}"
echo "  File: $SECRET_FILE"
echo "  Permissions: 600 (owner read/write only)"
echo ""
echo "Usage in compose.yml:"
echo "  volumes:"
echo "    - ./secrets/${ENVIRONMENT}/${SECRET_NAME}.txt:/run/secrets/${SECRET_NAME}:ro"
echo "  environment:"
echo "    - ${SECRET_NAME^^}_FILE=/run/secrets/${SECRET_NAME}"
echo ""
