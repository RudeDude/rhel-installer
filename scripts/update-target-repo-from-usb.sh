#!/usr/bin/env bash
# On the *target* air-gapped system: refresh the local offline mirror from USB.
# Lives on the USB at scripts/update-target-repo-from-usb.sh (also installable to /usr/local/sbin).
#
# Does NOT reinstall packages — only updates /var/lib/offline-repos (or LOCAL_REPO_ROOT)
# and rewrites dnf file:// repo config.
#
#   sudo authorize-offline-usb.sh          # if keyboard/storage blocked
#   sudo bash /mnt/rhel8offline/scripts/update-target-repo-from-usb.sh
#
# Env:
#   USB_REPO_LABEL   default RHEL8OFFLINE
#   USB_MNT          default /mnt/rhel8offline
#   LOCAL_REPO_ROOT  default /var/lib/offline-repos
#   MOUNT_RW=1       mount USB read-write (default: ro is fine for copy)
set -euo pipefail

LABEL="${USB_REPO_LABEL:-RHEL8OFFLINE}"
USB_MNT="${USB_MNT:-/mnt/rhel8offline}"
LOCAL_REPO_ROOT="${LOCAL_REPO_ROOT:-/var/lib/offline-repos}"
REPO_FILE_LOCAL="/etc/yum.repos.d/offline-local.repo"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

log() { echo "==> $*"; }

# USB authorize if helper present
if [[ -x /usr/local/sbin/authorize-offline-usb.sh ]]; then
  /usr/local/sbin/authorize-offline-usb.sh || true
elif [[ -x "$USB_MNT/scripts/authorize-offline-usb.sh" ]]; then
  bash "$USB_MNT/scripts/authorize-offline-usb.sh" || true
else
  systemctl stop usbguard.service 2>/dev/null || true
  systemctl disable usbguard.service 2>/dev/null || true
  echo 1 > /sys/module/usbcore/parameters/authorized_default 2>/dev/null || true
  for a in /sys/bus/usb/devices/*/authorized; do [[ -f "$a" ]] && echo 1 > "$a" 2>/dev/null || true; done
  modprobe usbhid 2>/dev/null || true
  modprobe usb_storage 2>/dev/null || true
  modprobe uas 2>/dev/null || true
fi

mkdir -p "$USB_MNT"
if ! findmnt "$USB_MNT" >/dev/null 2>&1; then
  if [[ -x /usr/local/sbin/mount-offline-usb.sh ]]; then
    /usr/local/sbin/mount-offline-usb.sh "$LABEL" "$USB_MNT" || true
  fi
fi
if ! findmnt "$USB_MNT" >/dev/null 2>&1; then
  dev="$(blkid -L "$LABEL" 2>/dev/null || true)"
  if [[ -z "$dev" && -n "${USB_UUID:-}" ]]; then
    dev="$(blkid -U "$USB_UUID" 2>/dev/null || true)"
  fi
  if [[ -z "$dev" ]]; then
    echo "ERROR: LABEL=$LABEL not found (and mount-offline-usb failed)." >&2
    echo "If only ~3G+~20M partitions: reimage on build host with 03-prepare-usb" >&2
    echo "(04-update-usb never rewrites partitions)." >&2
    lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL,UUID,START; blkid || true
    exit 1
  fi
  mount -o ro "$dev" "$USB_MNT"
  log "Mounted $dev -> $USB_MNT"
else
  log "Using already-mounted $USB_MNT"
fi

if [[ ! -d "$USB_MNT/BaseOS" || ! -d "$USB_MNT/AppStream" ]]; then
  echo "ERROR: $USB_MNT missing BaseOS/AppStream" >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "ERROR: rsync required (install once from offline media if needed)" >&2
  exit 1
fi

log "Syncing USB offline mirror -> $LOCAL_REPO_ROOT"
mkdir -p "$LOCAL_REPO_ROOT"
rsync -aH --info=progress2 --delete \
  --exclude='lost+found' \
  "$USB_MNT"/ "$LOCAL_REPO_ROOT"/

# Refresh ALL helpers + docs from local mirror (single installer — no partial cp list)
if [[ -x "$LOCAL_REPO_ROOT/scripts/install-airgap-helpers.sh" ]]; then
  bash "$LOCAL_REPO_ROOT/scripts/install-airgap-helpers.sh" "$LOCAL_REPO_ROOT" || true
elif [[ -x /usr/local/sbin/install-airgap-helpers.sh ]]; then
  /usr/local/sbin/install-airgap-helpers.sh "$LOCAL_REPO_ROOT" || true
fi

# Point dnf at local mirror (canonical enable script)
export LOCAL_REPO_ROOT
if [[ -x /usr/local/sbin/enable-offline-repos.sh ]]; then
  /usr/local/sbin/enable-offline-repos.sh
else
  # Minimal fallback if helpers not yet installed
  EPEL_EN=0; CRB_EN=0; FUSION_EN=0
  [[ -d "$LOCAL_REPO_ROOT/EPEL/repodata" || -d "$LOCAL_REPO_ROOT/EPEL/Packages" ]] && EPEL_EN=1
  [[ -d "$LOCAL_REPO_ROOT/CodeReadyBuilder" ]] && CRB_EN=1
  [[ -d "$LOCAL_REPO_ROOT/RPMFusion/repodata" || -d "$LOCAL_REPO_ROOT/RPMFusion/Packages" ]] && FUSION_EN=1
  cat > "$REPO_FILE_LOCAL" <<EOF
# Updated by update-target-repo-from-usb.sh $(date -Is)
[offline-local-baseos]
name=Offline BaseOS (local disk)
baseurl=file://${LOCAL_REPO_ROOT}/BaseOS
enabled=1
gpgcheck=0
module_hotfixes=1
[offline-local-appstream]
name=Offline AppStream (local disk)
baseurl=file://${LOCAL_REPO_ROOT}/AppStream
enabled=1
gpgcheck=0
module_hotfixes=1
[offline-local-crb]
name=Offline CodeReady Builder (local disk)
baseurl=file://${LOCAL_REPO_ROOT}/CodeReadyBuilder
enabled=${CRB_EN}
gpgcheck=0
module_hotfixes=1
[offline-local-epel]
name=Offline EPEL 8 (local disk)
baseurl=file://${LOCAL_REPO_ROOT}/EPEL
enabled=${EPEL_EN}
gpgcheck=0
[offline-local-rpmfusion]
name=Offline RPM Fusion (local disk)
baseurl=file://${LOCAL_REPO_ROOT}/RPMFusion
enabled=${FUSION_EN}
gpgcheck=0
EOF
fi

dnf clean all >/dev/null 2>&1 || true

log "Local mirror updated."
du -sh "$LOCAL_REPO_ROOT" "$LOCAL_REPO_ROOT"/* 2>/dev/null | head -20
echo
echo "dnf is pointed at file://${LOCAL_REPO_ROOT}/..."
echo "  Root guide: /root/README.md"
echo "  sudo dnf --refresh list updates | head"
echo "  sudo dnf upgrade"
echo "  sudo dnf install <package>"
echo
echo "Note: 'system not registered' messages from subscription-manager are expected offline and harmless."
echo "USB may be unmounted: sudo umount $USB_MNT"
