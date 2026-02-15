#!/usr/bin/env bash
# =================================================================
# Alert/Notification Helper (hosting-blueprint)
# =================================================================
# Lightweight notifier used by security/maintenance scripts.
#
# Supported channels (optional):
# - Webhook: ALERT_WEBHOOK_URL (recommended: ntfy, generic HTTP endpoint)
# - Email:   ALERT_EMAIL (requires a working `mail` command on the host)
#
# Configuration file (optional):
#   /etc/hosting-blueprint/alerting.env
#     ALERT_WEBHOOK_URL="https://ntfy.sh/your-topic"
#     ALERT_EMAIL="you@example.com"
#
# Usage:
#   ./notify.sh "Subject" "Body"
#   echo "Body" | ./notify.sh "Subject"
# =================================================================

set -euo pipefail

SUBJECT="${1:-}"
BODY="${2:-}"

if [ -z "$SUBJECT" ] || [ "$SUBJECT" = "--help" ] || [ "$SUBJECT" = "-h" ]; then
  echo "Usage: $0 <subject> [body]"
  echo ""
  echo "Examples:"
  echo "  $0 \"AIDE changes\" \"Changes detected on host\""
  echo "  echo \"details...\" | $0 \"Lynis warnings\""
  exit 0
fi

if [ -z "$BODY" ] && [ ! -t 0 ]; then
  BODY="$(cat)"
fi

# Load optional config (best-effort)
if [ -f /etc/hosting-blueprint/alerting.env ]; then
  # shellcheck disable=SC1091
  set +u
  . /etc/hosting-blueprint/alerting.env
  set -u
fi

# Always log a short message locally
logger -t hosting-blueprint-alert -- "$SUBJECT"

MESSAGE="$SUBJECT"
if [ -n "$BODY" ]; then
  MESSAGE="${MESSAGE}\n\n${BODY}"
fi

# Webhook (best-effort)
if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
  curl -fsS -X POST \
    -H "Content-Type: text/plain; charset=utf-8" \
    --data-binary "$(printf "%b" "$MESSAGE")" \
    "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
fi

# Email (best-effort)
if [ -n "${ALERT_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
  printf "%b\n" "${BODY:-$SUBJECT}" | mail -s "$SUBJECT" "$ALERT_EMAIL" >/dev/null 2>&1 || true
fi

