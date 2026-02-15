#!/usr/bin/env bash
# =================================================================
# Lynis Weekly Audit (hosting-blueprint)
# =================================================================
# Runs Lynis security audit and alerts if:
# - warnings are present, OR
# - hardening index drops compared to previous run.
# =================================================================

set -euo pipefail

LOGDIR="/var/log/hosting-blueprint/security"
LOGFILE="${LOGDIR}/lynis-audit.log"

STATE_DIR="/var/lib/hosting-blueprint"
SCORE_FILE="${STATE_DIR}/lynis-prev-score"

REPORT="/var/log/lynis-report.dat"

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

mkdir -p "$LOGDIR" "$STATE_DIR"

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

if ! command -v lynis >/dev/null 2>&1; then
  log "ERROR: lynis is not installed"
  notify "Lynis ERROR (not installed) - ${HOSTNAME_FQDN}" "Install with: sudo apt install lynis"
  exit 1
fi

log "=== Lynis audit started (${HOSTNAME_FQDN}) ==="
lynis audit system --no-colors --quiet >> "$LOGFILE" 2>&1 || true

CURRENT_SCORE="$(grep -oP '^hardening_index=\\K\\d+' "$REPORT" 2>/dev/null || echo "0")"
WARNINGS="$(grep -c '^warning\\[' "$REPORT" 2>/dev/null || echo "0")"
SUGGESTIONS="$(grep -c '^suggestion\\[' "$REPORT" 2>/dev/null || echo "0")"

PREV_SCORE="0"
if [ -f "$SCORE_FILE" ]; then
  PREV_SCORE="$(cat "$SCORE_FILE" 2>/dev/null || echo "0")"
fi
echo "$CURRENT_SCORE" > "$SCORE_FILE"

log "Score: ${CURRENT_SCORE}/100 (prev: ${PREV_SCORE}/100), warnings=${WARNINGS}, suggestions=${SUGGESTIONS}"

ALERT=false
SUBJECT="Lynis weekly audit - ${HOSTNAME_FQDN}"

if [ "$WARNINGS" -gt 0 ]; then
  ALERT=true
  SUBJECT="Lynis WARNINGS (${WARNINGS}) - score ${CURRENT_SCORE}/100 - ${HOSTNAME_FQDN}"
fi

if [ "$CURRENT_SCORE" -lt "$PREV_SCORE" ]; then
  ALERT=true
  SUBJECT="Lynis score DROPPED ${PREV_SCORE} -> ${CURRENT_SCORE} - ${HOSTNAME_FQDN}"
fi

if [ "$ALERT" = true ]; then
  # Include warnings lines (bounded)
  WARNINGS_TEXT="$(grep '^warning\\[' "$REPORT" 2>/dev/null | head -200 || true)"
  notify "$SUBJECT" "Hardening Index: ${CURRENT_SCORE}/100 (previous: ${PREV_SCORE}/100)\nWarnings: ${WARNINGS}\nSuggestions: ${SUGGESTIONS}\n\n${WARNINGS_TEXT}\n\nFull report: ${REPORT}\nFull log: /var/log/lynis.log"
fi

log "=== Lynis audit complete ==="

