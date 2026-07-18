#!/usr/bin/env bash
# Download RPM Fusion packages (and deps) into out/offline-repo/RPMFusion.
# Expects container running with EPEL available (run fetch-epel first ideally).
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
RPMFUSION_SKIP_NONFREE="${RPMFUSION_SKIP_NONFREE:-0}"
RPMFUSION_FREE_URL="${RPMFUSION_FREE_URL:-https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-8.noarch.rpm}"
RPMFUSION_NONFREE_URL="${RPMFUSION_NONFREE_URL:-https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-8.noarch.rpm}"

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

# shellcheck disable=SC1091
source "$LIB/ensure-container.sh"

# Install release RPMs only if missing (no dnf clean, no reinstall tools/CRB)
docker exec -u 0 \
  -e "RPMFUSION_FREE_URL=${RPMFUSION_FREE_URL}" \
  -e "RPMFUSION_NONFREE_URL=${RPMFUSION_NONFREE_URL}" \
  -e "RPMFUSION_SKIP_NONFREE=${RPMFUSION_SKIP_NONFREE}" \
  "$CONTAINER_NAME" bash -lc '
  set -euo pipefail
  if ! rpm -q epel-release >/dev/null 2>&1; then
    echo "Installing epel-release (RPM Fusion depends on EPEL)..."
    dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
  fi
  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    echo "Installing rpmfusion-free-release..."
    dnf -y install --nogpgcheck "$RPMFUSION_FREE_URL"
  else
    echo "rpmfusion-free-release already installed — skip"
  fi
  if [[ "${RPMFUSION_SKIP_NONFREE}" != "1" ]]; then
    if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
      echo "Installing rpmfusion-nonfree-release..."
      dnf -y install --nogpgcheck "$RPMFUSION_NONFREE_URL"
    else
      echo "rpmfusion-nonfree-release already installed — skip"
    fi
  fi
'

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

  echo 'Pruning packages already present in BaseOS/AppStream/CRB/EPEL...'
  pruned=0
  for rpm in /repo/RPMFusion/Packages/*.rpm; do
    [[ -f \"\$rpm\" ]] || continue
    base=\$(basename \"\$rpm\")
    if find /repo/BaseOS /repo/AppStream /repo/CodeReadyBuilder /repo/EPEL \
         -name \"\$base\" 2>/dev/null | grep -q .; then
      rm -f \"\$rpm\"
      pruned=\$((pruned+1))
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

echo "Done. Offline RPM Fusion content: $FUSION_DIR"
