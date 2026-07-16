#!/usr/bin/env bash
# Run on the installed RHEL system with the offline USB inserted.
# Installs any packages that were not pulled during kickstart.
set -euo pipefail

LABEL="${USB_REPO_LABEL:-RHEL8OFFLINE}"
MNT="${MNT:-/mnt/rhel8offline}"
WHEEL_DIR="${PYTHON_WHEEL_DIR:-$MNT/python-wheels}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if command -v enable-offline-repos.sh >/dev/null 2>&1; then
  enable-offline-repos.sh
else
  mkdir -p "$MNT"
  DEV="$(blkid -L "$LABEL" || true)"
  [[ -n "$DEV" ]] || { echo "USB label $LABEL not found"; exit 1; }
  mountpoint -q "$MNT" || mount -o ro "$DEV" "$MNT"
  cat > /etc/yum.repos.d/offline-usb.repo <<EOF
[offline-baseos]
name=Offline BaseOS
baseurl=file://$MNT/BaseOS
enabled=1
gpgcheck=0

[offline-appstream]
name=Offline AppStream
baseurl=file://$MNT/AppStream
enabled=1
gpgcheck=0

[offline-crb]
name=Offline CRB
baseurl=file://$MNT/CodeReadyBuilder
enabled=1
gpgcheck=0

[offline-epel]
name=Offline EPEL 8
baseurl=file://$MNT/EPEL
enabled=$( [[ -d "$MNT/EPEL/repodata" || -d "$MNT/EPEL/Packages" ]] && echo 1 || echo 0 )
gpgcheck=0
EOF
fi

# Prefer media wheel dir if present
if [[ -d "$MNT/python-wheels" ]]; then
  WHEEL_DIR="$MNT/python-wheels"
fi

echo "==> Applying offline upgrades (security errata on the USB)"
dnf -y upgrade || true

# Fail loudly on missing packages/deps (do not mask with || true).

echo "==> Core required packages (RHEL repos)"
dnf -y install \
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

echo "==> Selected extras (admin/observability + desktop)"
dnf -y install \
  iotop sysstat lsof strace bash-completion man-pages man-db \
  firefox evince gnome-terminal gnome-system-monitor \
  psmisc procps-ng which file less diffutils

echo "==> EPEL extras (htop, nload, pv, keepassxc, rdesktop)"
if [[ -d "$MNT/EPEL/repodata" || -d "$MNT/EPEL/Packages" ]]; then
  dnf -y install htop nload pv keepassxc rdesktop
else
  echo "ERROR: EPEL offline tree missing on media. On build host: ./scripts/02-fetch-epel-packages.sh" >&2
  exit 1
fi

echo "==> Python wheels (offline pip — pipx and friends)"
if [[ -d "$WHEEL_DIR" ]] && compgen -G "$WHEEL_DIR/*.whl" >/dev/null; then
  REQ="$WHEEL_DIR/requirements.txt"
  if [[ ! -f "$REQ" ]]; then
    # fall back to installing every wheel present
    echo "No requirements.txt in $WHEEL_DIR — installing all .whl files"
    python3.11 -m pip install --no-index --find-links="$WHEEL_DIR" "$WHEEL_DIR"/*.whl
  else
    python3.11 -m pip install --no-index --find-links="$WHEEL_DIR" -r "$REQ"
  fi
  # Ensure pipx is on PATH for the invoking user later
  if command -v pipx >/dev/null 2>&1 || python3.11 -m pipx --version >/dev/null 2>&1; then
    echo "pipx available"
    python3.11 -m pipx ensurepath 2>/dev/null || true
  fi
else
  echo "ERROR: Python wheels not found at $WHEEL_DIR" >&2
  echo "On build host: ./scripts/03-fetch-python-wheels.sh" >&2
  exit 1
fi

echo "==> Server with GUI (if not already installed)"
dnf -y groupinstall "Server with GUI" || \
  dnf -y install @graphical-server-environment
systemctl set-default graphical.target || true

echo "Extra package pass complete."
rpm -qa | wc -l
echo "sshd active? $(systemctl is-active sshd 2>/dev/null || echo n/a)"
command -v pipx >/dev/null && pipx --version || python3.11 -m pip show pipx | head -3 || true
