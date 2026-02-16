#!/usr/bin/env bash
# =================================================================
# Add Subdomain Route
# =================================================================
# Easily add a new subdomain → container route through the
# Caddy reverse proxy and Cloudflare Tunnel.
#
# Usage:
#   sudo ./scripts/add-subdomain.sh                        # Interactive
#   sudo ./scripts/add-subdomain.sh grafana.example.com grafana:3000
#   sudo ./scripts/add-subdomain.sh grafana.example.com grafana:3000 monitoring
#
# What this does:
#   1. Adds an ingress rule to the Caddyfile
#   2. Optionally routes DNS via cloudflared
#   3. Reloads Caddy to apply changes
# =================================================================

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/opt/vm-config/setup.conf"
CADDYFILE="/srv/infrastructure/reverse-proxy/Caddyfile"

# =================================================================
# Helper Functions
# =================================================================

print_header() {
  echo ""
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BLUE}${BOLD} $1${NC}"
  echo -e "${BLUE}======================================================================${NC}"
  echo ""
}

print_step() {
  echo -e "${CYAN}>>> $1${NC}"
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
  echo -e "${RED}✗ $1${NC}"
}

print_info() {
  echo -e "${BLUE}ℹ $1${NC}"
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"

  if [ "$default" = "y" ]; then
    prompt="$prompt [Y/n]: "
  else
    prompt="$prompt [y/N]: "
  fi

  read -rp "$prompt" response
  response=${response:-$default}

  [[ "$response" =~ ^[Yy]$ ]]
}

# =================================================================
# Validation
# =================================================================

