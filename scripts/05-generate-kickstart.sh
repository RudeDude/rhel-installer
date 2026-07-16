#!/usr/bin/env bash
# Build out/ks.cfg from template + package lists + config.env
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/config.env" ]]; then
  # shellcheck disable=SC1091
  set +u
  source "$ROOT/config.env"
  set -u
else
  echo "Missing config.env — copy config.env.example first." >&2
  exit 1
fi

OUT_DIR="$ROOT/out"
KS_OUT="$OUT_DIR/ks.cfg"
TEMPLATE="$ROOT/kickstart/ks.cfg.template"
mkdir -p "$OUT_DIR"

: "${KS_HOSTNAME:=rhel8-airgap}"
: "${KS_TIMEZONE:=America/New_York}"
: "${KS_DISK:=sda}"
: "${KS_USER_NAME:=admin}"
: "${KS_USER_GECOS:=Local Admin}"
: "${KS_CLEARPART_ALL:=no}"
: "${KS_NETWORK_MODE:=dhcp}"
: "${KS_ENABLE_FIPS:=yes}"
: "${INCLUDE_RECOMMENDED:=yes}"
: "${USB_REPO_LABEL:=RHEL8OFFLINE}"
: "${KS_INSTALL_MODE:=liveimg}"
: "${KS_WANT_GUI:=yes}"
: "${KS_ENV_GROUP:=graphical-server-environment}"

if [[ -z "${KS_ROOT_PASSWORD_HASH:-}" || "$KS_ROOT_PASSWORD_HASH" == *REPLACE* ]]; then
  echo "ERROR: Set KS_ROOT_PASSWORD_HASH in config.env" >&2
  echo "  openssl passwd -6 'YourRootPassword'" >&2
  exit 1
fi
if [[ -z "${KS_USER_PASSWORD_HASH:-}" || "$KS_USER_PASSWORD_HASH" == *REPLACE* ]]; then
  echo "ERROR: Set KS_USER_PASSWORD_HASH in config.env" >&2
  exit 1
fi

if [[ "$KS_NETWORK_MODE" == "static" ]]; then
  : "${KS_IP:?Need KS_IP for static}"
  : "${KS_NETMASK:?Need KS_NETMASK for static}"
  : "${KS_GATEWAY:?Need KS_GATEWAY for static}"
  : "${KS_NAMESERVER:=$KS_GATEWAY}"
  KS_NETWORK_LINE="network --bootproto=static --ip=${KS_IP} --netmask=${KS_NETMASK} --gateway=${KS_GATEWAY} --nameserver=${KS_NAMESERVER} --device=link --activate"
else
  KS_NETWORK_LINE="network --bootproto=dhcp --device=link --activate --onboot=on"
fi

# Storage / bootloader
if [[ "$KS_CLEARPART_ALL" == "yes" ]]; then
  KS_STORAGE_BLOCK="ignoredisk --only-use=${KS_DISK}
clearpart --all --initlabel --drives=${KS_DISK}
autopart --type=lvm"
  KS_BOOTLOADER_LINE="bootloader --location=mbr --boot-drive=${KS_DISK} --append=\"crashkernel=auto\""
else
  # Interactive partitioning — Anaconda will prompt for disks/layout.
  KS_STORAGE_BLOCK="# Interactive partitioning (no clearpart/autopart)
# Anaconda UI will ask for installation destination."
  KS_BOOTLOADER_LINE="bootloader --location=mbr --append=\"crashkernel=auto\""
fi

# Install source block
if [[ "$KS_INSTALL_MODE" == "liveimg" ]]; then
  KS_INSTALL_SOURCE_BLOCK="# Image Builder / liveimg media (fips-stig / nofips ISOs)
# Root filesystem comes from liveimg.tar.gz on the boot ISO.
liveimg --url=file:///run/install/repo/liveimg.tar.gz
# Extra RPMs + errata come from the USB offline partition in %post.
"
  KS_PACKAGES_BLOCK="%packages
# liveimg supplies the base OS image; keep %packages minimal/empty.
%end
"
else
  KS_INSTALL_SOURCE_BLOCK="# Traditional package install from offline USB tree
harddrive --partition=/dev/disk/by-label/${USB_REPO_LABEL} --dir=/
repo --name=\"AppStream\" --baseurl=file:///run/install/repo/AppStream
"
  KS_PACKAGES_BLOCK="%packages
