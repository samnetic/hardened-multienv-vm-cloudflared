#!/usr/bin/env bash
# =================================================================
# Boot Services Script (hosting-blueprint)
# =================================================================
# Called by hosting-boot.service at system startup.
# Creates Docker networks, optionally decrypts secrets, and starts
# all compose services found under /srv.
#
# Resilient: continues on individual failures, reports error count.
# =================================================================

set -uo pipefail

ERRORS=0
SERVICES_STARTED=0

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

run_step() {
  local desc="$1"
  shift
  log "STEP: ${desc}"
  if "$@"; then
    log "  OK: ${desc}"
  else
    log "  FAIL: ${desc} (exit $?)"
    ERRORS=$((ERRORS + 1))
  fi
}

# =================================================================
# Step 1: Create Docker Networks
# =================================================================
log "=== Boot services starting ==="

NETWORKS_SCRIPT=""
for candidate in /opt/hosting-blueprint/scripts/create-networks.sh /opt/scripts/hosting-create-networks.sh; do
  if [ -x "$candidate" ]; then
    NETWORKS_SCRIPT="$candidate"
    break
  fi
done

if [ -n "$NETWORKS_SCRIPT" ]; then
  run_step "Create Docker networks" "$NETWORKS_SCRIPT"
else
  log "SKIP: No network creation script found (Docker networks should already exist)"
fi

# =================================================================
# Step 2: Decrypt Secrets (if SOPS is available)
# =================================================================
if command -v sops >/dev/null 2>&1 && [ -n "${SOPS_AGE_KEY_FILE:-}" ] && [ -f "${SOPS_AGE_KEY_FILE:-}" ]; then
  log "STEP: Decrypting secrets..."
  DECRYPT_ERRORS=0

  # Find all .env.*.enc files under /srv and decrypt them
  while IFS= read -r enc_file; do
    # Derive the output path: .env.production.enc -> .env.production
    dec_file="${enc_file%.enc}"
    if sops --decrypt --input-type dotenv --output-type dotenv "$enc_file" > "${dec_file}.tmp" 2>/dev/null; then
      mv "${dec_file}.tmp" "$dec_file"
      chmod 600 "$dec_file"
    else
      rm -f "${dec_file}.tmp"
      log "  FAIL: Could not decrypt ${enc_file}"
      DECRYPT_ERRORS=$((DECRYPT_ERRORS + 1))
    fi
  done < <(find /srv -name '*.env.*.enc' -o -name '.env.enc' 2>/dev/null || true)

  if [ "$DECRYPT_ERRORS" -eq 0 ]; then
    log "  OK: Secrets decrypted"
  else
    log "  WARN: ${DECRYPT_ERRORS} secret file(s) failed to decrypt"
    ERRORS=$((ERRORS + DECRYPT_ERRORS))
  fi
else
  log "SKIP: SOPS not available or no age key found"
fi

# =================================================================
# Step 3: Start Compose Services
# =================================================================
log "STEP: Starting compose services..."

# Find all compose files under /srv (infrastructure + apps)
while IFS= read -r compose_file; do
  dir="$(dirname "$compose_file")"
  name="$(basename "$dir")"
  log "  Starting: ${name} (${compose_file})"
  if docker compose -f "$compose_file" up -d 2>/dev/null; then
    SERVICES_STARTED=$((SERVICES_STARTED + 1))
  else
    log "  FAIL: ${name}"
    ERRORS=$((ERRORS + 1))
  fi
done < <(find /srv -maxdepth 4 -name 'compose.yaml' -o -name 'compose.yml' -o -name 'docker-compose.yml' 2>/dev/null | sort || true)

# =================================================================
# Step 4: Report Status
# =================================================================
CONTAINERS="$(docker ps --format '{{.Names}}' 2>/dev/null | head -30 | wc -l || echo 0)"
log "=== Boot complete: ${SERVICES_STARTED} service(s) started, ${CONTAINERS} container(s) running, ${ERRORS} error(s) ==="

if [ "$ERRORS" -gt 0 ]; then
  log "WARNING: ${ERRORS} error(s) during boot. Check logs: journalctl -u hosting-boot"
fi

exit 0
