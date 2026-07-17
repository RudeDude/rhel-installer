#!/usr/bin/env bash
# Rebuild repodata for offline trees from RPMs that *actually exist* on disk.
#
# Fixes: "Package from local repository has incorrect checksum" /
#        "Error opening ...rpm: No such file or directory"
# when reposync used -n (newest-only) but kept full CDN metadata.
#
# Note: We intentionally do NOT re-inject modules.yaml. CDN modules metadata +
# newest-only package sets often desync; offline installs use module_hotfixes=1.
#
# Usage:
#   ./scripts/rebuild-offline-repodata.sh
#   ./scripts/rebuild-offline-repodata.sh BaseOS AppStream
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
[[ "$REPO_DIR" != /* ]] && REPO_DIR="$ROOT/${REPO_DIR#./}"
CONTAINER_NAME="${CONTAINER_NAME:-rhel8-reposync}"

if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  TARGETS=()
  for d in BaseOS AppStream CodeReadyBuilder EPEL RPMFusion; do
    [[ -d "$REPO_DIR/$d" ]] && TARGETS+=("$d")
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No repo trees under $REPO_DIR" >&2
  exit 1
fi

rebuild_one() {
  local name="$1"
  echo "==> Rebuild repodata: $name"
  docker exec -u 0 "$CONTAINER_NAME" bash -lc "
    set -euo pipefail
    dest='/repo/$name'
    [[ -d \"\$dest\" ]] || { echo missing \$dest; exit 1; }
    # Drop any previous modules record (can corrupt dnf if gzipped twice / mismatched)
    if [[ -d \"\$dest/repodata\" ]] && command -v modifyrepo_c >/dev/null 2>&1; then
      modifyrepo_c --remove modules \"\$dest/repodata\" 2>/dev/null || true
    fi
    rm -f \"\$dest/repodata/\"*modules* 2>/dev/null || true
    # Optional comps for groups
    comps_src=\$(find \"\$dest/repodata\" -name '*comps*.xml*' 2>/dev/null | head -1 || true)
    tmp=\$(mktemp -d)
    comps_arg=()
    if [[ -n \"\$comps_src\" && -f \"\$comps_src\" ]]; then
      case \"\$comps_src\" in
        *.gz) gunzip -c \"\$comps_src\" > \"\$tmp/comps.xml\" && comps_arg=(-g \"\$tmp/comps.xml\") ;;
        *.xml) comps_arg=(-g \"\$comps_src\") ;;
      esac
    fi
    createrepo_c --workers \$(nproc 2>/dev/null || echo 2) \"\${comps_arg[@]}\" \"\$dest\"
    rm -rf \"\$tmp\"
    # Ensure modules not left behind from --update leftovers
    rm -f \"\$dest/repodata/\"*modules* 2>/dev/null || true
    if command -v modifyrepo_c >/dev/null 2>&1; then
      modifyrepo_c --remove modules \"\$dest/repodata\" 2>/dev/null || true
    fi
    echo \"   rpms=\$(find \"\$dest\" -name '*.rpm' | wc -l) repodata ok\"
  "
}

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  for t in "${TARGETS[@]}"; do
    rebuild_one "$t"
  done
else
  echo "Container $CONTAINER_NAME not running — using host createrepo_c if available"
  command -v createrepo_c >/dev/null 2>&1 || { echo "Need container or createrepo_c" >&2; exit 1; }
  for t in "${TARGETS[@]}"; do
    echo "==> Rebuild (host): $t"
    createrepo_c --workers "$(nproc 2>/dev/null || echo 2)" "$REPO_DIR/$t"
  done
fi

echo
echo "Done. Re-run: ./scripts/04-check-offline-deps.sh"
