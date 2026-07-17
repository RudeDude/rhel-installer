#!/usr/bin/env bash
# Enable USB keyboard, mouse, and mass-storage on STIG/FIPS-hardened RHEL.
#
# Confirmed working approach on the target FIPS/STIG image:
#   - stop/disable USBGuard (rules alone were not enough "as is")
#   - usbcore.authorized_default=1 + authorize attached devices
#   - modprobe usbhid uas usb_storage
#
# dmesg symptom: "device is not authorized for usage"
#
#   sudo authorize-offline-usb.sh
#   sudo mount -L RHEL8OFFLINE /mnt/rhel8offline
#
# STIG note: USBGuard is stopped/disabled for air-gap media workflow.
# Re-enable later with a strict allow-list if your policy requires it:
#   systemctl enable --now usbguard
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

log() { echo "==> $*"; }

log "USB authorize for offline media / keyboard / mouse / storage"

# ---------------------------------------------------------------------------
# 1) USBGuard: disable for air-gap installs (primary fix on STIG image)
# ---------------------------------------------------------------------------
if systemctl list-unit-files usbguard.service >/dev/null 2>&1 || \
   systemctl is-active --quiet usbguard 2>/dev/null || \
   command -v usbguard >/dev/null 2>&1; then
  log "USBGuard present — stopping and disabling (allows HID + storage)"
  systemctl stop usbguard.service 2>/dev/null || true
  systemctl stop usbguard-dbus.service 2>/dev/null || true
  systemctl disable usbguard.service 2>/dev/null || true
  systemctl disable usbguard-dbus.service 2>/dev/null || true
  # Do not mask by default so admins can re-enable; write permissive policy if re-enabled
  mkdir -p /etc/usbguard /etc/usbguard/rules.d
  if [[ -f /etc/usbguard/rules.conf && ! -f /etc/usbguard/rules.conf.bak-airgap ]]; then
    cp -a /etc/usbguard/rules.conf /etc/usbguard/rules.conf.bak-airgap
  fi
  cat > /etc/usbguard/rules.d/10-airgap-allow-hid-storage.conf <<'EOF'
# Air-gap offline media + console input (authorize-offline-usb.sh)
# Applied if/when usbguard is re-enabled.
allow with-interface equals { 03:*:* }
allow with-interface one-of { 03:00:01 03:01:01 03:00:02 03:01:02 }
allow with-interface equals { 08:*:* }
allow with-interface equals { 09:*:* }
EOF
  # Also prepend allows to main rules.conf for older usbguard layouts
  {
    echo "# --- air-gap allows (authorize-offline-usb.sh) ---"
    echo "allow with-interface equals { 03:*:* }"
    echo "allow with-interface equals { 08:*:* }"
    echo "allow with-interface equals { 09:*:* }"
    echo "# --- end air-gap ---"
    [[ -f /etc/usbguard/rules.conf.bak-airgap ]] && cat /etc/usbguard/rules.conf.bak-airgap
    [[ -f /etc/usbguard/rules.conf && ! -f /etc/usbguard/rules.conf.bak-airgap ]] && cat /etc/usbguard/rules.conf
  } > /etc/usbguard/rules.conf.new
  mv /etc/usbguard/rules.conf.new /etc/usbguard/rules.conf
  chmod 0600 /etc/usbguard/rules.conf
  log "USBGuard stopped/disabled; permissive HID/storage rules written if re-enabled later"
fi

# ---------------------------------------------------------------------------
# 2) Kernel USB authorization
# ---------------------------------------------------------------------------
if [[ -f /sys/module/usbcore/parameters/authorized_default ]]; then
  echo 1 > /sys/module/usbcore/parameters/authorized_default 2>/dev/null || true
  log "usbcore.authorized_default -> $(cat /sys/module/usbcore/parameters/authorized_default 2>/dev/null || echo '?')"
fi
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/offline-usb-authorize.conf <<'EOF'
# Air-gap: authorize USB by default (STIG images often use 0).
options usbcore authorized_default=1
EOF

for auth in /sys/bus/usb/devices/*/authorized; do
  [[ -f "$auth" ]] || continue
  echo 1 > "$auth" 2>/dev/null || true
done
for auth in /sys/bus/usb/devices/*/authorized_default; do
  [[ -f "$auth" ]] || continue
  echo 1 > "$auth" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 3) STIG modprobe install-hooks that block usb-storage / usbhid
# ---------------------------------------------------------------------------
for f in /etc/modprobe.d/* /lib/modprobe.d/*; do
  [[ -f "$f" ]] || continue
  if grep -Eqi '^\s*(install\s+usb-storage|install\s+usbhid|blacklist\s+usb)' "$f" 2>/dev/null; then
    if grep -Eqi '^\s*install\s+usb-storage\s+/bin/(true|false)|^\s*install\s+usbhid\s+/bin/(true|false)|^\s*blacklist\s+usb' "$f" 2>/dev/null; then
      log "Commenting USB blocks in $f"
      cp -a "$f" "${f}.bak-airgap-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
      sed -i -E \
        -e 's/^(\s*install\s+usb-storage\s+\/bin\/(true|false))/\# airgap: \1/' \
        -e 's/^(\s*install\s+usbhid\s+\/bin\/(true|false))/\# airgap: \1/' \
        -e 's/^(\s*blacklist\s+usb-storage)/\# airgap: \1/' \
        -e 's/^(\s*blacklist\s+usb_storage)/\# airgap: \1/' \
        -e 's/^(\s*blacklist\s+usbhid)/\# airgap: \1/' \
        "$f" 2>/dev/null || true
    fi
  fi
done

# ---------------------------------------------------------------------------
# 4) Load HID + storage drivers (confirmed needed on target)
# ---------------------------------------------------------------------------
log "Loading usbhid, uas, usb_storage"
modprobe hid 2>/dev/null || true
modprobe hid_generic 2>/dev/null || true
modprobe usbhid 2>/dev/null || true
modprobe usb_storage 2>/dev/null || modprobe usb-storage 2>/dev/null || true
modprobe uas 2>/dev/null || true
modprobe sd_mod 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5) udev rescan
# ---------------------------------------------------------------------------
udevadm trigger --subsystem-match=usb --action=add 2>/dev/null || true
udevadm trigger --subsystem-match=hid --action=add 2>/dev/null || true
udevadm trigger --subsystem-match=input --action=add 2>/dev/null || true
udevadm trigger --subsystem-match=block --action=add 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 1

log "Input devices (keyboard):"
ls -l /dev/input/by-id/ 2>/dev/null | head -20 || true
log "Block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL 2>/dev/null || true
echo
if blkid -L RHEL8OFFLINE >/dev/null 2>&1; then
  log "Found LABEL=RHEL8OFFLINE at $(blkid -L RHEL8OFFLINE)"
else
  log "LABEL=RHEL8OFFLINE not visible — re-seat USB if needed"
  dmesg 2>/dev/null | tail -n 20 | grep -iE 'usb|authoriz|storage|hid' || true
fi

echo
echo "Done."
echo "  USBGuard: stopped/disabled (permissive rules kept for optional re-enable)"
echo "  Mount:  sudo mkdir -p /mnt/rhel8offline && sudo mount -L RHEL8OFFLINE /mnt/rhel8offline"
echo "  Then:   sudo bash /mnt/rhel8offline/scripts/post-install-extra.sh"
echo "  Update: sudo bash /mnt/rhel8offline/scripts/update-target-repo-from-usb.sh"
