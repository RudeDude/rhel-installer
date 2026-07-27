#!/usr/bin/env bash
# ==== Air-gap first-time setup — STEP 1 of 2 ====  (RUN FROM THE USB; needs USB mounted)
#
# Explicit sub-steps (each uses shared airgap-common.sh / dedicated helpers):
#   authorize → mount → install helpers → temp USB dnf → rsync → helpers again → local dnf
#
#   sudo bash /mnt/rhel8offline/scripts/airgap-setup-1-copy-mirror.sh
#
# Does:
#   - install helpers/docs early from USB
#   - rsync full offline mirror USB → LOCAL disk
#   - point dnf at local mirror
#   - reinstall helpers from local copy (so later steps do not need USB)
#   - does NOT unmount USB (you do that) and does NOT install packages
#
# Then (STEP 2 of 2):
#   sudo umount /mnt/rhel8offline
#   # remove USB
#   sudo airgap-setup-2-install.sh
#
# Env:
#   USB_REPO_LABEL   default RHEL8OFFLINE
#   USB_MNT          default /mnt/rhel8offline
#   LOCAL_REPO_ROOT  default /var/lib/offline-repos
#   SKIP_REPO_COPY=1 skip rsync if local mirror already complete
set -euo pipefail

LABEL="${USB_REPO_LABEL:-RHEL8OFFLINE}"
USB_MNT="${USB_MNT:-${MNT:-/mnt/rhel8offline}}"
LOCAL_REPO_ROOT="${LOCAL_REPO_ROOT:-/var/lib/offline-repos}"
REPO_FILE_LOCAL="/etc/yum.repos.d/offline-local.repo"
REPO_FILE_USB="/etc/yum.repos.d/offline-usb.repo"
SKIP_REPO_COPY="${SKIP_REPO_COPY:-0}"

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
  echo "ERROR: airgap-common.sh not found beside this script (is media incomplete?)" >&2
  exit 1
fi

export USB_MNT USB_REPO_LABEL="$LABEL" LOCAL_REPO_ROOT

install_helpers_from() {
  local src="$1"
  if [[ -x "$src/scripts/install-airgap-helpers.sh" ]]; then
    bash "$src/scripts/install-airgap-helpers.sh" "$src" || true
  elif [[ -x /usr/local/sbin/install-airgap-helpers.sh ]]; then
    /usr/local/sbin/install-airgap-helpers.sh "$src" || true
  else
    airgap_log "WARN: install-airgap-helpers.sh not found; minimal helper copy from $src"
    mkdir -p /usr/local/sbin /usr/local/share/airgap/scripts /root/airgap-docs
    local s list="$src/scripts/target-scripts.list"
    if [[ -f "$list" ]]; then
      while IFS= read -r s || [[ -n "$s" ]]; do
        s="${s%%#*}"; s="$(echo "$s" | tr -d '[:space:]')"
        [[ -n "$s" && -f "$src/scripts/$s" ]] || continue
        cp -a "$src/scripts/$s" /usr/local/sbin/
        cp -a "$src/scripts/$s" /usr/local/share/airgap/scripts/
        chmod 755 "/usr/local/sbin/$s" "/usr/local/share/airgap/scripts/$s"
      done < "$list"
    fi
    # Always try common library
    if [[ -f "$src/scripts/airgap-common.sh" ]]; then
      cp -a "$src/scripts/airgap-common.sh" /usr/local/sbin/
      cp -a "$src/scripts/airgap-common.sh" /usr/local/share/airgap/scripts/
      chmod 755 /usr/local/sbin/airgap-common.sh /usr/local/share/airgap/scripts/airgap-common.sh
    fi
    [[ -d "$src/docs" ]] && cp -a "$src/docs"/. /root/airgap-docs/ 2>/dev/null || true
    [[ -f "$src/docs/ROOT-HOME-README.md" ]] && cp -a "$src/docs/ROOT-HOME-README.md" /root/README.md
  fi
}

echo
echo "############################################################"
echo "# Step 1/2: copy offline mirror USB → local disk            #"
echo "############################################################"

# --- sub-step: authorize ---
airgap_step_authorize

# --- sub-step: mount ---
if ! airgap_step_mount "$LABEL" "$USB_MNT"; then
  exit 1
fi

