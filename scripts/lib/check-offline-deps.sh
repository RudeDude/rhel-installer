#!/usr/bin/env bash
# Verify that packages from packages/*.txt can be resolved using ONLY
# the offline trees under out/offline-repo (no CDN).
#
# Uses the registered rhel8-reposync container with file:// repos.
# Keep lists in packages/{required,recommended,epel-extra}.txt — same as
# install-from-local-mirror.sh / lib/generate-kickstart.sh.
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
INCLUDE_RECOMMENDED="${INCLUDE_RECOMMENDED:-yes}"
CHECK_GUI_GROUP="${CHECK_GUI_GROUP:-0}"

pkg_file_to_lines() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$f"
}

mapfile -t RHEL_PKGS < <({
  pkg_file_to_lines "$ROOT/packages/required.txt"
  if [[ "$INCLUDE_RECOMMENDED" == "yes" ]]; then
    pkg_file_to_lines "$ROOT/packages/recommended.txt"
  fi
} | sort -u)

mapfile -t EPEL_PKGS < <(pkg_file_to_lines "$ROOT/packages/epel-extra.txt" | sort -u)
mapfile -t FUSION_PKGS < <(pkg_file_to_lines "$ROOT/packages/rpmfusion-extra.txt" | sort -u)

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container $CONTAINER_NAME not running. Start with ./scripts/01-fetch-offline-content.sh first." >&2
  exit 1
fi

for d in BaseOS AppStream; do
  if [[ ! -d "$REPO_DIR/$d/repodata" ]]; then
    echo "Missing $REPO_DIR/$d/repodata — run reposync first." >&2
    exit 1
  fi
done

HAVE_CRB=0
[[ -d "$REPO_DIR/CodeReadyBuilder/repodata" || -d "$REPO_DIR/CodeReadyBuilder/Packages" ]] && HAVE_CRB=1
HAVE_EPEL=0
if [[ -d "$REPO_DIR/EPEL/repodata" ]]; then
  HAVE_EPEL=1
else
  echo "WARN: no EPEL/repodata — EPEL package checks will fail or be skipped."
  echo "      Run: ./scripts/01-fetch-offline-content.sh"
fi
HAVE_FUSION=0
if [[ -d "$REPO_DIR/RPMFusion/repodata" ]]; then
  HAVE_FUSION=1
else
  echo "WARN: no RPMFusion/repodata — Fusion package checks will be skipped."
  echo "      Run: ./scripts/01-fetch-offline-content.sh"
fi

echo "==> Checking deps offline using only file:// repos under /repo"
echo "    RHEL packages (required+recommended): ${#RHEL_PKGS[@]}"
echo "    EPEL packages (epel-extra.txt): ${#EPEL_PKGS[@]} (have_epel=$HAVE_EPEL have_crb=$HAVE_CRB)"
echo "    RPM Fusion packages (rpmfusion-extra.txt): ${#FUSION_PKGS[@]} (have_fusion=$HAVE_FUSION)"
echo

# Pass package lists via files on the bind-mounted /repo
mkdir -p "$REPO_DIR/.check"
printf '%s\n' "${RHEL_PKGS[@]}" > "$REPO_DIR/.check/rhel-pkgs.txt"
printf '%s\n' "${EPEL_PKGS[@]}" > "$REPO_DIR/.check/epel-pkgs.txt"
printf '%s\n' "${FUSION_PKGS[@]}" > "$REPO_DIR/.check/fusion-pkgs.txt"

docker exec -u 0 -e HAVE_EPEL="$HAVE_EPEL" -e HAVE_CRB="$HAVE_CRB" -e HAVE_FUSION="$HAVE_FUSION" \
  -e CHECK_GUI_GROUP="$CHECK_GUI_GROUP" \
  "$CONTAINER_NAME" bash -lc '
set -euo pipefail
mkdir -p /etc/yum.repos.d/offline-check.d
CRB_EN=0
[[ "${HAVE_CRB:-0}" == "1" ]] && CRB_EN=1
EPEL_EN=0
[[ "${HAVE_EPEL:-0}" == "1" ]] && EPEL_EN=1
FUSION_EN=0
[[ "${HAVE_FUSION:-0}" == "1" ]] && FUSION_EN=1

