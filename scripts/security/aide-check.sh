#!/usr/bin/env bash
# =================================================================
# AIDE Check (hosting-blueprint)
# =================================================================
# Runs an AIDE integrity check in "update" mode (detect changes since last run),
# stores a new database, and rotates the baseline DB when successful.
#
# Alerts via scripts/security/notify.sh if changes are detected or errors occur.
# =================================================================

set -euo pipefail

LOGDIR="/var/log/hosting-blueprint/security"
LOGFILE="${LOGDIR}/aide-check.log"

AIDE_BIN="/usr/bin/aide"
AIDE_CONF="/etc/aide/aide.conf"
AIDE_DB="/var/lib/aide/aide.db"
AIDE_DB_NEW="/var/lib/aide/aide.db.new"

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

if [ ! -x "$AIDE_BIN" ]; then
  log "ERROR: aide is not installed"
  notify "AIDE ERROR (not installed) - ${HOSTNAME_FQDN}" "Install with: sudo apt install aide"
  exit 1
fi

if [ ! -f "$AIDE_DB" ]; then
  log "ERROR: AIDE database not found: $AIDE_DB"
  log "Hint: initialize with 'sudo aideinit' then move .new -> aide.db"
  notify "AIDE ERROR (no DB) - ${HOSTNAME_FQDN}" "AIDE database missing at ${AIDE_DB}. Run: sudo aideinit"
  exit 1
fi

log "=== AIDE check started (${HOSTNAME_FQDN}) ==="

EXIT_CODE=0
"$AIDE_BIN" --update --config "$AIDE_CONF" > "${LOGFILE}.tmp" 2>&1 || EXIT_CODE=$?
cat "${LOGFILE}.tmp" >> "$LOGFILE"
rm -f "${LOGFILE}.tmp"

if [ "$EXIT_CODE" -ge 1 ] && [ "$EXIT_CODE" -le 7 ]; then
  ADDED="$(grep -oP '^\\s*Added entries:\\s*\\K\\d+' "$LOGFILE" 2>/dev/null | tail -1 || echo "0")"
  REMOVED="$(grep -oP '^\\s*Removed entries:\\s*\\K\\d+' "$LOGFILE" 2>/dev/null | tail -1 || echo "0")"
  CHANGED="$(grep -oP '^\\s*Changed entries:\\s*\\K\\d+' "$LOGFILE" 2>/dev/null | tail -1 || echo "0")"

  log "WARNING: Changes detected (added=${ADDED}, removed=${REMOVED}, changed=${CHANGED})"
  notify "AIDE ALERT (changes) - ${HOSTNAME_FQDN}" "Added: ${ADDED}\nRemoved: ${REMOVED}\nChanged: ${CHANGED}\n\nSee: ${LOGFILE}"
elif [ "$EXIT_CODE" -ge 14 ]; then
  log "ERROR: AIDE failed with exit code ${EXIT_CODE}"
  notify "AIDE ERROR (exit ${EXIT_CODE}) - ${HOSTNAME_FQDN}" "See: ${LOGFILE}"
  exit "$EXIT_CODE"
else
  log "OK: No changes detected"
fi

# Rotate baseline DB so only NEW changes trigger alerts next run
if [ -f "$AIDE_DB_NEW" ]; then
  cp "$AIDE_DB_NEW" "$AIDE_DB"
  log "Rotated baseline DB: ${AIDE_DB_NEW} -> ${AIDE_DB}"
fi

log "=== AIDE check complete ==="

