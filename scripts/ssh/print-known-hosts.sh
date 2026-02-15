#!/usr/bin/env bash
# =================================================================
# Print SSH known_hosts Entries for This Server
# =================================================================
# GitHub Actions (and other CI) should pin the SSH host key to prevent MITM.
#
# This script prints known_hosts lines for one or more hostnames using the
# server's own host public keys (no network scan required).
#
# Usage:
#   ./scripts/ssh/print-known-hosts.sh ssh.yourdomain.com
#   ./scripts/ssh/print-known-hosts.sh ssh.yourdomain.com ssh-alt.yourdomain.com
#
# Output example:
#   ssh.yourdomain.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI...
#
# Copy the output into your CI secret (e.g. GitHub Actions: SSH_KNOWN_HOSTS).
# =================================================================

set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ] || [ $# -lt 1 ]; then
  echo "Usage: $0 <hostname> [hostname2 ...]"
  echo ""
  echo "Example:"
  echo "  $0 ssh.yourdomain.com"
  exit 0
fi

HOSTS=("$@")

PUBKEYS=()
for f in /etc/ssh/ssh_host_*_key.pub; do
  [ -f "$f" ] || continue
  PUBKEYS+=("$f")
done

if [ "${#PUBKEYS[@]}" -eq 0 ]; then
  echo "ERROR: No SSH host public keys found under /etc/ssh (expected /etc/ssh/ssh_host_*_key.pub)" >&2
  exit 1
fi

for host in "${HOSTS[@]}"; do
  for pub in "${PUBKEYS[@]}"; do
    # host key pub file format: "<type> <base64> <comment...>"
    key_type="$(awk '{print $1}' "$pub")"
    key_b64="$(awk '{print $2}' "$pub")"

    if [ -z "${key_type:-}" ] || [ -z "${key_b64:-}" ]; then
      echo "WARN: Could not parse $pub" >&2
      continue
    fi

    echo "$host $key_type $key_b64"
  done
done

