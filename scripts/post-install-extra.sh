#!/usr/bin/env bash
# Run on the installed RHEL system with the offline USB inserted.
# Installs any packages that were not pulled during kickstart.
set -euo pipefail

LABEL="${USB_REPO_LABEL:-RHEL8OFFLINE}"
MNT="${MNT:-/mnt/rhel8offline}"

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
name=Offline EPEL 8 (optional extras)
baseurl=file://$MNT/EPEL
enabled=$( [[ -d "$MNT/EPEL/repodata" || -d "$MNT/EPEL/Packages" ]] && echo 1 || echo 0 )
gpgcheck=0
EOF
fi

echo "==> Applying offline upgrades (security errata on the USB)"
dnf -y upgrade || true

# Fail loudly on missing packages/deps (do not mask with || true).
# Comment out individual blocks if you need best-effort installs.

echo "==> Core required packages (RHEL repos)"
dnf -y install \
  chrony nano bc socat jq python3 python3-pip python3-setuptools \
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

echo "==> EPEL extras (required offline tree: htop, nload, pv, keepassxc, rdesktop)"
if [[ -d "$MNT/EPEL/repodata" || -d "$MNT/EPEL/Packages" ]]; then
  dnf -y install htop nload pv keepassxc rdesktop
else
  echo "ERROR: EPEL offline tree missing on media. On build host: ./scripts/05-fetch-epel-packages.sh" >&2
  exit 1
fi

echo "==> pipx (no RHEL/EPEL 8 RPM — install via pip if network or local wheels available)"
if python3 -m pip install --user pipx 2>/dev/null; then
  echo "pipx installed via pip --user"
else
  echo "NOTE: skipped pipx (no RPM on RHEL/EPEL 8; offline pip wheels not staged). python3-pip is installed."
fi

echo "==> Server with GUI (if not already installed)"
dnf -y groupinstall "Server with GUI" || \
  dnf -y install @graphical-server-environment
systemctl set-default graphical.target || true

echo "Extra package pass complete."
rpm -qa | wc -l
echo "sshd active? $(systemctl is-active sshd 2>/dev/null || echo n/a)"
