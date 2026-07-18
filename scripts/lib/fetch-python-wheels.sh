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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
    # Binary wheels need cp311 (etc.), not abi=none (that only fits pure py3-none-any)
    if [[ -n "${PYTHON_DOWNLOAD_ABI:-}" ]]; then
      _out+=(--abi "${PYTHON_DOWNLOAD_ABI}")
    elif [[ -n "${TARGET_PY}" ]]; then
      _out+=(--abi "cp${TARGET_PY}")
    else
      _out+=(--abi none)
    fi
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

# Pick a Python that matches TARGET_PY tags (e.g. 311 -> python3.11).
# Returns empty if no matching interpreter is installed (do not fall back to host
# python3 — that produces noisy false "No matching distribution" errors for cp311 wheels).
resolve_verify_python() {
  local major minor cand
  if [[ "${TARGET_PY}" =~ ^([0-9])([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    for cand in "python${major}.${minor}" "python${major}${minor}"; do
      if command -v "$cand" >/dev/null 2>&1; then
        echo "$cand"
        return 0
      fi
    done
  fi
  if [[ -z "${TARGET_PY}" ]] && command -v python3 >/dev/null 2>&1; then
    echo "python3"
    return 0
  fi
  return 1
}

# Heuristic: every requirement name has at least one matching wheel/sdist in WHEEL_DIR
inventory_covers_requirements() {
  local req name alt ok=0 miss=0
  while IFS= read -r req || [[ -n "$req" ]]; do
    req="${req%%#*}"
    req="${req#"${req%%[![:space:]]*}"}"
    req="${req%"${req##*[![:space:]]}"}"
    [[ -z "$req" ]] && continue
    # strip extras and version: "numpy==1.26", "foo[bar]>=1", "pkg~=1.0"
    name="${req%%[*}"          # drop [extras]
    name="${name%%=*}"
    name="${name%%<*}"
    name="${name%%>*}"
    name="${name%%!*}"
    name="${name%%~*}"
    name="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    alt="${name//-/_}"
    if find "$WHEEL_DIR" -maxdepth 1 -type f \( \
         -iname "${name}-*.whl" -o -iname "${name}-*.tar.gz" -o \
         -iname "${alt}-*.whl" -o -iname "${alt}-*.tar.gz" \
       \) 2>/dev/null | grep -q .; then
      echo "  OK inventory: $name"
      ok=$((ok + 1))
    else
      echo "  MISSING wheel/sdist for requirement: $req (name=$name)" >&2
      miss=$((miss + 1))
    fi
  done < "$WHEEL_DIR/requirements.txt"
  [[ "$miss" -eq 0 && "$ok" -gt 0 ]]
}

verify_offline() {
  echo
  echo "==> Verifying offline install would succeed (no network)"
  echo "    TARGET_PY=${TARGET_PY:-host} (wheels tagged for that ABI, e.g. cp311)"

  local py_verify="" venv dry_st v_st
  if py_verify="$(resolve_verify_python)"; then
    echo "    verify interpreter: $py_verify"
  else
    # Do NOT dry-run under host python3.12 when TARGET_PY=311 — pip prints red
    # "No matching distribution found for numpy" even when the cp311 wheel is present.
    echo "    no python matching TARGET_PY=${TARGET_PY} on build host"
    echo "    skipping pip dry-run (avoids false errors for cp${TARGET_PY} wheels)"
    echo "    optional: sudo apt install python${TARGET_PY:0:1}.${TARGET_PY:1} python${TARGET_PY:0:1}.${TARGET_PY:1}-venv"
    if inventory_covers_requirements; then
      echo "OK: inventory covers all requirements.txt names"
      return 0
    fi
    echo "ERROR: offline verification failed — missing wheels for some requirements" >&2
    return 1
  fi

  if ! "$py_verify" -c 'import venv' 2>/dev/null; then
    echo "WARN: $py_verify cannot create venv; inventory coverage check only"
    if inventory_covers_requirements; then
      echo "OK: inventory covers all requirements.txt names (no venv verify)"
      return 0
    fi
    echo "ERROR: offline verification failed — missing wheels for some requirements" >&2
    return 1
  fi

  # Throwaway venv avoids PEP 668 on Debian/Ubuntu build hosts
  venv=$(mktemp -d /tmp/pywheel-verify.XXXXXX)
  if ! "$py_verify" -m venv "$venv" 2>/dev/null; then
    echo "WARN: $py_verify -m venv failed; inventory coverage check only"
    rm -rf "$venv"
    if inventory_covers_requirements; then
      echo "OK: inventory covers all requirements.txt names"
      return 0
    fi
    return 1
  fi

  set +e
  # Quiet pip unless it fails (still show failure output)
  if "$venv/bin/pip" install --no-index --find-links="$WHEEL_DIR" \
      -r "$WHEEL_DIR/requirements.txt" --dry-run >/tmp/pywheel-dryrun.out 2>&1; then
    dry_st=0
  else
    dry_st=$?
  fi
  if [[ $dry_st -eq 0 ]]; then
    echo "OK: pip install --dry-run --no-index in $py_verify venv succeeded (deps complete)"
    rm -rf "$venv" /tmp/pywheel-dryrun.out
    set -e
    return 0
  fi

  echo "NOTE: dry-run failed; trying full offline venv install"
  cat /tmp/pywheel-dryrun.out 2>/dev/null || true
  "$venv/bin/pip" install --no-index --find-links="$WHEEL_DIR" pip setuptools wheel >/dev/null 2>&1
  "$venv/bin/pip" install --no-index --find-links="$WHEEL_DIR" -r "$WHEEL_DIR/requirements.txt"
  v_st=$?
  set -e
  rm -rf "$venv" /tmp/pywheel-dryrun.out
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
  ./scripts/01-fetch-offline-content.sh
  # then re-run ./scripts/03-prepare-usb.sh (or rsync python-wheels/ onto the USB)
EOF

echo
echo "Staged wheels / sdists:"
ls -lh "$WHEEL_DIR" | sed -n '1,50p'
echo
echo "Count: $ARTIFACTS artifacts"
du -sh "$WHEEL_DIR"
echo
echo "DONE. Full dependency tree staged under $WHEEL_DIR"
echo "Next: ./scripts/01-fetch-offline-content.sh --only-check   # optional (RPMs)"
echo "Then: ./scripts/02-build-kickstart-iso.sh && ./scripts/02-build-kickstart-iso.sh"
echo "Then: sudo ./scripts/03-prepare-usb.sh /dev/sdb"
echo "Re-fetch anytime after editing $PKG_FILE"
