#!/usr/bin/env bash
# Point dnf at air-gap package sources. Prefers local disk mirror; falls back to USB.
#
#   sudo enable-offline-repos.sh
#   LOCAL_REPO_ROOT=/data/offline-repos sudo enable-offline-repos.sh
#
# Env:
#   LOCAL_REPO_ROOT  default /var/lib/offline-repos
#   USB_REPO_LABEL   default RHEL8OFFLINE
#   USB_MNT          default /mnt/rhel8offline
set -euo pipefail

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
  echo "ERROR: airgap-common.sh not found (beside this script or under /usr/local/share/airgap/scripts/)" >&2
  exit 1
fi

LOCAL="${LOCAL_REPO_ROOT:-/var/lib/offline-repos}"
USB_MNT="${USB_MNT:-/mnt/rhel8offline}"
LABEL="${USB_REPO_LABEL:-RHEL8OFFLINE}"
REPO_LOCAL=/etc/yum.repos.d/offline-local.repo
REPO_USB=/etc/yum.repos.d/offline-usb.repo

if [[ -d "$LOCAL/BaseOS" ]]; then
  BASE="$LOCAL"
  OUT="$REPO_LOCAL"
  PREFIX=offline-local
  rm -f "$REPO_USB"
else
  # Need USB media — mount if possible (authorize is a separate operator step)
  if ! findmnt "$USB_MNT" >/dev/null 2>&1; then
    if ! airgap_step_mount "$LABEL" "$USB_MNT"; then
      echo "ERROR: no local mirror at $LOCAL and USB mount failed" >&2
      exit 1
    fi
  fi
  BASE="$USB_MNT"
  OUT="$REPO_USB"
  PREFIX=offline-usb
fi

if [[ ! -d "$BASE/BaseOS" && ! -d "$BASE/AppStream" ]]; then
  echo "ERROR: no offline mirror at $LOCAL or $USB_MNT" >&2
  exit 1
fi

airgap_apply_offline_repos "$BASE" "$OUT" "$PREFIX"

echo "Offline repos enabled from: $BASE"
echo "(Unregistered system warnings from subscription-manager are expected offline.)"
echo "Example:  dnf install <pkg>   |   dnf upgrade"