validate_hostname() {
  local h="$1"
  if [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && [[ "$h" == *.* ]]; then
    return 0
  fi
  return 1
}

validate_upstream() {
  local u="$1"
  # Format: container_name:port
  if [[ "$u" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*:[0-9]+$ ]]; then
    return 0
  fi
  return 1
}

# =================================================================
# Main
# =================================================================

main() {
  print_header "Add Subdomain Route"

  # Check root
  if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root (sudo)"
    echo "  sudo $0"
    exit 1
  fi

  # Check Caddyfile exists
  if [ ! -f "$CADDYFILE" ]; then
    print_error "Caddyfile not found at: $CADDYFILE"
    print_info "Run the setup first or ensure /srv/infrastructure is initialized."
    exit 1
  fi

  # Load domain from config if available
  local DOMAIN=""
  if [ -f "$CONFIG_FILE" ]; then
    DOMAIN="$(grep -E '^DOMAIN=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)"
  fi

  # Parse arguments or prompt interactively
  local HOSTNAME="${1:-}"
  local UPSTREAM="${2:-}"
  local NETWORK="${3:-monitoring}"

  if [ -z "$HOSTNAME" ]; then
    echo "This tool adds a new subdomain route to your reverse proxy."
    echo ""
    if [ -n "$DOMAIN" ]; then
      echo "Your configured domain: $DOMAIN"
      echo ""
      echo "Examples:"
      echo "  grafana.$DOMAIN  →  grafana:3000"
      echo "  prometheus.$DOMAIN  →  prometheus:9090"
      echo "  myapp.$DOMAIN  →  myapp:8080"
      echo ""
    fi

    read -rp "Full hostname (e.g., grafana.example.com): " HOSTNAME
    while [ -z "$HOSTNAME" ] || ! validate_hostname "$HOSTNAME"; do
      if [ -z "$HOSTNAME" ]; then
        print_error "Hostname is required"
      else
        print_error "Invalid hostname: '$HOSTNAME'"
      fi
      read -rp "Full hostname: " HOSTNAME
    done
  fi

  HOSTNAME="$(echo "$HOSTNAME" | tr '[:upper:]' '[:lower:]')"

  if ! validate_hostname "$HOSTNAME"; then
    print_error "Invalid hostname: '$HOSTNAME'"
    exit 1
  fi

  if [ -z "$UPSTREAM" ]; then
    echo ""
    echo "Enter the container name and port the subdomain should route to."
    echo "Format: container_name:port"
    echo ""
    read -rp "Upstream (e.g., grafana:3000): " UPSTREAM
    while [ -z "$UPSTREAM" ] || ! validate_upstream "$UPSTREAM"; do
      if [ -z "$UPSTREAM" ]; then
        print_error "Upstream is required"
      else
        print_error "Invalid format: '$UPSTREAM' (expected: container:port)"
      fi
      read -rp "Upstream (e.g., grafana:3000): " UPSTREAM
    done
  fi

  if ! validate_upstream "$UPSTREAM"; then
    print_error "Invalid upstream format: '$UPSTREAM' (expected: container:port)"
    exit 1
  fi

  local CONTAINER_NAME="${UPSTREAM%%:*}"
  local CONTAINER_PORT="${UPSTREAM##*:}"

  if [ -z "$3" ]; then
    echo ""
    echo "Which Docker network is the container on?"
    echo "  Common networks: monitoring, prod-web, staging-web, dev-web"
    echo ""
    read -rp "Network [monitoring]: " NETWORK
    NETWORK="${NETWORK:-monitoring}"
  fi

  # Show summary
  echo ""
  echo -e "${CYAN}Route Summary:${NC}"
  echo "  Hostname:   https://${HOSTNAME}"
  echo "  Upstream:    ${CONTAINER_NAME}:${CONTAINER_PORT}"
  echo "  Network:     ${NETWORK}"
  echo ""

  if ! confirm "Add this route?" "y"; then
    echo "Cancelled."
    exit 0
  fi

  # Check if route already exists
  if grep -qF "http://${HOSTNAME}" "$CADDYFILE"; then
    print_warning "A route for ${HOSTNAME} already exists in the Caddyfile!"
    if ! confirm "Add another block anyway?"; then
      exit 0
    fi
  fi

  # =================================================================
  # Step 1: Add Caddyfile entry
  # =================================================================
  print_step "Adding route to Caddyfile..."

  # Insert before the wildcard catch-all block
  # Find the line number of the catch-all and insert before it
  local CATCHALL_LINE=""
  CATCHALL_LINE="$(grep -n '^http://\*\.' "$CADDYFILE" | head -1 | cut -d: -f1 || true)"

  if [ -n "$CATCHALL_LINE" ]; then
    # Walk backwards from the catch-all to find start of its comment/blank section
    local INSERT_BEFORE="$CATCHALL_LINE"
    while [ "$INSERT_BEFORE" -gt 1 ]; do
      local prev_line
      prev_line="$(sed -n "$((INSERT_BEFORE - 1))p" "$CADDYFILE")"
      if [ -z "$prev_line" ] || [[ "$prev_line" == \#* ]]; then
        INSERT_BEFORE=$((INSERT_BEFORE - 1))
      else
        break
      fi
    done

    # Write new block to a temp file, then splice it into the Caddyfile
    local TMPFILE
    TMPFILE="$(mktemp)"
    cat > "$TMPFILE" << EOF

# ${CONTAINER_NAME} - Added $(date '+%Y-%m-%d')
http://${HOSTNAME} {
  import tunnel_only
  import security_headers
  reverse_proxy ${CONTAINER_NAME}:${CONTAINER_PORT} {
    import proxy_headers
  }
}
EOF

    {
      head -n "$((INSERT_BEFORE - 1))" "$CADDYFILE"
      cat "$TMPFILE"
      echo ""
      tail -n "+${INSERT_BEFORE}" "$CADDYFILE"
    } > "${CADDYFILE}.tmp"
    mv "${CADDYFILE}.tmp" "$CADDYFILE"
    rm -f "$TMPFILE"
  else
    # No catch-all found, append to end
    cat >> "$CADDYFILE" << EOF

# ${CONTAINER_NAME} - Added $(date '+%Y-%m-%d')
http://${HOSTNAME} {
  import tunnel_only
  import security_headers
  reverse_proxy ${CONTAINER_NAME}:${CONTAINER_PORT} {
    import proxy_headers
  }
}
EOF
  fi

  print_success "Route added to Caddyfile"

  # =================================================================
  # Step 2: Ensure network exists on Caddy container
  # =================================================================
  print_step "Checking if Caddy is connected to '${NETWORK}' network..."

  if docker network ls --format '{{.Name}}' | grep -qx "$NETWORK"; then
    # Check if caddy container is connected to this network
    if docker container inspect caddy >/dev/null 2>&1; then
      local CONNECTED=""
      CONNECTED="$(docker container inspect caddy --format '{{range $key, $_ := .NetworkSettings.Networks}}{{$key}} {{end}}' 2>/dev/null || true)"
      if echo "$CONNECTED" | grep -qw "$NETWORK"; then
        print_success "Caddy is already connected to '${NETWORK}' network"
      else
        print_step "Connecting Caddy to '${NETWORK}' network..."
        docker network connect "$NETWORK" caddy 2>/dev/null || true
        print_success "Connected Caddy to '${NETWORK}' network"
      fi
    else
      print_warning "Caddy container not running. Connect the network after starting Caddy."
    fi
  else
    print_warning "Network '${NETWORK}' doesn't exist yet."
    print_info "It will be created when you start the container's compose stack."
    print_info "Then run: sudo docker network connect ${NETWORK} caddy"
  fi

  # =================================================================
  # Step 3: Validate and reload Caddy
  # =================================================================
  print_step "Validating Caddyfile..."

  if docker container inspect caddy >/dev/null 2>&1; then
    if docker exec caddy caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
      print_success "Caddyfile is valid"

      print_step "Reloading Caddy..."
      docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || \
        docker restart caddy 2>/dev/null || true
      print_success "Caddy reloaded"
    else
      print_warning "Caddyfile validation failed. Caddy NOT reloaded."
      print_info "Fix the Caddyfile and restart manually:"
      print_info "  sudo docker compose -f /srv/infrastructure/reverse-proxy/compose.yml restart"
    fi
  else
    print_warning "Caddy container not running. Start it with:"
    print_info "  cd /srv/infrastructure/reverse-proxy && sudo docker compose --compatibility up -d"
  fi

  # =================================================================
  # Step 4: DNS routing (optional)
  # =================================================================
  echo ""
  if command -v cloudflared >/dev/null 2>&1; then
    local TUNNEL_NAME=""
    TUNNEL_NAME="$(cloudflared tunnel list 2>/dev/null | awk 'NR>1 && $2!="" {print $2; exit}' || true)"

    if [ -n "$TUNNEL_NAME" ]; then
      echo "Detected tunnel: $TUNNEL_NAME"
      echo ""

      if confirm "Add DNS route for ${HOSTNAME} via cloudflared?" "y"; then
        print_step "Routing DNS..."
        local route_out="" route_rc=0
        route_out="$(cloudflared tunnel route dns "$TUNNEL_NAME" "$HOSTNAME" 2>&1)" || route_rc=$?
        if echo "$route_out" | grep -qi "already exists"; then
          print_warning "DNS route for ${HOSTNAME} already exists"
        elif [ "$route_rc" -ne 0 ]; then
          print_warning "DNS routing failed. Add manually in Cloudflare dashboard."
          echo "  $route_out"
        else
          print_success "DNS route created: ${HOSTNAME} → tunnel"
        fi
      fi
    else
      print_info "No active tunnel found. Add DNS CNAME manually in Cloudflare."
    fi
  else
    print_info "cloudflared not installed. Add DNS CNAME manually in Cloudflare dashboard."
  fi

  # =================================================================
  # Done
  # =================================================================
  print_header "Done!"

  echo -e "${GREEN}Route added successfully!${NC}"
  echo ""
  echo -e "  ${BOLD}https://${HOSTNAME}${NC}  →  ${CONTAINER_NAME}:${CONTAINER_PORT}"
  echo ""
  echo -e "${CYAN}Checklist:${NC}"
  echo "  [✓] Caddyfile updated"

  if docker container inspect caddy >/dev/null 2>&1; then
    echo "  [✓] Caddy reloaded"
  else
    echo "  [ ] Start Caddy: cd /srv/infrastructure/reverse-proxy && sudo docker compose up -d"
  fi

  echo "  [ ] Ensure container '${CONTAINER_NAME}' is running on '${NETWORK}' network"
  echo "  [ ] Ensure DNS CNAME for '${HOSTNAME}' points to your tunnel"
  echo "  [ ] (Optional) Add Cloudflare Access policy to protect this subdomain"
  echo ""
}

# Run
main "$@"