if [[ ! -d "$USB_MNT/BaseOS" || ! -d "$USB_MNT/AppStream" ]]; then
  echo "ERROR: $USB_MNT does not look like the offline media (need BaseOS/ and AppStream/)." >&2
  ls -la "$USB_MNT" || true
  exit 1
fi

# --- sub-step: helpers from USB ---
airgap_log "STEP helpers: install from USB (early)"
install_helpers_from "$USB_MNT"
# Re-resolve common after install (sbin/share now populated)
AIRGAP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /usr/local/share/airgap/scripts/airgap-common.sh ]]; then
  # shellcheck disable=SC1091
  source /usr/local/share/airgap/scripts/airgap-common.sh
fi

# --- sub-step: temporary USB dnf (bootstrap rsync only) ---
airgap_log "STEP enable-repos (temporary): USB file:// for bootstrap packages"
# Prefer USB explicitly — do not call enable-offline-repos yet if a partial
# local tree exists; write offline-usb.repo via shared helper once.
airgap_apply_offline_repos "$USB_MNT" "$REPO_FILE_USB" "offline-usb"

if ! command -v rsync >/dev/null 2>&1; then
  airgap_log "Installing rsync from USB media (bootstrap)"
  dnf -y --disablerepo='*' --enablerepo='offline-usb-*' install rsync
fi

# --- sub-step: rsync ---
airgap_log "STEP copy: USB offline repo → local disk (${LOCAL_REPO_ROOT})"
echo "    This can take a while (~30GB+)."
mkdir -p "$LOCAL_REPO_ROOT"

if [[ "$SKIP_REPO_COPY" == "1" ]] && airgap_local_mirror_ok "$LOCAL_REPO_ROOT"; then
  airgap_log "SKIP_REPO_COPY=1 and local mirror looks present — not re-copying"
else
  rsync -aH --info=progress2 \
    --exclude='lost+found' \
    "$USB_MNT"/ "$LOCAL_REPO_ROOT"/
fi

if ! airgap_local_mirror_ok "$LOCAL_REPO_ROOT"; then
  echo "ERROR: local mirror incomplete after copy: $LOCAL_REPO_ROOT" >&2
  ls -la "$LOCAL_REPO_ROOT" || true
  exit 1
fi

airgap_log "Local mirror size:"
du -sh "$LOCAL_REPO_ROOT" "$LOCAL_REPO_ROOT"/* 2>/dev/null | head -20

# --- sub-step: helpers from local ---
airgap_log "STEP helpers: re-install from local mirror (step 2 must not need USB)"
install_helpers_from "$LOCAL_REPO_ROOT"

# --- sub-step: permanent local dnf ---
airgap_log "STEP enable-repos (permanent): file://${LOCAL_REPO_ROOT}/..."
rm -f "$REPO_FILE_USB"
export LOCAL_REPO_ROOT
if ! airgap_step_enable_repos; then
  exit 1
fi

if grep -q "file://${USB_MNT}" /etc/yum.repos.d/*.repo 2>/dev/null; then
  echo "ERROR: A yum repo still points at USB mount $USB_MNT" >&2
  grep -n "file://${USB_MNT}" /etc/yum.repos.d/*.repo || true
  exit 1
fi
if [[ ! -f "$REPO_FILE_LOCAL" ]] || ! grep -q "file://${LOCAL_REPO_ROOT}/BaseOS" "$REPO_FILE_LOCAL" 2>/dev/null; then
  echo "ERROR: $REPO_FILE_LOCAL does not point at local BaseOS after enable-repos" >&2
  exit 1
fi

sync

echo
echo "############################################################"
echo "# Step 1 complete — STOP HERE                                #"
echo "############################################################"
echo
echo "  Local mirror:  $LOCAL_REPO_ROOT"
echo "  dnf repos:     $REPO_FILE_LOCAL"
echo "  Helpers:       /usr/local/sbin/  (airgap-setup-2-install.sh is local now)"
echo
echo "  Next (manual) — STEP 2 of 2:"
echo "    1) sudo umount $USB_MNT"
echo "    2) Unplug the USB stick"
echo "    3) sudo airgap-setup-2-install.sh"
echo "       (or: sudo /usr/local/sbin/airgap-setup-2-install.sh)"
echo "       (or: sudo bash $LOCAL_REPO_ROOT/scripts/airgap-setup-2-install.sh)"
echo
echo "  Do NOT leave this script running — package install is a separate script"
echo "  so it is not interrupted when the USB is removed."
echo
