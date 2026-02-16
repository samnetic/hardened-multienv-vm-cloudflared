#!/usr/bin/env bash
# =================================================================
# Cloudflare API Token Setup & Validation
# =================================================================
# Creates and validates a comprehensive Cloudflare API token
#
# This token is used for:
#   - DNS management (tunnel routing)
#   - SSL/TLS configuration
#   - Zone settings
#
# Usage:
#   source ./scripts/cloudflare-api-setup.sh
#   setup_cloudflare_api "yourdomain.com"
# =================================================================

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Token storage
TOKEN_DIR="/root/.cloudflare"
TOKEN_FILE="$TOKEN_DIR/api-token"

# =================================================================
# Helper Functions
# =================================================================

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

# =================================================================
# Token Creation Guide
# =================================================================

show_token_creation_guide() {
  local domain="$1"

  echo ""
  echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${CYAN}║  Create Cloudflare API Token for Automation                 ║${NC}"
  echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BLUE}ℹ ${NC} Following security best practice: separate token for automation"
  echo -e "${BLUE}ℹ ${NC} This token is different from your tunnel token (principle of least privilege)"
  echo ""
  echo -e "${BOLD}Quick Instructions:${NC}"
  echo ""
  echo -e "1. ${CYAN}Open:${NC} https://dash.cloudflare.com/profile/api-tokens"
  echo ""
  echo -e "2. ${CYAN}Click:${NC} Create Token → Create Custom Token"
  echo ""
  echo -e "3. ${CYAN}Name:${NC} Automation - ${domain}"
  echo ""
  echo -e "4. ${CYAN}Add these permissions:${NC}"
  echo ""
  echo -e "   ${GREEN}✓${NC} Zone | DNS | ${BOLD}Edit${NC}"
  echo -e "   ${GREEN}✓${NC} Zone | SSL and Certificates | ${BOLD}Edit${NC}"
  echo -e "   ${GREEN}✓${NC} Zone | Zone Settings | ${BOLD}Edit${NC}"
  echo -e "   ${GREEN}✓${NC} Zone | Zone | ${BOLD}Read${NC}"
  echo ""
  echo -e "5. ${CYAN}Zone Resources:${NC} Include → Specific zone → ${BOLD}${domain}${NC}"
  echo ""
  echo -e "6. ${CYAN}Finish:${NC} Continue to summary → Create Token"
  echo ""
  echo -e "7. ${RED}${BOLD}COPY THE TOKEN${NC} (shown only once!)"
  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "${GREEN}Why separate tokens?${NC}"
  echo -e "  • ${GREEN}✓${NC} Principle of least privilege (each token does one thing)"
  echo -e "  • ${GREEN}✓${NC} If tunnel token leaks, SSL settings remain secure"
  echo -e "  • ${GREEN}✓${NC} Easier to audit and rotate tokens independently"
  echo ""
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

# =================================================================
# Token Validation
# =================================================================

validate_token() {
  local token="$1"
  local domain="$2"

  print_step "Validating API token..."

  # Test token with verify endpoint
  local verify_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  if ! echo "$verify_response" | grep -q '"success":true'; then
    print_error "Token validation failed"
    echo "$verify_response" | grep -oP '"message":"\K[^"]+' || echo "$verify_response"
    return 1
  fi

  print_success "Token is valid"

  # Get Zone ID
  print_step "Getting Zone ID for $domain..."

  local zone_response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$domain" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json")

  local zone_id=$(echo "$zone_response" | grep -oP '"id":"\K[^"]+' | head -1)

  if [ -z "$zone_id" ]; then
    print_error "Could not get Zone ID for $domain"
    print_warning "Make sure the token has access to this zone"
    return 1
  fi

  print_success "Zone ID: $zone_id"

  # Export for use by caller
  export CF_ZONE_ID="$zone_id"
  export CF_API_TOKEN="$token"

  return 0
}

# =================================================================
# Token Storage
# =================================================================

save_token() {
  local token="$1"
  local domain="$2"

  mkdir -p "$TOKEN_DIR"
  chmod 700 "$TOKEN_DIR"

  # Store token with domain info
  cat > "$TOKEN_FILE" << EOF
# Cloudflare API Token
# Domain: $domain
# Created: $(date -Iseconds)
# DO NOT SHARE THIS FILE
$token
EOF

  chmod 600 "$TOKEN_FILE"
  print_success "Token saved securely to $TOKEN_FILE"
}

