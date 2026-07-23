#!/usr/bin/env bash
# Step 01: Fetch all offline content (connected build host).
#
#   1) ensure-container  — start/reuse Docker; ONE dnf install for tools+EPEL+Fusion releases
#   2) RHEL reposync
#   3) EPEL download
#   4) RPM Fusion download
#   5) RKE2 RPM mirror (rpm.rancher.io — backup offline install)
#   6) Python wheels
#   7) Offline dep check
# Then stop the container (keep it for the next run). Does not remove by default.
#
#   ./scripts/01-fetch-offline-content.sh
#   ./scripts/01-fetch-offline-content.sh --skip-reposync --skip-wheels
#   ./scripts/01-fetch-offline-content.sh --keep-running
#   ./scripts/01-fetch-offline-content.sh --remove-container
#   METADATA_REFRESH_HOURS=0 ./scripts/01-fetch-offline-content.sh   # always makecache
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
SKIP_RKE2=0
SKIP_WHEELS=0
SKIP_CHECK=0
KEEP_RUNNING=0
REMOVE_CONTAINER=0
ONLY_CHECK=0

usage() {
  cat <<EOF
Usage: $0 [options]

  --skip-reposync     Skip RHEL reposync
  --skip-epel         Skip EPEL package download
  --skip-rpmfusion    Skip RPM Fusion download
  --skip-rke2         Skip Rancher RKE2 RPM mirror (rpm.rancher.io)
  --skip-wheels       Skip Python wheel fetch
  --skip-check        Skip offline dependency check
  --keep-running      Leave container running (default: stop, keep state)
  --remove-container  docker rm after stop (loses registration)
  --only-check        Start container if needed, run dep check, stop
  -h, --help

Env: RKE2_MINOR (default 34 → channel 1.34), LINUX_MAJOR=8
Default: docker stop at end (not rm). Next run restarts the same container quickly.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-reposync) SKIP_REPOSYNC=1; shift ;;
    --skip-epel) SKIP_EPEL=1; shift ;;
    --skip-rpmfusion) SKIP_RPMFUSION=1; shift ;;
    --skip-rke2) SKIP_RKE2=1; shift ;;
    --skip-wheels) SKIP_WHEELS=1; shift ;;
    --skip-check) SKIP_CHECK=1; shift ;;
    --keep-running|--keep-container) KEEP_RUNNING=1; shift ;;
    --remove-container) REMOVE_CONTAINER=1; shift ;;
    --only-check) ONLY_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

export SKIP_EPEL SKIP_RPMFUSION

stop_container() {
  if [[ "$KEEP_RUNNING" -eq 1 ]]; then
    echo "==> Leaving container $CONTAINER_NAME running (--keep-running)"
    return 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "==> Stopping container $CONTAINER_NAME (preserved for next run)"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
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
echo "# 01-fetch-offline-content                                 #"
echo "############################################################"
echo "Project: $ROOT"
echo

# Shared setup once; lib fetch scripts skip re-ensure when AIRGAP_CONTAINER_READY=1
echo "==== [0] Container + single-pass tool/release install ===="
# shellcheck disable=SC1091
source "$LIB/ensure-container.sh"
export AIRGAP_CONTAINER_READY=1

if [[ "$ONLY_CHECK" -eq 1 ]]; then
  echo
  echo "==== Offline dependency check only ===="
  bash "$LIB/check-offline-deps.sh"
  exit 0
fi

if [[ "$SKIP_REPOSYNC" -eq 0 ]]; then
  echo
  echo "==== [1/6] RHEL reposync ===="
  bash "$LIB/reposync.sh"
else
  echo
  echo "==== [1/6] RHEL reposync — SKIPPED ===="
fi

if [[ "$SKIP_EPEL" -eq 0 ]]; then
  echo
  echo "==== [2/6] EPEL packages ===="
  bash "$LIB/fetch-epel.sh"
else
  echo
  echo "==== [2/6] EPEL packages — SKIPPED ===="
fi

if [[ "$SKIP_RPMFUSION" -eq 0 ]]; then
  echo
  echo "==== [3/6] RPM Fusion packages ===="
  bash "$LIB/fetch-rpmfusion.sh"
else
  echo
  echo "==== [3/6] RPM Fusion packages — SKIPPED ===="
fi

if [[ "$SKIP_RKE2" -eq 0 ]]; then
  echo
  echo "==== [4/6] RKE2 RPM mirror (rpm.rancher.io) ===="
  bash "$LIB/fetch-rke2.sh"
else
  echo
  echo "==== [4/6] RKE2 RPM mirror — SKIPPED ===="
fi

if [[ "$SKIP_WHEELS" -eq 0 ]]; then
  echo
  echo "==== [5/6] Python wheels ===="
  bash "$LIB/fetch-python-wheels.sh"
else
  echo
  echo "==== [5/6] Python wheels — SKIPPED ===="
fi

if [[ "$SKIP_CHECK" -eq 0 ]]; then
  echo
  echo "==== [6/6] Offline dependency check ===="
  bash "$LIB/check-offline-deps.sh"
else
  echo
  echo "==== [6/6] Offline dependency check — SKIPPED ===="
fi

echo
echo "############################################################"
echo "# Offline content fetch complete                           #"
echo "############################################################"
echo "Tree: ${REPO_DIR:-$ROOT/out/offline-repo}"
du -sh "${REPO_DIR:-$ROOT/out/offline-repo}" 2>/dev/null || true
echo
echo "Next:"
echo "  ./scripts/02-build-kickstart-iso.sh"
echo "  sudo ./scripts/03-prepare-usb.sh /dev/sdX"
