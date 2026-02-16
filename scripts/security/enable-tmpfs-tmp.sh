#!/usr/bin/env bash
# =================================================================
# Optional Hardening: Mount /tmp as tmpfs with noexec,nodev,nosuid
# =================================================================
# Why:
# - Reduces persistence of malicious artifacts in /tmp
# - Blocks executing binaries from /tmp (common dropper technique)
# - Removes device/suid attack surface on /tmp
#
# Implementation:
# - Uses systemd's tmp.mount unit (preferred over editing /etc/fstab)
# - Configures mount options via a drop-in
#
# Caveats:
# - noexec can break software that insists on executing from /tmp
# - tmpfs consumes RAM (and swap)
#
# Usage:
#   sudo ./scripts/security/enable-tmpfs-tmp.sh
#   sudo ./scripts/security/enable-tmpfs-tmp.sh --size 512M
#   sudo ./scripts/security/enable-tmpfs-tmp.sh --disable
# =================================================================

set -euo pipefail

print_usage() {
  echo "Usage: $0 [--size <size>] [--disable]"
  echo ""
  echo "Examples:"
  echo "  sudo $0"
  echo "  sudo $0 --size 512M"
  echo "  sudo $0 --disable"
}

if [ "${EUID:-0}" -ne 0 ]; then
  echo "ERROR: This script must be run as root (use sudo)." >&2
  exit 1
fi

DISABLE=false
SIZE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --disable)
      DISABLE=true
      shift
      ;;
    --size)
      SIZE="${2:-}"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

if [ "$DISABLE" = true ]; then
  echo "Disabling tmp.mount and removing overrides..."
  systemctl disable --now tmp.mount >/dev/null 2>&1 || true
  rm -rf /etc/systemd/system/tmp.mount.d
  systemctl daemon-reload
  echo "Done."
  echo ""
  echo "Verify:"
  echo "  mount | grep ' on /tmp ' || true"
  exit 0
fi

# Pick a conservative default size: 25% of RAM, min 256M, max 2G.
if [ -z "$SIZE" ]; then
  ram_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  ram_mb=$((ram_kb / 1024))
  size_mb=$((ram_mb / 4))
  if [ "$size_mb" -lt 256 ]; then size_mb=256; fi
  if [ "$size_mb" -gt 2048 ]; then size_mb=2048; fi
  SIZE="${size_mb}M"
fi

echo "Enabling /tmp as tmpfs with hardening mount options"
echo "  size: $SIZE"
echo ""
echo "This will clear /tmp on reboot, and may break installers that execute from /tmp."
echo "If something breaks, disable with: sudo $0 --disable"
echo ""

# Some Ubuntu versions mask or omit tmp.mount entirely.
# Unmask first so enable/start can succeed.
systemctl unmask tmp.mount >/dev/null 2>&1 || true

# If the base unit doesn't exist at all, create it.
if ! systemctl cat tmp.mount >/dev/null 2>&1; then
  echo "tmp.mount unit not found — creating it..."
  cat > /etc/systemd/system/tmp.mount <<EOF
[Unit]
Description=Temporary Directory /tmp
Documentation=man:hier(7)
ConditionPathIsSymbolicLink=!/tmp
DefaultDependencies=no
Conflicts=umount.target
Before=local-fs.target umount.target
After=swap.target

[Mount]
What=tmpfs
Where=/tmp
Type=tmpfs
Options=mode=1777,strictatime,nosuid,nodev,noexec,size=${SIZE}

[Install]
WantedBy=local-fs.target
EOF
else
  # Unit exists — use a drop-in override for mount options
  mkdir -p /etc/systemd/system/tmp.mount.d
  cat > /etc/systemd/system/tmp.mount.d/override.conf <<EOF
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,noexec,size=${SIZE}
EOF
fi

systemctl daemon-reload
if ! systemctl enable --now tmp.mount 2>&1; then
  echo ""
  echo "WARNING: tmp.mount failed to start. This is non-critical."
  echo "Your system may use /etc/fstab or another mechanism for /tmp."
  echo "You can try manually: sudo systemctl start tmp.mount"
  echo "Or add to /etc/fstab:  tmpfs /tmp tmpfs nosuid,nodev,noexec,size=${SIZE} 0 0"
  echo ""
  exit 0
fi

echo ""
echo "Verify:"
mount | grep ' on /tmp ' || true
echo ""
echo "Done."

