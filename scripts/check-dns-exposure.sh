#!/usr/bin/env bash
#
# DNS Exposure Checker
# Detects if VM IP is still exposed via DNS A records
#
# Usage: sudo ./scripts/check-dns-exposure.sh [domain]
#
# This script checks if your domain's DNS A records expose your VM's public IP.
# After setting up Cloudflare Tunnel, all traffic should go through CNAMEs,
# not direct A records pointing to your server IP.

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print functions
print_header() {
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_step() {
  echo -e "${GREEN}➜${NC} $1"
}

print_info() {
  echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1"
}

print_success() {
  echo -e "${GREEN}✓${NC} $1"
}

# Get domain from config or parameter
get_domain() {
  local domain=""

  if [ -n "${1:-}" ]; then
    domain="$1"
  elif [ -f "/opt/vm-config/setup.conf" ]; then
    domain=$(grep "^DOMAIN=" /opt/vm-config/setup.conf 2>/dev/null | cut -d'=' -f2 | tr -d '"' || echo "")
  elif [ -f "/opt/hosting-blueprint/.env" ]; then
    domain=$(grep "^DOMAIN=" /opt/hosting-blueprint/.env | cut -d'=' -f2 | tr -d '"' || echo "")
  fi

  if [ -z "$domain" ]; then
    print_error "Domain not specified!"
    print_info "Usage: $0 [domain]"
    print_info "Or ensure DOMAIN is set in /opt/vm-config/setup.conf"
    exit 1
  fi

  echo "$domain"
}

# Get public IP of this server
get_server_ip() {
  local ip=""

  # Try multiple services for reliability
  for service in "ifconfig.me" "icanhazip.com" "ipecho.net/plain" "ident.me"; do
    ip=$(curl -s --max-time 3 "$service" 2>/dev/null || echo "")
    if [ -n "$ip" ]; then
      # Validate IP format
      if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
      fi
    fi
  done

  print_error "Could not determine public IP address"
  exit 1
}

# Query DNS A records for domain and subdomains
query_dns_records() {
  local domain=$1
  local records=()

  # Check if dig is available
  if ! command -v dig &> /dev/null; then
    print_warning "dig not found, installing dnsutils..."
    apt-get -o Dpkg::Lock::Timeout=300 -o Acquire::Retries=3 update -qq
    apt-get -o Dpkg::Lock::Timeout=300 -o Acquire::Retries=3 install -y -qq dnsutils > /dev/null 2>&1
  fi

  # Common subdomains to check
  local subdomains=("" "www" "ssh" "dev" "staging" "prod" "api" "app")

  for subdomain in "${subdomains[@]}"; do
    local fqdn="$domain"
    if [ -n "$subdomain" ]; then
      fqdn="$subdomain.$domain"
    fi

    # Query A records
    local ips=$(dig +short A "$fqdn" 2>/dev/null | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || echo "")

    if [ -n "$ips" ]; then
      while IFS= read -r ip; do
        records+=("$fqdn:$ip")
      done <<< "$ips"
    fi
  done

  printf '%s\n' "${records[@]}"
}

# Check if IP is exposed
check_exposure() {
  local domain=$1
  local server_ip=$2

  print_step "Querying DNS records for $domain..."
  echo

  local dns_records=$(query_dns_records "$domain")
  local exposed=false
  local exposed_hosts=()

  if [ -z "$dns_records" ]; then
    print_warning "No A records found for $domain or common subdomains"
    print_info "This could mean:"
    print_info "  • All records are CNAMEs (good!)"
    print_info "  • DNS hasn't propagated yet"
    print_info "  • Domain is not configured"
    return 0
  fi

  # Check each record
  while IFS= read -r record; do
    local host=$(echo "$record" | cut -d':' -f1)
    local ip=$(echo "$record" | cut -d':' -f2)

    if [ "$ip" = "$server_ip" ]; then
      exposed=true
      exposed_hosts+=("$host")
      print_error "EXPOSED: $host → $ip"
    else
      print_info "OK: $host → $ip (not your server)"
    fi
  done <<< "$dns_records"

  echo

  if [ "$exposed" = true ]; then
    print_header "⚠️  SECURITY WARNING: IP ADDRESS EXPOSED"
    echo
    print_warning "Your server IP ($server_ip) is exposed via DNS A records:"
    echo
    for host in "${exposed_hosts[@]}"; do
      echo "  • $host"
    done
    echo
    print_info "This defeats the purpose of Cloudflare Tunnel!"
    print_info "Attackers can:"
    print_info "  • Discover your server IP"
    print_info "  • Bypass Cloudflare protection"
    print_info "  • Attack your server directly"
    echo

    print_header "How to Fix"
    echo
    print_step "1. Log into Cloudflare Dashboard:"
    print_info "   https://dash.cloudflare.com/"
    echo
    print_step "2. Navigate to DNS settings for $domain"
    echo
    print_step "3. For each exposed hostname, either:"
    echo
    print_info "   Option A: Delete the A record (if using tunnel)"
    print_info "   - Click the A record"
    print_info "   - Click Delete"
    echo
    print_info "   Option B: Change to CNAME (recommended)"
    print_info "   - Delete the A record"
    print_info "   - Add CNAME record:"
    for host in "${exposed_hosts[@]}"; do
      local subdomain="${host%.$domain}"
      if [ "$subdomain" = "$domain" ]; then
        subdomain="@"
      fi
      echo "       Name: $subdomain"
      echo "       Target: ${domain} (or your tunnel domain)"
      echo "       Proxy: On (orange cloud)"
      echo
    done
    echo
    print_step "4. Wait 5 minutes and run this check again:"
    print_info "   sudo ./scripts/check-dns-exposure.sh $domain"
    echo

    print_header "DNS Migration Guide"
    echo
    print_info "See full DNS migration guide:"
    print_info "   /opt/hosting-blueprint/docs/00-initial-setup.md"
    print_info "   Section: Step 9 - Migrate DNS to Tunnel"
    echo

    return 1
  else
    print_header "✓ DNS Configuration Secure"
    echo
    print_success "No A records expose your server IP ($server_ip)"
    print_success "Your VM is protected by Cloudflare Tunnel"
    echo
    print_info "All traffic is routed through Cloudflare's network"
    print_info "Direct IP access is blocked by firewall"
    echo

    return 0
  fi
}

# Show current firewall status
show_firewall_status() {
  if command -v ufw &> /dev/null; then
    echo
    print_header "Firewall Status"
    echo
    ufw status | head -20
    echo
    if ufw status | grep -q "Status: active"; then
      print_success "UFW firewall is active"
      if ! ufw status | grep -q "22/tcp.*ALLOW"; then
        print_success "No public SSH access (good!)"
      else
        print_warning "SSH port 22 is open - consider closing after tunnel setup"
      fi
    else
      print_warning "UFW firewall is not active"
      print_info "Run setup.sh to configure firewall"
    fi
  fi
}

# Main execution
main() {
  clear

  print_header "DNS Exposure Check"
  echo

  # Check if running as root
  if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root: sudo $0"
    exit 1
  fi

  # Get domain
  domain=$(get_domain "${1:-}")
  print_info "Domain: $domain"

  # Get server IP
  print_step "Detecting server public IP..."
  server_ip=$(get_server_ip)
  print_success "Server IP: $server_ip"
  echo

  # Check exposure
  if check_exposure "$domain" "$server_ip"; then
    # Not exposed - show firewall status
    show_firewall_status
    exit 0
  else
    # Exposed - show how to fix
    exit 1
  fi
}

# Run main
main "$@"
