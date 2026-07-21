#!/usr/bin/env bash
# Sync RHEL 8 BaseOS + AppStream + CRB into out/offline-repo (newest-only).
# Container setup is owned by ensure-container.sh (called once by the orchestrator
# or here if invoked standalone).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
LIB="$ROOT/scripts/lib"

if [[ -f "$ROOT/config.env" ]]; then
  set +u
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  set -u
else
  echo "Missing config.env" >&2
  exit 1
fi

REPO_DIR="${REPO_DIR:-$ROOT/out/offline-repo}"
[[ "$REPO_DIR" != /* ]] && REPO_DIR="$ROOT/${REPO_DIR#./}"
SYNC_REPOS="${SYNC_REPOS:-rhel-8-for-x86_64-baseos-rpms rhel-8-for-x86_64-appstream-rpms codeready-builder-for-rhel-8-x86_64-rpms}"
CONTAINER_NAME="${CONTAINER_NAME:-rhel8-reposync}"

mkdir -p "$REPO_DIR"

map_repo_dir() {
  case "$1" in
    *baseos*) echo "BaseOS" ;;
    *appstream*) echo "AppStream" ;;
    *codeready-builder*|*crb*) echo "CodeReadyBuilder" ;;
    *) echo "$1" ;;
  esac
}

# Standalone invoke: ensure container. When called from 01 after ensure, this is cheap.
if [[ "${AIRGAP_CONTAINER_READY:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$LIB/ensure-container.sh"
fi

echo "==> reposync (incremental newest-only)"
for repoid in $SYNC_REPOS; do
  dest="$(map_repo_dir "$repoid")"
  echo "---- sync $repoid -> /repo/$dest ----"
  docker exec -u 0 "$CONTAINER_NAME" bash -lc "
    set -euo pipefail
    mkdir -p /repo/$dest
    dnf reposync \
      --repoid=$repoid \
      --download-path=/repo/$dest \
      --downloadcomps \
      --download-metadata \
      --norepopath \
      -n

    tmp=\$(mktemp -d)
    comps_src=\$(find /repo/$dest/repodata -name '*comps*.xml*' ! -name '*modules*' 2>/dev/null | head -1 || true)
    comps_arg=()
    if [[ -n \"\$comps_src\" && -f \"\$comps_src\" ]]; then
      case \"\$comps_src\" in
        *.gz) gunzip -c \"\$comps_src\" > \"\$tmp/comps.xml\" && comps_arg=(-g \"\$tmp/comps.xml\") ;;
        *.xml) comps_arg=(-g \"\$comps_src\") ;;
      esac
    fi
    echo \"Rebuilding repodata for /repo/$dest from on-disk RPMs...\"
    rm -f /repo/$dest/repodata/*modules* 2>/dev/null || true
    createrepo_c --workers \$(nproc 2>/dev/null || echo 2) \"\${comps_arg[@]}\" /repo/$dest
    rm -rf \"\$tmp\"
    echo \"size=\$(du -sh /repo/$dest | cut -f1) rpms=\$(find /repo/$dest -name '*.rpm' | wc -l)\"
  "
done

cat > "$REPO_DIR/README-ON-MEDIA.txt" <<EOF
RHEL 8 offline repository tree
Generated: $(date -Is)
Repos: $SYNC_REPOS
EOF

echo "==> Repo sizes:"
du -sh "$REPO_DIR"/* 2>/dev/null || du -sh "$REPO_DIR"
echo "DONE. RHEL offline repos at: $REPO_DIR"
