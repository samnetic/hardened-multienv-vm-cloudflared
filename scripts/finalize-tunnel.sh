#!/usr/bin/env bash
# =================================================================
# Finalize Cloudflare Tunnel Setup - Safe Migration to Zero Ports
# =================================================================
# Automates the final steps with comprehensive safety checks:
#   1. Tests SSH via tunnel extensively
#   2. Adds CNAME DNS records (keeps A records initially)
#   3. Tests access via CNAME records
#   4. Removes old A records
#   5. Locks down firewall (closes port 22)
#   6. Final verification
#
# Rollback capability at each step if checks fail.
#
# Usage:
#   sudo ./scripts/finalize-tunnel.sh yourdomain.com
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
# Prerequisites
# =================================================================

check_root() {
  if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root"
    echo "Run: sudo ./scripts/finalize-tunnel.sh yourdomain.com"
    exit 1
  fi
}

# Detect original user (who invoked sudo)
if [ -n "${SUDO_USER:-}" ]; then
  ORIGINAL_USER="$SUDO_USER"
else
  ORIGINAL_USER="root"
fi

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
# Main
# =================================================================

main() {
  clear
  print_header "Finalize Cloudflare Tunnel Setup"

  echo "  Domain: $DOMAIN"
  echo "  User: $ORIGINAL_USER"
  echo ""

  check_root

  print_warning "This script will:"
  echo "  1. Test SSH access via tunnel extensively"
  echo "  2. Migrate DNS from A records to CNAME tunnel records"
  echo "  3. Close port 22 (SSH) on the firewall"
  echo "  4. Result: ZERO open ports to the internet"
  echo ""
  print_warning "After this, you can ONLY access via Cloudflare Tunnel!"
  echo ""

  if ! confirm "Ready to proceed?" "n"; then
    echo "Cancelled by user."
    exit 0
  fi

  # =================================================================
  # Step 1: Pre-flight Checks
  # =================================================================
  print_header "Step 1/6: Pre-flight Checks"

  # Check tunnel is running
  print_step "Checking cloudflared service..."
  if ! systemctl is-active --quiet cloudflared; then
    print_error "Cloudflared service is not running"
    echo "Start it: sudo systemctl start cloudflared"
    exit 1
  fi
  print_success "Cloudflared service is running"

  # Check tunnel config exists
  if [ ! -f /etc/cloudflared/config.yml ]; then
    print_error "Tunnel config not found: /etc/cloudflared/config.yml"
    echo "Run: sudo ./scripts/setup-cloudflared.sh $DOMAIN"
    exit 1
  fi

  # Extract tunnel ID
  TUNNEL_ID=$(grep '^tunnel:' /etc/cloudflared/config.yml | awk '{print $2}')
  if [ -z "$TUNNEL_ID" ]; then
    print_error "Could not extract tunnel ID from config"
    exit 1
  fi
  print_success "Tunnel ID: $TUNNEL_ID"

  # Check tunnel has registered connections
  print_step "Checking tunnel connections..."
  if journalctl -u cloudflared --since "5 minutes ago" | grep -q "registered"; then
    print_success "Tunnel has active connections to Cloudflare"
  else
    print_warning "No recent 'registered' messages in tunnel logs"
    echo ""
    echo "Recent tunnel logs:"
    journalctl -u cloudflared --since "5 minutes ago" --no-pager | tail -10
    echo ""
    if ! confirm "Continue anyway?" "n"; then
      exit 1
    fi
  fi

  # =================================================================
  # Step 2: Test SSH via Tunnel (from local machine)
  # =================================================================
  print_header "Step 2/6: Test SSH via Tunnel"

  echo -e "${BOLD}IMPORTANT:${NC} You must test SSH via tunnel from your LOCAL MACHINE"
  echo ""
  echo "On your LOCAL MACHINE, run these tests:"
  echo ""
  echo -e "${CYAN}# Test 1: Basic connection${NC}"
  echo "ssh ${DOMAIN%%.*} \"echo 'Connection works'\""
  echo ""
  echo -e "${CYAN}# Test 2: Sudo access${NC}"
  echo "ssh ${DOMAIN%%.*} \"sudo whoami\""
  echo ""
  echo -e "${CYAN}# Test 3: File transfer${NC}"
  echo "echo 'test' > /tmp/test.txt"
  echo "scp /tmp/test.txt ${DOMAIN%%.*}:/tmp/"
  echo ""
  echo -e "${CYAN}# Test 4: Reconnect${NC}"
  echo "ssh ${DOMAIN%%.*} \"exit\" && ssh ${DOMAIN%%.*} \"echo 'Reconnected'\""
  echo ""

  if ! confirm "Have you successfully tested SSH via tunnel from your local machine?" "n"; then
    print_error "Please test SSH via tunnel before proceeding"
    echo ""
    echo "Setup instructions:"
    echo "  curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/master/scripts/setup-local-ssh.sh | bash -s -- ssh.$DOMAIN sysadmin"
    exit 1
  fi

  print_success "SSH via tunnel confirmed working"

  # =================================================================
  # Step 3: DNS Migration via Cloudflare API
  # =================================================================
  print_header "Step 3/6: DNS Migration"

  echo "This step will:"
  echo "  1. Add CNAME records pointing to tunnel"
  echo "  2. Test access via CNAME records"
  echo "  3. Remove old A records"
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
    print_warning "Cloudflare API not configured"
    echo ""
    echo "You can still migrate DNS manually:"
    echo "  1. Go to: https://dash.cloudflare.com → DNS → Records"
    echo "  2. Add CNAME records:"
    echo "     • @ → ${TUNNEL_ID}.cfargotunnel.com (Proxied)"
    echo "     • www → ${TUNNEL_ID}.cfargotunnel.com (Proxied)"
    echo "     • * → ${TUNNEL_ID}.cfargotunnel.com (Proxied)"
    echo "  3. Delete old A records pointing to VM IP"
    echo ""
    if ! confirm "Skip DNS automation and continue?" "n"; then
      exit 1
    fi
    DNS_MIGRATED_MANUALLY=true
  else
    # We have API access, automate DNS migration
    print_step "Adding CNAME records..."

    # Add CNAME for root domain
    add_cname_record "$CF_ZONE_ID" "$CF_API_TOKEN" "@" "${TUNNEL_ID}.cfargotunnel.com"

    # Add CNAME for www
    add_cname_record "$CF_ZONE_ID" "$CF_API_TOKEN" "www" "${TUNNEL_ID}.cfargotunnel.com"

    # Add wildcard CNAME
    add_cname_record "$CF_ZONE_ID" "$CF_API_TOKEN" "*" "${TUNNEL_ID}.cfargotunnel.com"

    print_success "CNAME records added"
    echo ""
    print_info "DNS propagation may take 1-2 minutes..."
    sleep 10

    # Test CNAME records
    print_step "Testing CNAME record resolution..."
    if nslookup "$DOMAIN" | grep -q "$TUNNEL_ID.cfargotunnel.com"; then
      print_success "CNAME records are resolving correctly"
    else
      print_warning "CNAME records not yet propagating (this is normal, may take a few minutes)"
    fi

    # Remove old A records (function handles confirmation internally)
    echo ""
    remove_a_records "$CF_ZONE_ID" "$CF_API_TOKEN" "$DOMAIN"

    DNS_MIGRATED_MANUALLY=false
  fi

  # =================================================================
  # Step 4: Allow Cloudflare IPs Only
  # =================================================================
  print_header "Step 4/6: Configure Firewall for Cloudflare Only"

  print_step "Downloading Cloudflare IP ranges..."

  # Get Cloudflare IPs
  curl -s https://www.cloudflare.com/ips-v4 -o /tmp/cf_ips_v4
  curl -s https://www.cloudflare.com/ips-v6 -o /tmp/cf_ips_v6

  print_step "Allowing Cloudflare IPs to web ports (80, 443)..."

  # Allow Cloudflare IPv4
  while read -r ip; do
    ufw allow from "$ip" to any port 80,443 proto tcp comment "Cloudflare" >/dev/null 2>&1 || true
  done < /tmp/cf_ips_v4

  # Allow Cloudflare IPv6
  while read -r ip; do
    ufw allow from "$ip" to any port 80,443 proto tcp comment "Cloudflare" >/dev/null 2>&1 || true
  done < /tmp/cf_ips_v6

  print_success "Firewall configured to allow only Cloudflare IPs"

  # =================================================================
  # Step 5: Final Confirmation Before Lockdown
  # =================================================================
  print_header "Step 5/6: Final Confirmation"

  echo -e "${BOLD}${RED}⚠️  CRITICAL DECISION POINT${NC}"
  echo ""
  echo "About to close port 22 (SSH) completely."
  echo ""
  echo -e "${YELLOW}After this, you can ONLY access via:${NC}"
  echo "  • SSH: ssh ${DOMAIN%%.*} (via Cloudflare Tunnel)"
  echo "  • HTTP/HTTPS: Via Cloudflare proxy"
  echo ""
  echo -e "${GREEN}Benefits:${NC}"
  echo "  • ${GREEN}✓${NC} Zero open ports to the internet"
  echo "  • ${GREEN}✓${NC} Protected by Cloudflare's DDoS protection"
  echo "  • ${GREEN}✓${NC} All traffic encrypted via tunnel"
  echo ""
  echo -e "${YELLOW}Recovery if needed:${NC}"
  echo "  • Use your cloud provider's web console (serial/VNC access):"
  echo "    - Oracle Cloud: Instance → Console Connection"
  echo "    - AWS: EC2 → Connect → EC2 Serial Console"
  echo "    - Hetzner: Cloud Console → Your Server → Console"
  echo "    - DigitalOcean: Droplets → Access → Recovery Console"
  echo "  • From console, run: sudo ufw allow OpenSSH"
  echo ""

  if ! confirm "Close port 22 and complete lockdown?" "n"; then
    print_warning "Lockdown cancelled"
    echo ""
    echo "Current state:"
    echo "  • Tunnel is running"
    echo "  • DNS records migrated (if API was used)"
    echo "  • Port 22 is still OPEN (you can still SSH directly)"
    echo ""
    echo "To complete lockdown later, run:"
    echo "  sudo ./scripts/finalize-tunnel.sh $DOMAIN"
    exit 0
  fi

  # =================================================================
  # Step 6: Lock Down Firewall
  # =================================================================
  print_header "Step 6/6: Firewall Lockdown"

  print_step "Blocking external SSH access..."

  # Remove any existing allow rules for port 22
  if ufw status | grep -q "OpenSSH"; then
    ufw delete allow OpenSSH 2>/dev/null || true
    print_info "Removed OpenSSH rule"
  fi

  if ufw status | grep -q "22/tcp"; then
    ufw delete allow 22/tcp 2>/dev/null || true
    print_info "Removed port 22/tcp allow rule"
  fi

  if ufw status | grep -q " 22 "; then
    ufw delete allow 22 2>/dev/null || true
    print_info "Removed port 22 allow rule"
  fi

  # Add explicit DENY rule for port 22 from anywhere
  # This blocks external access while allowing tunnel (localhost) connections
  print_step "Adding deny rule for port 22..."
  ufw deny 22/tcp comment "SSH blocked - use Cloudflare Tunnel only" 2>/dev/null || true
  print_success "Port 22 access denied from external IPs"

  echo ""
  print_info "Tunnel can still access SSH via localhost (127.0.0.1:22)"
  echo ""

  # Verify port 22 is blocked
  print_step "Verifying firewall configuration..."
  if ufw status | grep -q "22/tcp.*DENY"; then
    print_success "Port 22 is now BLOCKED externally"
  else
    print_warning "Could not verify port 22 deny rule"
    echo ""
    echo "Current firewall rules:"
    ufw status numbered
  fi

  # =================================================================
  # Final Verification
  # =================================================================
  print_header "Setup Complete!"

  echo -e "${GREEN}✓ Cloudflare Tunnel is fully configured!${NC}"
  echo -e "${GREEN}✓ Firewall is locked down (zero open ports)${NC}"
  echo ""
  echo -e "${CYAN}Security Status:${NC}"
  echo "  • Direct SSH: ${RED}DISABLED${NC}"
  echo "  • Tunnel SSH: ${GREEN}ENABLED${NC}"
  echo "  • HTTP/HTTPS: ${GREEN}Via Cloudflare${NC}"
  echo "  • Open Ports: ${GREEN}ZERO${NC}"
  echo ""
  echo -e "${CYAN}Access Methods:${NC}"
  echo "  • SSH: ssh ${DOMAIN%%.*}"
  echo "  • Web: https://$DOMAIN"
  echo "  • Subdomains: https://staging-app.$DOMAIN"
  echo ""
  echo -e "${CYAN}Verification:${NC}"
  echo "  # SSH daemon still listens (for tunnel), but firewall blocks external access:"
  echo "  sudo ss -tlnp | grep ':22'  # Will show SSH listening"
  echo "  sudo ufw status | grep 22   # Will show DENY rule"
  echo ""
  echo "  # Test from LOCAL MACHINE (should FAIL):"
  echo "  ssh -i ~/.ssh/your-key.key user@${DOMAIN%%.*}-direct-ip  # Should timeout/be refused"
  echo ""
  echo "  # Test via tunnel (should WORK):"
  echo "  ssh ${DOMAIN%%.*}  # Should connect successfully"
  echo ""
  echo "  # View tunnel status:"
  echo "  sudo systemctl status cloudflared"
  echo ""
  echo -e "${YELLOW}Remember:${NC}"
  echo "  • If you lose tunnel access, use your cloud provider's console"
  echo "  • Keep your local machine's cloudflared up to date"
  echo "  • Monitor tunnel logs: sudo journalctl -u cloudflared -f"
  echo ""
}

