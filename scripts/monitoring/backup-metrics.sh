#!/usr/bin/env bash
# =================================================================
# Backup Status Metrics (hosting-blueprint)
# =================================================================
# Exports backup file timestamps and sizes as Prometheus metrics.
# Run via cron every 15 minutes to track backup freshness.
#
# Scans the configured backup directory for the latest backup files.
#
# Output: /var/lib/prometheus/node-exporter/backup.prom
# =================================================================

set -euo pipefail

METRICS_FILE="/var/lib/prometheus/node-exporter/backup.prom"
BACKUP_DIR="${BACKUP_DIR:-/srv/backups}"
tmp="${METRICS_FILE}.tmp.$$"

{
  echo "# HELP backup_last_timestamp Unix timestamp of last backup file"
  echo "# TYPE backup_last_timestamp gauge"
  echo "# HELP backup_last_size_bytes Size of last backup file in bytes"
  echo "# TYPE backup_last_size_bytes gauge"
  echo "# HELP backup_files_count Number of backup files found"
  echo "# TYPE backup_files_count gauge"

  if [ -d "$BACKUP_DIR" ]; then
    # Scan for backup subdirectories and their latest files
    for subdir in "$BACKUP_DIR"/*/; do
      [ -d "$subdir" ] || continue
      name="$(basename "$subdir")"

      # Find the most recent file in this subdirectory
      latest="$(find "$subdir" -type f -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.json' -o -name '*.gz' 2>/dev/null \
        | xargs ls -t 2>/dev/null | head -1 || true)"

      if [ -n "$latest" ]; then
        ts="$(stat -c %Y "$latest" 2>/dev/null || echo 0)"
        sz="$(stat -c %s "$latest" 2>/dev/null || echo 0)"
        count="$(find "$subdir" -type f \( -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.json' -o -name '*.gz' \) 2>/dev/null | wc -l || echo 0)"
      else
        ts=0
        sz=0
        count=0
      fi

      echo "backup_last_timestamp{name=\"${name}\"} ${ts}"
      echo "backup_last_size_bytes{name=\"${name}\"} ${sz}"
      echo "backup_files_count{name=\"${name}\"} ${count}"
    done
  fi

  # Restic off-site backup status (if cache exists)
  RESTIC_CACHE="${BACKUP_DIR}/.restic-last-snapshot"
  if [ -f "$RESTIC_CACHE" ]; then
    RESTIC_TS="$(stat -c %Y "$RESTIC_CACHE" 2>/dev/null || echo 0)"
    echo "# HELP backup_offsite_last_timestamp Unix timestamp of last off-site backup"
    echo "# TYPE backup_offsite_last_timestamp gauge"
    echo "backup_offsite_last_timestamp ${RESTIC_TS}"
  fi
} > "$tmp"

mv "$tmp" "$METRICS_FILE"
