#!/usr/bin/env bash
# Allow USB mass-storage (installer / offline-repo stick) on STIG/FIPS-hardened RHEL.
#
# dmesg: "device is not authorized for usage" = USB authorization denied
# (usbcore.authorized_default=0 and/or USBGuard and/or usb-storage blocked).
#
# Run as root on the installed system BEFORE mounting the offline media:
#   sudo authorize-offline-usb.sh
#   sudo mount -L RHEL8OFFLINE /mnt/rhel8offline
#
# STIG note: this intentionally relaxes USB lockdown enough to use offline media.
# Re-tighten with USBGuard allow-lists for production if required by your policy.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

log() { echo "==> $*"; }

log "Authorizing USB devices for offline media use"

# 1) Kernel USB authorization: authorize all currently attached USB devices
#    and set default for new ones when possible.
if [[ -f /sys/module/usbcore/parameters/authorized_default ]]; then
  # 1 = authorize by default; -1 = authorize non-wireless (often acceptable)
  echo 1 > /sys/module/usbcore/parameters/authorized_default 2>/dev/null || true
  log "usbcore.authorized_default -> $(cat /sys/module/usbcore/parameters/authorized_default 2>/dev/null || echo '?')"
fi

# Persist across reboot (module option)
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/offline-usb-authorize.conf <<'EOF'
# Air-gap installer: allow USB devices by default so offline media can mount.
# STIG images often ship authorized_default=0 ("device is not authorized for usage").
options usbcore authorized_default=1
EOF

# Authorize every USB device node now
for auth in /sys/bus/usb/devices/*/authorized; do
  [[ -f "$auth" ]] || continue
  echo 1 > "$auth" 2>/dev/null || true
done
# Interfaces sometimes need authorized as well
for auth in /sys/bus/usb/devices/*/*/authorized; do
  [[ -f "$auth" ]] || continue
  echo 1 > "$auth" 2>/dev/null || true
done

# 2) Ensure usb-storage is not blocked by STIG modprobe install-hooks
for f in /etc/modprobe.d/*usb* /etc/modprobe.d/*storage* /etc/modprobe.d/*blacklist*; do
  [[ -f "$f" ]] || continue
  if grep -Eqi '^\s*install\s+usb-storage\s+/bin/(true|false)' "$f" 2>/dev/null || \
     grep -Eqi '^\s*blacklist\s+usb[_-]storage' "$f" 2>/dev/null; then
    log "Disabling USB storage block in $f (backed up)"
    cp -a "$f" "${f}.bak-airgap-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    # Comment out blocking lines
    sed -i -E \
      -e 's/^(\s*install\s+usb-storage\s+\/bin\/(true|false))/\# airgap: \1/' \
      -e 's/^(\s*blacklist\s+usb-storage)/\# airgap: \1/' \
      -e 's/^(\s*blacklist\s+usb_storage)/\# airgap: \1/' \
      "$f" 2>/dev/null || true
  fi
done

# Load storage drivers
modprobe usb_storage 2>/dev/null || modprobe usb-storage 2>/dev/null || true
modprobe uas 2>/dev/null || true
modprobe sd_mod 2>/dev/null || true

# 3) USBGuard: allow mass storage (and currently present devices)
if systemctl is-active --quiet usbguard 2>/dev/null || command -v usbguard >/dev/null 2>&1; then
  log "USBGuard detected — installing allow rules for mass storage / present devices"
  mkdir -p /etc/usbguard
  RULES=/etc/usbguard/rules.conf
  # Backup existing policy once
  if [[ -f "$RULES" && ! -f "${RULES}.bak-airgap" ]]; then
    cp -a "$RULES" "${RULES}.bak-airgap"
  fi
  # Prepend allow rules (usbguard uses first match in many configs — put allows first)
  TMP=$(mktemp)
  {
    echo "# --- air-gap offline media (added by authorize-offline-usb.sh) ---"
    echo "allow with-interface equals { 08:*:* }"   # Mass Storage class
    echo "allow with-interface equals { 09:*:* }"   # Hub
    echo "allow with-interface equals { 03:*:* }"   # HID (keyboard/mouse)
    # Snapshot currently connected devices as allow
    if command -v usbguard >/dev/null 2>&1; then
      usbguard generate-policy 2>/dev/null | sed 's/^block /allow /' || true
    fi
    echo "# --- end air-gap rules ---"
    [[ -f "$RULES" ]] && cat "$RULES" || true
  } > "$TMP"
  mv "$TMP" "$RULES"
  chmod 0600 "$RULES"
  systemctl restart usbguard 2>/dev/null || systemctl try-restart usbguard 2>/dev/null || true
  # Also try runtime allow-all if daemon supports it
  if command -v usbguard >/dev/null 2>&1; then
    usbguard list-devices 2>/dev/null | while read -r line; do
      id=$(echo "$line" | awk '{print $1}' | tr -d ':')
      [[ "$id" =~ ^[0-9]+$ ]] && usbguard allow-device "$id" 2>/dev/null || true
    done
  fi
fi

# 4) Trigger udev so block devices appear
udevadm trigger --subsystem-match=usb --action=add 2>/dev/null || true
udevadm trigger --subsystem-match=block --action=add 2>/dev/null || true
udevadm settle 2>/dev/null || true
sleep 1

log "Block devices now:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL 2>/dev/null || true
echo
if blkid -L RHEL8OFFLINE >/dev/null 2>&1; then
  log "Found LABEL=RHEL8OFFLINE at $(blkid -L RHEL8OFFLINE)"
else
  log "LABEL=RHEL8OFFLINE not visible yet — re-seat USB or check dmesg | tail"
  dmesg 2>/dev/null | tail -n 15 | grep -iE 'usb|authoriz|storage' || true
fi

echo
echo "Done. Mount offline media with:"
echo "  sudo mkdir -p /mnt/rhel8offline"
echo "  sudo mount -L RHEL8OFFLINE /mnt/rhel8offline"
echo "  sudo bash /mnt/rhel8offline/scripts/post-install-extra.sh"
