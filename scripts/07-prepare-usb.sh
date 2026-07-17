#!/usr/bin/env bash
# Step 07 (final): Write bootable installer + offline package partition to a USB disk.
#
# Run AFTER all fetch steps:
#   01-reposync, 02-fetch-epel, 03-fetch-python-wheels, (04-check),
#   05-generate-kickstart, 06-inject-kickstart
#
# Layout after success:
#   [0 .. ISO image]  isohybrid RHEL installer (dd of custom kickstart ISO)
#   [after ISO .. end] ext4 LABEL=RHEL8OFFLINE:
#       BaseOS/ AppStream/ CodeReadyBuilder/ EPEL/ python-wheels/
#       packages/ docs/ scripts/ ks/ README-ON-MEDIA.txt
#
# Usage:
#   ./scripts/07-prepare-usb.sh --dry-run [/dev/sdb]
#   sudo ./scripts/07-prepare-usb.sh /dev/sdb
#   sudo ./scripts/07-prepare-usb.sh --yes /dev/sdb
#
# Defaults DEVICE from config.env USB_DEVICE if set.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/config.env" ]]; then
  # shellcheck disable=SC1091
  set +u
  source "$ROOT/config.env"
  set -u
fi

# Resolve relative paths from project root
cd "$ROOT"

DRY_RUN=0
ASSUME_YES=0
ALLOW_INCOMPLETE_REPO=0
ALLOW_STOCK_ISO=0
DEVICE=""

usage() {
  cat <<EOF
Usage: $0 [options] [DEVICE]

Options:
  --dry-run              Print the plan and preflight checks; do not write
  --yes                  Do not prompt for YES (still requires root for real run)
  --allow-incomplete-repo
                         Proceed even if AppStream/BaseOS look incomplete
  --allow-stock-iso      Allow SOURCE_ISO if custom kickstart ISO is missing
  -h, --help             This help

DEVICE defaults to USB_DEVICE from config.env (currently: ${USB_DEVICE:-unset})
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --allow-incomplete-repo) ALLOW_INCOMPLETE_REPO=1; shift ;;
    --allow-stock-iso) ALLOW_STOCK_ISO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      DEVICE="$1"
      shift
      ;;
  esac
done

