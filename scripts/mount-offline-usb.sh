#!/usr/bin/env bash
# Mount the offline USB (LABEL=RHEL8OFFLINE by default).
# Installed early via kickstart and install-airgap-helpers.sh.
#
#   sudo mount-offline-usb.sh [LABEL] [MNT]
set -euo pipefail

LABEL="${1:-${USB_REPO_LABEL:-RHEL8OFFLINE}}"
MNT="${2:-${USB_MNT:-/mnt/rhel8offline}}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

mkdir -p "$MNT"
if findmnt "$MNT" >/dev/null 2>&1; then
  echo "Already mounted: $MNT"
  exit 0
fi

if [[ -x /usr/local/sbin/authorize-offline-usb.sh ]]; then
  /usr/local/sbin/authorize-offline-usb.sh >/dev/null 2>&1 || true
fi

DEV="$(blkid -L "$LABEL" 2>/dev/null || true)"
if [[ -z "${DEV}" ]]; then
  echo "No filesystem with LABEL=$LABEL found" >&2
  echo "Try: sudo authorize-offline-usb.sh  then re-insert USB" >&2
  blkid 2>/dev/null || true
  exit 1
fi
mount -o ro "$DEV" "$MNT"
echo "Mounted $DEV -> $MNT"
