#!/usr/bin/env bash
# Generate docs/INSTALLED-SOFTWARE-MANIFEST.md — flat default install lists only.
# RPMs: required + recommended (if INCLUDE_RECOMMENDED=yes) + epel-extra + rpmfusion-extra
# Python: python-extra.txt
#
#   ./scripts/lib/generate-installed-manifest.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OUT="${1:-$ROOT/docs/INSTALLED-SOFTWARE-MANIFEST.md}"
if [[ -f "$ROOT/config.env" ]]; then
  set +u
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  set -u
fi
INCLUDE_RECOMMENDED="${INCLUDE_RECOMMENDED:-yes}"

list_sorted() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  read_pkg_list "$f" | sed '/^$/d' | sort -u
}

rpm_list() {
  list_sorted "$ROOT/packages/required.txt"
  if [[ "${INCLUDE_RECOMMENDED,,}" == "yes" || "$INCLUDE_RECOMMENDED" == "1" ]]; then
    list_sorted "$ROOT/packages/recommended.txt"
  fi
  list_sorted "$ROOT/packages/epel-extra.txt"
  list_sorted "$ROOT/packages/rpmfusion-extra.txt"
}

py_list() {
  list_sorted "$ROOT/packages/python-extra.txt"
}

mapfile -t RPMS < <(rpm_list | sort -u)
mapfile -t PYS < <(py_list | sort -u)

{
  printf '# Default installed software\n\n'
  printf 'Names installed by this project’s default process '
  printf '(not every RPM on the offline mirror).\n'
  printf 'Regenerate: `./scripts/lib/generate-installed-manifest.sh`\n\n'

  printf '## RPM packages (%s)\n\n' "${#RPMS[@]}"
  printf '```\n'
  printf '%s\n' "${RPMS[@]}"
  printf '```\n\n'

  printf '## Python packages (%s)\n\n' "${#PYS[@]}"
  if [[ ${#PYS[@]} -eq 0 ]]; then
    printf '_None listed in packages/python-extra.txt._\n'
  else
    printf '```\n'
    printf '%s\n' "${PYS[@]}"
    printf '```\n'
  fi
} > "$OUT"

echo "Wrote $OUT (${#RPMS[@]} RPMs, ${#PYS[@]} Python)"
