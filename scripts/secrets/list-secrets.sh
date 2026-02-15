#!/usr/bin/env bash
# =================================================================
# List All Secrets
# =================================================================
# Lists all secret files across all environments.
#
# Usage:
#   ./list-secrets.sh           # List all
#   ./list-secrets.sh dev       # List dev only
#   ./list-secrets.sh staging   # List staging only
# =================================================================

set -euo pipefail

# Configuration
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
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

FILTER_ENV="${1:-all}"

# Re-exec with sudo when listing system secrets (avoids group membership/session issues)
if [ "$SYSTEM_SECRETS" = true ] && [ "${EUID:-0}" -ne 0 ]; then
  exec sudo SECRETS_DIR="$SECRETS_DIR" SECRETS_GROUP="$SECRETS_GROUP" SECRETS_GID="$SECRETS_GID" "$0" "$@"
fi

# Portable stat functions for Linux/macOS compatibility
get_file_perms() {
  local file="$1"
  if stat -c "%a" "$file" 2>/dev/null; then
    return 0
  elif stat -f "%OLp" "$file" 2>/dev/null; then
    return 0
  else
    echo "???"
    return 1
  fi
}

get_file_modified() {
  local file="$1"
  # Try GNU stat first (Linux), then BSD stat (macOS)
  if stat -c "%y" "$file" 2>/dev/null | cut -d' ' -f1; then
    return 0
  elif stat -f "%Sm" -t "%Y-%m-%d" "$file" 2>/dev/null; then
    return 0
  else
    echo "unknown"
    return 1
  fi
}

echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${BLUE} Secret Files${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo ""

list_env_secrets() {
  local env=$1
  local dir="${SECRETS_DIR}/${env}"

  echo -e "${CYAN}${env^^}:${NC}"

  if [ ! -d "$dir" ]; then
    echo "  (no secrets directory)"
    return
  fi

  local count=0
  shopt -s nullglob
  for file in "$dir"/*.txt; do
    if [ -f "$file" ]; then
      local name=$(basename "$file" .txt)
      local perms=$(get_file_perms "$file")
      local modified=$(get_file_modified "$file")

      if [ "$SYSTEM_SECRETS" = true ] && [ "$perms" = "640" ]; then
        echo -e "  ${GREEN}✓${NC} ${name} (${perms}) - modified: ${modified}"
      elif [ "$SYSTEM_SECRETS" = false ] && [ "$perms" = "600" ]; then
        echo -e "  ${GREEN}✓${NC} ${name} (${perms}) - modified: ${modified}"
      else
        if [ "$SYSTEM_SECRETS" = true ]; then
          echo -e "  ${YELLOW}⚠${NC} ${name} (${perms}) - ${YELLOW}permissions should be 640 (root:${SECRETS_GROUP})${NC}"
        else
          echo -e "  ${YELLOW}⚠${NC} ${name} (${perms}) - ${YELLOW}permissions should be 600${NC}"
        fi
      fi
      ((count++)) || true
    fi
  done
  shopt -u nullglob

  if [ $count -eq 0 ]; then
    echo "  (no secrets)"
  fi

  echo ""
}

if [ "$FILTER_ENV" = "all" ]; then
  for env in dev staging production; do
    list_env_secrets "$env"
  done
else
  if [[ ! "$FILTER_ENV" =~ ^(dev|staging|production)$ ]]; then
    echo "Invalid environment: $FILTER_ENV"
    echo "Valid: dev, staging, production, all"
    exit 1
  fi
  list_env_secrets "$FILTER_ENV"
fi

echo "Commands:"
echo "  Create:  ./scripts/secrets/create-secret.sh <env> <name>"
echo "  Rotate:  ./scripts/secrets/rotate-secret.sh <env> <name>"
if [ "$SYSTEM_SECRETS" = true ]; then
  echo ""
  echo "System secrets:"
  echo "  Root: /var/secrets"
  echo "  Group: ${SECRETS_GROUP} (GID ${SECRETS_GID})"
fi
echo ""
