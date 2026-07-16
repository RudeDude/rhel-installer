#!/usr/bin/env bash
# Download Python wheels **and all dependencies** for offline install on air-gapped RHEL.
#
# `pip download` resolves the full dependency tree by default (we never pass --no-deps).
# After download we verify with `pip install --no-index --find-links=... --dry-run`
# (or a real install into a temporary venv) so missing deps fail the fetch step.
#
# Config (config.env):
#   PYTHON_EXTRA_FILE              default: packages/python-extra.txt
#   PYTHON_WHEEL_DIR               default: out/offline-repo/python-wheels
#   PYTHON_PIP                     default: python3 -m pip  (build-host downloader)
#   PYTHON_TARGET_VERSION          default: 311  (match RHEL 8 python3.11 when resolving)
#   PYTHON_DOWNLOAD_PLATFORM       optional, e.g. manylinux2014_x86_64 (for binary wheels)
#   PYTHON_INCLUDE_PIP_BOOTSTRAP   default: yes  (also stage pip/setuptools/wheel)
#   PYTHON_VERIFY_OFFLINE          default: yes  (fail if offline install cannot resolve)
#
# Target systems should install python3.11 + python3.11-pip (see packages/required.txt)
# then:
#   python3.11 -m pip install --no-index --find-links=<wheel-dir> -r <wheel-dir>/requirements.txt
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
# RHEL 8 AppStream ships python3.11 — resolve tags for that by default
TARGET_PY="${PYTHON_TARGET_VERSION:-311}"
INCLUDE_BOOTSTRAP="${PYTHON_INCLUDE_PIP_BOOTSTRAP:-yes}"
VERIFY_OFFLINE="${PYTHON_VERIFY_OFFLINE:-yes}"

if [[ ! -f "$PKG_FILE" ]]; then
  echo "Python package list not found: $PKG_FILE" >&2
  exit 1
fi

mapfile -t PKGS < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PKG_FILE")
if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "No packages listed in $PKG_FILE" >&2
  exit 1
fi

echo "==> Staging Python wheels for offline install (WITH dependencies)"
echo "    list:              $PKG_FILE"
echo "    dest:              $WHEEL_DIR"
echo "    pip:               $PIP_CMD"
echo "    target py version: $TARGET_PY  (for tag selection; empty = host default)"
echo "    packages:          ${PKGS[*]}"
echo "    deps:              ALWAYS included (never uses --no-deps)"

# shellcheck disable=SC2086
if ! $PIP_CMD --version >/dev/null 2>&1; then
  echo "ERROR: cannot run: $PIP_CMD" >&2
  echo "Install pip on the build host or set PYTHON_PIP in config.env" >&2
  exit 1
fi

mkdir -p "$WHEEL_DIR"
# Fresh staging tree for reproducibility (keep README only if re-run mid-debug — wipe wheels)
find "$WHEEL_DIR" -maxdepth 1 -type f \( -name '*.whl' -o -name '*.tar.gz' -o -name '*.zip' \) -delete 2>/dev/null || true

REQ_TMP=$(mktemp)
printf '%s\n' "${PKGS[@]}" > "$REQ_TMP"
# Also persist clean requirements on media
cp "$REQ_TMP" "$WHEEL_DIR/requirements.txt"

# Common download args: resolve full dependency closure into WHEEL_DIR
# NOTE: Do NOT add --no-deps.
build_download_args() {
  local -n _out=$1
  _out=(-r "$REQ_TMP" -d "$WHEEL_DIR")
  # Prefer wheels so the offline host does not need a compiler.
  # NEVER pass --no-deps — full dependency closure is required for air-gap install.
  _out+=(--prefer-binary)
  # When restricting interpreter/platform, pip requires either --no-deps (bad for us)
  # or --only-binary=:all:. Prefer binary-only when targeting RHEL's python3.11.
  if [[ -n "${TARGET_PY}" || -n "${PYTHON_DOWNLOAD_PLATFORM:-}" ]]; then
    _out+=(--only-binary=:all:)
  fi
  if [[ -n "${TARGET_PY}" ]]; then
    _out+=(--python-version "${TARGET_PY}")
  fi
  if [[ -n "${PYTHON_DOWNLOAD_PLATFORM:-}" ]]; then
    _out+=(--platform "${PYTHON_DOWNLOAD_PLATFORM}")
    _out+=(--implementation cp)
    # For pure py3-none-any use abi=none; for cp311 manylinux set PYTHON_DOWNLOAD_ABI=cp311
    _out+=(--abi "${PYTHON_DOWNLOAD_ABI:-none}")
  fi
}

run_download() {
  local label=$1
  shift
  echo
  echo "==> pip download [$label] (dependency resolution ON)"
  # shellcheck disable=SC2086
  echo "    $PIP_CMD download $*"
  # shellcheck disable=SC2086
  $PIP_CMD download "$@"
}

DL_ARGS=()
build_download_args DL_ARGS

set +e
run_download "primary (prefer-binary, py${TARGET_PY:-host})" "${DL_ARGS[@]}"
st=$?
set -e

# If platform-tag filtering made pure-python resolution fail, retry without platform
if [[ $st -ne 0 && -n "${PYTHON_DOWNLOAD_PLATFORM:-}" ]]; then
  echo "WARN: tagged download failed; retrying without PYTHON_DOWNLOAD_PLATFORM"
  unset PYTHON_DOWNLOAD_PLATFORM
  DL_ARGS=()
  build_download_args DL_ARGS
  set +e
  run_download "fallback (no platform tag)" "${DL_ARGS[@]}"
  st=$?
  set -e
