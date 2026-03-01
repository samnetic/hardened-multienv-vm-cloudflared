#!/usr/bin/env bash
# =================================================================
# AIDE File Integrity Metrics (hosting-blueprint)
# =================================================================
# Exports AIDE check results as Prometheus textfile metrics.
# Call this after the AIDE check completes (from aide-check.sh or cron).
#
# Output: /var/lib/prometheus/node-exporter/aide.prom
# =================================================================

set -euo pipefail

METRICS_FILE="/var/lib/prometheus/node-exporter/aide.prom"
AIDE_LOGFILE="/var/log/hosting-blueprint/security/aide-check.log"

ADDED=0
REMOVED=0
CHANGED=0
HEALTH=1  # 1=clean, 0=changes detected

if [ -f "$AIDE_LOGFILE" ]; then
  ADDED="$(grep -oP '^\s*Added entries:\s*\K\d+' "$AIDE_LOGFILE" 2>/dev/null | tail -1 || echo 0)"
  REMOVED="$(grep -oP '^\s*Removed entries:\s*\K\d+' "$AIDE_LOGFILE" 2>/dev/null | tail -1 || echo 0)"
  CHANGED="$(grep -oP '^\s*Changed entries:\s*\K\d+' "$AIDE_LOGFILE" 2>/dev/null | tail -1 || echo 0)"

  if [ "$ADDED" -gt 0 ] || [ "$REMOVED" -gt 0 ] || [ "$CHANGED" -gt 0 ]; then
    HEALTH=0
  fi
fi

# Get last check timestamp from log
LAST_CHECK=0
if [ -f "$AIDE_LOGFILE" ]; then
  LAST_CHECK="$(stat -c %Y "$AIDE_LOGFILE" 2>/dev/null || echo 0)"
fi

# Atomic write
tmp="${METRICS_FILE}.tmp.$$"
cat > "$tmp" <<EOF
# HELP aide_entries_added Number of added entries in last AIDE check
# TYPE aide_entries_added gauge
aide_entries_added ${ADDED}
# HELP aide_entries_removed Number of removed entries in last AIDE check
# TYPE aide_entries_removed gauge
aide_entries_removed ${REMOVED}
# HELP aide_entries_changed Number of changed entries in last AIDE check
# TYPE aide_entries_changed gauge
aide_entries_changed ${CHANGED}
# HELP aide_health 1 if no changes detected, 0 if changes found
# TYPE aide_health gauge
aide_health ${HEALTH}
# HELP aide_last_check_timestamp Unix timestamp of last AIDE check
# TYPE aide_last_check_timestamp gauge
aide_last_check_timestamp ${LAST_CHECK}
EOF
mv "$tmp" "$METRICS_FILE"
