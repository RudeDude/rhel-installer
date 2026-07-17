#!/usr/bin/env bash
# Verify that packages from install-from-local-mirror.sh can be resolved using ONLY
# the offline trees under out/offline-repo (no CDN).
#
# Uses the registered rhel8-reposync container with file:// repos.
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

# Packages installed by install-from-local-mirror.sh (keep in sync with that script)
RHEL_PKGS=(
  chrony nano bc socat jq python3 python3-pip python3-setuptools
  python3.11 python3.11-pip python3.11-setuptools
  tcpdump wireshark wireshark-cli freerdp
  java-1.8.0-openjdk java-1.8.0-openjdk-devel
  java-11-openjdk java-11-openjdk-devel
  java-17-openjdk java-17-openjdk-devel java-17-openjdk-headless
  vim-enhanced tmux net-tools gedit tree util-linux util-linux-user
  rsync openssh openssh-server openssh-clients
  git gitk git-lfs
  curl wget tar unzip zip bind-utils nmap-ncat
  iotop sysstat lsof strace bash-completion man-pages man-db
  firefox evince gnome-terminal gnome-system-monitor
  psmisc procps-ng which file less diffutils
)
EPEL_PKGS=(htop nload pv keepassxc rdesktop)
# pipx: wheels in python-wheels/ — not an RPM check
# Optional heavy group (set CHECK_GUI_GROUP=1 to include)
CHECK_GUI_GROUP="${CHECK_GUI_GROUP:-0}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container $CONTAINER_NAME not running. Start with ./scripts/01-reposync.sh first." >&2
  exit 1
fi

for d in BaseOS AppStream; do
  if [[ ! -d "$REPO_DIR/$d/repodata" ]]; then
    echo "Missing $REPO_DIR/$d/repodata — run reposync first." >&2
    exit 1
  fi
done

HAVE_EPEL=0
if [[ -d "$REPO_DIR/EPEL/repodata" ]]; then
  HAVE_EPEL=1
else
  echo "WARN: no EPEL/repodata — EPEL package checks will fail or be skipped."
fi

echo "==> Checking deps offline using only file:// repos under /repo"
echo "    RHEL packages: ${#RHEL_PKGS[@]}"
echo "    EPEL packages: ${#EPEL_PKGS[@]} (have_epel=$HAVE_EPEL)"
echo

# Run inside container: only local repos, no CDN
docker exec -u 0 "$CONTAINER_NAME" bash -lc '
set -euo pipefail
mkdir -p /etc/yum.repos.d/offline-check.d
# Isolate: disable everything else for this invocation via --setopt=reposdir=
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
enabled=1
gpgcheck=0
module_hotfixes=1

[local-epel]
name=local EPEL
baseurl=file:///repo/EPEL
enabled=1
gpgcheck=0
EOF

# Drop metadata cache for these ids
dnf -q --setopt=reposdir=/etc/yum.repos.d/offline-check.d clean all || true

check_set() {
  local label="$1"; shift
  echo "---- $label ----"
  if [[ "$#" -eq 0 ]]; then
    echo "(empty set)"
    return 0
  fi
  # --downloadonly: full dep solve; succeeds only if every RPM is available offline.
  # (Do not use --assumeno alone — dnf often exits non-zero after a cancelled prompt.)
  local dl
  dl=$(mktemp -d /tmp/offline-dl.XXXXXX)
  set +e
  dnf --setopt=reposdir=/etc/yum.repos.d/offline-check.d \
      --disablerepo="*" \
      --enablerepo=local-baseos,local-appstream,local-crb,local-epel \
      install --downloadonly -y --downloaddir="$dl" "$@" 2>&1
  local st=$?
  set -e
  local n
  n=$(find "$dl" -name "*.rpm" 2>/dev/null | wc -l)
  rm -rf "$dl"
  if [[ $st -eq 0 ]]; then
    echo "OK: $label resolves offline (would download $n rpms into cache dir)"
    return 0
  fi
  echo "FAIL: $label could not resolve offline (dnf exit $st)" >&2
  return 1
}

rc=0
check_set "RHEL package list" '"${RHEL_PKGS[*]}"' || rc=1
if [[ "'"$HAVE_EPEL"'" == "1" ]]; then
  check_set "EPEL package list" '"${EPEL_PKGS[*]}"' || rc=1
  check_set "combined RHEL+EPEL" '"${RHEL_PKGS[*]} ${EPEL_PKGS[*]}"' || rc=1
fi

if [[ "'"$CHECK_GUI_GROUP"'" == "1" ]]; then
  echo "---- Server with GUI group ----"
  dnf --setopt=reposdir=/etc/yum.repos.d/offline-check.d \
      --disablerepo="*" \
      --enablerepo=local-baseos,local-appstream,local-crb \
      groupinstall --assumeno -y "Server with GUI" 2>&1 || rc=1
fi

exit $rc
'

echo
echo "Exit code from container check: $?"
echo "Note: install-from-local-mirror.sh fails loudly if offline trees are incomplete."
echo "      Prefer fixing missing deps here rather than relying on that."
