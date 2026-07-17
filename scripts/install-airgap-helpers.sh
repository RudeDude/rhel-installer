#!/usr/bin/env bash
# Install air-gap operator scripts + docs onto the target system as early as possible.
#
# Usage (as root):
#   install-airgap-helpers.sh /mnt/rhel8offline
#   install-airgap-helpers.sh /var/lib/offline-repos
#
# Copies:
#   scripts  -> /usr/local/sbin/  and  /usr/local/share/airgap/scripts/
#   docs     -> /usr/local/share/airgap/docs/  and  /root/airgap-docs/
#   packages -> /usr/local/share/airgap/packages/  and  /root/airgap-packages/
#   ROOT-HOME-README.md -> /root/README.md
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

SRC="${1:-}"
if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "Usage: $0 /path/to/usb-or-local-mirror" >&2
  exit 1
fi

SBIN=/usr/local/sbin
SHARE=/usr/local/share/airgap
ROOT_DOCS=/root/airgap-docs
mkdir -p "$SBIN" "$SHARE/scripts" "$SHARE/docs" "$SHARE/packages" "$ROOT_DOCS" /root /root/airgap-packages

# Prefer target-scripts.list on media; fall back to built-in list
HELPERS=()
if [[ -f "$SRC/scripts/target-scripts.list" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$line" ]] && HELPERS+=("$line")
  done < "$SRC/scripts/target-scripts.list"
fi
if [[ ${#HELPERS[@]} -eq 0 ]]; then
  HELPERS=(
    authorize-offline-usb.sh
    mount-offline-usb.sh
    enable-offline-repos.sh
    offline-repo-status.sh
    configure-grub-timeout.sh
    install-airgap-helpers.sh
    copy-offline-mirror-from-usb.sh
    install-from-local-mirror.sh
    update-target-repo-from-usb.sh
  )
fi

echo "==> Installing air-gap helpers from $SRC"

# From media scripts/
if [[ -d "$SRC/scripts" ]]; then
  # Also keep the list file for re-installs
  [[ -f "$SRC/scripts/target-scripts.list" ]] && \
    cp -a "$SRC/scripts/target-scripts.list" "$SHARE/scripts/"
  for s in "${HELPERS[@]}"; do
    if [[ -f "$SRC/scripts/$s" ]]; then
      cp -a "$SRC/scripts/$s" "$SHARE/scripts/$s"
      cp -a "$SRC/scripts/$s" "$SBIN/$s"
      chmod 755 "$SBIN/$s" "$SHARE/scripts/$s"
      echo "  script: $s"
    fi
  done
fi

# Docs from media docs/ or partition root
if [[ -d "$SRC/docs" ]]; then
  cp -a "$SRC/docs"/. "$SHARE/docs/" 2>/dev/null || true
  cp -a "$SRC/docs"/. "$ROOT_DOCS/" 2>/dev/null || true
  echo "  docs: $SRC/docs -> $SHARE/docs and $ROOT_DOCS"
fi
for f in OFFLINE-INSTALL.md README-ON-MEDIA.txt; do
  if [[ -f "$SRC/$f" ]]; then
    cp -a "$SRC/$f" "$SHARE/docs/$f"
    cp -a "$SRC/$f" "$ROOT_DOCS/$f"
    [[ "$f" == "OFFLINE-INSTALL.md" ]] && cp -a "$SRC/$f" /root/OFFLINE-INSTALL.md
  fi
done

# Master root README (canonical operator guide)
if [[ -f "$SRC/docs/ROOT-HOME-README.md" ]]; then
  cp -a "$SRC/docs/ROOT-HOME-README.md" /root/README.md
  cp -a "$SRC/docs/ROOT-HOME-README.md" "$SHARE/docs/ROOT-HOME-README.md"
  cp -a "$SRC/docs/ROOT-HOME-README.md" "$ROOT_DOCS/ROOT-HOME-README.md"
  echo "  /root/README.md updated from ROOT-HOME-README.md"
elif [[ -f "$SHARE/docs/ROOT-HOME-README.md" ]]; then
  cp -a "$SHARE/docs/ROOT-HOME-README.md" /root/README.md
elif [[ -f "$SRC/docs/OFFLINE-INSTALL.md" ]]; then
  cp -a "$SRC/docs/OFFLINE-INSTALL.md" /root/README.md
  echo "  /root/README.md from OFFLINE-INSTALL.md (fallback)"
elif [[ -f "$SRC/OFFLINE-INSTALL.md" ]]; then
  cp -a "$SRC/OFFLINE-INSTALL.md" /root/README.md
fi

# Package lists for reference
if [[ -d "$SRC/packages" ]]; then
  cp -a "$SRC/packages"/*.txt "$SHARE/packages/" 2>/dev/null || true
  cp -a "$SRC/packages"/*.txt /root/airgap-packages/ 2>/dev/null || true
  echo "  package lists copied"
fi

# Short pointer (full guide is /root/README.md — do not duplicate long docs here)
cat > /root/README-OFFLINE-REPOS.txt <<EOF
See /root/README.md for the full air-gap operator guide.

Quick:
  sudo authorize-offline-usb.sh
  sudo mount-offline-usb.sh
  # First setup (two steps — do not run installs while USB is the script path):
  sudo bash /mnt/rhel8offline/scripts/copy-offline-mirror-from-usb.sh
  sudo umount /mnt/rhel8offline   # then unplug USB
  sudo install-from-local-mirror.sh
  # Later updates: sudo update-target-repo-from-usb.sh
  sudo enable-offline-repos.sh && sudo dnf install <pkg>
  sudo offline-repo-status.sh

Local mirror (after step 1): /var/lib/offline-repos
Docs: /usr/local/share/airgap/docs/  and  /root/airgap-docs/
Package lists: /root/airgap-packages/  and  /usr/local/share/airgap/packages/
EOF

# Minimal motd (single file; do not create a second conflicting motd)
mkdir -p /etc/motd.d
cat > /etc/motd.d/99-airgap <<'EOF'
Air-gapped RHEL — read: /root/README.md
USB stuck?  sudo authorize-offline-usb.sh
Setup: copy-offline-mirror-from-usb.sh → umount USB → install-from-local-mirror.sh
Day-to-day: sudo enable-offline-repos.sh && sudo dnf install <pkg>
EOF
# Remove older duplicate motd if present
rm -f /etc/motd.d/99-offline-repos 2>/dev/null || true

echo "==> Helpers installed under $SBIN"
ls -1 "$SBIN"/authorize* "$SBIN"/mount-offline* "$SBIN"/enable-offline* \
  "$SBIN"/offline-repo* "$SBIN"/post-install* "$SBIN"/update-target* \
  "$SBIN"/install-airgap* 2>/dev/null || true
echo "==> Docs: $SHARE/docs  |  /root/README.md  |  $ROOT_DOCS"
