#!/usr/bin/env bash
#
# Public IP Rotator (Oracle Cloud)
# Rotates the VM's reserved public IP with rollback and verification
#
# Usage: ./scripts/maintenance/rotate-public-ip.sh [options]
#
#   --ip ADDRESS      Reuse an existing unassigned reserved IP instead of creating one
#   --delete-old      Release the previous reserved IP after a successful rotation
#   --dry-run         Show what would happen, change nothing
#   --yes             Skip the confirmation prompt
#   --no-verify       Skip the post-rotation SSH/egress verification
#   -h, --help        Show this help
#
# MUST be run from your workstation, never from the VM itself. Rotation
# unassigns the current IP before attaching the new one, so the VM loses all
# outbound connectivity for a few seconds. A session running on the VM would
# cut its own connection mid-rotation and strand the instance with no public
# IP -- which kills the Cloudflare tunnel and locks you out (serial console
# only). This script refuses to run on the target instance.
#
# Config (env vars, or config/ip-rotation.env relative to the repo root):
#   INSTANCE_OCID   required  OCID of the target instance
#   SSH_HOST        optional  SSH alias used to verify recovery (unset: skip the check)
#   OCI_PROFILE     optional  OCI CLI profile (default: DEFAULT)
#   OCI_REGION      optional  region for new reserved IPs (default: instance region)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

print_warn() {
  echo -e "${YELLOW}⚠${NC}  $1"
}

print_error() {
  echo -e "${RED}✖${NC} $1" >&2
}

print_ok() {
  echo -e "${GREEN}✔${NC} $1"
}

# ── Config ───────────────────────────────────────────────────────────────

[[ -f "$REPO_ROOT/config/ip-rotation.env" ]] && source "$REPO_ROOT/config/ip-rotation.env"

INSTANCE_OCID="${INSTANCE_OCID:-}"
SSH_HOST="${SSH_HOST:-}"
OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
OCI_REGION="${OCI_REGION:-}"

REUSE_IP=""
DELETE_OLD=false
DRY_RUN=false
ASSUME_YES=false
VERIFY=true
VERIFIED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)         REUSE_IP="$2"; shift 2 ;;
    --delete-old) DELETE_OLD=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --yes|-y)     ASSUME_YES=true; shift ;;
    --no-verify)  VERIFY=false; shift ;;
    -h|--help)    sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            print_error "Unknown option: $1"; exit 2 ;;
  esac
done

if $VERIFY && [[ -z "$SSH_HOST" ]]; then
  print_warn "SSH_HOST is not set; skipping the post-rotation SSH check"
  VERIFY=false
fi

export OCI_CLI_AUTH=security_token
export OCI_CLI_SUPPRESS_WARNINGS=1

oci_q() { oci --profile "$OCI_PROFILE" "$@" 2>/dev/null; }

# The CLI has no lookup-by-address, so scan both scopes: reserved IPs are
# regional, ephemeral ones live in the instance's availability domain.
find_public_ip_id() {
  local addr="$1" id
  id="$(oci_q network public-ip list --compartment-id "$COMPARTMENT" --scope REGION --all \
    --query "data[?\"ip-address\"=='$addr']|[0].id" --raw-output)"
  if [[ -z "$id" || "$id" == "null" ]]; then
    id="$(oci_q network public-ip list --compartment-id "$COMPARTMENT" \
      --scope AVAILABILITY_DOMAIN --availability-domain "$AVAILABILITY_DOMAIN" --all \
      --query "data[?\"ip-address\"=='$addr']|[0].id" --raw-output)"
  fi
  [[ "$id" == "null" ]] && id=""
  printf '%s' "$id"
}

# ── Preflight ────────────────────────────────────────────────────────────

print_header "Preflight"

command -v oci >/dev/null || { print_error "oci CLI not found (brew install oci-cli)"; exit 1; }
[[ -n "$INSTANCE_OCID" ]] || { print_error "INSTANCE_OCID not set (env or config/ip-rotation.env)"; exit 1; }

# Refuse to run on the instance we are about to disconnect.
SELF_OCID="$(curl -s -m 2 -H 'Authorization: Bearer Oracle' \
  http://169.254.169.254/opc/v2/instance/id 2>/dev/null || true)"
if [[ -n "$SELF_OCID" && "$SELF_OCID" == "$INSTANCE_OCID" ]]; then
  print_error "Running ON the target instance. Rotation would sever this session"
  print_error "and strand the VM with no public IP. Run from your workstation."
  exit 1
fi
print_ok "Not running on the target instance"

oci session validate --profile "$OCI_PROFILE" >/dev/null 2>&1 || {
  print_error "OCI session invalid/expired. Run:"
  print_error "  oci session authenticate --region <region> --profile-name $OCI_PROFILE"
  exit 1
}
print_ok "OCI session valid"

STATE="$(oci_q compute instance get --instance-id "$INSTANCE_OCID" \
  --query 'data."lifecycle-state"' --raw-output)"