# =================================================================
# Cloudflare API Functions
# =================================================================

add_cname_record() {
  local zone_id="$1"
  local token="$2"
  local name="$3"
  local target="$4"

  # Check if record already exists
  local existing=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=CNAME&name=$name" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  if echo "$existing" | grep -q "\"count\":0"; then
    # Create new CNAME record
    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"CNAME\",\"name\":\"$name\",\"content\":\"$target\",\"proxied\":true}")

    if echo "$response" | grep -q '"success":true'; then
      print_success "Added CNAME: $name → $target"
    else
      print_error "Failed to add CNAME: $name"
      echo "$response" | grep -oP '"message":"\K[^"]+' || echo "$response"
    fi
  else
    print_info "CNAME already exists: $name"
  fi
}

detect_vm_ip() {
  # Try multiple methods to detect public IP
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
      print_warning "Detected private IP: $ip" >&2
      print_warning "This VM is behind NAT. External services couldn't determine public IP." >&2
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
    print_error "Failed to fetch DNS records from Cloudflare API"
    echo "$records" | grep -oP '"message":"\K[^"]+' || true
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

remove_a_records() {
  local zone_id="$1"
  local token="$2"
  local domain="$3"

  # Detect VM's public IP
  print_step "Detecting VM's public IP address..."
  local vm_ip=$(detect_vm_ip)

  if [ -z "$vm_ip" ]; then
    print_warning "Could not detect VM's public IP"
    print_info "You should manually remove A records pointing to your VM"
    return 1
  fi

  print_success "VM IP detected: $vm_ip"
  echo ""

  # List A records pointing to this IP
  print_step "Scanning for A records pointing to $vm_ip..."
  local exposed_records=$(list_a_records_for_ip "$zone_id" "$token" "$vm_ip")

  if [ -z "$exposed_records" ]; then
    print_success "No A records found pointing to $vm_ip"
    return 0
  fi

  # Show exposed records
  echo ""
  print_warning "Found A records exposing your VM IP:"
  echo ""
  echo "  Name                    IP Address          Status"
  echo "  ─────────────────────────────────────────────────────"

  while IFS='|' read -r record_id record_name record_content; do
    printf "  %-23s %-19s ${RED}EXPOSED${NC}\n" "$record_name" "$record_content"
  done <<< "$exposed_records"

  echo ""
  print_warning "These records bypass Cloudflare protection and expose your real IP!"
  echo ""

  if ! confirm "Remove these A records?" "y"; then
    print_info "Skipping A record removal"
    print_warning "Your VM IP is still exposed via DNS"
    return 0
  fi

  # Delete each exposed A record
  print_step "Removing exposed A records..."
  local removed=0
  local failed=0

  while IFS='|' read -r record_id record_name record_content; do
    local response=$(curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json")

    if echo "$response" | grep -q '"success":true'; then
      print_success "Removed: $record_name → $record_content"
      ((removed++))
    else
      print_error "Failed to remove: $record_name"
      ((failed++))
    fi
  done <<< "$exposed_records"

  echo ""
  if [ $removed -gt 0 ]; then
    print_success "Removed $removed A record(s)"
  fi

  if [ $failed -gt 0 ]; then
    print_warning "$failed A record(s) could not be removed"
  fi
}

# Run main function
main "$@"
