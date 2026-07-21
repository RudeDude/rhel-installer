#!/usr/bin/env bash
# Download RPM Fusion packages into out/offline-repo/RPMFusion (download + createrepo only).
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
PKG_FILE="${1:-$ROOT/packages/rpmfusion-extra.txt}"
FUSION_DIR="$REPO_DIR/RPMFusion"

if [[ ! -f "$PKG_FILE" ]]; then
  echo "Package list not found: $PKG_FILE" >&2
  exit 1
fi

mapfile -t PKGS < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PKG_FILE")
if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "No packages listed in $PKG_FILE" >&2
  exit 1
fi

echo "Packages to fetch from RPM Fusion: ${PKGS[*]}"
mkdir -p "$FUSION_DIR/Packages"

if [[ "${AIRGAP_CONTAINER_READY:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$LIB/ensure-container.sh"
fi

if ! docker exec -u 0 "$CONTAINER_NAME" rpm -q rpmfusion-free-release >/dev/null 2>&1; then
  echo "ERROR: rpmfusion-free-release not installed (ensure-container should have installed it)" >&2
  exit 1
fi

pkg_args="${PKGS[*]}"
echo "==> dnf download --resolve --alldeps -> /repo/RPMFusion/Packages"
docker exec -u 0 "$CONTAINER_NAME" bash -lc "
  set -euo pipefail
  mkdir -p /repo/RPMFusion/Packages
  cd /repo/RPMFusion/Packages
  dnf -y download --resolve --alldeps \
    --setopt=reposdir=/etc/yum.repos.d \
    --enablerepo=epel \
    --enablerepo=rpmfusion-free* \
    --enablerepo=rpmfusion-nonfree* \
    $pkg_args
  find /repo/RPMFusion -name '*.rpm' -type f ! -path '/repo/RPMFusion/Packages/*' \
    -exec mv -n {} /repo/RPMFusion/Packages/ \\; 2>/dev/null || true
  pruned=0
  for rpm in /repo/RPMFusion/Packages/*.rpm; do
    [[ -f \"\$rpm\" ]] || continue
    base=\$(basename \"\$rpm\")
    if find /repo/BaseOS /repo/AppStream /repo/CodeReadyBuilder /repo/EPEL \
         -name \"\$base\" 2>/dev/null | grep -q .; then
      rm -f \"\$rpm\"; pruned=\$((pruned+1))
    fi
  done
  echo \"  pruned \$pruned duplicate RPMs\"
  createrepo_c /repo/RPMFusion
  echo \"RPMFusion: \$(du -sh /repo/RPMFusion | cut -f1)  rpms=\$(find /repo/RPMFusion/Packages -name '*.rpm' | wc -l)\"
  for p in $pkg_args; do
    if find /repo/RPMFusion/Packages -name \"\${p}*.rpm\" | grep -q .; then
      echo \"  OK leaf: \$p\"
    else
      echo \"  WARN: no rpm matching \$p\" >&2
    fi
  done
"

{
  echo "RPM Fusion offline inventory — $(date -Is)"
  echo "Source list: $PKG_FILE"
  echo "Packages requested: ${PKGS[*]}"
  echo
  find "$FUSION_DIR/Packages" -name '*.rpm' -printf '%f\n' 2>/dev/null | sort
} > "$FUSION_DIR/INVENTORY.txt"

echo "Done. Offline RPM Fusion: $FUSION_DIR"
