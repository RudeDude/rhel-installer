#!/usr/bin/env bash
# Step 02: Generate kickstart + inject into custom installer ISO.
#
#   ./scripts/02-build-kickstart-iso.sh
#
# Requires config.env with password hashes set.
# Output: out/ks.cfg and out/rhel-8.10-airgap-ks.iso (or OUT_ISO)
#
# After this: sudo ./scripts/03-prepare-usb.sh /dev/sdX
# Later ks-only media update: ./scripts/02-build-kickstart-iso.sh
#                              sudo ./scripts/04-update-usb.sh --ks --device /dev/sdX
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LIB="$ROOT/scripts/lib"

echo "############################################################"
echo "# 02-build-kickstart-iso — generate ks + custom ISO        #"
echo "############################################################"
echo

echo "==== [1/2] Generate kickstart (out/ks.cfg) ===="
bash "$LIB/generate-kickstart.sh"

echo
echo "==== [2/2] Inject kickstart into installer ISO ===="
bash "$LIB/inject-kickstart.sh"

echo
echo "############################################################"
echo "# Kickstart ISO ready                                        #"
echo "############################################################"
echo "Next (first USB write):"
echo "  sudo ./scripts/03-prepare-usb.sh /dev/sdX"
echo "Later content-only USB refresh:"
echo "  sudo ./scripts/04-update-usb.sh --repos --device /dev/sdX"
echo "Later kickstart file on data partition only:"
echo "  sudo ./scripts/04-update-usb.sh --ks --device /dev/sdX"
