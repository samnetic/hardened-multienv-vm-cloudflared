#!/usr/bin/env bash
# =================================================================
# Verify SSH via Cloudflare Tunnel
# =================================================================
# Tests that SSH via Cloudflare Tunnel is working correctly before
# closing the direct SSH port.
#
# Usage:
#   ./verify-tunnel-ssh.sh <ssh-hostname> [username]
#
# Example:
#   ./verify-tunnel-ssh.sh ssh.yourdomain.com sysadmin
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
SSH_HOSTNAME="${1:-}"
SSH_USER="${2:-sysadmin}"
TESTS_PASSED=0
TESTS_FAILED=0
TEMP_FILE=""

# Cleanup function for temp files
cleanup() {
  [ -n "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
}
trap cleanup EXIT

print_header() {
  echo ""
  echo -e "${CYAN}======================================================================${NC}"
  echo -e "${CYAN} $1${NC}"
  echo -e "${CYAN}======================================================================${NC}"
  echo ""
}

print_test() {
  echo -n "  Testing: $1... "
}

print_pass() {
  echo -e "${GREEN}PASS${NC}"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

print_fail() {
  echo -e "${RED}FAIL${NC}"
  echo -e "    ${RED}Error: $1${NC}"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Helper function to run SSH via tunnel (safe from command injection)
run_ssh() {
  local remote_cmd="${1:-}"
  ssh \
    -o "ProxyCommand=cloudflared access ssh --hostname '${SSH_HOSTNAME}'" \
    -o "ConnectTimeout=30" \
    -o "StrictHostKeyChecking=accept-new" \
    "${SSH_USER}@${SSH_HOSTNAME}" \
    "$remote_cmd"
}

# Helper function to run SCP via tunnel (safe from command injection)
run_scp() {
  local src="$1"
  local dst="$2"
  scp \
    -o "ProxyCommand=cloudflared access ssh --hostname '${SSH_HOSTNAME}'" \
    -o "ConnectTimeout=30" \
    "$src" "$dst"
}

# Check arguments
if [ -z "$SSH_HOSTNAME" ]; then
  echo "Usage: $0 <ssh-hostname> [username]"
  echo ""
  echo "Examples:"
  echo "  $0 ssh.yourdomain.com sysadmin"
  echo "  $0 ssh.example.com appmgr"
  echo ""
  echo "This script tests SSH connectivity via Cloudflare Tunnel"
  echo "to verify it's working before closing the direct SSH port."
  exit 1
fi

# Validate hostname format (security: prevent command injection)
if [[ ! "$SSH_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
  echo -e "${RED}Error: Invalid hostname format '${SSH_HOSTNAME}'${NC}"
  echo "Hostname must contain only letters, numbers, dots, and hyphens."
  exit 1
fi

print_header "SSH via Cloudflare Tunnel - Verification"

echo "Testing: $SSH_USER@$SSH_HOSTNAME"
echo ""

# Check if cloudflared is installed locally
print_test "cloudflared installed locally"
if command -v cloudflared &> /dev/null; then
  VERSION=$(cloudflared --version 2>&1 | head -1)
  print_pass
  echo "    Version: $VERSION"
else
  print_fail "cloudflared not found. Install it first."
  echo ""
  echo "Installation:"
  echo "  Debian/Ubuntu: curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb && sudo dpkg -i cloudflared.deb"
  echo "  macOS: brew install cloudflared"
  echo ""
  exit 1
fi

# Test 1: Basic SSH connection
print_test "SSH connection via tunnel"
if timeout 60 run_ssh 'echo connected' 2>/dev/null; then
  print_pass
else
  print_fail "Could not connect via tunnel"
  echo ""
  echo "Debug steps:"
  echo "  1. Verify tunnel is running on server: sudo systemctl status cloudflared"
  echo "  2. Check DNS resolves: dig $SSH_HOSTNAME"
  echo "  3. Test tunnel manually: cloudflared access ssh --hostname $SSH_HOSTNAME"
  echo ""
  exit 1
fi

# Test 2: Command execution
print_test "Command execution"
if OUTPUT=$(timeout 30 run_ssh 'whoami' 2>/dev/null); then
  if [ "$OUTPUT" = "$SSH_USER" ]; then
    print_pass
  else
    print_fail "Unexpected user: $OUTPUT (expected: $SSH_USER)"
  fi
else
  print_fail "Command execution failed"
fi

# Test 3: Sudo access (for sysadmin)
if [ "$SSH_USER" = "sysadmin" ]; then
  print_test "Sudo access"
  if OUTPUT=$(timeout 30 run_ssh 'sudo whoami' 2>/dev/null); then
    if [ "$OUTPUT" = "root" ]; then
      print_pass
    else
      print_fail "Sudo returned: $OUTPUT (expected: root)"
    fi
  else
    print_fail "Sudo command failed"
  fi
fi

# Test 4: File transfer (SCP)
print_test "File transfer (SCP)"
TEMP_FILE=$(mktemp)
echo "tunnel-test-$(date +%s)" > "$TEMP_FILE"
TEMP_BASENAME=".tunnel-test-$(basename "$TEMP_FILE")"
# Use home directory instead of /tmp to avoid noexec mount issues
REMOTE_PATH="~/${TEMP_BASENAME}"
if timeout 30 run_scp "$TEMP_FILE" "$SSH_USER@$SSH_HOSTNAME:${REMOTE_PATH}" 2>/dev/null; then
  # Verify file was transferred
  if REMOTE_CONTENT=$(timeout 30 run_ssh "cat ${REMOTE_PATH}" 2>/dev/null); then
    if [ "$REMOTE_CONTENT" = "$(cat "$TEMP_FILE")" ]; then
      print_pass
      timeout 10 run_ssh "rm -f ${REMOTE_PATH}" 2>/dev/null || true
    else
      print_fail "File content mismatch"
    fi
  else
    print_fail "Could not verify transferred file"
  fi
else
  print_fail "SCP transfer failed"
fi
rm -f "$TEMP_FILE"

# Test 5: Connection stability (longer test)
print_test "Connection stability (10s)"
if timeout 15 run_ssh 'sleep 10 && echo stable' 2>/dev/null | grep -q "stable"; then
  print_pass
else
  print_fail "Connection dropped during stability test"
fi

# Test 6: Reconnection
print_test "Reconnection after disconnect"
# First connection
timeout 15 run_ssh 'exit 0' 2>/dev/null || true
# Second connection
if timeout 30 run_ssh 'echo reconnected' 2>/dev/null | grep -q "reconnected"; then
  print_pass
else
  print_fail "Reconnection failed"
fi

# Summary
print_header "Test Results"

echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo ""

if [ "$TESTS_FAILED" -eq 0 ]; then
  echo -e "${GREEN}All tests passed! SSH via tunnel is working correctly.${NC}"
  echo ""
  echo -e "${YELLOW}You can now safely close the direct SSH port:${NC}"
  echo ""
  echo "  # On your server:"
  echo "  sudo ufw delete allow OpenSSH"
  echo "  sudo ufw delete allow 22/tcp"
  echo "  sudo ufw status  # Verify port 22 is not listed"
  echo ""
  echo "  # Recommended: Add your SSH config for easy access"
  echo "  # Add to ~/.ssh/config:"
  echo "  Host myserver"
  echo "    HostName $SSH_HOSTNAME"
  echo "    User $SSH_USER"
  echo "    ProxyCommand cloudflared access ssh --hostname $SSH_HOSTNAME"
  echo ""
else
  echo -e "${RED}Some tests failed! Do NOT close the direct SSH port yet.${NC}"
  echo ""
  echo "Fix the issues above before proceeding."
  echo "Check server logs: sudo journalctl -u cloudflared -f"
  exit 1
fi
