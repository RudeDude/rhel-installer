#!/usr/bin/env bash
# Download Python wheels (and dependencies) for offline install on air-gapped RHEL.
#
# Config (config.env):
#   PYTHON_EXTRA_FILE   default: packages/python-extra.txt
#   PYTHON_WHEEL_DIR    default: out/offline-repo/python-wheels
#   PYTHON_PIP          default: python3 -m pip  (host or container interpreter used to *download*)
#   PYTHON_ONLY_BINARY  default: auto  (try binary-only first, fall back to any)
#
# Target systems should install python3.11 + python3.11-pip (see packages/required.txt)
# then: python3.11 -m pip install --no-index --find-links=<wheel-dir> -r python-extra.txt
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/config.env" ]]; then
  set +u
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  set -u
fi

REPO_DIR="${REPO_DIR:-$ROOT/out/offline-repo}"
if [[ "$REPO_DIR" != /* ]]; then REPO_DIR="$ROOT/${REPO_DIR#./}"; fi

PKG_FILE="${1:-${PYTHON_EXTRA_FILE:-$ROOT/packages/python-extra.txt}}"
if [[ "$PKG_FILE" != /* ]]; then PKG_FILE="$ROOT/${PKG_FILE#./}"; fi

WHEEL_DIR="${PYTHON_WHEEL_DIR:-$REPO_DIR/python-wheels}"
if [[ "$WHEEL_DIR" != /* ]]; then WHEEL_DIR="$ROOT/${WHEEL_DIR#./}"; fi

PIP_CMD="${PYTHON_PIP:-python3 -m pip}"
# Optional: pin download tags for manylinux if you need compiled deps later
# PYTHON_DOWNLOAD_PYTHON_VERSION=311
# PYTHON_DOWNLOAD_PLATFORM=manylinux2014_x86_64

if [[ ! -f "$PKG_FILE" ]]; then
  echo "Python package list not found: $PKG_FILE" >&2
  exit 1
fi

mapfile -t PKGS < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PKG_FILE")
if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "No packages listed in $PKG_FILE" >&2
  exit 1
fi

echo "==> Staging Python wheels for offline install"
echo "    list:   $PKG_FILE"
echo "    dest:   $WHEEL_DIR"
echo "    pip:    $PIP_CMD"
echo "    pkgs:   ${PKGS[*]}"

mkdir -p "$WHEEL_DIR"
# Requirements file without comments for pip
REQ_TMP=$(mktemp)
printf '%s\n' "${PKGS[@]}" > "$REQ_TMP"

# shellcheck disable=SC2086
if ! $PIP_CMD --version >/dev/null 2>&1; then
  echo "ERROR: cannot run: $PIP_CMD" >&2
  echo "Install pip on the build host or set PYTHON_PIP in config.env" >&2
  rm -f "$REQ_TMP"
  exit 1
fi

EXTRA_ARGS=()
if [[ -n "${PYTHON_DOWNLOAD_PYTHON_VERSION:-}" ]]; then
  EXTRA_ARGS+=(--python-version "${PYTHON_DOWNLOAD_PYTHON_VERSION}")
fi
if [[ -n "${PYTHON_DOWNLOAD_PLATFORM:-}" ]]; then
  EXTRA_ARGS+=(--platform "${PYTHON_DOWNLOAD_PLATFORM}")
  EXTRA_ARGS+=(--implementation cp)
  EXTRA_ARGS+=(--abi none)
fi

echo "==> pip download (with dependencies)"
set +e
# shellcheck disable=SC2086
$PIP_CMD download \
  -r "$REQ_TMP" \
  -d "$WHEEL_DIR" \
  "${EXTRA_ARGS[@]}" \
  2>&1
st=$?
set -e
rm -f "$REQ_TMP"

if [[ $st -ne 0 ]]; then
  echo "ERROR: pip download failed (exit $st)" >&2
  exit $st
fi

# Copy the requirement list onto the media for reproducible installs
cp -a "$PKG_FILE" "$WHEEL_DIR/requirements.txt"
cat > "$WHEEL_DIR/README-OFFLINE-PIP.txt" <<EOF
Offline Python wheels for air-gapped RHEL 8
Generated: $(date -Is)
Source list: $(basename "$PKG_FILE")

On the installed system (USB mounted at e.g. /mnt/rhel8offline):

  # Prefer Python 3.11+ (RHEL 8 AppStream); base python3 is often 3.6 and is too old for modern pipx
  sudo dnf install python3.11 python3.11-pip
  python3.11 -m pip install --no-index --find-links=/mnt/rhel8offline/python-wheels -r /mnt/rhel8offline/python-wheels/requirements.txt

Or install one package:

  python3.11 -m pip install --no-index --find-links=/mnt/rhel8offline/python-wheels pipx
EOF

echo
echo "Staged wheels:"
ls -lh "$WHEEL_DIR" | sed -n '1,40p'
echo
echo "Count: $(find "$WHEEL_DIR" -type f \( -name '*.whl' -o -name '*.tar.gz' \) | wc -l) artifacts"
du -sh "$WHEEL_DIR"
echo
echo "DONE. Wheels staged under $WHEEL_DIR"
echo "Next: ./scripts/04-check-offline-deps.sh   # optional"
echo "Then: ./scripts/05-generate-kickstart.sh && ./scripts/06-inject-kickstart.sh"
echo "Then: sudo ./scripts/07-prepare-usb.sh /dev/sdb   # copies wheels + RPMs + docs to USB"
echo "Re-fetch anytime after editing $PKG_FILE"