load_token() {
  if [ -f "$TOKEN_FILE" ]; then
    # Extract token (skip comment lines)
    CF_API_TOKEN=$(grep -v '^#' "$TOKEN_FILE" | tr -d '\n' | xargs)
    export CF_API_TOKEN
    return 0
  fi
  return 1
}

# =================================================================
# Main Setup Function
# =================================================================

setup_cloudflare_api() {
  local domain="$1"

  echo ""
  echo -e "${BOLD}${BLUE}Cloudflare API Setup${NC}"
  echo ""

  # Check if token already exists
  if load_token; then
    print_info "Existing API token found"
    echo ""
    read -rp "Use existing token? (yes/no): " use_existing

    if [ "$use_existing" = "yes" ]; then
      if validate_token "$CF_API_TOKEN" "$domain"; then
        print_success "Using existing token"
        return 0
      else
        print_warning "Existing token is invalid, will create new one"
      fi
    fi
  fi

  # Show creation guide
  show_token_creation_guide "$domain"

  # Prompt for token
  echo -e "${CYAN}Paste your Cloudflare API token (or press Enter to skip):${NC}"
  echo -e "${BLUE}ℹ ${NC} Token won't be visible as you paste (security feature)"
  echo ""
  read -rsp "> " token
  echo ""
  echo ""

  if [ -z "$token" ]; then
    print_warning "No token provided - skipping API configuration"
    echo ""
    print_info "You can configure SSL/TLS manually at:"
    echo "  https://dash.cloudflare.com → $domain → SSL/TLS → Overview"
    echo "  Set Encryption mode to: Full"
    echo ""
    return 1
  fi

  print_step "Validating token..."

  # Validate token
  if ! validate_token "$token" "$domain"; then
    return 1
  fi

  # Save token
  save_token "$token" "$domain"

  echo ""
  print_success "Cloudflare API setup complete!"
  echo ""
  print_info "Token stored securely at: $TOKEN_FILE"
  print_info "This token will be reused for all future SSL/TLS operations"
  echo ""
  echo -e "${CYAN}Next: Configuring SSL/TLS settings automatically...${NC}"
  echo ""

  return 0
}

# =================================================================
# Cloudflare API Operations
# =================================================================

# Set SSL/TLS mode to Full (recommended; avoids "Flexible" downgrade footguns)
set_ssl_full() {
  local zone_id="$1"
  local token="$2"

  print_step "Setting SSL/TLS mode to Full..."

  local ssl_response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/settings/ssl" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data '{"value":"full"}')

  if echo "$ssl_response" | grep -q '"success":true'; then
    print_success "SSL/TLS mode set to Full"
    return 0
  else
    print_error "Failed to set SSL/TLS mode"
    echo "$ssl_response" | grep -oP '"message":"\K[^"]+' || echo "$ssl_response"
    return 1
  fi
}

# Enable Always Use HTTPS
enable_always_https() {
  local zone_id="$1"
  local token="$2"

  print_step "Enabling 'Always Use HTTPS'..."

  local response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/settings/always_use_https" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data '{"value":"on"}')

  if echo "$response" | grep -q '"success":true'; then
    print_success "'Always Use HTTPS' enabled"
    return 0
  else
    print_warning "Could not enable 'Always Use HTTPS' (may already be enabled)"
    return 0
  fi
}

# Enable Automatic HTTPS Rewrites
enable_auto_https_rewrites() {
  local zone_id="$1"
  local token="$2"

  print_step "Enabling 'Automatic HTTPS Rewrites'..."

  local response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/settings/automatic_https_rewrites" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data '{"value":"on"}')

  if echo "$response" | grep -q '"success":true'; then
    print_success "'Automatic HTTPS Rewrites' enabled"
    return 0
  else
    print_warning "Could not enable 'Automatic HTTPS Rewrites' (may already be enabled)"
    return 0
  fi
}

# Configure all SSL/TLS settings
configure_ssl_settings() {
  local zone_id="$1"
  local token="$2"

  set_ssl_full "$zone_id" "$token"
  enable_always_https "$zone_id" "$token"
  enable_auto_https_rewrites "$zone_id" "$token"
}
