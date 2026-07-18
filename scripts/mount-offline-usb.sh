#!/usr/bin/env bash
# Mount the offline USB data partition (LABEL=RHEL8OFFLINE by default).
# Installed early via kickstart and install-airgap-helpers.sh.
#
#   sudo mount-offline-usb.sh [LABEL] [MNT]
#   USB_UUID=... sudo mount-offline-usb.sh     # optional UUID override
#
# Finding order:
#   1) filesystem LABEL
#   2) USB_UUID / UUID= env
#   3) GPT PARTLABEL
#   4) largest ext4 partition that has BaseOS/ at root (probe)
#   5) largest multi-GB ext4 on a removable/USB disk
set -euo pipefail

LABEL="${1:-${USB_REPO_LABEL:-RHEL8OFFLINE}}"
MNT="${2:-${USB_MNT:-/mnt/rhel8offline}}"
MIN_DATA_BYTES=$((5 * 1024 * 1024 * 1024))

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

mkdir -p "$MNT"
if findmnt "$MNT" >/dev/null 2>&1; then
  echo "Already mounted: $MNT"
  findmnt "$MNT"
  exit 0
fi

if [[ -x /usr/local/sbin/authorize-offline-usb.sh ]]; then
  /usr/local/sbin/authorize-offline-usb.sh >/dev/null 2>&1 || true
fi
# Give udev a moment after authorize
udevadm settle 2>/dev/null || true
sleep 1

looks_like_offline_repo() {
  local dev="$1" tmp rc=1
  tmp="$(mktemp -d)"
  if mount -o ro "$dev" "$tmp" 2>/dev/null; then
    if [[ -d "$tmp/BaseOS" && -d "$tmp/AppStream" ]]; then
      rc=0
    fi
    umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
  fi
  rmdir "$tmp" 2>/dev/null || true
  return $rc
}

DEV=""

# 1) LABEL
DEV="$(blkid -L "$LABEL" 2>/dev/null || true)"

# 2) explicit UUID
if [[ -z "$DEV" && -n "${USB_UUID:-}" ]]; then
  DEV="$(blkid -U "$USB_UUID" 2>/dev/null || true)"
fi

# 3) PARTLABEL (sgdisk -c name)
if [[ -z "$DEV" ]]; then
  while read -r name; do
    [[ -z "$name" || "$name" != /dev/* ]] && continue
    pl="$(blkid -o value -s PARTLABEL "$name" 2>/dev/null || true)"
    if [[ "$pl" == "$LABEL" ]]; then
      DEV="$name"
      break
    fi
  done < <(blkid -o device 2>/dev/null || true)
fi

# 4) Scan blkid for ext4 multi-GB; prefer ones that contain BaseOS/
if [[ -z "$DEV" ]]; then
  echo "LABEL=$LABEL not found — scanning for offline-repo filesystem..." >&2
  best="" bestsz=0
  while read -r name; do
    [[ -b "$name" ]] || continue
    ft="$(blkid -o value -s TYPE "$name" 2>/dev/null || true)"
    [[ "$ft" == "ext4" || "$ft" == "xfs" ]] || continue
    sz="$(blockdev --getsize64 "$name" 2>/dev/null || echo 0)"
    (( sz >= MIN_DATA_BYTES )) || continue
    if looks_like_offline_repo "$name"; then
      DEV="$name"
      echo "Found offline repo by content probe: $name" >&2
      break
    fi
    if (( sz > bestsz )); then
      bestsz=$sz
      best="$name"
    fi
  done < <(blkid -o device 2>/dev/null || true)
  if [[ -z "$DEV" && -n "$best" ]]; then
    DEV="$best"
    echo "Using largest multi-GB $ft candidate: $DEV (verify contents after mount)" >&2
  fi
fi

if [[ -z "${DEV}" ]]; then
  echo "ERROR: No offline-repo filesystem found (LABEL=$LABEL)." >&2
  echo >&2
  echo "Block devices:" >&2
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,UUID,START 2>/dev/null | sed 's/^/  /' >&2 || true
  echo >&2
  echo "blkid:" >&2
  blkid 2>/dev/null | sed 's/^/  /' >&2 || true
  echo >&2
  echo "If you only see ~3G boot + ~20M EFI (no multi-GB data part):" >&2
  echo "  Offline-repo partition entry is missing (bad GPT / incomplete first image)." >&2
  echo "  04-update-usb never rewrites partitions. On the *build host* reimage:" >&2
  echo "    sudo ./scripts/03-prepare-usb.sh --yes /dev/sdX" >&2
  echo >&2
  echo "If a multi-GB ext4 is present but unlabeled:" >&2
  echo "    sudo mount /dev/sdXN $MNT" >&2
  echo "    sudo e2label /dev/sdXN $LABEL" >&2
  exit 1
fi

mount -o ro "$DEV" "$MNT"
echo "Mounted $DEV -> $MNT (ro)"
if [[ -d "$MNT/BaseOS" ]]; then
  echo "  OK: BaseOS/ present"
else
  echo "  WARN: BaseOS/ missing on this volume — wrong partition?" >&2
fi
# Show identity for operators
blkid "$DEV" 2>/dev/null || true
