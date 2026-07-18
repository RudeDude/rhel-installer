#!/usr/bin/env bash
# Build out/ks.cfg from template + package lists + config.env
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
# STIG images often use GRUB_TIMEOUT=-1 (wait forever); default to 5s auto-boot
: "${KS_GRUB_TIMEOUT:=5}"

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
replace "__KS_GRUB_TIMEOUT__" "$KS_GRUB_TIMEOUT" "$KS_OUT"
replace "__KS_POST_PACKAGE_LIST__" "$POST_PKG_LIST" "$KS_OUT"
replace "__PACKAGE_PLACEHOLDER__" "$PKG_NL" "$KS_OUT"

# Embed core helpers + root README into kickstart (available before USB mount)
embed_or_stub() {
  local placeholder="$1" path="$2" stub="$3"
  if [[ -f "$path" ]]; then
    replace "$placeholder" "$(cat "$path")" "$KS_OUT"
  else
    replace "$placeholder" "$stub" "$KS_OUT"
  fi
}
embed_or_stub "__EMBED_AUTHORIZE_SCRIPT__" "$ROOT/scripts/authorize-offline-usb.sh" \
  "#!/bin/bash
echo 'authorize-offline-usb.sh missing at image build time' >&2"
embed_or_stub "__EMBED_MOUNT_SCRIPT__" "$ROOT/scripts/mount-offline-usb.sh" \
  "#!/bin/bash
echo 'mount-offline-usb.sh missing at image build time' >&2"
embed_or_stub "__EMBED_ENABLE_SCRIPT__" "$ROOT/scripts/enable-offline-repos.sh" \
  "#!/bin/bash
echo 'enable-offline-repos.sh missing at image build time' >&2"
embed_or_stub "__EMBED_STATUS_SCRIPT__" "$ROOT/scripts/offline-repo-status.sh" \
  "#!/bin/bash
echo 'offline-repo-status.sh missing at image build time' >&2"
embed_or_stub "__EMBED_GRUB_TIMEOUT_SCRIPT__" "$ROOT/scripts/configure-grub-timeout.sh" \
  "#!/bin/bash
echo 'configure-grub-timeout.sh missing at image build time' >&2"
embed_or_stub "__EMBED_ROOT_README__" "$ROOT/docs/ROOT-HOME-README.md" \
  "# See docs/OFFLINE-INSTALL.md on the USB media"

# Stage ALL target-facing scripts + docs into offline-repo early (for USB + install)
REPO_OUT="${REPO_DIR:-$ROOT/out/offline-repo}"
if [[ "$REPO_OUT" != /* ]]; then REPO_OUT="$ROOT/${REPO_OUT#./}"; fi
mkdir -p "$REPO_OUT/ks" "$REPO_OUT/scripts" "$REPO_OUT/docs" "$REPO_OUT/packages"
cp -a "$KS_OUT" "$REPO_OUT/ks/ks.cfg"

# Target script list (single source of truth)
if [[ -f "$ROOT/scripts/target-scripts.list" ]]; then
  cp -a "$ROOT/scripts/target-scripts.list" "$REPO_OUT/scripts/"
  mapfile -t TARGET_SCRIPTS < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    "$ROOT/scripts/target-scripts.list")
else
  TARGET_SCRIPTS=(
    authorize-offline-usb.sh mount-offline-usb.sh enable-offline-repos.sh
    offline-repo-status.sh configure-grub-timeout.sh install-airgap-helpers.sh
    copy-offline-mirror-from-usb.sh install-from-local-mirror.sh
    update-target-repo-from-usb.sh
  )
fi
for s in "${TARGET_SCRIPTS[@]}"; do
  if [[ -f "$ROOT/scripts/$s" ]]; then
    cp -a "$ROOT/scripts/$s" "$REPO_OUT/scripts/"
    chmod 755 "$REPO_OUT/scripts/$s"
  else
    echo "WARN: target script missing: $s" >&2
  fi
done

cp -a "$ROOT/docs"/*.md "$REPO_OUT/docs/" 2>/dev/null || true
cp -a "$ROOT/docs/OFFLINE-INSTALL.md" "$REPO_OUT/OFFLINE-INSTALL.md" 2>/dev/null || true
cp -a "$ROOT/packages"/*.txt "$REPO_OUT/packages/" 2>/dev/null || true
[[ -f "$ROOT/README.md" ]] && cp -a "$ROOT/README.md" "$REPO_OUT/docs/PROJECT-README.md"

# Sanity: no leftover embed placeholders
if grep -q '__EMBED_' "$KS_OUT"; then
  echo "ERROR: unresolved embed placeholders remain in $KS_OUT:" >&2
  grep -n '__EMBED_' "$KS_OUT" >&2 || true
  exit 1
fi

echo "Wrote $KS_OUT"
echo "  Install mode: $KS_INSTALL_MODE"
echo "  Partitioning: $([[ "$KS_CLEARPART_ALL" == "yes" ]] && echo automated || echo interactive)"
echo "  FIPS: $KS_ENABLE_FIPS  GUI:%post=$KS_WANT_GUI"
echo "  Post packages: ${#PKG_ARR[@]}"
echo "  Staged ${#TARGET_SCRIPTS[@]} helpers + docs into $REPO_OUT/{scripts,docs,packages}"
echo "Done generating ks.cfg"