DEVICE="${DEVICE:-${USB_DEVICE:-}}"
CUSTOM_ISO="${OUT_ISO:-$ROOT/out/rhel-8.10-airgap-ks.iso}"
SOURCE_ISO_PATH="${SOURCE_ISO:-$ROOT/rhel-8.10-fips-stig.iso}"
# Resolve relative SOURCE_ISO against project root
if [[ "$SOURCE_ISO_PATH" != /* ]]; then
  SOURCE_ISO_PATH="$ROOT/${SOURCE_ISO_PATH#./}"
fi
REPO_DIR_CFG="${REPO_DIR:-$ROOT/out/offline-repo}"
if [[ "$REPO_DIR_CFG" != /* ]]; then
  REPO_DIR_CFG="$ROOT/${REPO_DIR_CFG#./}"
fi
REPO_DIR="$REPO_DIR_CFG"
USB_REPO_LABEL="${USB_REPO_LABEL:-RHEL8OFFLINE}"
ISO=""

hr() { printf '%s\n' "------------------------------------------------------------"; }

pick_iso() {
  if [[ -f "$CUSTOM_ISO" ]]; then
    ISO="$CUSTOM_ISO"
    echo "ISO: custom kickstart image"
    echo "     $ISO"
    return 0
  fi
  if [[ "$ALLOW_STOCK_ISO" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
    if [[ -f "$SOURCE_ISO_PATH" ]]; then
      ISO="$SOURCE_ISO_PATH"
      echo "ISO: STOCK source (kickstart NOT injected yet)"
      echo "     $ISO"
      echo "     Build custom ISO with: ./scripts/05-generate-kickstart.sh && ./scripts/06-inject-kickstart.sh"
      return 0
    fi
  fi
  echo "ERROR: Custom ISO not found: $CUSTOM_ISO" >&2
  echo "  1) Set password hashes in config.env" >&2
  echo "  2) ./scripts/05-generate-kickstart.sh" >&2
  echo "  3) ./scripts/06-inject-kickstart.sh" >&2
  echo "  Or re-run with --allow-stock-iso to write the unpatched FIPS ISO (not recommended for final media)." >&2
  return 1
}

bytes_human() {
  local b="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$b"
  else
    echo "${b} bytes"
  fi
}

preflight() {
  local rc=0
  echo "==> Preflight"
  hr

  if [[ -z "$DEVICE" ]]; then
    echo "ERROR: No DEVICE. Pass /dev/sdb or set USB_DEVICE in config.env" >&2
    lsblk -d -o NAME,SIZE,MODEL,TRAN,TYPE | sed 's/^/  /' || true
    return 1
  fi

  if [[ ! -b "$DEVICE" ]]; then
    echo "ERROR: Not a block device: $DEVICE" >&2
    return 1
  fi

  # Never operate on the disk that backs /
  local root_src
  root_src="$(findmnt -n -o SOURCE / || true)"
  if [[ -n "$root_src" ]] && [[ "$root_src" == "$DEVICE"* ]]; then
    echo "ERROR: $DEVICE appears to back root filesystem ($root_src). Aborting." >&2
    return 1
  fi
  if findmnt -n "$DEVICE" >/dev/null 2>&1; then
    echo "WARN: $DEVICE or a child is mounted — will unmount before write (real run only)."
  fi

  # Prefer USB-attached disks
  local bus model serial size
  bus="$(lsblk -dn -o TRAN "$DEVICE" 2>/dev/null || true)"
  model="$(lsblk -dn -o MODEL "$DEVICE" 2>/dev/null || true)"
  serial="$(lsblk -dn -o SERIAL "$DEVICE" 2>/dev/null || true)"
  size="$(lsblk -dn -o SIZE "$DEVICE" 2>/dev/null || true)"
  echo "Device:  $DEVICE"
  echo "  size:  $size"
  echo "  model: $model"
  echo "  serial:$serial"
  echo "  tran:  ${bus:-unknown}"
  if [[ "${bus}" != "usb" && "${bus}" != "USB" ]]; then
    echo "WARN: transport is '${bus:-unknown}', not 'usb'. Double-check this is the stick you intend."
  fi

  echo
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL "$DEVICE" || true
  echo

  pick_iso || rc=1
  if [[ -n "$ISO" && -f "$ISO" ]]; then
    local iso_bytes
    iso_bytes="$(stat -c%s "$ISO")"
    echo "  size:  $(bytes_human "$iso_bytes") ($iso_bytes bytes)"
  fi

  echo
  echo "Repo:  $REPO_DIR  ->  partition label $USB_REPO_LABEL"
  if [[ ! -d "$REPO_DIR" ]]; then
    echo "ERROR: REPO_DIR missing: $REPO_DIR" >&2
    rc=1
  else
    du -sh "$REPO_DIR" 2>/dev/null || true
    for d in BaseOS AppStream CodeReadyBuilder EPEL; do
      if [[ -d "$REPO_DIR/$d" ]]; then
        local n
        n="$(find "$REPO_DIR/$d" -name '*.rpm' 2>/dev/null | wc -l)"
        printf '  %-18s %s  rpms=%s\n' "$d" "$(du -sh "$REPO_DIR/$d" 2>/dev/null | awk '{print $1}')" "$n"
      else
        printf '  %-18s MISSING\n' "$d"
      fi
    done
    if [[ -d "$REPO_DIR/python-wheels" ]]; then
      local nw
      nw="$(find "$REPO_DIR/python-wheels" -name '*.whl' 2>/dev/null | wc -l)"
      printf '  %-18s %s  wheels=%s\n' "python-wheels" "$(du -sh "$REPO_DIR/python-wheels" 2>/dev/null | awk '{print $1}')" "$nw"
    else
      printf '  %-18s MISSING (run ./scripts/03-fetch-python-wheels.sh)\n' "python-wheels"
      if [[ "$ALLOW_INCOMPLETE_REPO" -eq 0 ]]; then
        rc=1
      fi
    fi
    local total_rpms
    total_rpms="$(find "$REPO_DIR" -name '*.rpm' 2>/dev/null | wc -l)"
    echo "  total rpms: $total_rpms"
    if [[ ! -d "$REPO_DIR/BaseOS" || ! -d "$REPO_DIR/AppStream" ]]; then
      echo "ERROR: BaseOS and AppStream directories are required under $REPO_DIR" >&2
      rc=1
    fi
    if [[ ! -d "$REPO_DIR/EPEL/repodata" && ! -d "$REPO_DIR/EPEL/Packages" ]]; then
      echo "ERROR: EPEL tree missing — run ./scripts/02-fetch-epel-packages.sh" >&2
      if [[ "$ALLOW_INCOMPLETE_REPO" -eq 0 ]]; then
        rc=1
      fi
    fi
    local sync_running=0
    if docker top rhel8-reposync 2>/dev/null | grep -q 'dnf reposync'; then
      sync_running=1
      echo "WARN: reposync is still running in container rhel8-reposync"
    fi
    if [[ ! -d "$REPO_DIR/CodeReadyBuilder" ]]; then
      echo "WARN: CodeReadyBuilder not present yet (optional but useful)"
    fi
    if [[ "$total_rpms" -lt 2000 ]]; then
      echo "ERROR: Repo looks incomplete ($total_rpms RPMs)." >&2
      rc=1
    fi
    # Block real writes while download is still active unless explicitly allowed
    if [[ "$sync_running" -eq 1 && "$ALLOW_INCOMPLETE_REPO" -eq 0 ]]; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "NOTE: Real sudo run will REFUSE while reposync is active (unless --allow-incomplete-repo)."
        echo "      Wait for ALL_SYNC_COMPLETE in the download log first."
      else
        echo "ERROR: Offline repo download still in progress." >&2
        echo "       Wait for ALL_SYNC_COMPLETE in out/logs/LATEST_DOWNLOAD, or pass" >&2
        echo "       --allow-incomplete-repo to write a partial tree now." >&2
        rc=1
      fi
    fi
  fi

  echo
  echo "Content that will be copied onto the data partition:"
  echo "  - Full offline-repo tree (BaseOS, AppStream, CRB, EPEL, python-wheels)"
  echo "  - packages/*.txt (package lists)"
  echo "  - docs/ (ROOT-HOME-README, OFFLINE-INSTALL, ADDING-PACKAGES, …)"
  echo "  - scripts/ (all target helpers via target-scripts.list)"
  echo "  - project README.md"
  [[ -f "$ROOT/out/ks.cfg" ]] && echo "  - ks/ks.cfg" || echo "  - ks: (missing out/ks.cfg — run ./scripts/05-generate-kickstart.sh)"
  [[ -f "$ROOT/scripts/post-install-extra.sh" ]] && echo "  - scripts/post-install-extra.sh OK" || echo "  - post-install-extra.sh MISSING"
  [[ -f "$ROOT/scripts/install-airgap-helpers.sh" ]] && echo "  - scripts/install-airgap-helpers.sh OK" || echo "  - install-airgap-helpers.sh MISSING"
  [[ -f "$ROOT/docs/ROOT-HOME-README.md" ]] && echo "  - docs/ROOT-HOME-README.md OK" || echo "  - ROOT-HOME-README.md MISSING"

  echo
  echo "Required tools:"
  local t
  for t in dd sgdisk parted mkfs.ext4 rsync wipefs partprobe blockdev; do
    if command -v "$t" >/dev/null 2>&1; then
      echo "  OK  $t"
    else
      echo "  MISSING  $t"
      rc=1
    fi
  done

  hr
  if [[ "$rc" -ne 0 ]]; then
    echo "Preflight FAILED (see ERROR lines above)."
  else
    echo "Preflight OK."
  fi
  return "$rc"
}

plan() {
  local iso_bytes start_mib
  iso_bytes="$(stat -c%s "$ISO")"
  start_mib=$(( (iso_bytes / 1048576) + 2 ))
  echo "==> Write plan for $DEVICE"
  hr
  cat <<EOF
1. Unmount any mounted partitions on $DEVICE
2. dd if=$ISO of=$DEVICE bs=4M conv=fsync status=progress
   - Writes isohybrid installer to the start of the disk
3. Create a Linux partition in free space starting at ~${start_mib} MiB to end of disk
4. mkfs.ext4 -L $USB_REPO_LABEL <new-partition>
5. rsync -aH $REPO_DIR/  (BaseOS, AppStream, CRB, EPEL, python-wheels, …)
6. Overlay offline reference material:
     packages/  docs/ (incl. ROOT-HOME-README)  scripts/ (all target helpers)  ks/ks.cfg
7. Write README-ON-MEDIA.txt pointing at docs/ROOT-HOME-README.md + OFFLINE-INSTALL.md
8. sync + unmount

RESULT:
  - Bootable installer at the beginning of $DEVICE
  - Offline RPMs + EPEL + Python wheels + install docs on LABEL=$USB_REPO_LABEL

DESTRUCTIVE: existing partitions on $DEVICE will be destroyed
  (currently has whatever lsblk showed in preflight).
EOF
  hr
}

resolve_data_part() {
  # Prefer the partition whose start (bytes) is past the ISO image
  local iso_bytes start_bytes part pstart
  iso_bytes="$(stat -c%s "$ISO")"
  start_bytes=$(( ((iso_bytes / 1048576) + 2) * 1048576 ))

  # Wait for udev
  partprobe "$DEVICE" 2>/dev/null || true
  sleep 1
  udevadm settle 2>/dev/null || true

  local best="" best_start=0
  while read -r part pstart; do
    [[ -z "$part" || -z "$pstart" ]] && continue
    # pstart from lsblk -b -n -o NAME,START is in sectors on some versions;
    # use /sys for reliability
    local sys="/sys/block/$(basename "$DEVICE")/$(basename "$part")/start"
    local sectors=0
    if [[ -f "$sys" ]]; then
      sectors="$(cat "$sys")"
    fi
    local byte_start=$(( sectors * 512 ))
    if (( byte_start >= start_bytes - 1048576 )); then
      if [[ -z "$best" || "$byte_start" -gt "$best_start" ]]; then
        best="/dev/$(basename "$part")"
        # if lsblk gave full path already
        if [[ -b "/dev/$(basename "$part")" ]]; then
          best="/dev/$(basename "$part")"
        fi
        best_start=$byte_start
      fi
    fi
  done < <(lsblk -ln -o NAME "$DEVICE" | tail -n +2)

  # Fallback: highest-numbered partition node
  if [[ -z "$best" || ! -b "$best" ]]; then
    if [[ "$DEVICE" == *nvme* || "$DEVICE" == *mmcblk* ]]; then
      for n in 4 3 2 1; do
        [[ -b "${DEVICE}p${n}" ]] && best="${DEVICE}p${n}" && break
      done
    else
      for n in 4 3 2 1; do
        [[ -b "${DEVICE}${n}" ]] && best="${DEVICE}${n}" && break
      done
    fi
  fi

  # Prefer largest partition that is not the tiny ISO hybrid partitions
  if [[ -n "$best" && -b "$best" ]]; then
    echo "$best"
    return 0
  fi
  return 1
}

do_write() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: Real write requires root. Use: sudo $0 $DEVICE" >&2
    exit 1
  fi

  if [[ "$ASSUME_YES" -ne 1 ]]; then
    echo
    echo "************************************************************"
    echo " THIS WILL ERASE ALL DATA ON: $DEVICE"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL "$DEVICE" || true
    echo " ISO:  $ISO"
    echo " REPO: $REPO_DIR -> LABEL=$USB_REPO_LABEL"
    echo "************************************************************"
    read -r -p "Type YES to continue: " ans
    [[ "$ans" == "YES" ]] || { echo "Aborted."; exit 1; }
  fi

  echo "==> Unmounting any filesystems on $DEVICE"
  # Unmount children first
  local m
  while read -r m; do
    [[ -z "$m" ]] && continue
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
  done < <(lsblk -ln -o MOUNTPOINT "$DEVICE" | grep -v '^$' | tac || true)

  echo "==> Writing isohybrid ISO to $DEVICE (this takes a few minutes for ~3GB)"
  dd if="$ISO" of="$DEVICE" bs=4M status=progress conv=fsync oflag=direct
  sync
  partprobe "$DEVICE" || true
  sleep 2

  local iso_bytes start_mib
  iso_bytes="$(stat -c%s "$ISO")"
  # First MiB *after* the ISO image (+ small gap). Fallback if free-space auto-detect fails.
  start_mib=$(( (iso_bytes / 1048576) + 2 ))
  echo "==> Creating offline-repo partition in free space after the hybrid ISO (~${start_mib} MiB+)"

  # RHEL/Fedora isohybrid ISOs embed a GPT that only spans the *image* size (~3GB).
  # After dd onto a larger USB, the backup GPT sits mid-disk and tools report
  # "Invalid partition data!". Relocate it to the real end of the disk first.
  create_data_partition() {
    if command -v sgdisk >/dev/null 2>&1; then
      echo "    Fixing hybrid GPT to cover the full disk (sgdisk -e)..."
      if ! sgdisk -e "$DEVICE" 2>&1; then
        echo "    WARN: sgdisk -e reported an error (continuing)" >&2
      fi
      # Clear any bogus secondary structures then re-expand if needed
      partprobe "$DEVICE" 2>/dev/null || true
      sleep 1

      echo "    Partition table after GPT fix:"
      sgdisk -p "$DEVICE" 2>&1 || true

      local first_free
      first_free="$(sgdisk -F "$DEVICE" 2>/dev/null | tail -n1 | tr -dc '0-9' || true)"
      echo "    First free sector: ${first_free:-unknown}"

      # Prefer start at first free sector; fill to end of disk (0 = end)
      if [[ -n "${first_free}" && "${first_free}" -gt 2048 ]]; then
        if sgdisk -n "0:${first_free}:0" -t "0:8300" -c "0:${USB_REPO_LABEL}" "$DEVICE" 2>&1; then
          echo "    Created data partition (sgdisk, start sector ${first_free})"
          return 0
        fi
      fi
      # Largest free block
      if sgdisk -n "0:0:0" -t "0:8300" -c "0:${USB_REPO_LABEL}" "$DEVICE" 2>&1; then
        echo "    Created data partition (sgdisk, largest free block)"
        return 0
      fi
      # Explicit MiB start after ISO
      if sgdisk -n "0:${start_mib}M:0" -t "0:8300" -c "0:${USB_REPO_LABEL}" "$DEVICE" 2>&1; then
        echo "    Created data partition (sgdisk, ${start_mib}MiB)"
        return 0
      fi
      echo "    sgdisk could not create data partition" >&2
    fi

    echo "    Falling back to parted..." >&2
    local pttype
    pttype="$(blkid -p -s PTTYPE -o value "$DEVICE" 2>/dev/null || true)"
    if [[ -z "$pttype" ]]; then
      pttype="$(parted -s "$DEVICE" print 2>/dev/null | awk '/Partition Table:/ {print $3}' || true)"
    fi
    echo "    Partition table type: ${pttype:-unknown}"

    # parted GPT: mkpart <name> <fs-type> <start> <end>
    # parted MBR: mkpart primary|logical|extended <fs-type> <start> <end>
    # Using "RHEL8OFFLINE" as first arg on MBR fails with "Expecting a partition type".
    if [[ "$pttype" == "gpt" ]]; then
      parted -s "$DEVICE" unit MiB mkpart "${USB_REPO_LABEL}" ext4 "${start_mib}MiB" 100% && return 0
      parted -s "$DEVICE" mkpart "${USB_REPO_LABEL}" ext4 "${start_mib}MiB" 100% && return 0
    fi
    # MBR / hybrid fallback — part-type must be primary
    parted -s "$DEVICE" unit MiB mkpart primary ext4 "${start_mib}MiB" 100% && return 0
    parted -s "$DEVICE" mkpart primary ext4 "${start_mib}MiB" 100% && return 0
    return 1
  }

  if ! create_data_partition; then
    echo "ERROR: Could not create offline-repo partition on $DEVICE" >&2
    echo "Manual recovery after the ISO dd:" >&2
    echo "  sudo sgdisk -e $DEVICE" >&2
    echo "  sudo sgdisk -n 0:0:0 -t 0:8300 -c 0:${USB_REPO_LABEL} $DEVICE" >&2
    echo "  sudo partprobe $DEVICE" >&2
    echo "  sudo mkfs.ext4 -L ${USB_REPO_LABEL} \$(lsblk -ln -o NAME,SIZE $DEVICE | sort -k2 -h | tail -1 | awk '{print \"/dev/\"\$1}')" >&2
    exit 1
  fi

  partprobe "$DEVICE" || true
  sleep 2
  udevadm settle 2>/dev/null || true
  echo "    Layout after partition create:"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,START "$DEVICE" || true
  sgdisk -p "$DEVICE" 2>/dev/null || true

  # Prefer the *largest* partition on the stick (repo data), never the ~3GB ISO or 20MB EFI.
  local DATA_PART=""
  DATA_PART="$(lsblk -ln -b -o NAME,SIZE,TYPE "$DEVICE" \
    | awk -v dev="$(basename "$DEVICE")" '$3=="part" && $1!=dev {print $1,$2}' \
    | sort -k2 -n | tail -1 | awk '{print "/dev/"$1}')"

  if [[ -z "${DATA_PART:-}" || ! -b "$DATA_PART" ]]; then
    DATA_PART="$(resolve_data_part || true)"
  fi

  if [[ -z "${DATA_PART:-}" || ! -b "$DATA_PART" ]]; then
    echo "ERROR: Could not determine data partition on $DEVICE" >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,START "$DEVICE" || true
    exit 1
  fi

  # Safety: never format the hybrid ISO/EFI slices by mistake
  local part_bytes
  part_bytes="$(blockdev --getsize64 "$DATA_PART")"
  if (( part_bytes < 5 * 1024 * 1024 * 1024 )); then
    echo "ERROR: Refusing to format $DATA_PART — only $(bytes_human "$part_bytes"); expected multi‑GB repo partition." >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,START "$DEVICE" || true
    exit 1
  fi
  echo "==> Using data partition $DATA_PART ($(bytes_human "$part_bytes"))"

  echo "==> Formatting $DATA_PART as ext4 LABEL=$USB_REPO_LABEL ($(bytes_human "$part_bytes"))"
  mkfs.ext4 -F -L "$USB_REPO_LABEL" "$DATA_PART"

  local MNT
  MNT="$(mktemp -d)"
  mount "$DATA_PART" "$MNT"
  echo "==> Copying offline repository (rsync) — can take a long time"
  if [[ -d "$REPO_DIR" ]]; then
    rsync -aH --info=progress2 "$REPO_DIR"/ "$MNT"/
  else
    echo "ERROR: REPO_DIR missing during copy" >&2
    umount "$MNT" || true
    rmdir "$MNT" || true
    exit 1
  fi

  # Explicitly ensure critical offline content is present (in case REPO_DIR was incomplete)
  echo "==> Ensuring EPEL RPMs, Python wheels, docs, and install helpers are on media"
  if [[ -d "$REPO_DIR/EPEL" ]]; then
    rsync -aH "$REPO_DIR/EPEL"/ "$MNT/EPEL"/
  fi
  if [[ -d "$REPO_DIR/python-wheels" ]]; then
    rsync -aH "$REPO_DIR/python-wheels"/ "$MNT/python-wheels"/
  elif [[ -d "$ROOT/out/offline-repo/python-wheels" ]]; then
    rsync -aH "$ROOT/out/offline-repo/python-wheels"/ "$MNT/python-wheels"/
  fi

  # Package lists + offline documentation for air-gapped operators
  mkdir -p "$MNT/packages" "$MNT/docs" "$MNT/ks" "$MNT/scripts"
  if [[ -d "$ROOT/packages" ]]; then
    rsync -aH --include='*.txt' --exclude='*' "$ROOT/packages"/ "$MNT/packages"/ 2>/dev/null || \
      cp -a "$ROOT/packages"/*.txt "$MNT/packages/" 2>/dev/null || true
  fi
  if [[ -d "$ROOT/docs" ]]; then
    rsync -aH "$ROOT/docs"/ "$MNT/docs"/
  fi
  [[ -f "$ROOT/README.md" ]] && cp -a "$ROOT/README.md" "$MNT/docs/PROJECT-README.md"
  # Primary entry point for operators on the stick
  if [[ -f "$ROOT/docs/OFFLINE-INSTALL.md" ]]; then
    cp -a "$ROOT/docs/OFFLINE-INSTALL.md" "$MNT/OFFLINE-INSTALL.md"
  fi

  if [[ -f "$ROOT/out/ks.cfg" ]]; then
    cp -a "$ROOT/out/ks.cfg" "$MNT/ks/ks.cfg"
  else
    echo "WARN: out/ks.cfg missing — not copied"
  fi
  # All target-facing helpers (single list)
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
    if [[ -f "$ROOT/scripts/$s" ]]; then
      cp -a "$ROOT/scripts/$s" "$MNT/scripts/"
      chmod 755 "$MNT/scripts/$s"
    else
      echo "WARN: target script missing: $s" >&2
    fi
  done

  # Verify critical paths landed on the stick
  local missing=0
  for need in BaseOS AppStream EPEL python-wheels docs/OFFLINE-INSTALL.md \
              docs/ROOT-HOME-README.md scripts/post-install-extra.sh \
              scripts/install-airgap-helpers.sh scripts/authorize-offline-usb.sh; do
    if [[ ! -e "$MNT/$need" ]]; then
      echo "WARN: missing on media after copy: $need" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 && "$ALLOW_INCOMPLETE_REPO" -eq 0 ]]; then
    echo "ERROR: USB data partition incomplete. Fix fetch steps and re-run." >&2
    umount "$MNT" || true
    rmdir "$MNT" || true
    exit 1
  fi

  cat > "$MNT/README-ON-MEDIA.txt" <<EOF
RHEL 8.10 air-gapped media
Created: $(date -Is)
Installer ISO written to start of this USB: $(basename "$ISO")
Repo filesystem label: $USB_REPO_LABEL

START HERE:
  docs/ROOT-HOME-README.md   (installed as /root/README.md on target)
  docs/OFFLINE-INSTALL.md    (also OFFLINE-INSTALL.md at partition root)

Layout:
  BaseOS/  AppStream/  CodeReadyBuilder/
  EPEL/                 # htop, nload, pv, keepassxc, rdesktop, …
  python-wheels/        # pipx + deps (offline pip)
  packages/             # required.txt, epel-extra.txt, python-extra.txt, …
  docs/                 # ROOT-HOME-README, OFFLINE-INSTALL, ADDING-PACKAGES, …
  scripts/              # all target helpers (post-install, authorize, update, …)
  ks/ks.cfg

Quick start on installed system (USB inserted):
  sudo authorize-offline-usb.sh          # if keyboard/storage blocked
  sudo mount -L $USB_REPO_LABEL /mnt/rhel8offline
  sudo bash /mnt/rhel8offline/scripts/post-install-extra.sh

  # Copies mirror to /var/lib/offline-repos, installs helpers/docs early,
  # unmounts USB, then installs packages from local disk.
  # Day-to-day (no USB): see /root/README.md
  #   sudo offline-repo-status.sh
  #   sudo dnf install <package>
EOF

  sync
  umount "$MNT"
  rmdir "$MNT"

  echo
  echo "=============================="
  echo " USB ready: $DEVICE"
  echo " Installer: dd of $ISO"
  echo " Offline repos: $DATA_PART LABEL=$USB_REPO_LABEL"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT "$DEVICE" || true
  echo "=============================="
  echo "Boot the target from this USB (UEFI preferred)."
  echo "Kickstart offline repos use LABEL=$USB_REPO_LABEL."
}

# --- main ---
echo "RHEL air-gap USB preparer (step 07 — final)"
echo "Project: $ROOT"
echo

if ! preflight; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo
    echo "Dry-run finished with preflight issues (no writes performed)."
    # Still show plan if we at least have an ISO path candidate
    if [[ -n "${ISO:-}" && -f "${ISO:-}" ]]; then
      plan
    fi
    exit 1
  fi
  exit 1
fi

plan

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "DRY-RUN complete — no changes written."
  echo "When ready (after 01–06 fetch/kickstart steps + custom ISO):"
  echo "  sudo $0 ${DEVICE}"
  echo "Optional flags: --yes  --allow-incomplete-repo  --allow-stock-iso"
  exit 0
fi

do_write
