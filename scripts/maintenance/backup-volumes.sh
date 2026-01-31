#!/usr/bin/env bash
# =================================================================
# Docker Volume Backup
# =================================================================
# Backs up Docker volumes to a specified directory.
#
# Usage:
#   ./backup-volumes.sh                    # Backup all volumes
#   ./backup-volumes.sh <volume-name>      # Backup specific volume
#   ./backup-volumes.sh --list             # List all volumes
# =================================================================

set -euo pipefail

# Configuration
BACKUP_DIR="${BACKUP_DIR:-/var/backups/docker-volumes}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Create backup directory
mkdir -p "$BACKUP_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

backup_volume() {
  local volume=$1
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="${BACKUP_DIR}/${volume}_${timestamp}.tar.gz"

  log "Backing up volume: $volume"

  # Create backup using a temporary container
  docker run --rm \
    -v "$volume":/source:ro \
    -v "$BACKUP_DIR":/backup \
    alpine \
    tar -czf "/backup/${volume}_${timestamp}.tar.gz" -C /source .

  if [ -f "$backup_file" ]; then
    local size=$(du -h "$backup_file" | awk '{print $1}')
    log "  Created: $backup_file ($size)"
    echo -e "${GREEN}✓${NC} $volume backed up successfully"
  else
    echo -e "${RED}✗${NC} Failed to backup $volume"
    return 1
  fi
}

cleanup_old_backups() {
  log "Cleaning up backups older than $RETENTION_DAYS days..."
  find "$BACKUP_DIR" -name "*.tar.gz" -mtime +$RETENTION_DAYS -delete 2>/dev/null || true
}

list_volumes() {
  echo ""
  echo "Docker Volumes:"
  echo ""
  docker volume ls --format "table {{.Name}}\t{{.Driver}}"
  echo ""
}

restore_volume() {
  local backup_file=$1
  local volume_name=$2

  if [ ! -f "$backup_file" ]; then
    echo -e "${RED}Error: Backup file not found: $backup_file${NC}"
    exit 1
  fi

  echo ""
  echo -e "${YELLOW}WARNING: This will DELETE all existing contents of volume '$volume_name'${NC}"
  echo "Backup file: $backup_file"
  echo ""
  read -rp "Are you sure you want to restore? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Restore cancelled."
    exit 0
  fi

  echo ""
  echo "Restoring $backup_file to volume $volume_name..."

  # Create volume if it doesn't exist
  docker volume create "$volume_name" > /dev/null 2>&1 || true

  # Restore backup
  local backup_basename
  backup_basename="$(basename "$backup_file")"
  docker run --rm \
    -v "$volume_name":/target \
    -v "$(dirname "$backup_file")":/backup:ro \
    alpine \
    sh -c "rm -rf /target/* && tar -xzf \"/backup/${backup_basename}\" -C /target"

  echo -e "${GREEN}✓${NC} Restored to volume: $volume_name"
}

# =================================================================
# MAIN
# =================================================================

case "${1:-all}" in
  --list|-l)
    list_volumes
    ;;

  --restore)
    if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
      echo "Usage: $0 --restore <backup-file> <volume-name>"
      exit 1
    fi
    restore_volume "$2" "$3"
    ;;

  --help|-h)
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  (no args)         Backup all Docker volumes"
    echo "  <volume-name>     Backup specific volume"
    echo "  --list, -l        List all volumes"
    echo "  --restore <file> <volume>  Restore backup to volume"
    echo "  --help, -h        Show this help"
    echo ""
    echo "Environment variables:"
    echo "  BACKUP_DIR        Backup directory (default: /var/backups/docker-volumes)"
    echo "  RETENTION_DAYS    Days to keep backups (default: 7)"
    echo ""
    echo "Examples:"
    echo "  $0                              # Backup all volumes"
    echo "  $0 my-app-data                  # Backup specific volume"
    echo "  $0 --restore backup.tar.gz vol  # Restore backup"
    ;;

  all)
    echo ""
    log "=== Docker Volume Backup ==="
    log "Backup directory: $BACKUP_DIR"
    echo ""

    # Get all volumes
    VOLUMES=$(docker volume ls -q 2>/dev/null)

    if [ -z "$VOLUMES" ]; then
      echo "No Docker volumes found"
      exit 0
    fi

    # Backup each volume
    SUCCESS=0
    FAILED=0
    while IFS= read -r volume; do
      [ -z "$volume" ] && continue
      if backup_volume "$volume"; then
        ((SUCCESS++))
      else
        ((FAILED++))
      fi
    done <<< "$VOLUMES"

    echo ""
    cleanup_old_backups
    echo ""

    log "=== Backup Complete ==="
    echo "  Successful: $SUCCESS"
    [ "$FAILED" -gt 0 ] && echo -e "  ${RED}Failed: $FAILED${NC}"
    echo ""
    echo "Backups stored in: $BACKUP_DIR"
    ;;

  *)
    # Specific volume
    if docker volume inspect "$1" > /dev/null 2>&1; then
      backup_volume "$1"
    else
      echo -e "${RED}Error: Volume '$1' not found${NC}"
      echo ""
      echo "Available volumes:"
      docker volume ls --format "  {{.Name}}"
      exit 1
    fi
    ;;
esac
