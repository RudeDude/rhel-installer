#!/usr/bin/env bash
# Shared helpers for the BUILD-HOST scripts only (01-04 and scripts/lib/*).
#
# Do NOT source this from target-facing helpers: those scripts are embedded
# verbatim into ks.cfg and/or copied standalone to /usr/local/sbin and the USB,
# so they must stay self-contained. Build-host scripts already source
# lib/ensure-container.sh, so sharing code here is safe.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"   # from a lib/ script
#   mapfile -t PKGS < <(read_pkg_list "$PKG_FILE")

# read_pkg_list <file>
#   Emit one package/requirement per line from a list file: strip "#" comments,
#   trim surrounding whitespace, and drop blank lines. Missing file -> no output.
read_pkg_list() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" ]] || return 0
  sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f"
}
