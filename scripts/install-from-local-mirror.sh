#!/usr/bin/env bash
# Step 2 of first-time air-gap setup — RUN FROM LOCAL DISK (USB unplugged).
#
# Prerequisites: step 1 already done:
#   sudo bash /mnt/rhel8offline/scripts/copy-offline-mirror-from-usb.sh
#   sudo umount /mnt/rhel8offline && unplug USB
#
#   sudo install-from-local-mirror.sh
#   # or: sudo /usr/local/sbin/install-from-local-mirror.sh
#   # or: sudo bash /var/lib/offline-repos/scripts/install-from-local-mirror.sh
#
# Installs packages, EPEL extras, Python wheels, GUI from LOCAL_REPO_ROOT only.
#
# Env:
#   LOCAL_REPO_ROOT  default /var/lib/offline-repos
#   GRUB_TIMEOUT     default 5
set -euo pipefail

LOCAL_REPO_ROOT="${LOCAL_REPO_ROOT:-/var/lib/offline-repos}"
REPO_FILE_LOCAL="/etc/yum.repos.d/offline-local.repo"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

log() { echo "==> $*"; }

# Refuse if this script is still executing from a USB mount path (common mistake)
script_src="${BASH_SOURCE[0]}"
if [[ -e "$script_src" ]]; then
  real="$(readlink -f "$script_src" 2>/dev/null || echo "$script_src")"
  if findmnt -n -T "$real" 2>/dev/null | grep -qiE 'usb|removable|/mnt/rhel8offline' \
     || [[ "$real" == /mnt/rhel8offline/* ]]; then
    echo "ERROR: This script appears to be running from USB media ($real)." >&2
    echo "Copy step must finish first; then run the local copy:" >&2
    echo "  sudo /usr/local/sbin/install-from-local-mirror.sh" >&2
    echo "  sudo bash ${LOCAL_REPO_ROOT}/scripts/install-from-local-mirror.sh" >&2
    exit 1
  fi
fi

local_mirror_ok() {
  [[ -d "$LOCAL_REPO_ROOT/BaseOS/repodata" || -d "$LOCAL_REPO_ROOT/BaseOS/Packages" ]] && \
  [[ -d "$LOCAL_REPO_ROOT/AppStream/repodata" || -d "$LOCAL_REPO_ROOT/AppStream/Packages" ]]
}

install_helpers_from() {
  local src="$1"
  if [[ -x /usr/local/sbin/install-airgap-helpers.sh ]]; then
    /usr/local/sbin/install-airgap-helpers.sh "$src" || true
  elif [[ -x "$src/scripts/install-airgap-helpers.sh" ]]; then
    bash "$src/scripts/install-airgap-helpers.sh" "$src" || true
  fi
}

echo
echo "############################################################"
echo "# Step 2/2: install packages from local disk (USB offline) #"
echo "############################################################"

if ! local_mirror_ok; then
  echo "ERROR: local offline mirror missing or incomplete at $LOCAL_REPO_ROOT" >&2
  echo "Run step 1 first (USB inserted):" >&2
  echo "  sudo bash /mnt/rhel8offline/scripts/copy-offline-mirror-from-usb.sh" >&2
  ls -la "$LOCAL_REPO_ROOT" 2>/dev/null || true
  exit 1
fi

export LOCAL_REPO_ROOT
if [[ -x /usr/local/sbin/enable-offline-repos.sh ]]; then
  /usr/local/sbin/enable-offline-repos.sh
elif [[ -x "$LOCAL_REPO_ROOT/scripts/enable-offline-repos.sh" ]]; then
  bash "$LOCAL_REPO_ROOT/scripts/enable-offline-repos.sh"
else
  echo "WARN: enable-offline-repos.sh not found; assuming $REPO_FILE_LOCAL is correct" >&2
fi

if ! grep -q "file://${LOCAL_REPO_ROOT}/BaseOS" "$REPO_FILE_LOCAL" 2>/dev/null; then
  echo "ERROR: $REPO_FILE_LOCAL does not point at local BaseOS" >&2
  echo "Re-run copy-offline-mirror-from-usb.sh with USB inserted." >&2
  exit 1
fi

# Ensure no repo still points at a USB mount
if grep -r "file:///mnt/rhel8offline" /etc/yum.repos.d/*.repo 2>/dev/null; then
  echo "ERROR: a yum repo still points at /mnt/rhel8offline — fix repos before install" >&2
  exit 1
fi

# Resolve package lists staged with the offline media (not a hard-coded dnf line)
find_pkg_list() {
  local name="$1" d
  for d in \
    "$LOCAL_REPO_ROOT/packages" \
    /root/airgap-packages \
    /usr/local/share/airgap/packages
  do
    if [[ -f "$d/$name" ]]; then
      echo "$d/$name"
      return 0
    fi
  done
  return 1
}

# Read one-name-per-line package file (strip comments / blanks)
pkg_file_to_array() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f"
}

dnf_install_list() {
  local label="$1"
  shift
  local -a pkgs=("$@")
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    log "No packages for: $label (skip)"
    return 0
  fi
  log "Installing $label (${#pkgs[@]} packages) from local offline repos"
  # shellcheck disable=SC2068
  dnf -y --disablerepo='*' --enablerepo='offline-local-*' install ${pkgs[@]}
}

dnf clean all >/dev/null 2>&1 || true

log "Applying upgrades from LOCAL offline mirror"
dnf -y --disablerepo='*' --enablerepo='offline-local-*' upgrade || true

mapfile -t REQ_PKGS < <(pkg_file_to_array "$(find_pkg_list required.txt || true)")
mapfile -t REC_PKGS < <(pkg_file_to_array "$(find_pkg_list recommended.txt || true)")
mapfile -t EPEL_PKGS < <(pkg_file_to_array "$(find_pkg_list epel-extra.txt || true)")
mapfile -t FUSION_PKGS < <(pkg_file_to_array "$(find_pkg_list rpmfusion-extra.txt || true)")

if [[ ${#REQ_PKGS[@]} -eq 0 && ${#REC_PKGS[@]} -eq 0 ]]; then
  echo "ERROR: no required.txt / recommended.txt found under $LOCAL_REPO_ROOT/packages (or airgap copies)." >&2
  echo "Re-run copy-offline-mirror-from-usb.sh so packages/*.txt are on the local mirror." >&2
  exit 1
fi

# Combined install (BaseOS/AppStream/CRB + EPEL + RPM Fusion offline trees)
dnf_install_list "required.txt" "${REQ_PKGS[@]:-}"
dnf_install_list "recommended.txt" "${REC_PKGS[@]:-}"

systemctl enable --now sshd 2>/dev/null || systemctl enable sshd 2>/dev/null || true

if [[ ${#EPEL_PKGS[@]} -gt 0 ]]; then
  if [[ -d "$LOCAL_REPO_ROOT/EPEL/repodata" || -d "$LOCAL_REPO_ROOT/EPEL/Packages" ]]; then
    dnf_install_list "epel-extra.txt" "${EPEL_PKGS[@]}"
  else
    echo "ERROR: EPEL packages listed but EPEL tree missing under $LOCAL_REPO_ROOT/EPEL" >&2
    echo "On build host: edit packages/epel-extra.txt && ./scripts/01-fetch-offline-content.sh" >&2
    exit 1
  fi
fi

if [[ ${#FUSION_PKGS[@]} -gt 0 ]]; then
  if [[ -d "$LOCAL_REPO_ROOT/RPMFusion/repodata" || -d "$LOCAL_REPO_ROOT/RPMFusion/Packages" ]]; then
    dnf_install_list "rpmfusion-extra.txt" "${FUSION_PKGS[@]}"
  else
    echo "ERROR: RPM Fusion packages listed but RPMFusion/ tree missing under $LOCAL_REPO_ROOT" >&2
    echo "On build host: edit packages/rpmfusion-extra.txt && ./scripts/01-fetch-offline-content.sh" >&2
    exit 1
  fi
fi

WHEEL_DIR="${LOCAL_REPO_ROOT}/python-wheels"
log "Installing Python wheels offline (pipx) from $WHEEL_DIR"
if [[ -d "$WHEEL_DIR" ]] && compgen -G "$WHEEL_DIR/*.whl" >/dev/null; then
  REQ="$WHEEL_DIR/requirements.txt"
  if [[ -f "$REQ" ]]; then
    python3.11 -m pip install --no-index --find-links="$WHEEL_DIR" -r "$REQ"
  else
    python3.11 -m pip install --no-index --find-links="$WHEEL_DIR" "$WHEEL_DIR"/*.whl
  fi
  python3.11 -m pipx ensurepath 2>/dev/null || true
else
  echo "ERROR: Python wheels not found at $WHEEL_DIR" >&2
  exit 1
fi

log "Installing Server with GUI (if needed)"
dnf -y --disablerepo='*' --enablerepo='offline-local-*' groupinstall "Server with GUI" || \
  dnf -y --disablerepo='*' --enablerepo='offline-local-*' install @graphical-server-environment
systemctl set-default graphical.target || true

log "Refreshing helpers/docs from local mirror"
install_helpers_from "$LOCAL_REPO_ROOT"
[[ -x /usr/local/sbin/enable-offline-repos.sh ]] && /usr/local/sbin/enable-offline-repos.sh || true

log "Configuring GRUB menu auto-timeout (STIG often disables this)"
if [[ -x /usr/local/sbin/configure-grub-timeout.sh ]]; then
  GRUB_TIMEOUT="${GRUB_TIMEOUT:-5}" /usr/local/sbin/configure-grub-timeout.sh "${GRUB_TIMEOUT:-5}" || true
elif [[ -x "$LOCAL_REPO_ROOT/scripts/configure-grub-timeout.sh" ]]; then
  bash "$LOCAL_REPO_ROOT/scripts/configure-grub-timeout.sh" "${GRUB_TIMEOUT:-5}" || true
fi

log "Install-from-local-mirror complete."
echo "  Local mirror:  $LOCAL_REPO_ROOT  ($(du -sh "$LOCAL_REPO_ROOT" | awk '{print $1}'))"
echo "  dnf repos:     $REPO_FILE_LOCAL"
echo "  Root guide:    /root/README.md"
echo "  Status:        sudo offline-repo-status.sh"
echo "  Reboot if the GUI or kernel was updated."
rpm -qa | wc -l | xargs -I{} echo "  Installed RPMs: {}"
systemctl is-active sshd 2>/dev/null | xargs -I{} echo "  sshd: {}" || true
python3.11 -m pip show pipx 2>/dev/null | head -2 || true
