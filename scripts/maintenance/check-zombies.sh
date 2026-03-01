#!/usr/bin/env bash
# =================================================================
# Zombie Process Checker (hosting-blueprint)
# =================================================================
# Detects zombie processes and sends alerts via notify.sh.
# Called by cron (daily) or manually.
# =================================================================

set -euo pipefail

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

notify() {
  local subject="$1"
  local body="$2"
  if [ -x /opt/scripts/hosting-notify.sh ]; then
    /opt/scripts/hosting-notify.sh "$subject" "$body" || true
  fi
}

ZOMBIES="$(ps aux 2>/dev/null | awk '$8 ~ /^Z/ { print $0 }' || true)"

if [ -n "$ZOMBIES" ]; then
  COUNT="$(echo "$ZOMBIES" | wc -l)"
  BODY="Found ${COUNT} zombie process(es) on ${HOSTNAME_FQDN}:\n\n${ZOMBIES}"
  notify "Zombie processes detected - ${HOSTNAME_FQDN}" "$BODY"
  logger -t zombie-check "ALERT: ${COUNT} zombie process(es) found"
  echo "$ZOMBIES"
else
  logger -t zombie-check "OK: No zombie processes"
fi
