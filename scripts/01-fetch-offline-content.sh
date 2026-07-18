#!/usr/bin/env bash
# Step 01: Fetch all offline content for the air-gap USB (connected build host).
#
# Runs (in order):
#   1) RHEL BaseOS + AppStream + CRB reposync
#   2) EPEL targeted packages
#   3) RPM Fusion targeted packages (ffmpeg, …)
#   4) Python wheels (pipx, numpy, …)
#   5) Offline dependency check
# Then stops and removes the rhel8-reposync Docker container.
#
# Usage:
#   ./scripts/01-fetch-offline-content.sh
#   ./scripts/01-fetch-offline-content.sh --skip-wheels
#   ./scripts/01-fetch-offline-content.sh --skip-check
#   ./scripts/01-fetch-offline-content.sh --keep-container
#   ./scripts/01-fetch-offline-content.sh --only-check   # re-check with container if still up
#
# Env (from config.env): same as the lib scripts (REPO_DIR, SYNC_REPOS, CONTAINER_NAME, …)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LIB="$ROOT/scripts/lib"

if [[ -f "$ROOT/config.env" ]]; then
  set +u
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  set -u
fi

CONTAINER_NAME="${CONTAINER_NAME:-rhel8-reposync}"
SKIP_EPEL=0
SKIP_RPMFUSION=0
SKIP_WHEELS=0
SKIP_CHECK=0
KEEP_CONTAINER=0
ONLY_CHECK=0

usage() {
  cat <<EOF
Usage: $0 [options]

  --skip-epel         Skip EPEL package fetch
  --skip-rpmfusion    Skip RPM Fusion package fetch
  --skip-wheels       Skip Python wheel fetch
  --skip-check        Skip offline dependency check
  --keep-container    Leave rhel8-reposync running after finish
  --only-check        Only run offline dep check (container must already exist)
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-epel) SKIP_EPEL=1; shift ;;
    --skip-rpmfusion) SKIP_RPMFUSION=1; shift ;;
    --skip-wheels) SKIP_WHEELS=1; shift ;;
    --skip-check) SKIP_CHECK=1; shift ;;
    --keep-container) KEEP_CONTAINER=1; shift ;;
    --only-check) ONLY_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

shutdown_container() {
  if [[ "$KEEP_CONTAINER" -eq 1 ]]; then
    echo "==> Keeping container $CONTAINER_NAME running (--keep-container)"
    return 0
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "==> Stopping and removing Docker container: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "    container removed"
  else
    echo "==> No container $CONTAINER_NAME to remove"
  fi
}

# Always try to clean up container on exit unless keep requested or only-check mid-debug
cleanup_on_exit() {
  local ec=$?
  if [[ "$ONLY_CHECK" -eq 1 ]]; then
    exit "$ec"
  fi
  if [[ "$ec" -ne 0 && "$KEEP_CONTAINER" -eq 0 ]]; then
    echo "==> Fetch failed (exit $ec); removing container unless you re-run with --keep-container" >&2
  fi
  shutdown_container
  exit "$ec"
}
trap cleanup_on_exit EXIT

echo "############################################################"
echo "# 01-fetch-offline-content — full offline media payload    #"
echo "############################################################"
echo "Project: $ROOT"
echo

if [[ "$ONLY_CHECK" -eq 1 ]]; then
  bash "$LIB/check-offline-deps.sh"
  KEEP_CONTAINER=1  # only-check does not own container lifecycle
  exit 0
fi

echo "==== [1/5] RHEL reposync (BaseOS / AppStream / CRB) ===="
bash "$LIB/reposync.sh"
# reposync leaves container running intentionally for subsequent steps;
# clear its EXIT trap leftovers by ensuring container still up
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "ERROR: $CONTAINER_NAME not running after reposync" >&2
  exit 1
fi

if [[ "$SKIP_EPEL" -eq 0 ]]; then
  echo
  echo "==== [2/5] EPEL packages (packages/epel-extra.txt) ===="
  bash "$LIB/fetch-epel.sh"
else
  echo
  echo "==== [2/5] EPEL packages — SKIPPED ===="
fi

if [[ "$SKIP_RPMFUSION" -eq 0 ]]; then
  echo
  echo "==== [3/5] RPM Fusion packages (packages/rpmfusion-extra.txt) ===="
  bash "$LIB/fetch-rpmfusion.sh"
else
  echo
  echo "==== [3/5] RPM Fusion packages — SKIPPED ===="
fi

if [[ "$SKIP_WHEELS" -eq 0 ]]; then
  echo
  echo "==== [4/5] Python wheels (packages/python-extra.txt) ===="
  bash "$LIB/fetch-python-wheels.sh"
else
  echo
  echo "==== [4/5] Python wheels — SKIPPED ===="
fi

if [[ "$SKIP_CHECK" -eq 0 ]]; then
  echo
  echo "==== [5/5] Offline dependency check ===="
  bash "$LIB/check-offline-deps.sh"
else
  echo
  echo "==== [5/5] Offline dependency check — SKIPPED ===="
fi

echo
echo "############################################################"
echo "# Offline content fetch complete                             #"
echo "############################################################"
echo "Tree: ${REPO_DIR:-$ROOT/out/offline-repo}"
du -sh "${REPO_DIR:-$ROOT/out/offline-repo}" 2>/dev/null || true
echo
echo "Next:"
echo "  ./scripts/02-build-kickstart-iso.sh"
echo "  sudo ./scripts/03-prepare-usb.sh /dev/sdX"
# trap runs shutdown_container
