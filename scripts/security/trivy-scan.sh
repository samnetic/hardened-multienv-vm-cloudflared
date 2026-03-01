#!/usr/bin/env bash
# =================================================================
# Trivy Container CVE Scan (hosting-blueprint)
# =================================================================
# Scans all unique running container images for CRITICAL and HIGH
# vulnerabilities. Exports Prometheus metrics and sends alerts.
#
# Called by cron (Sunday 03:45 UTC) or manually.
# =================================================================

set -euo pipefail

LOGDIR="/var/log/hosting-blueprint/security"
LOGFILE="${LOGDIR}/trivy-scan.log"
METRICS_FILE="/var/lib/prometheus/node-exporter/trivy.prom"
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
  elif [ -x "$(dirname "$0")/notify.sh" ]; then
    "$(dirname "$0")/notify.sh" "$subject" "$body" || true
  fi
}

write_metrics() {
  local tmp="${METRICS_FILE}.tmp.$$"
  cat > "$tmp" <<EOF
# HELP trivy_images_scanned Number of container images scanned
# TYPE trivy_images_scanned gauge
trivy_images_scanned ${IMAGES_SCANNED:-0}
# HELP trivy_vulnerabilities_critical Total CRITICAL vulnerabilities found
# TYPE trivy_vulnerabilities_critical gauge
trivy_vulnerabilities_critical ${TOTAL_CRITICAL:-0}
# HELP trivy_vulnerabilities_high Total HIGH vulnerabilities found
# TYPE trivy_vulnerabilities_high gauge
trivy_vulnerabilities_high ${TOTAL_HIGH:-0}
# HELP trivy_scan_errors Number of images that failed to scan
# TYPE trivy_scan_errors gauge
trivy_scan_errors ${SCAN_ERRORS:-0}
# HELP trivy_scan_clean 1 if no CRITICAL/HIGH findings, 0 otherwise
# TYPE trivy_scan_clean gauge
trivy_scan_clean ${SCAN_CLEAN:-1}
# HELP trivy_last_scan_timestamp Unix timestamp of last scan
# TYPE trivy_last_scan_timestamp gauge
trivy_last_scan_timestamp $(date +%s)
EOF
  mv "$tmp" "$METRICS_FILE"
}

if [ "${EUID:-0}" -ne 0 ]; then
  log "ERROR: Must run as root"
  exit 1
fi

if ! command -v trivy >/dev/null 2>&1; then
  log "ERROR: trivy is not installed"
  notify "Trivy ERROR (not installed) - ${HOSTNAME_FQDN}" "Install with: sudo apt install trivy"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  log "ERROR: jq is not installed (required for JSON parsing)"
  notify "Trivy ERROR (jq missing) - ${HOSTNAME_FQDN}" "Install with: sudo apt install jq"
  exit 1
fi

log "=== Trivy scan started (${HOSTNAME_FQDN}) ==="

# Get unique images from running containers
mapfile -t IMAGES < <(docker ps --format '{{.Image}}' 2>/dev/null | sort -u)

if [ ${#IMAGES[@]} -eq 0 ]; then
  log "No running containers found, nothing to scan"
  IMAGES_SCANNED=0
  TOTAL_CRITICAL=0
  TOTAL_HIGH=0
  SCAN_ERRORS=0
  SCAN_CLEAN=1
  write_metrics
  exit 0
fi

IMAGES_SCANNED=0
TOTAL_CRITICAL=0
TOTAL_HIGH=0
SCAN_ERRORS=0
ALERT_BODY=""

for IMAGE in "${IMAGES[@]}"; do
  log "Scanning: ${IMAGE}"
  IMAGES_SCANNED=$((IMAGES_SCANNED + 1))

  SCAN_OUTPUT="$(trivy image --severity HIGH,CRITICAL --format json --quiet "$IMAGE" 2>/dev/null)" || {
    log "ERROR: Failed to scan ${IMAGE}"
    SCAN_ERRORS=$((SCAN_ERRORS + 1))
    continue
  }

  # Parse results
  IMG_CRITICAL="$(echo "$SCAN_OUTPUT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo 0)"
  IMG_HIGH="$(echo "$SCAN_OUTPUT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo 0)"

  TOTAL_CRITICAL=$((TOTAL_CRITICAL + IMG_CRITICAL))
  TOTAL_HIGH=$((TOTAL_HIGH + IMG_HIGH))

  if [ "$IMG_CRITICAL" -gt 0 ] || [ "$IMG_HIGH" -gt 0 ]; then
    log "  FOUND: ${IMG_CRITICAL} CRITICAL, ${IMG_HIGH} HIGH in ${IMAGE}"
    ALERT_BODY="${ALERT_BODY}${IMAGE}: ${IMG_CRITICAL} CRITICAL, ${IMG_HIGH} HIGH\n"
  else
    log "  CLEAN: ${IMAGE}"
  fi
done

# Determine overall status
if [ "$TOTAL_CRITICAL" -gt 0 ] || [ "$TOTAL_HIGH" -gt 0 ]; then
  SCAN_CLEAN=0
else
  SCAN_CLEAN=1
fi

# Write Prometheus metrics (atomic)
write_metrics
log "Metrics written to ${METRICS_FILE}"

# Send alert if findings detected
if [ "$SCAN_CLEAN" -eq 0 ]; then
  SUMMARY="Scanned ${IMAGES_SCANNED} images: ${TOTAL_CRITICAL} CRITICAL, ${TOTAL_HIGH} HIGH"
  log "ALERT: ${SUMMARY}"
  notify "Trivy ALERT - ${HOSTNAME_FQDN}" "${SUMMARY}\n\n${ALERT_BODY}\nSee: ${LOGFILE}"
fi

if [ "$SCAN_ERRORS" -gt 0 ]; then
  log "WARNING: ${SCAN_ERRORS} image(s) failed to scan"
fi

log "=== Trivy scan complete (scanned=${IMAGES_SCANNED}, critical=${TOTAL_CRITICAL}, high=${TOTAL_HIGH}, errors=${SCAN_ERRORS}) ==="
