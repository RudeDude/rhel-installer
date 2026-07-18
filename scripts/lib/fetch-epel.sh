#!/usr/bin/env bash
# Download EPEL packages (and dependencies) into out/offline-repo/EPEL for air-gap use.
# Uses the existing registered rhel8-reposync container when available.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container $CONTAINER_NAME is not running." >&2
  echo "Start a registered sync environment first:" >&2
  echo "  ./scripts/01-fetch-offline-content.sh" >&2
  echo "(You can Ctrl-C after registration/tools install if a full reposync is not needed, or leave it running.)" >&2
  exit 1
fi

# Ensure container can see REPO_DIR (same bind mount as lib/reposync)
docker exec -u 0 "$CONTAINER_NAME" bash -lc '
  set -euo pipefail
  dnf -y install dnf-plugins-core createrepo_c 2>/dev/null || true
  if ! rpm -q epel-release >/dev/null 2>&1; then
    dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
  fi
  dnf clean all || true
'

# Download each package with deps into /repo/EPEL/Packages
pkg_args="${PKGS[*]}"
docker exec -u 0 "$CONTAINER_NAME" bash -lc "
  set -euo pipefail
  mkdir -p /repo/EPEL/Packages
  cd /repo/EPEL/Packages
  # Prefer EPEL for these; still allow BaseOS/AppStream to satisfy deps without re-downloading if already cached
  dnf -y download --resolve --alldeps \
    --setopt=reposdir=/etc/yum.repos.d \
    $pkg_args
  # Flatten if dnf nested by arch
  find /repo/EPEL -name '*.rpm' -type f ! -path '/repo/EPEL/Packages/*' -exec mv -n {} /repo/EPEL/Packages/ \\; 2>/dev/null || true
  createrepo_c /repo/EPEL
  echo 'EPEL offline tree:'
  du -sh /repo/EPEL
  ls /repo/EPEL/Packages | wc -l
"

echo
echo "Done. Offline EPEL content: $EPEL_DIR"
echo "Next: ./scripts/01-fetch-offline-content.sh   # ffmpeg / media (optional but recommended)"
echo "Then: ./scripts/01-fetch-offline-content.sh"
echo "Then: ./scripts/01-fetch-offline-content.sh --only-check   # optional"
echo "Then: ./scripts/02-build-kickstart-iso.sh && ./scripts/02-build-kickstart-iso.sh"
echo "Then: sudo ./scripts/03-prepare-usb.sh /dev/sdb"
