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
EOF
fi

echo "==> Applying offline upgrades (security errata on the USB)"
dnf -y upgrade || true

echo "==> Core required packages"
dnf -y install \
  chrony ntpdate nano bc socat jq python3 python3-pip python3-setuptools pipx \
  tcpdump java-1.8.0-openjdk java-1.8.0-openjdk-devel \
  java-11-openjdk java-11-openjdk-devel \
  vim-enhanced tmux net-tools gedit tree util-linux util-linux-user \
  rsync curl wget tar unzip zip bind-utils nmap-ncat || true

echo "==> Selected extras (admin/observability + desktop + git)"
dnf -y install \
  htop iotop sysstat lsof strace bash-completion man-pages man-db \
  firefox evince gnome-terminal gnome-system-monitor \
  git psmisc procps-ng which file less diffutils || true

echo "==> Server with GUI (if not already installed)"
dnf -y groupinstall "Server with GUI" || \
  dnf -y install @graphical-server-environment || true
systemctl set-default graphical.target || true

echo "Extra package pass complete."
rpm -qa | wc -l
