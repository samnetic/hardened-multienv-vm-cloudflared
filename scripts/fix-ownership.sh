#!/usr/bin/env bash
# =================================================================
# Fix Repository Ownership
# =================================================================
# Fixes git repository ownership to match the current user
#
# Usage:
#   ./scripts/fix-ownership.sh              # Fix for current user
#   sudo ./scripts/fix-ownership.sh         # Fix for original sudo user
#   sudo ./scripts/fix-ownership.sh sysadmin  # Fix for specific user
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Get script directory (repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Determine target user
if [ -n "${1:-}" ]; then
  # User specified as argument
  TARGET_USER="$1"
elif [ -n "${SUDO_USER:-}" ]; then
  # Running with sudo, use original user
  TARGET_USER="$SUDO_USER"
else
  # Not using sudo, use current user
  TARGET_USER="$(whoami)"
fi

# Validate user exists
if ! id "$TARGET_USER" &>/dev/null; then
  echo -e "${RED}✗ User '$TARGET_USER' does not exist${NC}"
  exit 1
fi

echo -e "${CYAN}Repository Ownership Fix${NC}"
echo ""
echo "  Repository: $SCRIPT_DIR"
echo "  Target User: $TARGET_USER"
echo ""

# Check current ownership
CURRENT_OWNER=$(stat -c '%U' "$SCRIPT_DIR")
if [ "$CURRENT_OWNER" = "$TARGET_USER" ]; then
  echo -e "${GREEN}✓ Repository already owned by $TARGET_USER${NC}"
  exit 0
fi

echo -e "${YELLOW}Current owner: $CURRENT_OWNER${NC}"
echo -e "${YELLOW}Changing to: $TARGET_USER${NC}"
echo ""

# Fix ownership
if [ "$EUID" -eq 0 ]; then
  # Running as root
  chown -R "${TARGET_USER}:${TARGET_USER}" "$SCRIPT_DIR"
  echo -e "${GREEN}✓ Ownership changed to $TARGET_USER${NC}"
else
  # Not root, need sudo
  echo "This requires sudo privileges..."
  sudo chown -R "${TARGET_USER}:${TARGET_USER}" "$SCRIPT_DIR"
  echo -e "${GREEN}✓ Ownership changed to $TARGET_USER${NC}"
fi

# Verify
NEW_OWNER=$(stat -c '%U' "$SCRIPT_DIR")
if [ "$NEW_OWNER" = "$TARGET_USER" ]; then
  echo -e "${GREEN}✓ Verification successful${NC}"
else
  echo -e "${RED}✗ Ownership change failed${NC}"
  exit 1
fi
