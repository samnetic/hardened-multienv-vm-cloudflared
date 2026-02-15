#!/usr/bin/env bash
# =================================================================
# Check Docker Exposed Ports
# =================================================================
# Detects containers publishing ports to public interfaces (0.0.0.0/::).
# This is a common footgun because Docker can bypass host firewalls when
# ports are published.
#
# Expected in this blueprint:
# - No public ports
# - At most: Caddy bound to 127.0.0.1:80 (cloudflared -> localhost only)
#
# Usage:
#   ./scripts/security/check-docker-exposed-ports.sh
# =================================================================

set -euo pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  GREEN=''
  YELLOW=''
  RED=''
  BLUE=''
  NC=''
fi

print_header() {
  echo ""
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BLUE} $1${NC}"
  echo -e "${BLUE}======================================================================${NC}"
  echo ""
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

notify_if_configured() {
  local subject="$1"
  local body="${2:-}"

  if [ -x /opt/scripts/hosting-notify.sh ]; then
    /opt/scripts/hosting-notify.sh "$subject" "$body" || true
  fi
}

log_if_configured() {
  local priority="$1"
  local message="$2"

  logger -t hosting-blueprint-docker-ports -p "$priority" -- "$message" || true
}

if ! command -v docker >/dev/null 2>&1; then
  print_warning "Docker not installed (skipping port exposure check)"
  exit 0
fi

# Prefer a security-first model: humans are not in the docker group.
# If docker isn't directly accessible, fall back to sudo.
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  DOCKER=(sudo docker)
  if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
    print_warning "Docker not accessible as this user (run with sudo to check port exposure)"
    exit 0
  fi
fi

print_header "Docker Port Exposure Check"

errors=0
warnings=0
public_offenders=()
loopback_offenders=()

# Format: name<TAB>ports
while IFS=$'\t' read -r name ports; do
  # No published ports
  if [ -z "${ports:-}" ] || [ "$ports" = " " ]; then
    continue
  fi

  # Public binds (IPv4/IPv6 wildcard)
  if echo "$ports" | grep -Eq '0\.0\.0\.0:|:::|\\[::\\]:'; then
    print_error "Public port publishing detected: $name → $ports"
    errors=$((errors + 1))
    public_offenders+=("$name → $ports")
    continue
  fi

  # Loopback binds are safer, but still a footgun if you expected zero ports
  if echo "$ports" | grep -Eq '127\.0\.0\.1:'; then
    # Allowlist: Caddy should bind 127.0.0.1:80 only
    if [ "$name" = "caddy" ] && echo "$ports" | grep -Eq '127\\.0\\.0\\.1:80->80/tcp'; then
      continue
    fi
    print_warning "Loopback port publishing detected: $name → $ports"
    warnings=$((warnings + 1))
    loopback_offenders+=("$name → $ports")
  fi
done < <("${DOCKER[@]}" ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || true)

if [ "$errors" -gt 0 ]; then
  echo ""
  print_error "$errors container(s) publish ports publicly. This breaks the tunnel-only threat model."
  log_if_configured user.err "Docker public port publishing detected on $(hostname -f 2>/dev/null || hostname) ($errors container(s))"

  if [ "${#public_offenders[@]}" -gt 0 ]; then
    notify_if_configured \
      "Docker public ports detected - $(hostname -f 2>/dev/null || hostname)" \
      "$(printf "%s\n" "${public_offenders[@]}")"
  fi
  echo ""
  echo "Fix:"
  echo "  1. Remove 'ports:' from the affected compose.yml"
  echo "  2. Route traffic via Caddy (internal Docker networks)"
  echo "  3. Recreate: sudo docker compose up -d"
  exit 1
fi

if [ "$warnings" -gt 0 ]; then
  echo ""
  print_warning "$warnings container(s) publish ports to localhost. Verify this is intentional."
  log_if_configured user.warning "Docker loopback port publishing detected on $(hostname -f 2>/dev/null || hostname) ($warnings container(s))"
  exit 0
fi

print_success "No publicly published container ports detected"
