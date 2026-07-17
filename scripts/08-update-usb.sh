#!/usr/bin/env bash
# Incrementally update content on an *existing* air-gap USB.
#
# NEVER rewrites the partition table, never dd's the whole disk, never mkfs.
# Only mounts existing filesystems and copies/rsyncs files.
#
# Usage (build host):
#   ./scripts/08-update-usb.sh                  # full repo tree on data partition (default)
#   ./scripts/08-update-usb.sh --repos
#   ./scripts/08-update-usb.sh --ks             # kickstart + scripts/docs only
#   ./scripts/08-update-usb.sh --boot           # update *writable* boot files via mount (EFI FAT)
#   ./scripts/08-update-usb.sh --all            # --boot + --repos
#   ./scripts/08-update-usb.sh --device /dev/sdb
#   ./scripts/08-update-usb.sh --dry-run
#
# Partition layout is owned solely by 07-prepare-usb.sh (first image).
# If the multi-GB data partition is missing from the table, re-run 07 (or fix
# GPT manually) — this script will refuse rather than create partitions.
#
# Kickstart (KS_BOOT_SOURCE=data): lives on LABEL=RHEL8OFFLINE as ks/ks.cfg.
#   ./scripts/05-generate-kickstart.sh && sudo $0 --ks --device /dev/sdX
#
# ISO9660 hybrid image content is read-only when mounted; full installer image
# replacement requires 07-prepare-usb.sh (not this script).
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
DO_KS_ONLY=0
DO_BOOT=0
DRY_RUN=0
DEVICE="${USB_DEVICE:-}"
USB_REPO_LABEL="${USB_REPO_LABEL:-RHEL8OFFLINE}"
REPO_DIR="${REPO_DIR:-$ROOT/out/offline-repo}"
[[ "$REPO_DIR" != /* ]] && REPO_DIR="$ROOT/${REPO_DIR#./}"
OUT_ISO="${OUT_ISO:-$ROOT/out/rhel-8.10-airgap-ks.iso}"
[[ "$OUT_ISO" != /* ]] && OUT_ISO="$ROOT/${OUT_ISO#./}"
ISO_EXTRACT="${ISO_EXTRACT:-$ROOT/out/iso-work/extract}"

# Multi-GB offline repo; hybrid ISO/EFI slices are much smaller
MIN_DATA_BYTES=$((5 * 1024 * 1024 * 1024))
MAX_BOOT_PART_BYTES=$((512 * 1024 * 1024))   # treat ≤512MiB vfat as boot/ESP candidates

usage() {
  cat <<EOF
Usage: $0 [options]

  --repos          Update full offline repo tree on data partition (default)
  --ks             Update only kickstart + scripts/docs/package lists (fast)
  --boot           Update writable boot/ESP files by *mounting* existing partitions
                   (never dd, never change partition table). ISO9660 stays read-only.
  --all            --boot + --repos
  --device PATH    USB block device (default: USB_DEVICE from config.env)
  --label NAME     Data partition filesystem label (default: $USB_REPO_LABEL)
  --dry-run        Show plan only
  -h, --help

This script does NOT:
  - dd an ISO onto the disk
  - run sgdisk/parted to create or resize partitions
  - mkfs any volume

First-time layout / broken GPT:  sudo ./scripts/07-prepare-usb.sh /dev/sdX

Kickstart-only (data partition, preferred):
  ./scripts/05-generate-kickstart.sh
  sudo $0 --ks --device /dev/sdX

Examples:
  $0 --repos --device /dev/sdb
  $0 --ks --device /dev/sdb
  $0 --boot --device /dev/sdb
  $0 --all --device /dev/sdb
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos) DO_REPOS=1; DO_KS_ONLY=0; DO_BOOT=0; shift ;;
    --ks) DO_REPOS=0; DO_KS_ONLY=1; DO_BOOT=0; shift ;;
    --boot) DO_BOOT=1; DO_REPOS=0; DO_KS_ONLY=0; shift ;;
    --all) DO_BOOT=1; DO_REPOS=1; DO_KS_ONLY=0; shift ;;
    --repair-gpt|--dd-boot|--reimage)
      echo "ERROR: $1 is not supported by 08-update-usb.sh" >&2
      echo "This script never rewrites partition tables or dd's the disk." >&2
      echo "Use: sudo ./scripts/07-prepare-usb.sh --yes /dev/sdX" >&2
      exit 2
      ;;
    --device) DEVICE="$2"; shift 2 ;;
    --label) USB_REPO_LABEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

disk_base() { basename "$1"; }

list_parts() {
  local d base
  d="$1"
  base="$(disk_base "$d")"
  lsblk -ln -b -o NAME,SIZE,TYPE "$d" 2>/dev/null \
    | awk -v b="$base" '$3=="part" && $1!=b {print $1, $2}'
}

# Data partition: LABEL, PARTLABEL, then largest >= MIN_DATA_BYTES
find_data_part() {
  local d="$1" lab="$2" p name size best="" bestsz=0
  if p="$(blkid -L "$lab" 2>/dev/null)" && [[ -n "$p" && -b "$p" ]]; then
    # Must belong to our disk if DEVICE is set
    if [[ -n "${DEVICE:-}" ]]; then
      local pk
      pk="$(lsblk -no PKNAME "$p" 2>/dev/null || true)"
      if [[ -n "$pk" && "$pk" != "$(disk_base "$DEVICE")" ]]; then
        :
      else
        echo "$p"
        return 0
      fi
    else
      echo "$p"
      return 0
    fi
  fi
  while read -r name size; do
    [[ -z "$name" ]] && continue
    p="/dev/$name"
    [[ -b "$p" ]] || continue
    if blkid -o value -s PARTLABEL "$p" 2>/dev/null | grep -qx "$lab"; then
      echo "$p"
      return 0
    fi
  done < <(list_parts "$d")

  while read -r name size; do
    [[ -z "$name" || -z "$size" ]] && continue
    if (( size >= MIN_DATA_BYTES && size > bestsz )); then
      bestsz=$size
      best="/dev/$name"
    fi
  done < <(list_parts "$d")
  [[ -n "$best" ]] && echo "$best" && return 0
  return 1
}

if [[ -z "$DEVICE" ]]; then
  if blkid -L "$USB_REPO_LABEL" >/dev/null 2>&1; then
    PART="$(blkid -L "$USB_REPO_LABEL")"
    pk="$(lsblk -no PKNAME "$PART" 2>/dev/null || true)"
    [[ -n "$pk" ]] && DEVICE="/dev/$pk"
  fi
fi

if [[ -z "$DEVICE" ]]; then
  echo "ERROR: Set --device /dev/sdX or USB_DEVICE in config.env" >&2
  lsblk -d -o NAME,SIZE,MODEL,TRAN | sed 's/^/  /'
  exit 1
fi

echo "=== Incremental USB content update (mount-only; no partition writes) ==="
echo "Device:  $DEVICE"
echo "Label:   $USB_REPO_LABEL"
echo "Repos:   $DO_REPOS   KS-only: $DO_KS_ONLY   Boot-files: $DO_BOOT   Dry-run: $DRY_RUN"
echo "Source:  $REPO_DIR"
if [[ -b "$DEVICE" ]]; then
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,UUID,MOUNTPOINT "$DEVICE" || true
else
  echo "(device not present on this host right now)"
fi
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would:"
  [[ "$DO_BOOT" -eq 1 ]] && echo "  - mount existing vfat/ESP partitions; copy boot files if writable"
  [[ "$DO_REPOS" -eq 1 ]] && echo "  - mount data partition; rsync $REPO_DIR/ + refresh ks/scripts/docs"
  [[ "$DO_KS_ONLY" -eq 1 ]] && echo "  - mount data partition; copy out/ks.cfg + scripts/docs/packages"
  echo "  - NEVER dd / sgdisk -n / mkfs / rewrite GPT"
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

# Unmount any mounted parts of device (so we can remount cleanly)
while read -r m; do
  [[ -z "$m" ]] && continue
  umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
done < <(lsblk -ln -o MOUNTPOINT "$DEVICE" | grep -v '^$' | tac || true)

# ---------------------------------------------------------------------------
# Resolve & mount data partition (existing only)
# ---------------------------------------------------------------------------
PART=""
MNT=""

mount_data_part() {
  PART="$(find_data_part "$DEVICE" "$USB_REPO_LABEL" || true)"
  if [[ -z "$PART" || ! -b "$PART" ]]; then
    echo "ERROR: no multi-GB data partition found on $DEVICE (LABEL=$USB_REPO_LABEL)." >&2
    echo "This script will not create partitions." >&2
    echo "Layout:" >&2
    lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,UUID "$DEVICE" >&2 || true
    echo >&2
    echo "If you only see ~3G + ~20M hybrid slices, the offline-repo entry is gone." >&2
    echo "Recover with a full reimage (rewrites partitions):" >&2
    echo "  sudo ./scripts/07-prepare-usb.sh --yes $DEVICE" >&2
    exit 1
  fi

  local part_bytes fstype
  part_bytes="$(blockdev --getsize64 "$PART")"
  if (( part_bytes < MIN_DATA_BYTES )); then
    echo "ERROR: refusing $PART ($(numfmt --to=iec --suffix=B "$part_bytes" 2>/dev/null || echo "$part_bytes")) — not the offline-repo volume" >&2
    exit 1
  fi
  fstype="$(blkid -o value -s TYPE "$PART" 2>/dev/null || true)"
  if [[ -z "$fstype" ]]; then
    echo "ERROR: $PART has no filesystem. Reimage with 07-prepare-usb.sh (this script never mkfs)." >&2
    exit 1
  fi

  MNT=$(mktemp -d)
  echo "==> Mounting data $PART -> $MNT (rw) [$(numfmt --to=iec --suffix=B "$part_bytes" 2>/dev/null || true) $fstype]"
  if ! mount "$PART" "$MNT"; then
    echo "ERROR: mount failed for $PART" >&2
    rmdir "$MNT" 2>/dev/null || true
    exit 1
  fi
}

umount_data_part() {
  if [[ -n "${MNT:-}" && -d "$MNT" ]]; then
    sync
    umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
    MNT=""
  fi
}

refresh_operator_files() {
  echo "==> Refreshing kickstart, scripts, packages lists, docs on data partition"
  mkdir -p "$MNT/scripts" "$MNT/packages" "$MNT/docs" "$MNT/ks"
  if [[ -f "$ROOT/out/ks.cfg" ]]; then
    cp -a "$ROOT/out/ks.cfg" "$MNT/ks/ks.cfg"
    echo "    ks/ks.cfg ($(wc -c < "$MNT/ks/ks.cfg") bytes)"
  else
    echo "WARN: out/ks.cfg missing — run ./scripts/05-generate-kickstart.sh" >&2
  fi
  if [[ -f "$ROOT/scripts/target-scripts.list" ]]; then
    cp -a "$ROOT/scripts/target-scripts.list" "$MNT/scripts/"
    mapfile -t _ts < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      "$ROOT/scripts/target-scripts.list")
  else
    _ts=(authorize-offline-usb.sh mount-offline-usb.sh enable-offline-repos.sh
         offline-repo-status.sh configure-grub-timeout.sh install-airgap-helpers.sh
         copy-offline-mirror-from-usb.sh install-from-local-mirror.sh
         update-target-repo-from-usb.sh)
  fi
  for s in "${_ts[@]}"; do
    [[ -f "$ROOT/scripts/$s" ]] && cp -a "$ROOT/scripts/$s" "$MNT/scripts/" && chmod 755 "$MNT/scripts/$s"
  done
  cp -a "$ROOT/packages"/*.txt "$MNT/packages/" 2>/dev/null || true
  cp -a "$ROOT/docs"/*.md "$MNT/docs/" 2>/dev/null || true
  [[ -f "$ROOT/docs/OFFLINE-INSTALL.md" ]] && cp -a "$ROOT/docs/OFFLINE-INSTALL.md" "$MNT/OFFLINE-INSTALL.md"
  [[ -f "$ROOT/README.md" ]] && cp -a "$ROOT/README.md" "$MNT/docs/PROJECT-README.md"
  cat > "$MNT/README-ON-MEDIA.txt" <<EOF
Air-gap media (content updated $(date -Is) via 08-update-usb — mount only)
Label: $USB_REPO_LABEL
Kickstart: ks/ks.cfg

On target (first setup — two steps):
  sudo authorize-offline-usb.sh
  sudo mount-offline-usb.sh
  sudo bash /mnt/rhel8offline/scripts/copy-offline-mirror-from-usb.sh
  sudo umount /mnt/rhel8offline   # unplug USB
  sudo install-from-local-mirror.sh
EOF
  if command -v e2label >/dev/null 2>&1 && [[ "$(blkid -o value -s TYPE "$PART")" == ext4 ]]; then
    # label is a filesystem metadata write, not a partition-table write
    e2label "$PART" "$USB_REPO_LABEL" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# --boot: mount existing writable boot partitions only (typically vfat ESP)
# ---------------------------------------------------------------------------
update_boot_files_via_mount() {
  echo "==> Boot file update (mount-only; no partition table / no dd)"

  local name size p ft bmnt updated=0 ro_iso=0
  local src=""
  # Prefer already-extracted tree from 06-inject; else extract needed files from OUT_ISO
  if [[ -d "$ISO_EXTRACT/EFI" || -d "$ISO_EXTRACT/isolinux" ]]; then
    src="$ISO_EXTRACT"
    echo "    Source tree: $src"
  elif [[ -f "$OUT_ISO" ]] && command -v xorriso >/dev/null 2>&1; then
    src="$(mktemp -d)"
    echo "    Extracting boot files from $OUT_ISO -> $src"
    # Minimal extract for ESP / boot configs
    xorriso -osirrox on -indev "$OUT_ISO" \
      -extract /EFI "$src/EFI" \
      -extract /isolinux "$src/isolinux" \
      -extract /ks "$src/ks" \
      2>/dev/null || true
    # Some ISOs nest differently
    xorriso -osirrox on -indev "$OUT_ISO" -extract / "$src/full" 2>/dev/null || true
  else
    echo "WARN: no ISO extract and no OUT_ISO/xorriso — cannot refresh boot files" >&2
    echo "      Run ./scripts/06-inject-kickstart.sh first, or skip --boot" >&2
    return 0
  fi

  while read -r name size; do
    [[ -z "$name" || -z "$size" ]] && continue
    p="/dev/$name"
    [[ -b "$p" ]] || continue
    ft="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
    [[ -n "$ft" ]] || continue

    # ISO9660: mount RO and report only
    if [[ "$ft" == "iso9660" || "$ft" == "udf" ]]; then
      ro_iso=1
      bmnt=$(mktemp -d)
      if mount -o ro "$p" "$bmnt" 2>/dev/null; then
        echo "    $p ($ft): mounted read-only — ISO hybrid content cannot be updated in place"
        if [[ -f "$bmnt/ks/ks.cfg" ]]; then
          echo "      (has ks/ks.cfg inside ISO image; change requires 07-prepare-usb reimage)"
        fi
        umount "$bmnt" 2>/dev/null || umount -l "$bmnt" 2>/dev/null || true
      fi
      rmdir "$bmnt" 2>/dev/null || true
      continue
    fi

    # Writable candidates: FAT ESP / small boot partitions
    case "$ft" in
      vfat|fat|fat32|msdos|exfat) ;;
      *)
        # skip large data-like partitions here
        continue
        ;;
    esac
    if (( size > MAX_BOOT_PART_BYTES )); then
      echo "    skip $p ($ft, large) — not treating as ESP"
      continue
    fi

    bmnt=$(mktemp -d)
    if ! mount -o rw "$p" "$bmnt" 2>/dev/null; then
      echo "    WARN: could not mount $p ($ft) rw" >&2
      rmdir "$bmnt" 2>/dev/null || true
      continue
    fi
    echo "    $p ($ft, $(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size")) mounted rw"

    # FAT/ESP cannot store Unix mode/owner/xattrs — avoid rsync -a / cp -a noise
    # -rltD ≈ archive minus -pgo (perms/owner/group); drop links if unsupported
    local fat_rsync=(rsync -rltD --no-perms --no-owner --no-group --no-acls --no-xattrs --modify-window=1)

    # Copy EFI tree if present on ESP
    for efi_src in "$src/EFI" "$src/full/EFI"; do
      if [[ -d "$efi_src" ]]; then
        mkdir -p "$bmnt/EFI"
        if "${fat_rsync[@]}" "$efi_src"/ "$bmnt/EFI"/; then
          echo "      updated EFI/ from $(basename "$(dirname "$efi_src")")/EFI"
          updated=1
        fi
        break
      fi
    done
    # Common flat ESP layout: EFI/BOOT/grub.cfg
    for gsrc in "$src/EFI/BOOT/grub.cfg" "$src/full/EFI/BOOT/grub.cfg"; do
      if [[ -f "$gsrc" ]]; then
        mkdir -p "$bmnt/EFI/BOOT"
        cp --no-preserve=mode,ownership,timestamps "$gsrc" "$bmnt/EFI/BOOT/grub.cfg" 2>/dev/null \
          || cp "$gsrc" "$bmnt/EFI/BOOT/grub.cfg"
        echo "      updated EFI/BOOT/grub.cfg"
        updated=1
        break
      fi
    done
    # Optional: isolinux if somehow on a small fat (uncommon)
    for isrc in "$src/isolinux" "$src/full/isolinux"; do
      if [[ -d "$isrc" && -d "$bmnt/isolinux" ]]; then
        if "${fat_rsync[@]}" "$isrc"/ "$bmnt/isolinux"/; then
          echo "      updated isolinux/"
          updated=1
        fi
        break
      fi
    done

    sync
    umount "$bmnt" 2>/dev/null || umount -l "$bmnt" 2>/dev/null || true
    rmdir "$bmnt" 2>/dev/null || true
  done < <(list_parts "$DEVICE")

  # Cleanup temp extract if we created one under /tmp
  if [[ -n "$src" && "$src" != "$ISO_EXTRACT" && "$src" == /tmp/* ]]; then
    rm -rf "$src"
  fi

  if [[ "$updated" -eq 1 ]]; then
    echo "==> Writable boot/ESP files updated via mount"
  else
    echo "==> No writable boot files updated"
    if [[ "$ro_iso" -eq 1 ]]; then
      echo "    Hybrid installer body is ISO9660 (read-only). To replace it:"
      echo "      ./scripts/05-generate-kickstart.sh && ./scripts/06-inject-kickstart.sh"
      echo "      sudo ./scripts/07-prepare-usb.sh --yes $DEVICE"
    fi
    echo "    Kickstart for installs should live on the data partition (use --ks)."
  fi
}

# ---------------------------------------------------------------------------
# Main actions
# ---------------------------------------------------------------------------
if [[ "$DO_BOOT" -eq 1 ]]; then
  update_boot_files_via_mount
fi

if [[ "$DO_REPOS" -eq 1 ]]; then
  if [[ ! -d "$REPO_DIR/BaseOS" ]]; then
    echo "ERROR: missing $REPO_DIR/BaseOS — run 01-reposync first" >&2
    exit 1
  fi
  mount_data_part
  echo "==> rsync offline repo -> data partition (incremental)"
  rsync -aH --info=progress2 --delete \
    --exclude='lost+found' \
    "$REPO_DIR"/ "$MNT"/
  refresh_operator_files
  umount_data_part
  echo "==> Repo content updated on data partition"
  PART="$(find_data_part "$DEVICE" "$USB_REPO_LABEL" || true)"
  [[ -n "$PART" ]] && blkid "$PART" || true
fi

if [[ "$DO_KS_ONLY" -eq 1 ]]; then
  mount_data_part
  refresh_operator_files
  umount_data_part
  echo "==> Kickstart/helpers updated on data partition"
  echo "    Installer should use: inst.ks=hd:LABEL=$USB_REPO_LABEL:/ks/ks.cfg"
  echo "    (KS_BOOT_SOURCE=data in 06-inject; no boot rewrite needed for ks changes)"
  PART="$(find_data_part "$DEVICE" "$USB_REPO_LABEL" || true)"
  [[ -n "$PART" ]] && blkid "$PART" || true
fi

echo
echo "DONE. Layout (unchanged partition table):"
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,UUID,MOUNTPOINT "$DEVICE" || true
echo
echo "Reminder: 08-update-usb never writes partitions. Broken layout → 07-prepare-usb."
