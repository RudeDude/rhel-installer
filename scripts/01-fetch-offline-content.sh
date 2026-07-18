#!/usr/bin/env bash
# Step 01: Fetch all offline content for the air-gap USB (connected build host).
#
# Runs (in order):
#   1) RHEL BaseOS + AppStream + CRB reposync
#   2) EPEL targeted packages
#   3) RPM Fusion targeted packages (ffmpeg, …)
#   4) Python wheels (pipx, numpy, …)
#   5) Offline dependency check
# Then *stops* the rhel8-reposync container (keeps it for the next run so
# registration and repo config are preserved). Does not remove the container.
#
# Usage:
#   ./scripts/01-fetch-offline-content.sh
#   ./scripts/01-fetch-offline-content.sh --skip-wheels
#   ./scripts/01-fetch-offline-content.sh --skip-check
#   ./scripts/01-fetch-offline-content.sh --keep-running   # leave container up
#   ./scripts/01-fetch-offline-content.sh --remove-container  # stop+rm (full reset)
#   ./scripts/01-fetch-offline-content.sh --only-check
#   FORCE_CONTAINER_SETUP=1 ./scripts/01-fetch-offline-content.sh  # re-register/tools
#   RECREATE_CONTAINER=1 ./scripts/01-fetch-offline-content.sh     # docker rm + new
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
SKIP_REPOSYNC=0
SKIP_EPEL=0
SKIP_RPMFUSION=0
SKIP_WHEELS=0
SKIP_CHECK=0
KEEP_RUNNING=0
REMOVE_CONTAINER=0
ONLY_CHECK=0

usage() {
  cat <<EOF
Usage: $0 [options]

  --skip-reposync     Skip RHEL reposync (use existing BaseOS/AppStream/CRB trees)
  --skip-epel         Skip EPEL package fetch
  --skip-rpmfusion    Skip RPM Fusion package fetch
  --skip-wheels       Skip Python wheel fetch
  --skip-check        Skip offline dependency check
  --keep-running      Leave container running after finish (default: stop, keep image+state)
  --remove-container  docker rm the container after stop (loses registration; rare)
  --only-check        Only run offline dep check (starts container if needed, then stops)
  -h, --help

Default: stop the container when done, but do not remove it (next run is faster).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-reposync) SKIP_REPOSYNC=1; shift ;;
    --skip-epel) SKIP_EPEL=1; shift ;;
    --skip-rpmfusion) SKIP_RPMFUSION=1; shift ;;
    --skip-wheels) SKIP_WHEELS=1; shift ;;
    --skip-check) SKIP_CHECK=1; shift ;;
    --keep-running|--keep-container) KEEP_RUNNING=1; shift ;;
    --remove-container) REMOVE_CONTAINER=1; shift ;;
    --only-check) ONLY_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

stop_container() {
  if [[ "$KEEP_RUNNING" -eq 1 ]]; then
    echo "==> Leaving container $CONTAINER_NAME running (--keep-running)"
    return 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "==> Stopping container $CONTAINER_NAME (preserved for next run)"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "    stopped (registration/repos retained). Start again via next 01 run."
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "==> Container $CONTAINER_NAME already stopped"
  else
    echo "==> No container $CONTAINER_NAME present"
  fi
  if [[ "$REMOVE_CONTAINER" -eq 1 ]]; then
    echo "==> Removing container $CONTAINER_NAME (--remove-container)"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

cleanup_on_exit() {
  local ec=$?
  stop_container
  exit "$ec"
}
trap cleanup_on_exit EXIT

echo "############################################################"
echo "# 01-fetch-offline-content — full offline media payload    #"
echo "############################################################"
echo "Project: $ROOT"
echo

if [[ "$ONLY_CHECK" -eq 1 ]]; then
  # ensure container up for check
  # shellcheck disable=SC1091
  source "$LIB/ensure-container.sh"
  bash "$LIB/check-offline-deps.sh"
  exit 0
fi

if [[ "$SKIP_REPOSYNC" -eq 0 ]]; then
  echo "==== [1/5] RHEL reposync (BaseOS / AppStream / CRB) ===="
  bash "$LIB/reposync.sh"
else
  echo "==== [1/5] RHEL reposync — SKIPPED ===="
  # Still need a running container for later steps
  # shellcheck disable=SC1091
  source "$LIB/ensure-container.sh"
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "ERROR: $CONTAINER_NAME not running after setup" >&2
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
# trap stops container (unless --keep-running)
