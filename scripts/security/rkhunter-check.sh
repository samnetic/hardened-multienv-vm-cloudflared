#!/usr/bin/env bash
# =================================================================
# rkhunter Weekly Scan (hosting-blueprint)
# =================================================================
# Runs a rkhunter scan and alerts if warnings are detected.
# =================================================================

set -euo pipefail

LOGDIR="/var/log/hosting-blueprint/security"
LOGFILE="${LOGDIR}/rkhunter-check.log"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

mkdir -p "$LOGDIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

notify() {
  local subject="$1"
  local body="$2"
  if [ -x /opt/scripts/hosting-notify.sh ]; then
    /opt/scripts/hosting-notify.sh "$subject" "$body" || true
  elif [ -x "$(dirname "$0")/notify.sh" ]; then
    "$(dirname "$0")/notify.sh" "$subject" "$body" || true
  fi
}

if [ "${EUID:-0}" -ne 0 ]; then
  log "ERROR: Must run as root"
  exit 1
fi

if ! command -v rkhunter >/dev/null 2>&1; then
  log "ERROR: rkhunter is not installed"
  notify "rkhunter ERROR (not installed) - ${HOSTNAME_FQDN}" "Install with: sudo apt install rkhunter"
  exit 1
fi

log "=== rkhunter scan started (${HOSTNAME_FQDN}) ==="

EXIT_CODE=0
rkhunter --check --skip-keypress --report-warnings-only >> "$LOGFILE" 2>&1 || EXIT_CODE=$?

# rkhunter returns non-zero on warnings too; treat as "signal" not fatal.
WARNINGS="$(grep -c '^\\[.*\\] Warning:' "$LOGFILE" 2>/dev/null || echo "0")"
SUSPECT="$(grep -oP 'Suspect files:\\s*\\K\\d+' /var/log/rkhunter.log 2>/dev/null | tail -1 || echo "-1")"
ROOTKITS="$(grep -oP 'Possible rootkits:\\s*\\K\\d+' /var/log/rkhunter.log 2>/dev/null | tail -1 || echo "-1")"

log "Exit=${EXIT_CODE}, warnings=${WARNINGS}, suspect_files=${SUSPECT}, possible_rootkits=${ROOTKITS}"

if [ "$WARNINGS" -gt 0 ] || [ "$SUSPECT" != "0" ] || [ "$ROOTKITS" != "0" ]; then
  notify "rkhunter WARNINGS - ${HOSTNAME_FQDN}" "Warnings: ${WARNINGS}\nSuspect files: ${SUSPECT}\nPossible rootkits: ${ROOTKITS}\n\nSee: ${LOGFILE}\nAlso check: /var/log/rkhunter.log"
fi

log "=== rkhunter scan complete ==="

