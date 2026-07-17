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
  dev="$(blkid -L "$LABEL" 2>/dev/null || true)"
  if [[ -z "$dev" ]]; then
    echo "ERROR: LABEL=$LABEL not found. Insert offline USB and re-run authorize-offline-usb.sh" >&2
    lsblk -o NAME,SIZE,FSTYPE,LABEL; blkid || true
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

# Configure permanent local repos
EPEL_EN=0
CRB_EN=0
[[ -d "$LOCAL_REPO_ROOT/EPEL/repodata" || -d "$LOCAL_REPO_ROOT/EPEL/Packages" ]] && EPEL_EN=1
[[ -d "$LOCAL_REPO_ROOT/CodeReadyBuilder" ]] && CRB_EN=1

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
EOF

# Quiet subscription noise; disable other repos
if command -v subscription-manager >/dev/null 2>&1; then
  subscription-manager repos --disable='*' >/dev/null 2>&1 || true
fi
if [[ -f /etc/dnf/plugins/subscription-manager.conf ]]; then
  sed -i 's/^enabled\s*=\s*1/enabled=0/' /etc/dnf/plugins/subscription-manager.conf 2>/dev/null || true
fi
for f in /etc/yum.repos.d/*.repo; do
  [[ -e "$f" ]] || continue
  case "$f" in
    *offline-local.repo) ;;
    *)
      [[ -f "${f}.disabled-by-airgap" ]] || mv "$f" "${f}.disabled-by-airgap" 2>/dev/null || true
      ;;
  esac
done

# Install/update helpers from media if present
if [[ -f "$LOCAL_REPO_ROOT/scripts/authorize-offline-usb.sh" ]]; then
  cp -a "$LOCAL_REPO_ROOT/scripts/authorize-offline-usb.sh" /usr/local/sbin/
  chmod 755 /usr/local/sbin/authorize-offline-usb.sh
fi
if [[ -f "$LOCAL_REPO_ROOT/scripts/update-target-repo-from-usb.sh" ]]; then
  cp -a "$LOCAL_REPO_ROOT/scripts/update-target-repo-from-usb.sh" /usr/local/sbin/
  chmod 755 /usr/local/sbin/update-target-repo-from-usb.sh
fi
if [[ -x /usr/local/sbin/enable-offline-repos.sh ]]; then
  /usr/local/sbin/enable-offline-repos.sh >/dev/null 2>&1 || true
fi

dnf clean all >/dev/null 2>&1 || true

log "Local mirror updated."
du -sh "$LOCAL_REPO_ROOT" "$LOCAL_REPO_ROOT"/* 2>/dev/null | head -20
echo
echo "dnf is pointed at file://${LOCAL_REPO_ROOT}/..."
echo "  sudo dnf --refresh list updates | head"
echo "  sudo dnf upgrade"
echo "  sudo dnf install <package>"
echo
echo "Note: 'system not registered' messages from subscription-manager are expected offline and harmless."
echo "USB may be unmounted: sudo umount $USB_MNT"