fi

# Last resort: host interpreter defaults (still with deps)
if [[ $st -ne 0 ]]; then
  echo "WARN: version-tagged download failed; retrying with host pip defaults (still with deps)"
  set +e
  # shellcheck disable=SC2086
  run_download "fallback (host defaults)" -r "$REQ_TMP" -d "$WHEEL_DIR" --prefer-binary
  st=$?
  set -e
fi

if [[ $st -ne 0 ]]; then
  echo "ERROR: pip download failed (exit $st)" >&2
  rm -f "$REQ_TMP"
  exit $st
fi

# Stage pip/setuptools/wheel so a minimal target can bootstrap if needed
if [[ "${INCLUDE_BOOTSTRAP,,}" == "yes" || "${INCLUDE_BOOTSTRAP}" == "1" ]]; then
  echo
  echo "==> Also staging pip / setuptools / wheel (bootstrap helpers, with their deps)"
  set +e
  # Host-default tags — still WITH deps (no --no-deps)
  # shellcheck disable=SC2086
  $PIP_CMD download -d "$WHEEL_DIR" --prefer-binary pip setuptools wheel
  set -e
fi

rm -f "$REQ_TMP"

ARTIFACTS=$(find "$WHEEL_DIR" -type f \( -name '*.whl' -o -name '*.tar.gz' -o -name '*.zip' \) | wc -l)
if [[ "$ARTIFACTS" -lt 1 ]]; then
  echo "ERROR: no wheels/sdists landed in $WHEEL_DIR" >&2
  exit 1
fi

# Write a lock-style inventory of what was downloaded (name only, for humans)
{
  echo "# Generated $(date -Is) — offline wheel inventory"
  echo "# Install with: python3.11 -m pip install --no-index --find-links=. -r requirements.txt"
  find "$WHEEL_DIR" -maxdepth 1 -type f \( -name '*.whl' -o -name '*.tar.gz' \) -printf '%f\n' | sort
} > "$WHEEL_DIR/WHEEL-INVENTORY.txt"

verify_offline() {
  echo
  echo "==> Verifying offline install would succeed (no network)"
  # Always use a throwaway venv so PEP 668 (externally-managed-environment) cannot
  # block verification on Debian/Ubuntu build hosts.
  local venv
  venv=$(mktemp -d /tmp/pywheel-verify.XXXXXX)
  python3 -m venv "$venv"
  set +e
  # dry-run first when supported
  "$venv/bin/pip" install --no-index --find-links="$WHEEL_DIR" \
    -r "$WHEEL_DIR/requirements.txt" --dry-run 2>&1
  local dry_st=$?
  if [[ $dry_st -eq 0 ]]; then
    echo "OK: pip install --dry-run --no-index in venv succeeded (deps complete)"
    rm -rf "$venv"
    set -e
    return 0
  fi
  echo "NOTE: dry-run failed or unsupported; doing full offline venv install"
  "$venv/bin/pip" install --no-index --find-links="$WHEEL_DIR" pip setuptools wheel 2>/dev/null
  "$venv/bin/pip" install --no-index --find-links="$WHEEL_DIR" -r "$WHEEL_DIR/requirements.txt"
  local v_st=$?
  set -e
  rm -rf "$venv"
  if [[ $v_st -eq 0 ]]; then
    echo "OK: offline venv install succeeded (full dependency closure present)"
    return 0
  fi
  echo "ERROR: offline verification failed — dependency closure incomplete" >&2
  echo "       Check WHEEL-INVENTORY.txt and re-run with network access." >&2
  return 1
}

if [[ "${VERIFY_OFFLINE,,}" == "yes" || "${VERIFY_OFFLINE}" == "1" ]]; then
  verify_offline
fi

cat > "$WHEEL_DIR/README-OFFLINE-PIP.txt" <<EOF
Offline Python wheels for air-gapped RHEL 8
Generated: $(date -Is)
Source list: $(basename "$PKG_FILE")
Dependency mode: FULL (pip download without --no-deps)
Artifacts: $ARTIFACTS files (see WHEEL-INVENTORY.txt)

On the installed system (USB mounted at e.g. /mnt/rhel8offline):

  # Prefer Python 3.11+ (RHEL 8 AppStream); base python3 is often 3.6 (too old for modern pipx)
  sudo dnf install python3.11 python3.11-pip
  python3.11 -m pip install --no-index \\
    --find-links=/mnt/rhel8offline/python-wheels \\
    -r /mnt/rhel8offline/python-wheels/requirements.txt

  python3.11 -m pipx ensurepath   # after pipx is installed

Rebuild/update on a connected host:
  edit packages/python-extra.txt
  ./scripts/03-fetch-python-wheels.sh
  # then re-run ./scripts/07-prepare-usb.sh (or rsync python-wheels/ onto the USB)
EOF

echo
echo "Staged wheels / sdists:"
ls -lh "$WHEEL_DIR" | sed -n '1,50p'
echo
echo "Count: $ARTIFACTS artifacts"
du -sh "$WHEEL_DIR"
echo
echo "DONE. Full dependency tree staged under $WHEEL_DIR"
echo "Next: ./scripts/04-check-offline-deps.sh   # optional (RPMs)"
echo "Then: ./scripts/05-generate-kickstart.sh && ./scripts/06-inject-kickstart.sh"
echo "Then: sudo ./scripts/07-prepare-usb.sh /dev/sdb"
echo "Re-fetch anytime after editing $PKG_FILE"
