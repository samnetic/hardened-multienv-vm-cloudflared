#!/usr/bin/env bash
# =================================================================
# Disk Usage Alert
# =================================================================
# Checks disk usage and logs warning if above threshold.
# Designed to be run via cron.
#
# Usage:
#   ./check-disk-usage.sh           # Default 85% threshold
#   ./check-disk-usage.sh 90        # Custom threshold
# =================================================================

set -euo pipefail

THRESHOLD="${1:-85}"

# Check root filesystem
USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

if [ "$USAGE" -gt "$THRESHOLD" ]; then
  MESSAGE="WARNING: Disk usage at ${USAGE}% (threshold: ${THRESHOLD}%)"
  echo "$MESSAGE"
  logger -t disk-check -p user.warning "$MESSAGE"

  # Optional alerting hook (if security tools/alerting are configured)
  if [ -x /opt/scripts/hosting-notify.sh ]; then
    /opt/scripts/hosting-notify.sh "Disk usage warning - $(hostname -f 2>/dev/null || hostname)" "$MESSAGE" || true
  fi

  # Log details to help troubleshoot
  logger -t disk-check "Top disk consumers:"
  du -h --max-depth=1 / 2>/dev/null | sort -hr | head -5 | while IFS= read -r line; do
    logger -t disk-check "  $line"
  done
fi

# Check Docker disk usage if docker is available
DOCKER=()
if command -v docker &> /dev/null; then
  if docker info &> /dev/null; then
    DOCKER=(docker)
  elif sudo docker info &> /dev/null; then
    DOCKER=(sudo docker)
  fi
fi

if [ "${#DOCKER[@]}" -gt 0 ]; then
  # Check for dangling images
  DANGLING=$("${DOCKER[@]}" images -f "dangling=true" -q 2>/dev/null | wc -l)
  if [ "$DANGLING" -gt 10 ]; then
    logger -t disk-check -p user.notice "Docker: $DANGLING dangling images - consider pruning"
  fi

  # Check for stopped containers
  STOPPED=$("${DOCKER[@]}" ps -a -f "status=exited" -q 2>/dev/null | wc -l)
  if [ "$STOPPED" -gt 10 ]; then
    logger -t disk-check -p user.notice "Docker: $STOPPED stopped containers - consider pruning"
  fi
fi
