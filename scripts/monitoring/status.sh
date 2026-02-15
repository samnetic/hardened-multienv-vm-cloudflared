#!/usr/bin/env bash
# =================================================================
# System Status Dashboard
# =================================================================
# Shows system health, Docker status, and service status at a glance.
#
# Usage:
#   ./status.sh           # Full status
#   ./status.sh --quick   # Quick summary only
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

QUICK_MODE="${1:-}"

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

check_status() {
  local name=$1
  local check=$2

  if eval "$check" > /dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $name"
  else
    echo -e "  ${RED}✗${NC} $name"
  fi
}

# =================================================================
# SYSTEM INFO
# =================================================================
print_header "System Status - $(hostname)"

print_section "System Info:"
echo "  Hostname:  $(hostname)"
echo "  OS:        $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
echo "  Kernel:    $(uname -r)"
echo "  Uptime:    $(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}' | sed 's/,//')"
echo ""

# =================================================================
# RESOURCE USAGE
# =================================================================
print_section "Resource Usage:"

# CPU - using load average for portability across distributions
LOAD_AVG=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "N/A")
NUM_CPUS=$(nproc 2>/dev/null || echo 1)
echo "  Load Avg:  ${LOAD_AVG} (${NUM_CPUS} CPUs)"

# Memory
MEM_INFO=$(free -h | awk '/^Mem:/ {print $3 "/" $2 " (" int($3/$2 * 100) "%)"}')
echo "  Memory:    ${MEM_INFO}"

# Swap
SWAP_INFO=$(free -h | awk '/^Swap:/ {if ($2 != "0B" && $2 != "0") print $3 "/" $2; else print "disabled"}')
echo "  Swap:      ${SWAP_INFO}"

# Disk
DISK_INFO=$(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')
echo "  Disk (/):  ${DISK_INFO}"
echo ""

# =================================================================
# SECURITY SERVICES
# =================================================================
print_section "Security Services:"
check_status "UFW Firewall" "systemctl is-active --quiet ufw"
check_status "fail2ban" "systemctl is-active --quiet fail2ban"
check_status "auditd" "systemctl is-active --quiet auditd"
check_status "SSH" "systemctl is-active --quiet ssh || systemctl is-active --quiet sshd"
check_status "unattended-upgrades" "systemctl is-active --quiet unattended-upgrades"
check_status "chrony (NTP)" "systemctl is-active --quiet chrony || systemctl is-active --quiet chronyd"
echo ""

# =================================================================
# DOCKER STATUS
# =================================================================
print_section "Docker:"
if [ "${#DOCKER[@]}" -gt 0 ]; then
  CONTAINERS_RUNNING=$("${DOCKER[@]}" ps -q 2>/dev/null | wc -l)
  CONTAINERS_TOTAL=$("${DOCKER[@]}" ps -aq 2>/dev/null | wc -l)
  IMAGES=$("${DOCKER[@]}" images -q 2>/dev/null | wc -l)

  echo -e "  ${GREEN}✓${NC} Docker daemon running"
  echo "  Containers: ${CONTAINERS_RUNNING} running / ${CONTAINERS_TOTAL} total"
  echo "  Images:     ${IMAGES}"
else
  echo -e "  ${YELLOW}⚠${NC} Docker not accessible as this user"
  echo "    Run with sudo to include Docker status:"
  echo "      sudo $0"
fi
echo ""

# Quick mode stops here
if [ "$QUICK_MODE" = "--quick" ]; then
  exit 0
fi

# =================================================================
# DOCKER CONTAINERS BY ENVIRONMENT
# =================================================================
print_section "Containers by Environment:"

if [ "${#DOCKER[@]}" -eq 0 ]; then
  echo "  (run with sudo to view Docker containers)"
  echo ""
else
  for env in dev staging prod; do
    containers=$("${DOCKER[@]}" ps --filter "network=${env}-web" --format "{{.Names}}" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')
    if [ -n "$containers" ]; then
      echo -e "  ${GREEN}${env^^}:${NC} $containers"
    else
      echo -e "  ${YELLOW}${env^^}:${NC} (no containers)"
    fi
  done
  echo ""
fi

# =================================================================
# DOCKER NETWORKS
# =================================================================
print_section "Docker Networks:"
if [ "${#DOCKER[@]}" -gt 0 ]; then
  "${DOCKER[@]}" network ls --format "  {{.Name}}" 2>/dev/null | grep -E "dev-|staging-|prod-|monitoring" || echo "  (none found)"
else
  echo "  (run with sudo to view Docker networks)"
fi
echo ""

# =================================================================
# FAIL2BAN STATUS
# =================================================================
print_section "fail2ban Status:"
if command -v fail2ban-client &> /dev/null && systemctl is-active --quiet fail2ban; then
  BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Currently banned" | awk '{print $NF}' || echo "0")
  TOTAL_BANNED=$(fail2ban-client status sshd 2>/dev/null | grep "Total banned" | awk '{print $NF}' || echo "0")
  echo "  Currently banned IPs: ${BANNED}"
  echo "  Total banned (since restart): ${TOTAL_BANNED}"
else
  echo "  fail2ban not running"
fi
echo ""

# =================================================================
# RECENT LOGINS
# =================================================================
print_section "Recent Logins (last 5):"
last -n 5 2>/dev/null | head -5 | while IFS= read -r line; do
  echo "  $line"
done
echo ""

# =================================================================
# LISTENING PORTS
# =================================================================
print_section "Listening Ports:"
ss -tulpn 2>/dev/null | grep LISTEN | awk '{print "  " $1 " " $5}' | head -10
echo ""

# =================================================================
# QUICK COMMANDS
# =================================================================
echo -e "${BLUE}----------------------------------------------------------------------${NC}"
echo "Quick Commands:"
echo "  ./scripts/monitoring/logs.sh        # View aggregated logs"
echo "  ./scripts/monitoring/disk-usage.sh  # Detailed disk usage"
echo "  sudo docker stats --no-stream       # Container resource usage"
echo ""
