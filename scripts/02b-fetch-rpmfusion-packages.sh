#!/usr/bin/env bash
# Download RPM Fusion packages (and dependencies) into out/offline-repo/RPMFusion.
# Uses the registered rhel8-reposync container (same as 01/02).
#
# Order:
#   01-reposync.sh
#   02-fetch-epel-packages.sh     # EPEL required as dep source for many Fusion packages
#   02b-fetch-rpmfusion-packages.sh
#   03-fetch-python-wheels.sh
#
# Env:
#   REPO_DIR              default out/offline-repo
#   CONTAINER_NAME        default rhel8-reposync
#   RPMFUSION_FREE_URL    default mirrors.rpmfusion.org free release EL8
#   RPMFUSION_NONFREE_URL default mirrors.rpmfusion.org nonfree release EL8
#   RPMFUSION_SKIP_NONFREE=1  only enable free repo
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

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container $CONTAINER_NAME is not running." >&2
  echo "Start a registered sync environment first:" >&2
  echo "  ./scripts/01-reposync.sh" >&2
  echo "Then preferably: ./scripts/02-fetch-epel-packages.sh  (EPEL deps for Fusion)" >&2
  exit 1
fi

echo "==> Enabling EPEL + RPM Fusion inside $CONTAINER_NAME"
docker exec -u 0 \
  -e "RPMFUSION_FREE_URL=${RPMFUSION_FREE_URL}" \
  -e "RPMFUSION_NONFREE_URL=${RPMFUSION_NONFREE_URL}" \
  -e "RPMFUSION_SKIP_NONFREE=${RPMFUSION_SKIP_NONFREE}" \
  "$CONTAINER_NAME" bash -lc '
  set -euo pipefail
  dnf -y install dnf-plugins-core createrepo_c 2>/dev/null || true

  # CRB — required by EPEL/Fusion on RHEL 8
  if command -v crb >/dev/null 2>&1; then
    crb enable || true
  else
    dnf config-manager --set-enabled codeready-builder-for-rhel-8-x86_64-rpms 2>/dev/null || true
  fi

  if ! rpm -q epel-release >/dev/null 2>&1; then
    echo "Installing epel-release..."
    dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
  fi

  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    echo "Installing rpmfusion-free-release from $RPMFUSION_FREE_URL"
    dnf -y install --nogpgcheck "$RPMFUSION_FREE_URL"
  fi

  if [[ "${RPMFUSION_SKIP_NONFREE}" != "1" ]]; then
    if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
      echo "Installing rpmfusion-nonfree-release from $RPMFUSION_NONFREE_URL"
      dnf -y install --nogpgcheck "$RPMFUSION_NONFREE_URL"
    fi
  fi

  dnf clean all || true
  echo "Enabled third-party repos:"
  dnf repolist --enabled 2>/dev/null | grep -iE "epel|rpmfusion|codeready|crb" || true
'

# Download listed packages + deps into /repo/RPMFusion/Packages, then drop any
# RPM that already exists in BaseOS/AppStream/CRB/EPEL (those come from local RHEL/EPEL
# trees on the air-gap host — keeps Fusion lean and avoids confusing duplicates).
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

  # Remove RHEL/EPEL packages that are already staged elsewhere (by basename)
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
  echo \"  pruned \$pruned duplicate RPMs (kept Fusion-unique packages)\"

  createrepo_c /repo/RPMFusion
  echo 'RPM Fusion offline tree:'
  du -sh /repo/RPMFusion
  echo -n 'RPMs: '
  find /repo/RPMFusion/Packages -name '*.rpm' | wc -l
  for p in $pkg_args; do
    if find /repo/RPMFusion/Packages -name \"\${p}*.rpm\" | grep -q .; then
      echo \"  OK leaf: \$p\"
    else
      echo \"  WARN: no rpm matching \$p under Packages/\" >&2
    fi
  done
"

# Inventory for operators
{
  echo "RPM Fusion offline inventory — $(date -Is)"
  echo "Source list: $PKG_FILE"
  echo "Packages requested: ${PKGS[*]}"
  echo
  find "$FUSION_DIR/Packages" -name '*.rpm' -printf '%f\n' 2>/dev/null | sort
} > "$FUSION_DIR/INVENTORY.txt"

echo
echo "Done. Offline RPM Fusion content: $FUSION_DIR"
echo "Next: ./scripts/03-fetch-python-wheels.sh"
echo "      ./scripts/04-check-offline-deps.sh   # optional"
echo "Then stage USB: sudo ./scripts/08-update-usb.sh --repos --device /dev/sdX"
