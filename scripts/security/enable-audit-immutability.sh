#!/usr/bin/env bash
# =================================================================
# Enable Audit Rules Immutability
# =================================================================
# Makes audit rules immutable, preventing attackers from disabling
# auditing. After enabling, a REBOOT is required to change rules.
#
# Usage:
#   sudo ./enable-audit-immutability.sh
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

AUDIT_RULES_FILE="/etc/audit/rules.d/hardening.rules"

echo "======================================================================"
echo " Enable Audit Rules Immutability"
echo "======================================================================"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

# Check if audit rules file exists
if [ ! -f "$AUDIT_RULES_FILE" ]; then
  echo -e "${RED}Audit rules file not found: $AUDIT_RULES_FILE${NC}"
  echo "Run setup-vm.sh first to install audit rules."
  exit 1
fi

# Check if already enabled
if grep -q "^-e 2" "$AUDIT_RULES_FILE"; then
  echo -e "${YELLOW}Audit immutability is already enabled.${NC}"
  echo "Rules can only be changed after a reboot."
  exit 0
fi

echo "This will make audit rules IMMUTABLE."
echo ""
echo "What this means:"
echo "  - Attackers cannot disable auditing (even as root)"
echo "  - You cannot change audit rules without a REBOOT"
echo "  - This is strongly recommended for production systems"
echo ""
echo -e "${YELLOW}WARNING: After enabling, any changes to audit rules${NC}"
echo -e "${YELLOW}will require a system reboot to take effect.${NC}"
echo ""

# Verify current rules work
echo "Verifying current audit rules..."
if ! auditctl -l > /dev/null 2>&1; then
  echo -e "${RED}Error: Cannot read current audit rules${NC}"
  echo "Fix audit configuration before enabling immutability."
  exit 1
fi

RULE_COUNT=$(auditctl -l | wc -l)
echo -e "${GREEN}  ✓ $RULE_COUNT audit rules currently active${NC}"
echo ""

# Confirm with user
read -rp "Enable audit immutability? This requires a reboot. (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
  echo "Cancelled."
  exit 0
fi

# Backup existing rules
BACKUP_FILE="${AUDIT_RULES_FILE}.backup.$(date +%Y%m%d%H%M%S)"
cp "$AUDIT_RULES_FILE" "$BACKUP_FILE"
echo -e "${GREEN}✓ Backup created: $BACKUP_FILE${NC}"

# Enable immutability by uncommenting -e 2 (handle optional leading/trailing whitespace)
sed -i 's/^[[:space:]]*#[[:space:]]*-e 2[[:space:]]*$/-e 2/' "$AUDIT_RULES_FILE"

# Verify the change
if grep -q "^-e 2" "$AUDIT_RULES_FILE"; then
  echo -e "${GREEN}✓ Immutability flag added to rules file${NC}"
else
  echo -e "${RED}✗ Failed to add immutability flag${NC}"
  cp "$BACKUP_FILE" "$AUDIT_RULES_FILE"
  exit 1
fi

echo ""
echo "======================================================================"
echo " Immutability Configured - Reboot Required"
echo "======================================================================"
echo ""
echo "The audit immutability flag has been added to the rules file."
echo ""
echo -e "${YELLOW}To activate, you MUST reboot the system:${NC}"
echo "  sudo reboot"
echo ""
echo "After reboot, verify with:"
echo "  sudo auditctl -s | grep enabled"
echo "  # Should show 'enabled 2' (locked/immutable)"
echo ""
echo "To disable immutability later:"
echo "  1. Edit $AUDIT_RULES_FILE"
echo "  2. Comment out or remove '-e 2'"
echo "  3. Reboot"
echo ""
