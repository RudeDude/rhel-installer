#!/usr/bin/env bash
# Embed custom kickstart into RHEL ISO and point boot entries at it.
# Supports:
#   - Image Builder liveimg ISOs (fips-stig / nofips) that already use osbuild.ks
#   - Traditional boot.iso
#
# Preserves volume label (required for inst.stage2) and FIPS/STIG kernel args.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/config.env" ]]; then
  # shellcheck disable=SC1091
  set +u
  source "$ROOT/config.env"
  set -u
fi

SOURCE_ISO="${SOURCE_ISO:-$ROOT/rhel-8.10-fips-stig.iso}"
KS_IN="${KS_IN:-$ROOT/out/ks.cfg}"
OUT_ISO="${OUT_ISO:-$ROOT/out/rhel-8.10-airgap-ks.iso}"
WORK="${WORK:-$ROOT/out/iso-work}"
PRESERVE_STIG_BOOT_ARGS="${PRESERVE_STIG_BOOT_ARGS:-yes}"

if [[ ! -f "$SOURCE_ISO" ]]; then
  echo "SOURCE_ISO not found: $SOURCE_ISO" >&2
  exit 1
fi
if [[ ! -f "$KS_IN" ]]; then
  echo "Kickstart not found: $KS_IN — run ./scripts/02-build-kickstart-iso.sh first" >&2
  exit 1
fi
command -v xorriso >/dev/null 2>&1 || { echo "xorriso required"; exit 1; }

VOL_ID="$(xorriso -indev "$SOURCE_ISO" -pvd_info 2>/dev/null | awk -F': ' '/Volume Id/ {print $2; exit}')"
VOL_ID="${VOL_ID//\'/}"
VOL_ID="$(echo "$VOL_ID" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[[ -n "$VOL_ID" ]] || VOL_ID="RHEL-8-10-0-BaseOS-x86_64"
echo "ISO volume id: $VOL_ID"
echo "Source ISO:    $SOURCE_ISO"

rm -rf "$WORK"
mkdir -p "$WORK/extract"

echo "==> Extracting ISO"
xorriso -osirrox on -indev "$SOURCE_ISO" -extract / "$WORK/extract"

mkdir -p "$WORK/extract/ks"
cp -a "$KS_IN" "$WORK/extract/ks/ks.cfg"
# Also replace stock osbuild.ks so any leftover ks= paths still work
if [[ -f "$WORK/extract/osbuild.ks" ]]; then
  cp -a "$KS_IN" "$WORK/extract/osbuild.ks"
  echo "Replaced osbuild.ks with custom kickstart"
fi

# Where Anaconda loads kickstart from (see KS_BOOT_SOURCE in config.env):
#   data (default) — LABEL=RHEL8OFFLINE:/ks/ks.cfg on the *ext4 offline* partition.
#                    Update with 04-update-usb --repos or --ks only (no ISO dd).
#   iso            — LABEL=<ISO volume>:/ks/ks.cfg inside the isohybrid image
#                    (ks changes need 03-prepare-usb reimage; ISO9660 not writable)
#   both           — data first; also keep a copy inside the ISO image
USB_REPO_LABEL="${USB_REPO_LABEL:-RHEL8OFFLINE}"
KS_BOOT_SOURCE="${KS_BOOT_SOURCE:-data}"
KS_CD="inst.ks=cdrom:/ks/ks.cfg"
case "$KS_BOOT_SOURCE" in
  iso)
    KS_HD="inst.ks=hd:LABEL=${VOL_ID}:/ks/ks.cfg"
    echo "inst.ks source: ISO volume LABEL=$VOL_ID (boot rewrite needed for ks changes)"
    ;;
  both)
    # Anaconda uses the first inst.ks=; put data partition first
    KS_HD="inst.ks=hd:LABEL=${USB_REPO_LABEL}:/ks/ks.cfg"
    echo "inst.ks source: data partition LABEL=$USB_REPO_LABEL (ISO still embeds a copy)"
    ;;
  data|*)
    KS_HD="inst.ks=hd:LABEL=${USB_REPO_LABEL}:/ks/ks.cfg"
    echo "inst.ks source: data partition LABEL=$USB_REPO_LABEL (update via --repos/--ks, not --boot)"
    ;;
esac

