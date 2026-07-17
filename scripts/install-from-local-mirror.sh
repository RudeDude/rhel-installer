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

dnf clean all >/dev/null 2>&1 || true

log "Applying upgrades from LOCAL offline mirror"
dnf -y --disablerepo='*' --enablerepo='offline-local-*' upgrade || true

log "Installing core required packages (from local mirror)"
dnf -y --disablerepo='*' --enablerepo='offline-local-*' install \
  chrony nano bc socat jq python3 python3-pip python3-setuptools \
  python3.11 python3.11-pip python3.11-setuptools \
  tcpdump wireshark wireshark-cli freerdp \
  java-1.8.0-openjdk java-1.8.0-openjdk-devel \
  java-11-openjdk java-11-openjdk-devel \
  java-17-openjdk java-17-openjdk-devel java-17-openjdk-headless \
  vim-enhanced tmux net-tools gedit tree util-linux util-linux-user \
  rsync openssh openssh-server openssh-clients \
  git gitk git-lfs \
  curl wget tar unzip zip bind-utils nmap-ncat

systemctl enable --now sshd 2>/dev/null || systemctl enable sshd 2>/dev/null || true

log "Installing selected extras"
dnf -y --disablerepo='*' --enablerepo='offline-local-*' install \
  iotop sysstat lsof strace bash-completion man-pages man-db \
  firefox evince gnome-terminal gnome-system-monitor \
  psmisc procps-ng which file less diffutils

log "Installing EPEL extras (htop, nload, pv, keepassxc, rdesktop)"
if [[ -d "$LOCAL_REPO_ROOT/EPEL/repodata" || -d "$LOCAL_REPO_ROOT/EPEL/Packages" ]]; then
  dnf -y --disablerepo='*' --enablerepo='offline-local-*' install htop nload pv keepassxc rdesktop
else
  echo "ERROR: EPEL tree missing under $LOCAL_REPO_ROOT/EPEL" >&2
  exit 1
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
