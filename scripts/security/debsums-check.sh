#!/usr/bin/env bash
# =================================================================
# debsums Integrity Check (hosting-blueprint)
# =================================================================
# Verifies installed package files against md5sums.
# Alerts if mismatches are found.
# =================================================================

set -euo pipefail

LOGDIR="/var/log/hosting-blueprint/security"
LOGFILE="${LOGDIR}/debsums-check.log"

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

if ! command -v debsums >/dev/null 2>&1; then
  log "ERROR: debsums is not installed"
  notify "debsums ERROR (not installed) - ${HOSTNAME_FQDN}" "Install with: sudo apt install debsums"
  exit 1
fi

log "=== debsums check started (${HOSTNAME_FQDN}) ==="

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# -s: silent (print only errors), exits non-zero if mismatches are found.
EXIT_CODE=0
debsums -s >"$TMP" 2>>"$LOGFILE" || EXIT_CODE=$?

if [ -s "$TMP" ]; then
  COUNT="$(wc -l <"$TMP" | tr -d ' ')"
  log "WARNING: ${COUNT} mismatch(es) detected"
  head -200 "$TMP" >> "$LOGFILE"
  notify "debsums MISMATCH (${COUNT}) - ${HOSTNAME_FQDN}" "Package file mismatches detected.\n\n$(head -50 "$TMP")\n\nSee: ${LOGFILE}"
else
  log "OK: No mismatches detected"
fi

log "Exit=${EXIT_CODE}"
log "=== debsums check complete ==="