python3 - "$WORK/extract" "$KS_HD" "$KS_CD" "$PRESERVE_STIG_BOOT_ARGS" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
ks_hd, ks_cd, preserve = sys.argv[2], sys.argv[3], sys.argv[4].lower() == "yes"

def patch_line(line: str) -> str:
    if not re.search(r"(\bappend\b|^\s*linux(efi)?\s+)", line):
        # grub may use "linux " without efi on these ISOs
        if not re.search(r"^\s*linux\s+", line) and not re.search(r"^\s*append\s+", line):
            return line
    # Remove any existing inst.ks=...
    line = re.sub(r"\s*inst\.ks=\S+", "", line)
    line = line.rstrip("\n")
    # Prefer hd:LABEL form (matches existing Image Builder style)
    if not line.endswith(" "):
        line += " "
    line += ks_hd
    # Ensure fips=1 if preserve / not present
    if preserve and "fips=1" not in line and re.search(r"(vmlinuz|initrd.img|quiet)", line):
        # only add to kernel command lines
        if re.search(r"(\bappend\b|^\s*linux)", line):
            line += " fips=1"
    return line + "\n"

for path in list(root.rglob("*.cfg")) + list(root.rglob("*.conf")):
    if not path.is_file():
        continue
    text = path.read_text(encoding="utf-8", errors="replace")
    orig = text
    out = []
    for line in text.splitlines(True):
        if re.search(r"^\s*append\s+", line) or re.search(r"^\s*linux(efi)?\s+", line) or re.search(r"^\s*linux\s+", line):
            out.append(patch_line(line))
        else:
            out.append(line)
    text = "".join(out)

    if path.name == "grub.cfg":
        text = re.sub(r'set default="1"', 'set default="0"', text)
        text = re.sub(r"set default=1\b", "set default=0", text)
        text = re.sub(r"set timeout=\d+", "set timeout=5", text)

    if path.name == "isolinux.cfg":
        text = re.sub(r"(?m)^\s*menu default\s*\n", "", text)
        # add menu default under label linux if present
        if re.search(r"(?m)^label linux\n", text) and "menu default" not in text.split("label linux", 1)[-1].split("label ", 1)[0]:
            text = re.sub(r"(?m)^label linux\n", "label linux\n  menu default\n", text, count=1)
        text = re.sub(r"(?m)^timeout\s+\d+", "timeout 50", text)

    if text != orig:
        path.write_text(text, encoding="utf-8")
        print(f"Patched {path.relative_to(root)}")
PY

echo "==> inst.ks references:"
grep -R "inst.ks=" "$WORK/extract" --include='*.cfg' --include='*.conf' | head -n 30 || true

echo "==> Rebuilding hybrid ISO -> $OUT_ISO"
rm -f "$OUT_ISO"

# Detect whether this is EFI-only style with images/efiboot.img
EFIBOOT=""
if [[ -f "$WORK/extract/images/efiboot.img" ]]; then
  EFIBOOT="images/efiboot.img"
fi

xorriso -as mkisofs \
  -o "$OUT_ISO" \
  -V "$VOL_ID" \
  -J -R \
  -isohybrid-mbr --interval:local_fs:0s-15s:zero_mbrpt,zero_gpt:"$SOURCE_ISO" \
  -partition_cyl_align on \
  -partition_offset 0 \
  --mbr-force-bootable \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -eltorito-alt-boot \
  -e "$EFIBOOT" \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$WORK/extract"

ls -lh "$OUT_ISO"
echo
echo "DONE: $OUT_ISO"
echo "  Volume label: $VOL_ID"
echo "  Kickstart on ISO image: /ks/ks.cfg (and osbuild.ks if present)"
echo "  Boot inst.ks= : $KS_HD  (KS_BOOT_SOURCE=$KS_BOOT_SOURCE)"
if [[ "$KS_BOOT_SOURCE" == "data" || "$KS_BOOT_SOURCE" == "both" ]]; then
  echo "  → After USB is built, update kickstart with:"
  echo "      ./scripts/02-build-kickstart-iso.sh"
  echo "      sudo ./scripts/04-update-usb.sh --ks --device /dev/sdX"
  echo "    (no --boot / no ISO rewrite for ks-only changes)"
fi
echo "Next (first time): sudo ./scripts/03-prepare-usb.sh /dev/sdX"
