#!/usr/bin/env bash
# =================================================================
# Off-Site Backup via Restic (hosting-blueprint)
# =================================================================
# Backs up local backup directory to a remote restic repository.
# Called by cron (daily 02:45 UTC) or manually.
#
# Reads credentials from /etc/hosting-blueprint/restic.env
# =================================================================

set -euo pipefail

LOGDIR="/var/log/hosting-blueprint"
LOGFILE="${LOGDIR}/backup-offsite.log"
BACKUP_DIR="${BACKUP_DIR:-/srv/backups}"
RESTIC_ENV="${RESTIC_ENV:-/etc/hosting-blueprint/restic.env}"
CACHE_FILE="${BACKUP_DIR}/.restic-last-snapshot"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"

mkdir -p "$LOGDIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOGFILE"
}

notify() {
  local subject="$1"
  local body="$2"
  if [ -x /opt/scripts/hosting-notify.sh ]; then
    /opt/scripts/hosting-notify.sh "$subject" "$body" || true
  fi
}

if [ "${EUID:-0}" -ne 0 ]; then
  log "ERROR: Must run as root"
  exit 1
fi

if [ ! -f "$RESTIC_ENV" ]; then
  log "ERROR: Restic environment file not found: ${RESTIC_ENV}"
  log "Run: sudo ./scripts/maintenance/setup-offsite-backup.sh"
  exit 1
fi

# Load restic credentials
# shellcheck disable=SC1090
set +u
. "$RESTIC_ENV"
set -u

if [ -z "${RESTIC_REPOSITORY:-}" ] || [ -z "${RESTIC_PASSWORD:-}" ]; then
  log "ERROR: RESTIC_REPOSITORY or RESTIC_PASSWORD not set in ${RESTIC_ENV}"
  exit 1
fi

export RESTIC_REPOSITORY RESTIC_PASSWORD
[ -n "${AWS_ACCESS_KEY_ID:-}" ] && export AWS_ACCESS_KEY_ID
[ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && export AWS_SECRET_ACCESS_KEY

if ! command -v restic >/dev/null 2>&1; then
  log "ERROR: restic is not installed"
  notify "Backup ERROR (restic missing) - ${HOSTNAME_FQDN}" "Install with: sudo apt install restic"
  exit 1
fi

log "=== Off-site backup started (${HOSTNAME_FQDN}) ==="

# Check if backup directory exists and has content
if [ ! -d "$BACKUP_DIR" ]; then
  log "WARNING: Backup directory does not exist: ${BACKUP_DIR}"
  notify "Backup WARNING - ${HOSTNAME_FQDN}" "Backup directory missing: ${BACKUP_DIR}"
  exit 0
fi

# Run backup
BACKUP_RC=0
log "Backing up: ${BACKUP_DIR}"
restic backup "$BACKUP_DIR" \
  --host "$HOSTNAME_FQDN" \
  --tag "automated" \
  --exclude-caches \
  >> "$LOGFILE" 2>&1 || BACKUP_RC=$?

if [ "$BACKUP_RC" -ne 0 ]; then
  log "ERROR: restic backup failed (exit ${BACKUP_RC})"
  notify "Backup FAILED - ${HOSTNAME_FQDN}" "restic backup exited with code ${BACKUP_RC}\nSee: ${LOGFILE}"
  exit 1
fi

log "Backup completed successfully"

# Update cache timestamp for metrics
date +%s > "$CACHE_FILE"

# Prune old snapshots (keep reasonable retention)
log "Pruning old snapshots..."
restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --prune \
  >> "$LOGFILE" 2>&1 || {
    log "WARNING: restic forget/prune failed (non-fatal)"
  }

# Verify repository integrity (weekly on Sunday)
if [ "$(date +%u)" = "7" ]; then
  log "Running weekly integrity check..."
  restic check >> "$LOGFILE" 2>&1 || {
    log "WARNING: restic check reported issues"
    notify "Backup INTEGRITY WARNING - ${HOSTNAME_FQDN}" "restic check reported issues\nSee: ${LOGFILE}"
  }
fi

# Update metrics
if [ -x /opt/scripts/hosting-backup-metrics.sh ]; then
  /opt/scripts/hosting-backup-metrics.sh >/dev/null 2>&1 || true
fi

log "=== Off-site backup complete ==="