[[ "$STATE" == "RUNNING" ]] || { print_error "Instance is $STATE, expected RUNNING"; exit 1; }
print_ok "Instance is RUNNING"

COMPARTMENT="$(oci_q compute instance get --instance-id "$INSTANCE_OCID" \
  --query 'data."compartment-id"' --raw-output)"
AVAILABILITY_DOMAIN="$(oci_q compute instance get --instance-id "$INSTANCE_OCID" \
  --query 'data."availability-domain"' --raw-output)"
[[ -n "$OCI_REGION" ]] || OCI_REGION="$(oci_q compute instance get --instance-id "$INSTANCE_OCID" \
  --query 'data.region' --raw-output)"

read -r VNIC_ID SUBNET_ID CURRENT_PUB <<<"$(oci_q compute instance list-vnics \
  --instance-id "$INSTANCE_OCID" \
  --query 'data[?"is-primary"]|[0].[id,"subnet-id","public-ip"]' \
  --raw-output | tr -d '[]",' | tr '\n' ' ')"
[[ -n "$VNIC_ID" ]] || { print_error "Could not resolve primary VNIC"; exit 1; }

PRIVATE_IP_ID="$(oci_q network private-ip list --vnic-id "$VNIC_ID" \
  --query 'data[?"is-primary"]|[0].id' --raw-output)"
PRIVATE_IP="$(oci_q network private-ip list --vnic-id "$VNIC_ID" \
  --query 'data[?"is-primary"]|[0]."ip-address"' --raw-output)"

# Egress needs a public subnet plus a default route to an Internet Gateway.
# Without both, attaching an IP restores nothing -- fail before mutating.
PROHIBIT="$(oci_q network subnet get --subnet-id "$SUBNET_ID" \
  --query 'data."prohibit-public-ip-on-vnic"' --raw-output)"
[[ "$PROHIBIT" == "false" ]] || { print_error "Subnet forbids public IPs on VNICs"; exit 1; }

RT_ID="$(oci_q network subnet get --subnet-id "$SUBNET_ID" \
  --query 'data."route-table-id"' --raw-output)"
oci_q network route-table get --rt-id "$RT_ID" \
  --query 'data."route-rules"[?destination==`0.0.0.0/0`]."network-entity-id"' \
  --raw-output | grep -q internetgateway || {
  print_error "No 0.0.0.0/0 route to an Internet Gateway; egress would stay broken"
  exit 1
}
print_ok "Subnet is public, default route reaches an Internet Gateway"

echo
echo "  Instance    : $INSTANCE_OCID"
echo "  Private IP  : $PRIVATE_IP"
echo "  Current IP  : ${CURRENT_PUB:-<none>}"
echo "  Region      : $OCI_REGION"
echo

# ── Resolve the incoming IP ──────────────────────────────────────────────

print_header "Rotation plan"

if [[ -n "$REUSE_IP" ]]; then
  NEW_IP_ID="$(oci_q network public-ip list --compartment-id "$COMPARTMENT" --scope REGION --all \
    --query "data[?\"ip-address\"=='$REUSE_IP' && \"lifecycle-state\"=='AVAILABLE']|[0].id" --raw-output)"
  [[ -n "$NEW_IP_ID" && "$NEW_IP_ID" != "null" ]] || {
    print_error "$REUSE_IP is not an available (unassigned) reserved IP"; exit 1; }
  NEW_IP="$REUSE_IP"
  print_step "Reusing reserved IP $NEW_IP"
else
  NEW_IP="<created at run time>"
  print_step "Creating a new reserved IP"
fi

print_step "Attaching to $PRIVATE_IP, replacing ${CURRENT_PUB:-<none>}"
$DELETE_OLD && print_warn "Previous reserved IP will be RELEASED afterwards"
print_warn "The VM loses outbound connectivity for a few seconds mid-rotation"

if $DRY_RUN; then
  echo; print_ok "Dry run - nothing changed"; exit 0
fi

if ! $ASSUME_YES; then
  echo
  read -rp "Proceed? (yes/no) " reply
  [[ "$reply" == "yes" ]] || { echo "Aborted."; exit 0; }
fi

# ── Rotate ───────────────────────────────────────────────────────────────

print_header "Rotating"

# Identify the outgoing IP before detaching, so rollback has a target.
OLD_IP_ID=""; OLD_LIFETIME=""
if [[ -n "$CURRENT_PUB" && "$CURRENT_PUB" != "null" ]]; then
  OLD_IP_ID="$(find_public_ip_id "$CURRENT_PUB")"
  if [[ -n "$OLD_IP_ID" ]]; then
    OLD_LIFETIME="$(oci_q network public-ip get --public-ip-id "$OLD_IP_ID" \
      --query 'data.lifetime' --raw-output || true)"
  else
    print_warn "Could not resolve $CURRENT_PUB to an OCID; rollback will be unavailable"
  fi
