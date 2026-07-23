#!/usr/bin/env bash
# Mirror Rancher RKE2 RPM repos into out/offline-repo/RKE2 for air-gap use.
# Source: https://docs.rke2.io/install/methods  (rpm.rancher.io)
#
# Env:
#   RKE2_MINOR     default 34  (channel 1.34; aligns with Rancher 2.13.x default)
#   LINUX_MAJOR    default 8   (EL8)
#   RKE2_CHANNEL   default latest  (or stable if you change base URLs)
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
PKG_FILE="${1:-$ROOT/packages/rke2-extra.txt}"
RKE2_DIR="$REPO_DIR/RKE2"
RKE2_MINOR="${RKE2_MINOR:-34}"
LINUX_MAJOR="${LINUX_MAJOR:-8}"
RKE2_GPGKEY_URL="${RKE2_GPGKEY_URL:-https://rpm.rancher.io/public.key}"
RKE2_COMMON_URL="${RKE2_COMMON_URL:-https://rpm.rancher.io/rke2/latest/common/centos/${LINUX_MAJOR}/noarch}"
RKE2_VERSION_URL="${RKE2_VERSION_URL:-https://rpm.rancher.io/rke2/latest/1.${RKE2_MINOR}/centos/${LINUX_MAJOR}/x86_64}"

if [[ ! -f "$PKG_FILE" ]]; then
  echo "Package list not found: $PKG_FILE" >&2
  exit 1
fi

mapfile -t PKGS < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PKG_FILE")
if [[ ${#PKGS[@]} -eq 0 ]]; then
  echo "No packages listed in $PKG_FILE" >&2
  exit 1
fi

echo "Packages to fetch from Rancher RKE2 (1.${RKE2_MINOR}, EL${LINUX_MAJOR}): ${PKGS[*]}"
echo "  common:  $RKE2_COMMON_URL"
echo "  version: $RKE2_VERSION_URL"
mkdir -p "$RKE2_DIR/Packages"

if [[ "${AIRGAP_CONTAINER_READY:-0}" != "1" ]]; then
  # shellcheck disable=SC1091
  source "$LIB/ensure-container.sh"
fi

pkg_args="${PKGS[*]}"
docker exec -u 0 \
  -e "RKE2_COMMON_URL=${RKE2_COMMON_URL}" \
  -e "RKE2_VERSION_URL=${RKE2_VERSION_URL}" \
  -e "RKE2_GPGKEY_URL=${RKE2_GPGKEY_URL}" \
  -e "RKE2_MINOR=${RKE2_MINOR}" \
  -e "LINUX_MAJOR=${LINUX_MAJOR}" \
  -e "PKG_ARGS=${pkg_args}" \
  "$CONTAINER_NAME" bash -lc '
  set -euo pipefail

  # Temporary repo definition for download only (not left as system default long-term)
  cat > /etc/yum.repos.d/rancher-rke2-airgap-fetch.repo <<EOF
[rancher-rke2-common-latest]
name=Rancher RKE2 Common Latest
baseurl=${RKE2_COMMON_URL}
enabled=1
gpgcheck=0
repo_gpgcheck=0

[rancher-rke2-1-${RKE2_MINOR}-latest]
name=Rancher RKE2 1.${RKE2_MINOR} Latest
baseurl=${RKE2_VERSION_URL}
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF

  mkdir -p /repo/RKE2/Packages
  cd /repo/RKE2/Packages
  # Resolve deps against RHEL offline-capable repos + Rancher (deps may come from BaseOS/AppStream)
  dnf -y download --resolve --alldeps \
    --setopt=reposdir=/etc/yum.repos.d \
    --enablerepo=rancher-rke2-common-latest \
    --enablerepo=rancher-rke2-1-${RKE2_MINOR}-latest \
    ${PKG_ARGS}

  find /repo/RKE2 -name "*.rpm" -type f ! -path "/repo/RKE2/Packages/*" \
    -exec mv -n {} /repo/RKE2/Packages/ \\; 2>/dev/null || true

  # Keep RKE2-unique packages; drop pure RHEL duplicates already on media
  pruned=0
  for rpm in /repo/RKE2/Packages/*.rpm; do
    [[ -f "$rpm" ]] || continue
    base=$(basename "$rpm")
    case "$base" in
      rke2-*) continue ;;
    esac
    if find /repo/BaseOS /repo/AppStream /repo/CodeReadyBuilder /repo/EPEL \
         -name "$base" 2>/dev/null | grep -q .; then
      rm -f "$rpm"
      pruned=$((pruned+1))
    fi
  done
  echo "  pruned $pruned non-rke2 RPMs already in RHEL/EPEL trees"

  createrepo_c /repo/RKE2
  echo "RKE2: $(du -sh /repo/RKE2 | cut -f1)  rpms=$(find /repo/RKE2/Packages -name "*.rpm" | wc -l)"
  for p in ${PKG_ARGS}; do
    if find /repo/RKE2/Packages -name "${p}*.rpm" | grep -q .; then
      echo "  OK leaf: $p"
    else
      echo "  WARN: no rpm matching $p" >&2
    fi
  done

  # Remove temporary fetch repo so it is not confused with production offline repos
  rm -f /etc/yum.repos.d/rancher-rke2-airgap-fetch.repo
'

{
  echo "RKE2 offline inventory — $(date -Is)"
  echo "RKE2_MINOR=1.${RKE2_MINOR}  LINUX_MAJOR=${LINUX_MAJOR}"
  echo "common:  $RKE2_COMMON_URL"
  echo "version: $RKE2_VERSION_URL"
  echo "Packages requested: ${PKGS[*]}"
  echo
  find "$RKE2_DIR/Packages" -name '*.rpm' -printf '%f\n' 2>/dev/null | sort
} > "$RKE2_DIR/INVENTORY.txt"

# Offline yum.repo snippet for operators (file:// after USB copy)
cat > "$RKE2_DIR/offline-rke2.repo.example" <<EOF
# Copy to /etc/yum.repos.d/ after RKE2 tree is on disk, or use enable-offline-repos.sh
# (enable-offline-repos includes RKE2 when out/offline-repo/RKE2 exists).
[offline-rke2]
name=Offline RKE2 (Rancher)
baseurl=file:///var/lib/offline-repos/RKE2
enabled=1
gpgcheck=0
EOF

echo "Done. Offline RKE2 content: $RKE2_DIR"
echo "  On target: sudo dnf install rke2-server   # or rke2-agent"
