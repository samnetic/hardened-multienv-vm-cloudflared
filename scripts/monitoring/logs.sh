#!/usr/bin/env bash
# =================================================================
# Log Viewer
# =================================================================
# Aggregated log viewer for system and Docker logs.
#
# Usage:
#   ./logs.sh                    # Recent system logs
#   ./logs.sh docker             # All Docker container logs
#   ./logs.sh docker <name>      # Specific container logs
#   ./logs.sh auth               # Authentication logs
#   ./logs.sh fail2ban           # fail2ban logs
#   ./logs.sh audit              # Audit logs
#   ./logs.sh --follow           # Follow system logs
#   ./logs.sh docker --follow    # Follow Docker logs
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_TYPE="${1:-system}"
ARG2="${2:-}"

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

case "$LOG_TYPE" in
  system|--follow)
    if [ "$LOG_TYPE" = "--follow" ]; then
      print_header "System Logs (following...)"
      journalctl -f -n 50
    else
      print_header "Recent System Logs"
      journalctl -n 100 --no-pager
    fi
    ;;

  docker)
    if [ "${#DOCKER[@]}" -eq 0 ]; then
      print_header "Docker Logs"
      echo "Docker not accessible as this user."
      echo ""
      echo "Run with sudo to view container logs:"
      echo "  sudo $0 docker"
      exit 0
    fi

    if [ -n "$ARG2" ] && [ "$ARG2" != "--follow" ]; then
      # Specific container
      print_header "Logs: $ARG2"
      if [ "${3:-}" = "--follow" ]; then
        "${DOCKER[@]}" logs -f --tail 100 "$ARG2"
      else
        "${DOCKER[@]}" logs --tail 200 "$ARG2"
      fi
    else
      # All containers
      print_header "Docker Container Logs (last 20 lines each)"

      for container in $("${DOCKER[@]}" ps --format "{{.Names}}" 2>/dev/null); do
        echo -e "${CYAN}=== $container ===${NC}"
        "${DOCKER[@]}" logs --tail 20 "$container" 2>&1
        echo ""
      done

      if [ "$ARG2" = "--follow" ]; then
        echo ""
        echo -e "${YELLOW}To follow a specific container:${NC}"
        echo "  ./logs.sh docker <container-name> --follow"
      fi
    fi
    ;;

  auth)
    print_header "Authentication Logs"
    if [ -f /var/log/auth.log ]; then
      tail -100 /var/log/auth.log
    else
      journalctl -u ssh -u sshd -n 100 --no-pager
    fi
    ;;

  fail2ban)
    print_header "fail2ban Logs"
    if [ -f /var/log/fail2ban.log ]; then
      tail -100 /var/log/fail2ban.log
    else
      journalctl -u fail2ban -n 100 --no-pager
    fi
    ;;

  audit)
    print_header "Audit Logs"
    if command -v ausearch &> /dev/null; then
      ausearch -ts recent 2>/dev/null | tail -100 || echo "No recent audit events"
    else
      echo "auditd not installed"
    fi
    ;;

  security)
    print_header "Security Events Summary"

    echo -e "${CYAN}Failed SSH attempts (last 24h):${NC}"
    journalctl -u ssh -u sshd --since "24 hours ago" 2>/dev/null | grep -i "failed\|invalid" | tail -20 || echo "  None found"
    echo ""

    echo -e "${CYAN}fail2ban bans (last 24h):${NC}"
    journalctl -u fail2ban --since "24 hours ago" 2>/dev/null | grep -i "ban" | tail -20 || echo "  None found"
    echo ""

    echo -e "${CYAN}Sudo commands (last 24h):${NC}"
    journalctl --since "24 hours ago" 2>/dev/null | grep -i "sudo" | tail -20 || echo "  None found"
    ;;

  caddy)
    print_header "Caddy (Reverse Proxy) Logs"
    if [ "${#DOCKER[@]}" -eq 0 ]; then
      echo "Docker not accessible as this user."
      echo "Run with sudo to view container logs:"
      echo "  sudo $0 caddy"
      exit 0
    fi
    container=$("${DOCKER[@]}" ps --filter "name=caddy" --format "{{.Names}}" 2>/dev/null | head -1)
    if [ -n "$container" ]; then
      if [ "$ARG2" = "--follow" ]; then
        "${DOCKER[@]}" logs -f --tail 100 "$container"
      else
        "${DOCKER[@]}" logs --tail 200 "$container"
      fi
    else
      echo "Caddy container not found"
    fi
    ;;

  cloudflared)
    print_header "Cloudflared Tunnel Logs"
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
      if [ "$ARG2" = "--follow" ]; then
        journalctl -u cloudflared -f -n 50
      else
        journalctl -u cloudflared -n 100 --no-pager
      fi
    else
      if [ "${#DOCKER[@]}" -eq 0 ]; then
        echo "cloudflared not found as a systemd service, and Docker is not accessible as this user."
        echo "Run with sudo to check the cloudflared container:"
        echo "  sudo $0 cloudflared"
        exit 0
      fi
      container=$("${DOCKER[@]}" ps --filter "name=cloudflared" --format "{{.Names}}" 2>/dev/null | head -1)
      if [ -n "$container" ]; then
        if [ "$ARG2" = "--follow" ]; then
          "${DOCKER[@]}" logs -f --tail 100 "$container"
        else
          "${DOCKER[@]}" logs --tail 200 "$container"
        fi
      else
        echo "cloudflared not found (neither systemd service nor container)"
      fi
    fi
    ;;

  *)
    echo "Usage: $0 <log-type> [options]"
    echo ""
    echo "Log types:"
    echo "  system              Recent system logs (default)"
    echo "  docker              All Docker container logs"
    echo "  docker <name>       Specific container logs"
    echo "  auth                Authentication/SSH logs"
    echo "  fail2ban            fail2ban logs"
    echo "  audit               Audit logs (auditd)"
    echo "  security            Security events summary"
    echo "  caddy               Caddy reverse proxy logs"
    echo "  cloudflared         Cloudflared tunnel logs"
    echo ""
    echo "Options:"
    echo "  --follow            Follow logs in real-time"
    echo ""
    echo "Examples:"
    echo "  $0                       # Recent system logs"
    echo "  $0 docker                # All container logs"
    echo "  $0 docker myapp --follow # Follow specific container"
    echo "  $0 security              # Security events summary"
    exit 1
    ;;
esac
