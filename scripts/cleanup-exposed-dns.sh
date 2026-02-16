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

  REMOVED=0
  FAILED=0

  if [ -z "$EXPOSED_RECORDS" ]; then
    print_success "No A records found pointing to $VM_IP"
    echo ""
    print_info "Your VM IP is not exposed via DNS - good!"
    echo ""
    # Don't exit - continue to check CNAME records
  else

  # Show exposed records with numbers
  echo ""
  print_warning "Found A records exposing your VM IP:"
  echo ""
  printf "  ${BOLD}%-4s %-30s %-20s ${RED}Status${NC}\n" "#" "Name" "IP Address"
  echo "  ───────────────────────────────────────────────────────────────"

  local index=1
  declare -A RECORD_MAP
  while IFS='|' read -r record_id record_name record_content; do
    if [ -n "$record_id" ]; then
      printf "  %-4s %-30s %-20s ${RED}EXPOSED${NC}\n" "$index" "$record_name" "$record_content"
      RECORD_MAP[$index]="$record_id|$record_name|$record_content"
      ((index++))
    fi
  done <<< "$EXPOSED_RECORDS"

  local TOTAL_RECORDS=$((index - 1))

  echo ""
  echo -e "${YELLOW}⚠ Security Risk:${NC}"
  echo "  • These records bypass Cloudflare's DDoS protection"
  echo "  • Attackers can target your VM directly"
  echo "  • Your real IP is visible to anyone"
  echo ""
  print_info "All traffic should go through Cloudflare Tunnel (CNAME records)"
  echo ""

  # Selection menu
  echo -e "${BOLD}Removal Options:${NC}"
  echo "  1) Remove all exposed A records (recommended)"
  echo "  2) Select individual records to remove"
  echo "  3) Skip removal (manual cleanup later)"
  echo ""
  read -rp "Select option (1-3): " REMOVAL_OPTION

  case "$REMOVAL_OPTION" in
    1)
      print_info "Will remove all $TOTAL_RECORDS exposed record(s)"
      RECORDS_TO_REMOVE="$EXPOSED_RECORDS"
      ;;
    2)
      echo ""
      echo "Enter record numbers to remove (space-separated, e.g., 1 3 5):"
      read -rp "> " SELECTED_NUMBERS

      RECORDS_TO_REMOVE=""
      for num in $SELECTED_NUMBERS; do
        if [ -n "${RECORD_MAP[$num]}" ]; then
          RECORDS_TO_REMOVE+="${RECORD_MAP[$num]}"$'\n'
        else
          print_warning "Invalid record number: $num (skipped)"
        fi
      done

      if [ -z "$RECORDS_TO_REMOVE" ]; then
        print_error "No valid records selected"
        exit 1
      fi
      ;;
    3)
      print_warning "DNS records NOT removed"
      echo ""
      print_info "To remove manually:"
      echo "  https://dash.cloudflare.com → $DOMAIN → DNS → Records"
      exit 0
      ;;
    *)
      print_error "Invalid option"
      exit 1
      ;;
  esac

    # Delete selected A records
    echo ""
    print_step "Removing selected A records..."

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
    done <<< "$RECORDS_TO_REMOVE"

    echo ""
    print_header "A Record Cleanup Complete"

    if [ $REMOVED -gt 0 ]; then
      echo -e "${GREEN}✓ Removed $REMOVED A record(s)${NC}"
    fi

    if [ $FAILED -gt 0 ]; then
      echo -e "${RED}✗ Failed to remove $FAILED A record(s)${NC}"
    fi
  fi  # End of EXPOSED_RECORDS check

  # =================================================================
  # Step 2: Add Missing CNAME Records (Always Run)
  # =================================================================

  echo ""
  print_header "Step 2: Setup Tunnel Routing (CNAME Records)"

    # Get tunnel ID from config
    TUNNEL_ID=""
    if [ -f "/etc/cloudflared/config.yml" ]; then
      TUNNEL_ID=$(grep '^tunnel:' /etc/cloudflared/config.yml | awk '{print $2}')
    fi

    if [ -z "$TUNNEL_ID" ]; then
      print_warning "Could not detect tunnel ID from /etc/cloudflared/config.yml"
      echo ""
      read -rp "Enter your Cloudflare Tunnel ID: " TUNNEL_ID

      if [ -z "$TUNNEL_ID" ]; then
        print_error "No tunnel ID provided - cannot create CNAME records"
        echo ""
        print_info "Find your tunnel ID:"
        echo "  sudo cat /etc/cloudflared/config.yml | grep tunnel:"
        echo ""
        print_info "Then manually add CNAME records at:"
        echo "  https://dash.cloudflare.com → $DOMAIN → DNS → Records"
        exit 1
      fi
    fi

    print_success "Tunnel ID: $TUNNEL_ID"
    echo ""

    # Check which CNAME records are missing
    print_step "Checking existing CNAME records..."

    REQUIRED_CNAMES=("@" "www" "*")
    MISSING_CNAMES=()

    for cname in "${REQUIRED_CNAMES[@]}"; do
      # Query for existing CNAME record
      EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=${cname}.${DOMAIN}" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json")

      # Special handling for root domain (@)
      if [ "$cname" = "@" ]; then
        EXISTING=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=${DOMAIN}" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json")
      fi

      if echo "$EXISTING" | grep -q '"count":0'; then
        MISSING_CNAMES+=("$cname")
        print_warning "Missing: $cname → ${TUNNEL_ID}.cfargotunnel.com"
      else
        print_success "Exists: $cname"
      fi
    done

    # Add missing CNAME records
    if [ ${#MISSING_CNAMES[@]} -gt 0 ]; then
      echo ""
      echo -e "${BOLD}Missing CNAME records:${NC}"
      for cname in "${MISSING_CNAMES[@]}"; do
        if [ "$cname" = "@" ]; then
          echo "  • Root domain ($DOMAIN) → ${TUNNEL_ID}.cfargotunnel.com"
        elif [ "$cname" = "*" ]; then
          echo "  • Wildcard (*.$DOMAIN) → ${TUNNEL_ID}.cfargotunnel.com"
        else
          echo "  • $cname.$DOMAIN → ${TUNNEL_ID}.cfargotunnel.com"
        fi
      done

      echo ""
      if confirm "Add these CNAME records?" "y"; then
        print_step "Adding CNAME records..."

        for cname in "${MISSING_CNAMES[@]}"; do
          CNAME_NAME="$cname"
          if [ "$cname" = "@" ]; then
            CNAME_NAME="$DOMAIN"
          elif [ "$cname" = "*" ]; then
            CNAME_NAME="*"
          fi

          RESPONSE=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{\"type\":\"CNAME\",\"name\":\"$CNAME_NAME\",\"content\":\"${TUNNEL_ID}.cfargotunnel.com\",\"proxied\":true}")

          if echo "$RESPONSE" | grep -q '"success":true'; then
            print_success "Added: $CNAME_NAME → ${TUNNEL_ID}.cfargotunnel.com"
          else
            print_error "Failed to add: $CNAME_NAME"
            ERROR_MSG=$(echo "$RESPONSE" | grep -oP '"message":"\K[^"]+' || echo "Unknown error")
            echo "  Error: $ERROR_MSG"
          fi

          sleep 0.5
        done
      else
        print_warning "Skipped CNAME record creation"
        echo ""
        print_info "Add manually at:"
        echo "  https://dash.cloudflare.com → $DOMAIN → DNS → Records"
      fi
    else
      print_success "All required CNAME records exist!"
    fi

  # =================================================================
  # Final Summary
  # =================================================================

  echo ""
  print_header "Setup Complete"

  # Show what was done
  if [ $REMOVED -gt 0 ]; then
    echo -e "${GREEN}✓ Removed $REMOVED A record(s) exposing VM IP${NC}"
  fi

  echo -e "${GREEN}✓ DNS is configured for Cloudflare Tunnel${NC}"
  echo ""

  print_info "Your DNS configuration:"
  echo -e "  • A records pointing to VM IP: ${GREEN}NONE${NC}"
  echo -e "  • CNAME records pointing to tunnel: ${GREEN}ACTIVE${NC}"
  echo -e "  • All traffic routed through: ${GREEN}Cloudflare${NC}"
  echo ""

  print_info "Test your setup:"
  echo "  curl https://$DOMAIN"
  echo "  curl https://www.$DOMAIN"
  echo "  curl https://staging-app.$DOMAIN"
  echo "  ssh ${DOMAIN%%.*}  # SSH via tunnel"

  echo ""
}

# Run main function
main "$@"
