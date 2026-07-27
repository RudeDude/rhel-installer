#!/usr/bin/env bash
# Shared functions for *target* air-gap helpers (not build-host pipeline).
#
# Sourced by authorize/mount/enable-repos consumers and setup scripts.
# Installed next to other helpers (USB scripts/, /usr/local/sbin,
# /usr/local/share/airgap/scripts/). Not meant to be executed directly.
#
# Callers must set AIRGAP_SELF_DIR to their own directory before sourcing,
# or place this file beside the caller:
#
#   AIRGAP_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=airgap-common.sh
#   source "${AIRGAP_SELF_DIR}/airgap-common.sh" 2>/dev/null \
#     || source /usr/local/share/airgap/scripts/airgap-common.sh
#
# Guard against double-source:
if [[ -n "${_AIRGAP_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_AIRGAP_COMMON_LOADED=1

airgap_log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Locate / run a co-installed helper by basename
# ---------------------------------------------------------------------------
airgap_helper_path() {
  local name="$1"
  local d
  for d in \
    /usr/local/sbin \
    "${AIRGAP_SELF_DIR:-}" \
    /usr/local/share/airgap/scripts \
    "${LOCAL_REPO_ROOT:-/var/lib/offline-repos}/scripts" \
    "${USB_MNT:-/mnt/rhel8offline}/scripts"
  do
    [[ -n "$d" && -f "$d/$name" ]] || continue
    echo "$d/$name"
    return 0
  done
  return 1
}

# Run helper; returns helper exit status, or 127 if not found.
airgap_run_helper() {
  local name="$1"
  shift
  local path
  if ! path="$(airgap_helper_path "$name")"; then
    return 127
  fi
  bash "$path" "$@"
}

# ---------------------------------------------------------------------------
# STEP: authorize USB (keyboard / storage)
# ---------------------------------------------------------------------------
airgap_authorize_last_resort() {
  airgap_log "USB authorize last-resort (no authorize-offline-usb.sh): USBGuard off, authorize devices, load hid/storage"
  systemctl stop usbguard.service usbguard-dbus.service 2>/dev/null || true
  systemctl disable usbguard.service usbguard-dbus.service 2>/dev/null || true
  if [[ -f /sys/module/usbcore/parameters/authorized_default ]]; then
    echo 1 > /sys/module/usbcore/parameters/authorized_default 2>/dev/null || true
  fi
  local auth
  for auth in /sys/bus/usb/devices/*/authorized; do
    [[ -f "$auth" ]] && echo 1 > "$auth" 2>/dev/null || true
  done
  modprobe usbhid 2>/dev/null || true
  modprobe usb_storage 2>/dev/null || true
  modprobe uas 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  sleep 1
}

# Prefer canonical authorize-offline-usb.sh; last-resort inline if missing.
# Always returns 0 (authorize is best-effort for operator workflows).
airgap_step_authorize() {
  airgap_log "STEP authorize: USB keyboard / mouse / mass-storage"
  local rc=0
  airgap_run_helper authorize-offline-usb.sh || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    airgap_log "STEP authorize: done (authorize-offline-usb.sh)"
    return 0
  fi
  if [[ "$rc" -eq 127 ]]; then
    airgap_authorize_last_resort
    airgap_log "STEP authorize: done (last-resort)"
    return 0
  fi
  airgap_log "WARN: authorize-offline-usb.sh exited $rc — continuing"
  return 0
}

# ---------------------------------------------------------------------------
# STEP: mount offline USB data partition
# ---------------------------------------------------------------------------
# Usage: airgap_step_mount [LABEL] [MNT]
# Prefer mount-offline-usb.sh; simple LABEL mount as last resort.
airgap_step_mount() {
  local label="${1:-${USB_REPO_LABEL:-RHEL8OFFLINE}}"
  local mnt="${2:-${USB_MNT:-/mnt/rhel8offline}}"
  USB_MNT="$mnt"
  USB_REPO_LABEL="$label"

  airgap_log "STEP mount: offline USB LABEL=$label -> $mnt"
  mkdir -p "$mnt"
  if findmnt "$mnt" >/dev/null 2>&1; then
    airgap_log "STEP mount: already mounted at $mnt"
    findmnt "$mnt" || true
    return 0
  fi

  local mrc=0
  airgap_run_helper mount-offline-usb.sh "$label" "$mnt" || mrc=$?
  if [[ "$mrc" -eq 0 ]] && findmnt "$mnt" >/dev/null 2>&1; then
    airgap_log "STEP mount: done (mount-offline-usb.sh)"
    return 0
  fi

  airgap_log "STEP mount: mount-offline-usb.sh unavailable or failed — LABEL last-resort"
  local dev i
  for i in 1 2 3 4 5 6 8 10; do
    dev="$(blkid -L "$label" 2>/dev/null || true)"
    [[ -n "$dev" ]] && break
    if [[ -n "${USB_UUID:-}" ]]; then
      dev="$(blkid -U "$USB_UUID" 2>/dev/null || true)"
      [[ -n "$dev" ]] && break
    fi
    sleep 1
    airgap_step_authorize >/dev/null 2>&1 || true
  done
  if [[ -z "${dev:-}" ]]; then
    echo "ERROR: STEP mount failed — no filesystem with LABEL=$label" >&2
    echo "If only ~3G boot + ~20M EFI: reimage on build host with 03-prepare-usb" >&2
    echo "(04-update-usb never rewrites partitions)." >&2
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTLABEL,UUID,START 2>/dev/null || true
    blkid 2>/dev/null || true
    return 1
  fi
  mount -o ro "$dev" "$mnt"
  airgap_log "STEP mount: mounted $dev -> $mnt (ro, last-resort)"
  return 0
}

# ---------------------------------------------------------------------------
# Offline dnf repo file + CDN disable (shared by enable-offline-repos + fallbacks)
# ---------------------------------------------------------------------------
# airgap_write_offline_repo_file <base_dir> <out_repo_file> <prefix>
#   prefix e.g. offline-local or offline-usb  → [prefix-baseos], …
airgap_write_offline_repo_file() {
  local base="$1" out="$2" prefix="$3"
  local epel_en=0 crb_en=0 fusion_en=0 rke2_en=0
  [[ -d "$base/EPEL/repodata" || -d "$base/EPEL/Packages" ]] && epel_en=1
  [[ -d "$base/CodeReadyBuilder" ]] && crb_en=1
  [[ -d "$base/RPMFusion/repodata" || -d "$base/RPMFusion/Packages" ]] && fusion_en=1
  [[ -d "$base/RKE2/repodata" || -d "$base/RKE2/Packages" ]] && rke2_en=1

  cat > "$out" <<EOF
# Generated by airgap-common.sh on $(date -Is)
# Source root: $base

[${prefix}-baseos]
name=Offline BaseOS
baseurl=file://${base}/BaseOS
enabled=1
gpgcheck=0
module_hotfixes=1

[${prefix}-appstream]
name=Offline AppStream
baseurl=file://${base}/AppStream
enabled=1
gpgcheck=0
module_hotfixes=1

[${prefix}-crb]
name=Offline CRB
baseurl=file://${base}/CodeReadyBuilder
enabled=${crb_en}
gpgcheck=0
module_hotfixes=1

[${prefix}-epel]
name=Offline EPEL
baseurl=file://${base}/EPEL
enabled=${epel_en}
gpgcheck=0

[${prefix}-rpmfusion]
name=Offline RPM Fusion (free+nonfree staged)
baseurl=file://${base}/RPMFusion
enabled=${fusion_en}
gpgcheck=0

[${prefix}-rke2]
name=Offline RKE2 (Rancher rpm.rancher.io mirror)
baseurl=file://${base}/RKE2
enabled=${rke2_en}
gpgcheck=0
EOF
}

# Quiet RHSM / move non-offline .repo files aside
airgap_disable_cdn_repos() {
  if command -v subscription-manager >/dev/null 2>&1; then
    subscription-manager repos --disable='*' >/dev/null 2>&1 || true
  fi
  if [[ -f /etc/dnf/plugins/subscription-manager.conf ]]; then
    sed -i 's/^enabled\s*=\s*1/enabled=0/' /etc/dnf/plugins/subscription-manager.conf 2>/dev/null || true
  fi

  mkdir -p /etc/yum.repos.d/backup-original
  local f
  for f in /etc/yum.repos.d/*.repo; do
    [[ -e "$f" ]] || continue
    case "$f" in
      *offline-local.repo|*offline-usb.repo) continue ;;
      *)
        if [[ ! -f "${f}.disabled-by-airgap" ]]; then
          cp -a "$f" /etc/yum.repos.d/backup-original/ 2>/dev/null || true
          mv "$f" "${f}.disabled-by-airgap" 2>/dev/null || true
        fi
        ;;
    esac
  done
}

# If disable step moved the file we just wrote, restore it
airgap_restore_repo_file_if_needed() {
  local out="$1"
  if [[ -f "${out}.disabled-by-airgap" && ! -f "$out" ]]; then
    mv "${out}.disabled-by-airgap" "$out"
  fi
}

# Disable CDN noise, then write the offline repo file once.
# airgap_apply_offline_repos <base_dir> <out_repo_file> <prefix>
airgap_apply_offline_repos() {
  local base="$1" out="$2" prefix="$3"
  airgap_disable_cdn_repos
  airgap_restore_repo_file_if_needed "$out"
  airgap_write_offline_repo_file "$base" "$out" "$prefix"
  dnf clean all >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# STEP: enable offline dnf repos (local preferred; USB fallback via helper)
# ---------------------------------------------------------------------------
# Prefer enable-offline-repos.sh; last-resort writes offline-local.repo from LOCAL_REPO_ROOT.
airgap_step_enable_repos() {
  local local_root="${LOCAL_REPO_ROOT:-/var/lib/offline-repos}"
  local repo_local="/etc/yum.repos.d/offline-local.repo"
  export LOCAL_REPO_ROOT="$local_root"

  airgap_log "STEP enable-repos: point dnf at offline mirror (prefer $local_root)"
  local rc=0
  airgap_run_helper enable-offline-repos.sh || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    airgap_log "STEP enable-repos: done (enable-offline-repos.sh)"
    return 0
  fi
  if [[ "$rc" -eq 127 ]]; then
    airgap_log "WARN: enable-offline-repos.sh not found — last-resort write of $repo_local"
  else
    airgap_log "WARN: enable-offline-repos.sh exited $rc — trying last-resort write"
  fi

  if [[ ! -d "$local_root/BaseOS" && ! -d "$local_root/AppStream" ]]; then
    echo "ERROR: STEP enable-repos failed — no BaseOS/AppStream under $local_root" >&2
    return 1
  fi
  airgap_apply_offline_repos "$local_root" "$repo_local" "offline-local"
  airgap_log "STEP enable-repos: done (last-resort offline-local.repo)"
  return 0
}

airgap_local_mirror_ok() {
  local root="${1:-${LOCAL_REPO_ROOT:-/var/lib/offline-repos}}"
  [[ -d "$root/BaseOS/repodata" || -d "$root/BaseOS/Packages" ]] && \
  [[ -d "$root/AppStream/repodata" || -d "$root/AppStream/Packages" ]]
}