cat > /etc/yum.repos.d/offline-check.d/local.repo <<EOF
[local-baseos]
name=local BaseOS
baseurl=file:///repo/BaseOS
enabled=1
gpgcheck=0
module_hotfixes=1

[local-appstream]
name=local AppStream
baseurl=file:///repo/AppStream
enabled=1
gpgcheck=0
module_hotfixes=1

[local-crb]
name=local CRB
baseurl=file:///repo/CodeReadyBuilder
enabled=${CRB_EN}
gpgcheck=0
module_hotfixes=1

[local-epel]
name=local EPEL
baseurl=file:///repo/EPEL
enabled=${EPEL_EN}
gpgcheck=0

[local-rpmfusion]
name=local RPM Fusion
baseurl=file:///repo/RPMFusion
enabled=${FUSION_EN}
gpgcheck=0
EOF

dnf -q --setopt=reposdir=/etc/yum.repos.d/offline-check.d clean all || true

mapfile -t RHEL_PKGS < <(sed "/^$/d" /repo/.check/rhel-pkgs.txt 2>/dev/null || true)
mapfile -t EPEL_PKGS < <(sed "/^$/d" /repo/.check/epel-pkgs.txt 2>/dev/null || true)
mapfile -t FUSION_PKGS < <(sed "/^$/d" /repo/.check/fusion-pkgs.txt 2>/dev/null || true)

check_set() {
  local label="$1"; shift
  echo "---- $label ----"
  if [[ "$#" -eq 0 ]]; then
    echo "(empty set)"
    return 0
  fi
  local dl st n
  dl=$(mktemp -d /tmp/offline-dl.XXXXXX)
  set +e
  dnf --setopt=reposdir=/etc/yum.repos.d/offline-check.d \
      --disablerepo="*" \
      --enablerepo=local-baseos,local-appstream,local-crb,local-epel,local-rpmfusion \
      install --downloadonly -y --downloaddir="$dl" "$@" 2>&1
  st=$?
  set -e
  n=$(find "$dl" -name "*.rpm" 2>/dev/null | wc -l)
  rm -rf "$dl"
  if [[ $st -eq 0 ]]; then
    echo "OK: $label resolves offline (would download $n rpms)"
    return 0
  fi
  echo "FAIL: $label could not resolve offline (dnf exit $st)" >&2
  echo "      If incorrect checksum / missing RPM under BaseOS/AppStream:" >&2
  echo "        CDN metadata listed RPMs that newest-only reposync never downloaded." >&2
  echo "        Fix:  ./scripts/rebuild-offline-repodata.sh" >&2
  echo "        (or re-run ./scripts/01-fetch-offline-content.sh / lib/rebuild-offline-repodata.sh)" >&2
  echo "      Else: re-run ./scripts/01-fetch-offline-content.sh (needs network + subscription)." >&2
  return 1
}

rc=0
check_set "RHEL package list (required+recommended)" "${RHEL_PKGS[@]}" || rc=1
if [[ "${HAVE_EPEL}" == "1" && ${#EPEL_PKGS[@]} -gt 0 ]]; then
  check_set "EPEL package list (epel-extra.txt)" "${EPEL_PKGS[@]}" || rc=1
fi
if [[ "${HAVE_FUSION}" == "1" && ${#FUSION_PKGS[@]} -gt 0 ]]; then
  check_set "RPM Fusion package list (rpmfusion-extra.txt)" "${FUSION_PKGS[@]}" || rc=1
fi

if [[ "${CHECK_GUI_GROUP}" == "1" ]]; then
  echo "---- Server with GUI group ----"
  dnf --setopt=reposdir=/etc/yum.repos.d/offline-check.d \
      --disablerepo="*" \
      --enablerepo=local-baseos,local-appstream,local-crb \
      groupinstall --assumeno -y "Server with GUI" 2>&1 || rc=1
fi

exit $rc
'

echo
echo "Note: install-from-local-mirror.sh installs from the same packages/*.txt lists."
echo "      Re-run 01, 02, and 02b after list changes."
