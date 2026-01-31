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

  # Log details to help troubleshoot
  logger -t disk-check "Top disk consumers:"
  du -h --max-depth=1 / 2>/dev/null | sort -hr | head -5 | while IFS= read -r line; do
    logger -t disk-check "  $line"
  done
fi

# Check Docker disk usage if docker is available
if command -v docker &> /dev/null && docker info &> /dev/null; then
  # Check for dangling images
  DANGLING=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
  if [ "$DANGLING" -gt 10 ]; then
    logger -t disk-check -p user.notice "Docker: $DANGLING dangling images - consider pruning"
  fi

  # Check for stopped containers
  STOPPED=$(docker ps -a -f "status=exited" -q 2>/dev/null | wc -l)
  if [ "$STOPPED" -gt 10 ]; then
    logger -t disk-check -p user.notice "Docker: $STOPPED stopped containers - consider pruning"
  fi
fi
