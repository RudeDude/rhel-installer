#!/usr/bin/env bash
# Ensure GRUB kernel/menu selection auto-continues after a timeout.
#
# STIG / hardened RHEL liveimg images often ship with:
#   GRUB_TIMEOUT=-1
#   GRUB_RECORDFAIL_TIMEOUT=-1
# which leave the boot menu waiting forever for a keypress.
#
# Usage (root):
#   configure-grub-timeout.sh           # default 5 seconds
#   GRUB_TIMEOUT=10 configure-grub-timeout.sh
#   configure-grub-timeout.sh 10
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

TIMEOUT="${1:-${GRUB_TIMEOUT:-5}}"
# Reject non-numeric / negative (except we always want a positive auto-boot timeout)
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: timeout must be a non-negative integer (seconds), got: $TIMEOUT" >&2
  exit 1
fi
# 0 = boot immediately (no menu wait). Prefer at least 1s so recovery is possible.
if [[ "$TIMEOUT" -eq 0 ]]; then
  echo "WARN: GRUB_TIMEOUT=0 boots immediately with no menu pause"
fi

DEFAULTS=/etc/default/grub
if [[ ! -f "$DEFAULTS" ]]; then
  echo "WARN: $DEFAULTS missing — creating minimal file"
  mkdir -p /etc/default
  cat > "$DEFAULTS" <<'EOF'
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="console"
GRUB_CMDLINE_LINUX=""
GRUB_DISABLE_RECOVERY="true"
EOF
fi

cp -a "$DEFAULTS" "${DEFAULTS}.bak-airgap-$(date +%Y%m%d%H%M%S)" 2>/dev/null || \
  cp -a "$DEFAULTS" "${DEFAULTS}.bak-airgap" 2>/dev/null || true

set_kv() {
  local key="$1" val="$2" file="$3"
  if grep -qE "^[[:space:]]*${key}=" "$file" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*${key}=.*|${key}=${val}|" "$file"
  else
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

echo "==> Setting GRUB auto-boot timeout to ${TIMEOUT}s in $DEFAULTS"

# -1 = wait forever (STIG default we are undoing)
set_kv GRUB_TIMEOUT "$TIMEOUT" "$DEFAULTS"
# After a failed/aborted boot, GRUB may also wait forever if this is -1
set_kv GRUB_RECORDFAIL_TIMEOUT "$TIMEOUT" "$DEFAULTS"

# Keep the menu visible briefly (not hidden forever / not "enter to boot")
if grep -qE '^[[:space:]]*GRUB_TIMEOUT_STYLE=' "$DEFAULTS" 2>/dev/null; then
  # "hidden" with timeout 0 can still feel stuck; prefer menu for operator recovery
  sed -i -E 's|^[[:space:]]*GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=menu|' "$DEFAULTS"
else
  echo 'GRUB_TIMEOUT_STYLE=menu' >> "$DEFAULTS"
fi

# Clear sticky recordfail so the next boot uses the normal timeout path
if command -v grub2-editenv >/dev/null 2>&1; then
  grub2-editenv - unset recordfail 2>/dev/null || true
  # menu_auto_hide can also change behaviour on some images
  grub2-editenv - unset menu_auto_hide 2>/dev/null || true
fi

# Show what we set
echo "    $(grep -E '^GRUB_TIMEOUT=|^GRUB_RECORDFAIL_TIMEOUT=|^GRUB_TIMEOUT_STYLE=' "$DEFAULTS" | tr '\n' ' ')"

regen_one() {
  local out="$1"
  local dir
  dir="$(dirname "$out")"
  [[ -d "$dir" ]] || return 0
  echo "==> grub2-mkconfig -> $out"
  if grub2-mkconfig -o "$out" 2>/tmp/airgap-grub-mkconfig.err; then
    # Ensure generated cfg has a positive timeout (mkconfig should, but belt-and-suspenders)
    if grep -qE 'set timeout=-1' "$out" 2>/dev/null; then
      sed -i -E "s/set timeout=-1/set timeout=${TIMEOUT}/g" "$out"
      echo "    patched set timeout=-1 -> ${TIMEOUT} in $out"
    fi
    if grep -qE 'set timeout_style=' "$out" 2>/dev/null; then
      sed -i -E 's/set timeout_style=.*/set timeout_style=menu/' "$out" || true
    fi
    return 0
  fi
  echo "WARN: grub2-mkconfig failed for $out" >&2
  cat /tmp/airgap-grub-mkconfig.err 2>/dev/null | tail -20 >&2 || true
  return 1
}

ok=0
# UEFI (RHEL default path)
if [[ -d /boot/efi/EFI/redhat ]] || [[ -d /sys/firmware/efi ]]; then
  regen_one /boot/efi/EFI/redhat/grub.cfg && ok=1 || true
  # Some installs also keep a BIOS-style copy
  regen_one /boot/grub2/grub.cfg && ok=1 || true
else
  regen_one /boot/grub2/grub.cfg && ok=1 || true
fi

# Last resort: patch any existing grub.cfg that still says timeout=-1
for cfg in /boot/grub2/grub.cfg /boot/efi/EFI/redhat/grub.cfg; do
  if [[ -f "$cfg" ]] && grep -qE 'set timeout=-1|set timeout=0-1' "$cfg" 2>/dev/null; then
    sed -i -E "s/set timeout=-1/set timeout=${TIMEOUT}/g" "$cfg"
    echo "==> Patched timeout=-1 in $cfg"
    ok=1
  fi
done

if [[ "$ok" -eq 0 ]]; then
  echo "WARN: could not regenerate GRUB config; /etc/default/grub is updated — run grub2-mkconfig manually after /boot is available" >&2
  exit 0
fi

echo "==> GRUB will auto-select the default kernel after ${TIMEOUT}s (press a key during menu to interrupt)"
echo "    Reboot to apply. Current defaults:"
grep -E '^GRUB_TIMEOUT=|^GRUB_RECORDFAIL_TIMEOUT=|^GRUB_TIMEOUT_STYLE=' "$DEFAULTS" || true
