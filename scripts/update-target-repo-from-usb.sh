#!/usr/bin/env bash
# On the *target* air-gapped system: refresh the local offline mirror from USB.
# Lives on the USB at scripts/update-target-repo-from-usb.sh (also installable to /usr/local/sbin).
#
# Sub-steps (shared airgap-common.sh): authorize → mount → rsync → helpers → enable-repos
#
# Does NOT reinstall packages — only updates /var/lib/offline-repos (or LOCAL_REPO_ROOT)
# and rewrites dnf file:// repo config.
#
#   sudo authorize-offline-usb.sh          # optional; this script also runs authorize
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

AIRGAP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=airgap-common.sh
if [[ -f "${AIRGAP_SELF_DIR}/airgap-common.sh" ]]; then
  # shellcheck disable=SC1091
  source "${AIRGAP_SELF_DIR}/airgap-common.sh"
elif [[ -f /usr/local/share/airgap/scripts/airgap-common.sh ]]; then
  # shellcheck disable=SC1091
  source /usr/local/share/airgap/scripts/airgap-common.sh
else
  echo "ERROR: airgap-common.sh not found beside this script or under /usr/local/share/airgap/scripts/" >&2
  exit 1
fi

export USB_MNT USB_REPO_LABEL="$LABEL" LOCAL_REPO_ROOT

airgap_step_authorize

if ! airgap_step_mount "$LABEL" "$USB_MNT"; then
  exit 1
fi

if [[ ! -d "$USB_MNT/BaseOS" || ! -d "$USB_MNT/AppStream" ]]; then
  echo "ERROR: $USB_MNT missing BaseOS/AppStream" >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "ERROR: rsync required (install once from offline media if needed)" >&2
  exit 1
fi

airgap_log "STEP copy: USB offline mirror → $LOCAL_REPO_ROOT"
mkdir -p "$LOCAL_REPO_ROOT"
rsync -aH --info=progress2 --delete \
  --exclude='lost+found' \
  "$USB_MNT"/ "$LOCAL_REPO_ROOT"/

airgap_log "STEP helpers: refresh from local mirror"
if [[ -x "$LOCAL_REPO_ROOT/scripts/install-airgap-helpers.sh" ]]; then
  bash "$LOCAL_REPO_ROOT/scripts/install-airgap-helpers.sh" "$LOCAL_REPO_ROOT" || true
elif [[ -x /usr/local/sbin/install-airgap-helpers.sh ]]; then
  /usr/local/sbin/install-airgap-helpers.sh "$LOCAL_REPO_ROOT" || true
fi

# Re-source common after helper refresh (updated library may be on disk)
if [[ -f /usr/local/share/airgap/scripts/airgap-common.sh ]]; then
  _AIRGAP_COMMON_LOADED=
  # shellcheck disable=SC1091
  source /usr/local/share/airgap/scripts/airgap-common.sh
fi

export LOCAL_REPO_ROOT
if ! airgap_step_enable_repos; then
  exit 1
fi

airgap_log "Local mirror updated."
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
