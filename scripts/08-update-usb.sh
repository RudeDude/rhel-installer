#!/usr/bin/env bash
# Incrementally update an existing air-gap USB *without* reimaging the whole stick.
#
# Default: refresh repo content on LABEL=RHEL8OFFLINE (BaseOS/AppStream/CRB/EPEL/wheels/docs/scripts).
# Optional: also refresh the hybrid boot/kickstart ISO area (preserves data partition if possible).
#
# Usage (on build host):
#   ./scripts/08-update-usb.sh                  # repos only (default)
#   ./scripts/08-update-usb.sh --repos
#   ./scripts/08-update-usb.sh --boot           # re-dd custom ISO + repair GPT; keep data part
#   ./scripts/08-update-usb.sh --all            # boot + repos
#   ./scripts/08-update-usb.sh --device /dev/sdb
#   ./scripts/08-update-usb.sh --dry-run
#
# Prerequisites: run fetch scripts first if content changed:
#   01-reposync / 02-fetch-epel / 03-fetch-python-wheels
#   05-generate-kickstart + 06-inject-kickstart  (if using --boot)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/config.env" ]]; then
  set +u
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  set -u
fi

DO_REPOS=1
DO_BOOT=0
DRY_RUN=0
DEVICE="${USB_DEVICE:-}"
USB_REPO_LABEL="${USB_REPO_LABEL:-RHEL8OFFLINE}"
REPO_DIR="${REPO_DIR:-$ROOT/out/offline-repo}"
[[ "$REPO_DIR" != /* ]] && REPO_DIR="$ROOT/${REPO_DIR#./}"
OUT_ISO="${OUT_ISO:-$ROOT/out/rhel-8.10-airgap-ks.iso}"
[[ "$OUT_ISO" != /* ]] && OUT_ISO="$ROOT/${OUT_ISO#./}"

usage() {
  cat <<EOF
Usage: $0 [options]

  --repos          Update offline repo partition only (default)
  --boot           Update hybrid installer ISO at start of USB (preserves data partition)
  --all            --boot + --repos
  --device PATH    USB block device (default: USB_DEVICE from config.env)
  --label NAME     Repo partition label (default: $USB_REPO_LABEL)
  --dry-run        Show plan only
  -h, --help

Examples:
  $0 --repos --device /dev/sdb
  $0 --all --device /dev/sdb
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos) DO_REPOS=1; DO_BOOT=0; shift ;;
    --boot) DO_BOOT=1; DO_REPOS=0; shift ;;
    --all) DO_BOOT=1; DO_REPOS=1; shift ;;
    --device) DEVICE="$2"; shift 2 ;;
    --label) USB_REPO_LABEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# If only --boot was set via flag order, keep both when --all; if user passed only --boot, DO_REPOS=0
# If no mode flags, default repos-only already set.

if [[ -z "$DEVICE" ]]; then
  # Try to find stick by existing label
  if blkid -L "$USB_REPO_LABEL" >/dev/null 2>&1; then
    PART="$(blkid -L "$USB_REPO_LABEL")"
    # parent disk
    DEVICE="/dev/$(lsblk -no PKNAME "$PART" 2>/dev/null || true)"
    [[ "$DEVICE" == "/dev/" ]] && DEVICE=""
  fi
fi

if [[ -z "$DEVICE" ]]; then
  echo "ERROR: Set --device /dev/sdX or USB_DEVICE in config.env" >&2
  lsblk -d -o NAME,SIZE,MODEL,TRAN | sed 's/^/  /'
  exit 1
fi

echo "=== Incremental USB update ==="
echo "Device:  $DEVICE"
echo "Label:   $USB_REPO_LABEL"
echo "Repos:   $DO_REPOS   Boot/ISO: $DO_BOOT   Dry-run: $DRY_RUN"
echo "Source:  $REPO_DIR"
if [[ -b "$DEVICE" ]]; then
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEVICE" || true
else
  echo "(device not present on this host right now)"
fi
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would:"
  [[ "$DO_BOOT" -eq 1 ]] && echo "  - dd $OUT_ISO -> $DEVICE (then sgdisk -e; recreate data part entry if needed, NO mkfs)"
  [[ "$DO_REPOS" -eq 1 ]] && echo "  - rsync $REPO_DIR/ -> mount of LABEL=$USB_REPO_LABEL"
  echo "  - refresh packages/, docs/, scripts/ on the repo partition"
  exit 0
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "ERROR: not a block device: $DEVICE" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0 $*" >&2
  exit 1
fi

# Unmount any mounted parts of device
while read -r m; do
  [[ -z "$m" ]] && continue
  umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
done < <(lsblk -ln -o MOUNTPOINT "$DEVICE" | grep -v '^$' | tac || true)

# ---------------------------------------------------------------------------
# Optional boot/ISO update (preserve data partition when possible)
# ---------------------------------------------------------------------------
if [[ "$DO_BOOT" -eq 1 ]]; then
  if [[ ! -f "$OUT_ISO" ]]; then
    echo "ERROR: custom ISO not found: $OUT_ISO" >&2
    echo "Run ./scripts/05-generate-kickstart.sh && ./scripts/06-inject-kickstart.sh first" >&2
    exit 1
  fi

  # Record existing data partition start (sectors) before re-dd
  DATA_START=""
  DATA_PART_BEFORE=""
  while read -r name size; do
    [[ -z "$name" ]] && continue
    # skip whole disk
    [[ "$name" == "$(basename "$DEVICE")" ]] && continue
    # largest part is likely data
    :
  done < <(lsblk -ln -b -o NAME,SIZE,TYPE "$DEVICE" | awk '$3=="part"{print $1,$2}' | sort -k2 -n)
  DATA_PART_BEFORE="$(lsblk -ln -b -o NAME,SIZE,TYPE "$DEVICE" | awk -v d="$(basename "$DEVICE")" '$3=="part"&&$1!=d{print $1,$2}' | sort -k2 -n | tail -1 | awk '{print $1}')"
  if [[ -n "$DATA_PART_BEFORE" ]]; then
    sys="/sys/block/$(basename "$DEVICE")/${DATA_PART_BEFORE}/start"
    [[ -f "$sys" ]] && DATA_START="$(cat "$sys")"
    echo "==> Existing data partition ${DATA_PART_BEFORE} start sector=${DATA_START:-unknown}"
  fi

  echo "==> Writing installer ISO to $DEVICE (boot area)"
  dd if="$OUT_ISO" of="$DEVICE" bs=4M status=progress conv=fsync oflag=direct
  sync
  # Relocate GPT to end of real disk
  sgdisk -e "$DEVICE" 2>&1 || true
  partprobe "$DEVICE" 2>/dev/null || true
  sleep 1

  # Recreate data partition entry at same start if missing (do NOT mkfs)
  if [[ -n "$DATA_START" ]]; then
    if ! lsblk -ln "$DEVICE" | grep -q .; then
      true
    fi
    # If no large partition remains, recreate from saved start
    LARGE="$(lsblk -ln -b -o NAME,SIZE,TYPE "$DEVICE" | awk -v d="$(basename "$DEVICE")" '$3=="part"&&$1!=d{print $1,$2}' | sort -k2 -n | tail -1 | awk '{print $2}')"
    if [[ -z "$LARGE" || "$LARGE" -lt 5000000000 ]]; then
      echo "==> Recreating data partition entry at sector $DATA_START (no format)"
      sgdisk -n "0:${DATA_START}:0" -t "0:8300" -c "0:${USB_REPO_LABEL}" "$DEVICE" 2>&1 || \
        sgdisk -n "0:0:0" -t "0:8300" -c "0:${USB_REPO_LABEL}" "$DEVICE" 2>&1 || true
      partprobe "$DEVICE" 2>/dev/null || true
    fi
  else
    echo "==> Ensuring data partition exists in free space (no format if already there)"
    sgdisk -e "$DEVICE" 2>/dev/null || true
    # only create if free space and no large part
    LARGE="$(lsblk -ln -b -o NAME,SIZE,TYPE "$DEVICE" | awk -v d="$(basename "$DEVICE")" '$3=="part"&&$1!=d{print $2}' | sort -n | tail -1)"
    if [[ -z "$LARGE" || "$LARGE" -lt 5000000000 ]]; then
      sgdisk -n "0:0:0" -t "0:8300" -c "0:${USB_REPO_LABEL}" "$DEVICE" 2>&1 || true
      echo "WARN: New data partition may need filesystem: mkfs.ext4 -L $USB_REPO_LABEL <part>" >&2
    fi
  fi
  partprobe "$DEVICE" 2>/dev/null || true
  sleep 1
  lsblk -o NAME,SIZE,FSTYPE,LABEL,START "$DEVICE" || true
fi

# ---------------------------------------------------------------------------
# Repo / content update on LABEL=RHEL8OFFLINE
# ---------------------------------------------------------------------------
if [[ "$DO_REPOS" -eq 1 ]]; then
  if [[ ! -d "$REPO_DIR/BaseOS" ]]; then
    echo "ERROR: missing $REPO_DIR/BaseOS — run 01-reposync first" >&2
    exit 1
  fi

  # Find data partition: by label, else largest partition
  PART=""
  if blkid -L "$USB_REPO_LABEL" >/dev/null 2>&1; then
    PART="$(blkid -L "$USB_REPO_LABEL")"
  else
    PART="/dev/$(lsblk -ln -b -o NAME,SIZE,TYPE "$DEVICE" | awk -v d="$(basename "$DEVICE")" '$3=="part"&&$1!=d{print $1,$2}' | sort -k2 -n | tail -1 | awk '{print $1}')"
  fi
  if [[ -z "$PART" || ! -b "$PART" ]]; then
    echo "ERROR: could not find repo partition on $DEVICE" >&2
    exit 1
  fi

  # If no filesystem yet, offer format only when empty of label
  FSTYPE="$(blkid -o value -s TYPE "$PART" 2>/dev/null || true)"
  if [[ -z "$FSTYPE" ]]; then
    echo "ERROR: $PART has no filesystem. Format once with:" >&2
    echo "  sudo mkfs.ext4 -L $USB_REPO_LABEL $PART" >&2
    exit 1
  fi

  MNT=$(mktemp -d)
  echo "==> Mounting $PART -> $MNT (rw)"
  mount "$PART" "$MNT"

  echo "==> rsync offline repo -> USB (incremental)"
  rsync -aH --info=progress2 --delete \
    --exclude='lost+found' \
    "$REPO_DIR"/ "$MNT"/

  # Always refresh operator scripts/docs from project tree (full target set)
  echo "==> Refreshing scripts, packages lists, and docs on USB"
  mkdir -p "$MNT/scripts" "$MNT/packages" "$MNT/docs"
  if [[ -f "$ROOT/scripts/target-scripts.list" ]]; then
    cp -a "$ROOT/scripts/target-scripts.list" "$MNT/scripts/"
    mapfile -t _ts < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      "$ROOT/scripts/target-scripts.list")
  else
    _ts=(authorize-offline-usb.sh mount-offline-usb.sh enable-offline-repos.sh
         offline-repo-status.sh install-airgap-helpers.sh post-install-extra.sh
         update-target-repo-from-usb.sh)
  fi
  for s in "${_ts[@]}"; do
    [[ -f "$ROOT/scripts/$s" ]] && cp -a "$ROOT/scripts/$s" "$MNT/scripts/" && chmod 755 "$MNT/scripts/$s"
  done
  cp -a "$ROOT/packages"/*.txt "$MNT/packages/" 2>/dev/null || true
  cp -a "$ROOT/docs"/*.md "$MNT/docs/" 2>/dev/null || true
  [[ -f "$ROOT/docs/OFFLINE-INSTALL.md" ]] && cp -a "$ROOT/docs/OFFLINE-INSTALL.md" "$MNT/OFFLINE-INSTALL.md"
  [[ -f "$ROOT/README.md" ]] && cp -a "$ROOT/README.md" "$MNT/docs/PROJECT-README.md"
  [[ -f "$ROOT/out/ks.cfg" ]] && mkdir -p "$MNT/ks" && cp -a "$ROOT/out/ks.cfg" "$MNT/ks/ks.cfg"

  # Ensure label
  if command -v e2label >/dev/null 2>&1 && [[ "$(blkid -o value -s TYPE "$PART")" == ext4 ]]; then
    e2label "$PART" "$USB_REPO_LABEL" 2>/dev/null || true
  fi

  cat > "$MNT/README-ON-MEDIA.txt" <<EOF
Air-gap media (incrementally updated $(date -Is))
Label: $USB_REPO_LABEL

START:  docs/ROOT-HOME-README.md  (becomes /root/README.md on target)
        docs/OFFLINE-INSTALL.md   or  OFFLINE-INSTALL.md

On target:
  sudo authorize-offline-usb.sh
  sudo mount -L $USB_REPO_LABEL /mnt/rhel8offline
  # first time full setup:
  sudo bash /mnt/rhel8offline/scripts/post-install-extra.sh
  # later incremental repo refresh only:
  sudo bash /mnt/rhel8offline/scripts/update-target-repo-from-usb.sh
  # or if helpers already installed:
  #   sudo update-target-repo-from-usb.sh
EOF

  sync
  umount "$MNT"
  rmdir "$MNT"
  echo "==> Repo partition updated: $PART LABEL=$USB_REPO_LABEL"
fi

echo
echo "DONE. Current layout:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$DEVICE" || true
echo "On target system after plugging USB:"
echo "  sudo bash /mnt/rhel8offline/scripts/update-target-repo-from-usb.sh"
