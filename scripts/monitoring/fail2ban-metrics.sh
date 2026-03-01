#!/usr/bin/env bash
# =================================================================
# fail2ban Prometheus Metrics (hosting-blueprint)
# =================================================================
# Exports fail2ban jail statistics as Prometheus textfile metrics.
# Run via cron every minute for near-real-time monitoring.
#
# Output: /var/lib/prometheus/node-exporter/fail2ban.prom
# =================================================================

set -euo pipefail

METRICS_FILE="/var/lib/prometheus/node-exporter/fail2ban.prom"
tmp="${METRICS_FILE}.tmp.$$"

# Check if fail2ban is running
if ! fail2ban-client ping >/dev/null 2>&1; then
  cat > "$tmp" <<'EOF'
# HELP fail2ban_up Whether fail2ban is running (1=up, 0=down)
# TYPE fail2ban_up gauge
fail2ban_up 0
EOF
  mv "$tmp" "$METRICS_FILE"
  exit 0
fi

{
  echo "# HELP fail2ban_up Whether fail2ban is running (1=up, 0=down)"
  echo "# TYPE fail2ban_up gauge"
  echo "fail2ban_up 1"
  echo "# HELP fail2ban_banned_current Currently banned IPs per jail"
  echo "# TYPE fail2ban_banned_current gauge"
  echo "# HELP fail2ban_banned_total Total banned IPs per jail (counter)"
  echo "# TYPE fail2ban_banned_total counter"
  echo "# HELP fail2ban_failed_current Currently failed attempts per jail"
  echo "# TYPE fail2ban_failed_current gauge"
  echo "# HELP fail2ban_failed_total Total failed attempts per jail (counter)"
  echo "# TYPE fail2ban_failed_total counter"

  # Get all active jails
  JAILS="$(fail2ban-client status 2>/dev/null | grep 'Jail list' | sed 's/.*:\s*//' | tr ',' '\n' | sed 's/^ *//' || true)"

  for JAIL in $JAILS; do
    [ -z "$JAIL" ] && continue
    STATUS="$(fail2ban-client status "$JAIL" 2>/dev/null || true)"

    CURRENTLY_BANNED="$(echo "$STATUS" | grep 'Currently banned' | awk '{print $NF}' || echo 0)"
    TOTAL_BANNED="$(echo "$STATUS" | grep 'Total banned' | awk '{print $NF}' || echo 0)"
    CURRENTLY_FAILED="$(echo "$STATUS" | grep 'Currently failed' | awk '{print $NF}' || echo 0)"
    TOTAL_FAILED="$(echo "$STATUS" | grep 'Total failed' | awk '{print $NF}' || echo 0)"

    echo "fail2ban_banned_current{jail=\"${JAIL}\"} ${CURRENTLY_BANNED:-0}"
    echo "fail2ban_banned_total{jail=\"${JAIL}\"} ${TOTAL_BANNED:-0}"
    echo "fail2ban_failed_current{jail=\"${JAIL}\"} ${CURRENTLY_FAILED:-0}"
    echo "fail2ban_failed_total{jail=\"${JAIL}\"} ${TOTAL_FAILED:-0}"
  done
} > "$tmp"

mv "$tmp" "$METRICS_FILE"
