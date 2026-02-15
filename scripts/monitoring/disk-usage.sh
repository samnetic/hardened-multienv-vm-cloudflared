#!/usr/bin/env bash
# =================================================================
# Disk Usage Report
# =================================================================
# Shows detailed disk usage for system and Docker.
#
# Usage:
#   ./disk-usage.sh           # Full report
#   ./disk-usage.sh --docker  # Docker only
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

DOCKER_ONLY="${1:-}"

# Docker is root-equivalent. Prefer sudo (no docker group needed).
# We avoid prompting for a sudo password in this script; run it with sudo if needed.
DOCKER=(docker)
if ! docker info &>/dev/null; then
  DOCKER=(sudo -n docker)
  if ! "${DOCKER[@]}" info &>/dev/null; then
    DOCKER=()
  fi
fi

print_header() {
  echo ""
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BLUE} $1${NC}"
  echo -e "${BLUE}======================================================================${NC}"
  echo ""
}

print_section() {
  echo -e "${CYAN}$1${NC}"
  echo ""
}

# Helper to colorize percentage
colorize_percent() {
  local percent=$1
  local num=${percent%\%}

  if [ "$num" -ge 90 ]; then
    echo -e "${RED}${percent}${NC}"
  elif [ "$num" -ge 75 ]; then
    echo -e "${YELLOW}${percent}${NC}"
  else
    echo -e "${GREEN}${percent}${NC}"
  fi
}

# =================================================================
# FILESYSTEM USAGE
# =================================================================
if [ "$DOCKER_ONLY" != "--docker" ]; then
  print_header "Disk Usage Report"

  print_section "Filesystem Usage:"
  df -h | awk 'NR==1 {print "  " $0} NR>1 {print "  " $0}' | head -10
  echo ""

  print_section "Largest Directories in /:"
  du -h --max-depth=1 / 2>/dev/null | sort -hr | head -10 | awk '{print "  " $0}'
  echo ""

  print_section "Log Directory Sizes:"
  if [ -d /var/log ]; then
    du -sh /var/log/* 2>/dev/null | sort -hr | head -10 | awk '{print "  " $0}'
  fi
  echo ""
fi

# =================================================================
# DOCKER DISK USAGE
# =================================================================
print_header "Docker Disk Usage"

if [ "${#DOCKER[@]}" -gt 0 ]; then
  print_section "Docker System Overview:"
  "${DOCKER[@]}" system df 2>/dev/null | awk '{print "  " $0}'
  echo ""

  print_section "Docker System Detailed:"
  "${DOCKER[@]}" system df -v 2>/dev/null | head -50 | awk '{print "  " $0}'
  echo ""

  print_section "Images (sorted by size):"
  "${DOCKER[@]}" images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null | head -15 | awk '{print "  " $0}'
  echo ""

  print_section "Volumes:"
  "${DOCKER[@]}" volume ls --format "table {{.Name}}\t{{.Driver}}" 2>/dev/null | awk '{print "  " $0}'
  echo ""

  # Volume sizes (shown in docker system df -v above)
  # Note: Individual volume sizes are included in the detailed view above.
  # The previous approach of spawning a container per volume was too slow.

  print_section "Container Sizes:"
  "${DOCKER[@]}" ps -a --format "table {{.Names}}\t{{.Size}}\t{{.Status}}" 2>/dev/null | awk '{print "  " $0}'
  echo ""

  # =================================================================
  # CLEANUP RECOMMENDATIONS
  # =================================================================
  print_section "Cleanup Recommendations:"

  # Dangling images
  DANGLING=$("${DOCKER[@]}" images -f "dangling=true" -q 2>/dev/null | wc -l)
  if [ "$DANGLING" -gt 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} $DANGLING dangling images found"
    echo "    Run: sudo docker image prune -f"
  else
    echo -e "  ${GREEN}✓${NC} No dangling images"
  fi

  # Stopped containers
  STOPPED=$("${DOCKER[@]}" ps -a -f "status=exited" -q 2>/dev/null | wc -l)
  if [ "$STOPPED" -gt 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} $STOPPED stopped containers"
    echo "    Run: sudo docker container prune -f"
  else
    echo -e "  ${GREEN}✓${NC} No stopped containers"
  fi

  # Unused volumes
  UNUSED_VOL=$("${DOCKER[@]}" volume ls -f "dangling=true" -q 2>/dev/null | wc -l)
  if [ "$UNUSED_VOL" -gt 0 ]; then
    echo -e "  ${YELLOW}⚠${NC} $UNUSED_VOL unused volumes"
    echo "    Run: sudo docker volume prune -f"
  else
    echo -e "  ${GREEN}✓${NC} No unused volumes"
  fi

  # Build cache
  BUILD_CACHE=$("${DOCKER[@]}" system df --format "{{.Size}}" 2>/dev/null | tail -1)
  if [ -n "$BUILD_CACHE" ] && [ "$BUILD_CACHE" != "0B" ]; then
    echo -e "  ${CYAN}ℹ${NC} Build cache: $BUILD_CACHE"
    echo "    Run: sudo docker builder prune -f"
  fi

  echo ""
  echo "  Full cleanup: sudo docker system prune -a --volumes"
  echo "  (WARNING: removes all unused data)"
  echo ""

else
  echo "  Docker not accessible as this user"
  echo "  Run with sudo to include Docker disk usage:"
  echo "    sudo $0"
fi

# =================================================================
# DISK HEALTH CHECK
# =================================================================
if [ "$DOCKER_ONLY" != "--docker" ]; then
  print_header "Disk Health Check"

  ROOT_USAGE=$(df / | awk 'NR==2 {print $5}' | tr -d '%')

  if [ "$ROOT_USAGE" -ge 90 ]; then
    echo -e "${RED}CRITICAL: Root filesystem at ${ROOT_USAGE}%${NC}"
    echo ""
    echo "Recommended actions:"
    echo "  1. docker system prune -a"
    echo "  2. journalctl --vacuum-size=100M"
    echo "  3. Check /var/log for large files"
  elif [ "$ROOT_USAGE" -ge 75 ]; then
    echo -e "${YELLOW}WARNING: Root filesystem at ${ROOT_USAGE}%${NC}"
    echo ""
    echo "Consider running:"
    echo "  docker system prune"
    echo "  journalctl --vacuum-time=7d"
  else
    echo -e "${GREEN}OK: Root filesystem at ${ROOT_USAGE}%${NC}"
  fi
  echo ""
fi