fi

# Create the replacement first: the shorter the window between detach and
# attach, the shorter the VM is offline.
if [[ -z "$REUSE_IP" ]]; then
  NEW_IP_ID="$(oci --profile "$OCI_PROFILE" network public-ip create \
    --compartment-id "$COMPARTMENT" --lifetime RESERVED \
    --display-name "vm-public-ip-rotated-$(date +%Y%m%d-%H%M%S)" \
    --region "$OCI_REGION" --query 'data.id' --raw-output)"
  NEW_IP="$(oci_q network public-ip get --public-ip-id "$NEW_IP_ID" \
    --query 'data."ip-address"' --raw-output)"
  print_ok "Created $NEW_IP"
fi

rollback() {
  print_error "Rotation failed - rolling back"
  if [[ -n "$OLD_IP_ID" && "$OLD_LIFETIME" == "RESERVED" ]]; then
    oci --profile "$OCI_PROFILE" network public-ip update --public-ip-id "$OLD_IP_ID" \
      --private-ip-id "$PRIVATE_IP_ID" --force >/dev/null 2>&1 \
      && print_ok "Restored $CURRENT_PUB" \
      || print_error "Could not restore $CURRENT_PUB - VM may have NO public IP. Attach one in the Console."
  else
    print_error "No reserved IP to restore. Attach one in the Console:"
    print_error "  Instance > VNIC > IPv4 Addresses > Edit > Ephemeral public IP"
  fi
}

if [[ -n "$OLD_IP_ID" ]]; then
  if [[ "$OLD_LIFETIME" == "RESERVED" ]]; then
    oci --profile "$OCI_PROFILE" network public-ip update --public-ip-id "$OLD_IP_ID" \
      --private-ip-id "" --force >/dev/null
  else
    oci --profile "$OCI_PROFILE" network public-ip delete --public-ip-id "$OLD_IP_ID" --force >/dev/null
  fi
  print_ok "Detached ${CURRENT_PUB}"
fi

trap rollback ERR
oci --profile "$OCI_PROFILE" network public-ip update --public-ip-id "$NEW_IP_ID" \
  --private-ip-id "$PRIVATE_IP_ID" --force >/dev/null
trap - ERR
print_ok "Attached $NEW_IP"

# ── Verify ───────────────────────────────────────────────────────────────

if $VERIFY; then
  print_header "Verifying"
  print_step "Waiting for the tunnel to reconnect (cloudflared retries on its own)"

  # SSH can answer before OCI's NAT mapping flips, briefly still reporting the
  # old address. Poll until egress actually matches rather than trusting the
  # first successful response.
  OBSERVED=""
  for i in $(seq 1 20); do
    OBSERVED="$(ssh -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new "$SSH_HOST" \
      'curl -s -m 8 https://api.ipify.org' 2>/dev/null || true)"
    [[ "$OBSERVED" == "$NEW_IP" ]] && break
    sleep 8
  done

  if [[ "$OBSERVED" == "$NEW_IP" ]]; then
    print_ok "SSH restored; VM egress reports $OBSERVED"
    VERIFIED=true
  elif [[ -z "$OBSERVED" ]]; then
    print_error "VM did not come back within ~160s."
    print_error "Check: oci network public-ip get --public-ip-id $NEW_IP_ID"
    print_error "Then on the VM (serial console): systemctl status cloudflared"
    exit 1
  else
    print_warn "SSH restored but egress still reports $OBSERVED (expected $NEW_IP)"
    print_warn "Re-check in a minute: ssh $SSH_HOST 'curl -s https://api.ipify.org'"
  fi
fi

# ── Cleanup ──────────────────────────────────────────────────────────────

if $DELETE_OLD && [[ -n "$OLD_IP_ID" && "$OLD_LIFETIME" == "RESERVED" ]]; then
  # An unverified rotation keeps the old IP: it is the only thing left to fall
  # back to if the new address turns out not to work.
  if $VERIFY && ! $VERIFIED; then
    print_warn "Keeping $CURRENT_PUB - rotation unverified, it is your rollback target"
    print_warn "Once egress looks right, release it in the Console or re-run --delete-old"
  else
    oci --profile "$OCI_PROFILE" network public-ip delete --public-ip-id "$OLD_IP_ID" --force >/dev/null \
      && print_ok "Released $CURRENT_PUB"
  fi
elif [[ -n "$OLD_IP_ID" && "$OLD_LIFETIME" == "RESERVED" ]]; then
  print_warn "$CURRENT_PUB is still reserved and unassigned (bills while idle)"
  print_warn "Release it with: --delete-old, or reuse it later with --ip $CURRENT_PUB"
fi

print_header "Done"
echo "  ${CURRENT_PUB:-<none>}  →  $NEW_IP"
echo
echo "  SSH is unaffected by rotation (it runs over the Cloudflare tunnel)."
echo "  Anything allowlisting the old IP needs updating."
