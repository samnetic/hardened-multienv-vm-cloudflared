#!/usr/bin/env bash
# =================================================================
# Cleanup Exposed DNS Records
# =================================================================
# Detects and removes A records that expose your VM's real IP
#
# This is a security measure to ensure all traffic goes through
# Cloudflare Tunnel instead of directly to your VM.
#
# Usage:
#   sudo ./scripts/cleanup-exposed-dns.sh yourdomain.com
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
# Parse Arguments
# =================================================================

if [ $# -lt 1 ]; then
  print_error "Domain name required"
  echo "Usage: sudo $0 yourdomain.com"
  exit 1
fi

DOMAIN="$1"

# =================================================================
# IP Detection Functions
# =================================================================

detect_vm_ip() {
  local ip=""

  # Method 1: Query Cloudflare (most reliable for public IP)
  ip=$(curl -s --max-time 5 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -oP 'ip=\K[0-9.]+')

  # Method 2: Query ipify.org
  if [ -z "$ip" ]; then
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
  fi

  # Method 3: Query ifconfig.me
  if [ -z "$ip" ]; then
    ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
  fi

  # Method 4: Check default route (fallback, may return private IP on NAT)
  if [ -z "$ip" ]; then
    ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+')
  fi

  # Validate it's a public IP (not private range)
  if [ -n "$ip" ]; then
    # Check if it's a private IP range (10.x, 172.16-31.x, 192.168.x)
    if [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || [[ "$ip" =~ ^192\.168\. ]]; then
      # It's private, warn user
      echo "" >&2
      echo -e "${YELLOW}⚠ Detected private IP: $ip${NC}" >&2
      echo -e "${YELLOW}This VM is behind NAT. External services couldn't determine public IP.${NC}" >&2
      echo "" >&2
      read -rp "Enter your VM's public IP address: " public_ip
      ip="$public_ip"
    fi
  fi

  echo "$ip"
}

list_a_records_for_ip() {
  local zone_id="$1"
  local token="$2"
  local target_ip="$3"

  # Get all A records for the zone
  local records=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  # Check if request succeeded
  if ! echo "$records" | grep -q '"success":true'; then
    print_error "Failed to fetch DNS records from Cloudflare API" >&2
    echo "$records" | grep -oP '"message":"\K[^"]+' >&2 || true
    return 1
  fi

  # Parse JSON to find records pointing to target IP
  # Format: id|name|content
  # Use Python if available (more robust), otherwise grep
  if command -v python3 &> /dev/null; then
    echo "$records" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    target_ip = '$target_ip'
    for record in data.get('result', []):
        if record.get('type') == 'A' and record.get('content') == target_ip:
            print(f\"{record['id']}|{record['name']}|{record['content']}\")
except Exception as e:
    pass
"
  else
    # Fallback to grep-based parsing (less robust but works without Python)
    # Extract the "result" array and parse each record
    local result_array=$(echo "$records" | grep -oP '"result":\[\K[^]]+(?=\])')

    if [ -z "$result_array" ]; then
      return 0  # No records found
    fi

    # Split by record objects and parse each
    echo "$result_array" | grep -o '{[^}]*"type":"A"[^}]*}' | while IFS= read -r record; do
      local record_id=$(echo "$record" | grep -oP '"id":"\K[^"]+')
      local record_name=$(echo "$record" | grep -oP '"name":"\K[^"]+')
      local record_content=$(echo "$record" | grep -oP '"content":"\K[^"]+')

      if [ "$record_content" = "$target_ip" ]; then
        echo "$record_id|$record_name|$record_content"
      fi
    done
  fi
}

# =================================================================
# Main
# =================================================================

main() {
  clear
  print_header "Cleanup Exposed DNS Records"

  echo "  Domain: $DOMAIN"
  echo ""

  # Source Cloudflare API helper
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ ! -f "$SCRIPT_DIR/cloudflare-api-setup.sh" ]; then
    print_error "cloudflare-api-setup.sh not found"
    exit 1
  fi
  source "$SCRIPT_DIR/cloudflare-api-setup.sh"

  # Setup or load API token
  if ! setup_cloudflare_api "$DOMAIN"; then
    print_error "Cloudflare API configuration failed"
    echo ""
    echo "Manual cleanup:"
    echo "  1. Go to: https://dash.cloudflare.com → DNS → Records"
    echo "  2. Look for A records pointing to your VM IP"
    echo "  3. Delete them (keep CNAME records for tunnel)"
    exit 1
  fi

  # Detect VM's public IP
  print_step "Detecting VM's public IP address..."
  VM_IP=$(detect_vm_ip)

  if [ -z "$VM_IP" ]; then
    print_error "Could not detect VM's public IP"
    echo ""
    print_info "Try running these commands to find your IP:"
    echo "  curl https://api.ipify.org"
    echo "  curl https://ifconfig.me"
    exit 1
  fi

  print_success "VM IP detected: $VM_IP"
  echo ""

  # List A records pointing to this IP
  print_step "Scanning DNS records for $DOMAIN..."
  EXPOSED_RECORDS=$(list_a_records_for_ip "$CF_ZONE_ID" "$CF_API_TOKEN" "$VM_IP")

  if [ -z "$EXPOSED_RECORDS" ]; then
    print_success "No A records found pointing to $VM_IP"
    echo ""
    print_success "Your VM IP is not exposed via DNS!"
    echo ""
    print_info "All traffic should be going through Cloudflare Tunnel"
    exit 0
  fi

  # Show exposed records
  echo ""
  print_warning "Found A records exposing your VM IP:"
  echo ""
  printf "  ${BOLD}%-30s %-20s ${RED}Status${NC}\n" "Name" "IP Address"
  echo "  ────────────────────────────────────────────────────────────"

  while IFS='|' read -r record_id record_name record_content; do
    printf "  %-30s %-20s ${RED}EXPOSED${NC}\n" "$record_name" "$record_content"
  done <<< "$EXPOSED_RECORDS"

  echo ""
  echo -e "${YELLOW}⚠ Security Risk:${NC}"
  echo "  • These records bypass Cloudflare's DDoS protection"
  echo "  • Attackers can target your VM directly"
  echo "  • Your real IP is visible to anyone"
  echo ""
  print_info "All traffic should go through Cloudflare Tunnel (CNAME records)"
  echo ""

  if ! confirm "Remove these A records?" "y"; then
    print_warning "DNS records NOT removed"
    echo ""
    print_info "To remove manually:"
    echo "  https://dash.cloudflare.com → $DOMAIN → DNS → Records"
    exit 0
  fi

  # Delete each exposed A record
  print_step "Removing exposed A records..."
  REMOVED=0
  FAILED=0

  while IFS='|' read -r record_id record_name record_content; do
    # Skip empty lines
    if [ -z "$record_id" ]; then
      continue
    fi

    print_info "Deleting: $record_name..."

    RESPONSE=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$record_id" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json")

    if echo "$RESPONSE" | grep -q '"success":true'; then
      print_success "Removed: $record_name → $record_content"
      ((REMOVED++))
    else
      print_error "Failed to remove: $record_name"
      ERROR_MSG=$(echo "$RESPONSE" | grep -oP '"message":"\K[^"]+' || echo "Unknown error")
      echo "  Error: $ERROR_MSG"
      ((FAILED++))
    fi

    # Small delay between API calls
    sleep 0.5
  done <<< "$EXPOSED_RECORDS"

  echo ""
  print_header "Cleanup Complete"

  if [ $REMOVED -gt 0 ]; then
    echo -e "${GREEN}✓ Removed $REMOVED A record(s)${NC}"
  fi

  if [ $FAILED -gt 0 ]; then
    echo -e "${RED}✗ Failed to remove $FAILED A record(s)${NC}"
  fi

  if [ $REMOVED -gt 0 ] && [ $FAILED -eq 0 ]; then
    echo ""
    print_success "Your VM IP is no longer exposed!"
    echo ""
    print_info "All traffic now flows through Cloudflare Tunnel"
  fi

  echo ""
}

# Run main function
main "$@"
