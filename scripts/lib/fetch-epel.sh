#!/usr/bin/env bash
# Download EPEL packages into out/offline-repo/EPEL (download + createrepo only).
# Release package install is handled by ensure-container.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
LIB="$ROOT/scripts/lib"

if [[ -f "$ROOT/config.env" ]]; then
  set +u
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  set -u
fi

REPO_DIR="${REPO_DIR:-$ROOT/out/offline-repo}"
[[ "$REPO_DIR" != /* ]] && REPO_DIR="$ROOT/${REPO_DIR#./}"
CONTAINER_NAME="${CONTAINER_NAME:-rhel8-reposync}"
PKG_FILE="${1:-$ROOT/packages/epel-extra.txt}"
EPEL_DIR="$REPO_DIR/EPEL"

if [[ ! -f "$PKG_FILE" ]]; then
  echo "Package list not found: $PKG_FILE" >&2
  exit 1
fi

mapfile -t PKGS < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PKG_FILE")
if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "No packages listed in $PKG_FILE" >&2
  exit 1
fi

echo "Packages to fetch from EPEL: ${PKGS[*]}"
mkdir -p "$EPEL_DIR/Packages"

if [[ "${AIRGAP_CONTAINER_READY:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$LIB/ensure-container.sh"
fi

if ! docker exec -u 0 "$CONTAINER_NAME" rpm -q epel-release >/dev/null 2>&1; then
  echo "ERROR: epel-release not installed in container (ensure-container should have installed it)" >&2
  exit 1
fi

pkg_args="${PKGS[*]}"
echo "==> dnf download --resolve --alldeps -> /repo/EPEL/Packages"
docker exec -u 0 "$CONTAINER_NAME" bash -lc "
  set -euo pipefail
  mkdir -p /repo/EPEL/Packages
  cd /repo/EPEL/Packages
  dnf -y download --resolve --alldeps --setopt=reposdir=/etc/yum.repos.d $pkg_args
  find /repo/EPEL -name '*.rpm' -type f ! -path '/repo/EPEL/Packages/*' \
    -exec mv -n {} /repo/EPEL/Packages/ \\; 2>/dev/null || true
  pruned=0
  for rpm in /repo/EPEL/Packages/*.rpm; do
    [[ -f \"\$rpm\" ]] || continue
    base=\$(basename \"\$rpm\")
    if find /repo/BaseOS /repo/AppStream /repo/CodeReadyBuilder -name \"\$base\" 2>/dev/null | grep -q .; then
      rm -f \"\$rpm\"; pruned=\$((pruned+1))
    fi
  done
  echo \"  pruned \$pruned RHEL-duplicate RPMs\"
  createrepo_c /repo/EPEL
  echo \"EPEL: \$(du -sh /repo/EPEL | cut -f1)  rpms=\$(find /repo/EPEL/Packages -name '*.rpm' | wc -l)\"
"
echo "Done. Offline EPEL: $EPEL_DIR"
