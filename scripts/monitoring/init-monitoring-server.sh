#!/usr/bin/env bash
# =================================================================
# Monitoring Server Bootstrap (Secrets + Config Safety Checks)
# =================================================================
# Purpose:
# - Prevent Docker bind-mount "missing file -> directory" footguns
# - Ensure required file-based secrets exist before `docker compose up`
# - Optionally create a starter Prometheus config file on first run
#
# Intended usage (on the monitoring VPS):
#   cd /srv/infrastructure/monitoring-server
#   sudo /opt/hosting-blueprint/scripts/monitoring/init-monitoring-server.sh
#
# This script is idempotent:
# - existing non-empty secrets are left untouched
# - missing secrets are created (Grafana password is generated; CF Access
#   token values are prompted)
# =================================================================

set -euo pipefail

SECRETS_DIR="${SECRETS_DIR:-/var/secrets}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

usage() {
  cat <<'EOF'
Usage:
  init-monitoring-server.sh [environment]

Examples:
  init-monitoring-server.sh
  init-monitoring-server.sh production

Notes:
  - If environment is omitted, the script will try to read ENVIRONMENT from ./.env
    (when run inside /srv/infrastructure/monitoring-server), otherwise defaults
    to "production".
EOF
}

normalize_env() {
  local env="${1:-}"
  if [ "$env" = "prod" ]; then
    env="production"
  fi
  printf '%s' "$env"
}

read_env_from_dotenv() {
  # Minimal dotenv parser for ENVIRONMENT=... only (no sourcing).
  # Strips surrounding quotes.
  local dotenv="${1:-.env}"
  if [ ! -f "$dotenv" ]; then
    return 1
  fi
  local line
  line="$(grep -E '^[[:space:]]*ENVIRONMENT=' "$dotenv" | tail -n 1 || true)"
  if [ -z "$line" ]; then
    return 1
  fi
  line="${line#ENVIRONMENT=}"
  line="${line%$'\r'}"
  line="${line%\"}"
  line="${line#\"}"
  line="${line%\'}"
  line="${line#\'}"
  printf '%s' "$line"
}

need_root() {
  [ "$SECRETS_DIR" = "/var/secrets" ]
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

ENVIRONMENT="${1:-}"
if [ -z "$ENVIRONMENT" ]; then
  ENVIRONMENT="$(read_env_from_dotenv ".env" 2>/dev/null || true)"
fi
ENVIRONMENT="$(normalize_env "${ENVIRONMENT:-production}")"

if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|production)$ ]]; then
  echo -e "${RED}Error: invalid environment '$ENVIRONMENT'${NC}"
  usage
  exit 1
fi

if need_root && [ "${EUID:-0}" -ne 0 ]; then
  exec sudo SECRETS_DIR="$SECRETS_DIR" "$0" "$ENVIRONMENT"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CREATE_SECRET="${ROOT_DIR}/scripts/secrets/create-secret.sh"

if [ ! -x "$CREATE_SECRET" ]; then
  echo -e "${RED}Error: missing executable: ${CREATE_SECRET}${NC}"
  exit 1
fi

secret_file() {
  local name="$1"
  printf '%s/%s/%s.txt' "$SECRETS_DIR" "$ENVIRONMENT" "$name"
}

assert_file_not_dir() {
  local path="$1"
  if [ -d "$path" ]; then
    echo -e "${RED}Error: expected a file but found a directory:${NC} $path"
    echo ""
    echo "This is a common Docker footgun: if a bind-mounted secret file is missing,"
    echo "Docker may create a directory at that path."
    echo ""
    echo "Fix:"
    echo "  sudo rm -rf \"$path\""
    echo "  sudo $0 $ENVIRONMENT"
    echo ""
    exit 1
  fi
}

assert_file_nonempty() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo -e "${RED}Error: missing required file:${NC} $path"
    exit 1
  fi
  if [ ! -s "$path" ]; then
    echo -e "${RED}Error: secret file exists but is empty:${NC} $path"
    echo "Fix: delete it and re-run this script:"
    echo "  sudo rm -f \"$path\""
    echo "  sudo $0 $ENVIRONMENT"
    exit 1
  fi
}

ensure_grafana_admin_password() {
  local path
  path="$(secret_file "grafana_admin_password")"

  assert_file_not_dir "$path"
  if [ -f "$path" ] && [ -s "$path" ]; then
    echo -e "${GREEN}✓${NC} grafana_admin_password already present"
    return 0
  fi

  echo ""
  echo "Creating Grafana admin password (generated)..."
  "$CREATE_SECRET" "$ENVIRONMENT" grafana_admin_password --generate 32
  assert_file_nonempty "$path"
}

ensure_cf_access_service_token() {
  local name="$1"
  local path
  path="$(secret_file "$name")"

  assert_file_not_dir "$path"
  if [ -f "$path" ] && [ -s "$path" ]; then
    echo -e "${GREEN}✓${NC} $name already present"
    return 0
  fi

  echo ""
  echo "Creating Cloudflare Access service token secret: $name"
  echo "Paste the value from Cloudflare Zero Trust (Access -> Service Auth -> Service Tokens)."
  "$CREATE_SECRET" "$ENVIRONMENT" "$name"
  assert_file_nonempty "$path"
}

ensure_prometheus_config_present() {
  # Optional QoL: create a starter Prometheus config on first run if user
  # cloned `infra/monitoring-server/` and hasn't copied the example yet.
  if [ -f "./configs/prometheus.yml" ]; then
    return 0
  fi
  if [ -f "./configs/prometheus.yml.example" ]; then
    echo ""
    echo -e "${YELLOW}Note:${NC} configs/prometheus.yml not found. Creating from example..."
    cp "./configs/prometheus.yml.example" "./configs/prometheus.yml"
    echo "Edit ./configs/prometheus.yml targets before starting Prometheus."
  fi
}

echo ""
echo "Monitoring server init (env: $ENVIRONMENT)"
echo "Secrets dir: $SECRETS_DIR"

ensure_grafana_admin_password
ensure_cf_access_service_token cf_access_client_id
ensure_cf_access_service_token cf_access_client_secret
ensure_prometheus_config_present

echo ""
echo -e "${GREEN}✓ Monitoring server prerequisites are ready.${NC}"
echo ""
echo "Next:"
echo "  cd /srv/infrastructure/monitoring-server"
echo "  sudo docker compose --compatibility up -d"
echo ""