@^${KS_ENV_GROUP}
__PACKAGE_PLACEHOLDER__
dnf-plugins-core
%end
"
fi

pkg_file_to_lines() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f"
}

PKG_LINES="$(pkg_file_to_lines "$ROOT/packages/required.txt")"
if [[ "$INCLUDE_RECOMMENDED" == "yes" ]]; then
  PKG_LINES+=$'\n'"$(pkg_file_to_lines "$ROOT/packages/recommended.txt")"
fi

# Unique package list (space-separated for dnf in %post; newline for %packages)
mapfile -t PKG_ARR < <(echo "$PKG_LINES" | sed '/^$/d' | sort -u)
POST_PKG_LIST="${PKG_ARR[*]}"
PKG_NL="$(printf '%s\n' "${PKG_ARR[@]}")"

cp "$TEMPLATE" "$KS_OUT"

replace() {
  local key="$1" val="$2" file="$3"
  python3 - "$key" "$val" "$file" <<'PY'
import sys
key, val, path = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
if key not in text and key != "__PACKAGE_PLACEHOLDER__":
    # still write
    pass
text = text.replace(key, val)
open(path, "w", encoding="utf-8").write(text)
PY
}

replace "__KS_INSTALL_MODE__" "$KS_INSTALL_MODE" "$KS_OUT"
replace "__USB_REPO_LABEL__" "$USB_REPO_LABEL" "$KS_OUT"
replace "__KS_TIMEZONE__" "$KS_TIMEZONE" "$KS_OUT"
replace "__KS_HOSTNAME__" "$KS_HOSTNAME" "$KS_OUT"
replace "__KS_ROOT_PASSWORD_HASH__" "$KS_ROOT_PASSWORD_HASH" "$KS_OUT"
replace "__KS_USER_NAME__" "$KS_USER_NAME" "$KS_OUT"
replace "__KS_USER_PASSWORD_HASH__" "$KS_USER_PASSWORD_HASH" "$KS_OUT"
replace "__KS_USER_GECOS__" "$KS_USER_GECOS" "$KS_OUT"
replace "__KS_NETWORK_LINE__" "$KS_NETWORK_LINE" "$KS_OUT"
replace "__KS_STORAGE_BLOCK__" "$KS_STORAGE_BLOCK" "$KS_OUT"
replace "__KS_BOOTLOADER_LINE__" "$KS_BOOTLOADER_LINE" "$KS_OUT"
replace "__KS_INSTALL_SOURCE_BLOCK__" "$KS_INSTALL_SOURCE_BLOCK" "$KS_OUT"
replace "__KS_PACKAGES_BLOCK__" "$KS_PACKAGES_BLOCK" "$KS_OUT"
replace "__KS_ENABLE_FIPS__" "$KS_ENABLE_FIPS" "$KS_OUT"
replace "__KS_WANT_GUI__" "$KS_WANT_GUI" "$KS_OUT"
replace "__KS_POST_PACKAGE_LIST__" "$POST_PKG_LIST" "$KS_OUT"
replace "__PACKAGE_PLACEHOLDER__" "$PKG_NL" "$KS_OUT"

if [[ -d "${REPO_DIR:-$ROOT/out/offline-repo}" ]]; then
  mkdir -p "${REPO_DIR:-$ROOT/out/offline-repo}/ks" "${REPO_DIR:-$ROOT/out/offline-repo}/scripts"
  cp -a "$KS_OUT" "${REPO_DIR:-$ROOT/out/offline-repo}/ks/ks.cfg"
  cp -a "$ROOT/scripts/post-install-extra.sh" "${REPO_DIR:-$ROOT/out/offline-repo}/scripts/" 2>/dev/null || true
fi

echo "Wrote $KS_OUT"
echo "  Install mode: $KS_INSTALL_MODE"
echo "  Partitioning: $([[ "$KS_CLEARPART_ALL" == "yes" ]] && echo automated || echo interactive)"
echo "  FIPS: $KS_ENABLE_FIPS  GUI:%post=$KS_WANT_GUI"
echo "  Post packages: ${#PKG_ARR[@]}"
echo "Next: ./scripts/06-inject-kickstart.sh"
