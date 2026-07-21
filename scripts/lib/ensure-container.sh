#!/usr/bin/env bash
# Ensure rhel8-reposync is running with RHSM + tools + third-party release RPMs.
# Safe to call repeatedly: reuses stopped containers; skips work when ready.
#
# When anything is missing, ONE dnf install installs:
#   tools: dnf-plugins-core yum-utils createrepo_c rsync findutils
#   + epel-release (unless SKIP_EPEL=1)
#   + rpmfusion free/nonfree releases (unless SKIP_RPMFUSION=1)
#
# Env: CONTAINER_NAME, REPO_DIR, REPOSYNC_IMAGE, SYNC_REPOS, RH_*,
#      FORCE_CONTAINER_SETUP, RECREATE_CONTAINER, SKIP_EPEL, SKIP_RPMFUSION,
#      RPMFUSION_SKIP_NONFREE, RPMFUSION_*_URL, METADATA_REFRESH_HOURS (default 6; 0=always)
set -euo pipefail

_ENSURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$_ENSURE_ROOT"

if [[ -f "$_ENSURE_ROOT/config.env" ]]; then
  set +u
  # shellcheck disable=SC1091
  source "$_ENSURE_ROOT/config.env"
  set -u
fi

REPO_DIR="${REPO_DIR:-$_ENSURE_ROOT/out/offline-repo}"
[[ "$REPO_DIR" != /* ]] && REPO_DIR="$_ENSURE_ROOT/${REPO_DIR#./}"
REPOSYNC_IMAGE="${REPOSYNC_IMAGE:-registry.access.redhat.com/ubi8/ubi:8.10}"
SYNC_REPOS="${SYNC_REPOS:-rhel-8-for-x86_64-baseos-rpms rhel-8-for-x86_64-appstream-rpms codeready-builder-for-rhel-8-x86_64-rpms}"
CONTAINER_NAME="${CONTAINER_NAME:-rhel8-reposync}"
FORCE_CONTAINER_SETUP="${FORCE_CONTAINER_SETUP:-0}"
RECREATE_CONTAINER="${RECREATE_CONTAINER:-0}"
SKIP_EPEL="${SKIP_EPEL:-0}"
SKIP_RPMFUSION="${SKIP_RPMFUSION:-0}"
RPMFUSION_SKIP_NONFREE="${RPMFUSION_SKIP_NONFREE:-0}"
RPMFUSION_FREE_URL="${RPMFUSION_FREE_URL:-https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-8.noarch.rpm}"
RPMFUSION_NONFREE_URL="${RPMFUSION_NONFREE_URL:-https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-8.noarch.rpm}"
METADATA_REFRESH_HOURS="${METADATA_REFRESH_HOURS:-6}"
HELPER_TAG="rhel8-reposync-helper:local"
MARKER=/var/lib/airgap-container-ready
METADATA_MARKER=/var/lib/airgap-metadata-refreshed
EPEL_RELEASE_URL="https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm"

mkdir -p "$REPO_DIR"
export RH_USER="${RH_USER:-}" RH_PASSWORD="${RH_PASSWORD:-}"
export RH_ORG_ID="${RH_ORG_ID:-}" RH_ACTIVATION_KEY="${RH_ACTIVATION_KEY:-}"

# --- Image ---
if [[ -f "$_ENSURE_ROOT/docker/Dockerfile.reposync" ]]; then
  if ! docker image inspect "$HELPER_TAG" >/dev/null 2>&1; then
    echo "==> Building helper image $HELPER_TAG (first time)"
    docker build -t "$HELPER_TAG" -f "$_ENSURE_ROOT/docker/Dockerfile.reposync" "$_ENSURE_ROOT/docker"
  fi
  RUN_IMAGE="$HELPER_TAG"
else
  if ! docker image inspect "$REPOSYNC_IMAGE" >/dev/null 2>&1; then
    echo "==> Pulling $REPOSYNC_IMAGE"
    docker pull "$REPOSYNC_IMAGE"
  fi
  RUN_IMAGE="$REPOSYNC_IMAGE"
fi

# --- Container lifecycle ---
if [[ "$RECREATE_CONTAINER" == "1" ]]; then
  echo "==> RECREATE_CONTAINER=1 — removing $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "==> Reusing running container: $CONTAINER_NAME"
elif docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "==> Starting existing container: $CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null
  for _ in 1 2 3 4 5 6 8 10; do
    docker exec -u 0 "$CONTAINER_NAME" true 2>/dev/null && break
    sleep 1
  done
else
  echo "==> Creating container $CONTAINER_NAME (image=$RUN_IMAGE)"
  docker run -d --name "$CONTAINER_NAME" \
    -v "$REPO_DIR:/repo:Z" \
    -e "RH_USER=${RH_USER}" \
    -e "RH_PASSWORD=${RH_PASSWORD}" \
    -e "RH_ORG_ID=${RH_ORG_ID}" \
    -e "RH_ACTIVATION_KEY=${RH_ACTIVATION_KEY}" \
    "$RUN_IMAGE" sleep infinity
fi

# --- RHSM + redhat.repo (once unless forced / unregistered) ---
base_ready=0
if [[ "$FORCE_CONTAINER_SETUP" != "1" ]] \
  && docker exec -u 0 "$CONTAINER_NAME" test -f "$MARKER" 2>/dev/null \
  && docker exec -u 0 "$CONTAINER_NAME" subscription-manager identity >/dev/null 2>&1; then
  base_ready=1
  echo "==> RHSM/repo base already configured"
  docker exec -u 0 "$CONTAINER_NAME" bash -lc 'command -v crb >/dev/null && crb enable >/dev/null 2>&1 || true' || true
fi

if [[ "$base_ready" -eq 0 ]]; then
  echo "==> Registering subscription (if needed)"
  set +e
  docker exec -u 0 \
    -e "RH_USER=${RH_USER}" -e "RH_PASSWORD=${RH_PASSWORD}" \
    -e "RH_ORG_ID=${RH_ORG_ID}" -e "RH_ACTIVATION_KEY=${RH_ACTIVATION_KEY}" \
    "$CONTAINER_NAME" bash -lc '
    set -euo pipefail
    if subscription-manager identity >/dev/null 2>&1; then
      echo "Already registered:"; subscription-manager identity || true; exit 0
    fi
    if [[ -n "${RH_ACTIVATION_KEY:-}" && -n "${RH_ORG_ID:-}" ]]; then
      subscription-manager register --org="$RH_ORG_ID" --activationkey="$RH_ACTIVATION_KEY"
    elif [[ -n "${RH_USER:-}" && -n "${RH_PASSWORD:-}" ]]; then
      subscription-manager register --username="$RH_USER" --password="$RH_PASSWORD" --auto-attach
    else
      echo "No RH credentials in env."; exit 42
    fi
    subscription-manager attach --auto 2>/dev/null || true
    subscription-manager refresh || true
    subscription-manager identity
  '
  reg_rc=$?
  set -e
  if [[ $reg_rc -eq 42 ]]; then
    echo "Register interactively: docker exec -it $CONTAINER_NAME subscription-manager register" >&2
    exit 1
  elif [[ $reg_rc -ne 0 ]]; then
    echo "Registration failed (exit $reg_rc)." >&2
    exit 1
  fi

  echo "==> Enabling BaseOS/AppStream/CRB"
  docker exec -u 0 -e "SYNC_REPOS=${SYNC_REPOS}" "$CONTAINER_NAME" bash -lc '
    set -euo pipefail
    /usr/libexec/platform-python - <<'"'"'PY'"'"'
from pathlib import Path
import os, re
path = Path("/etc/yum.repos.d/redhat.repo")
wanted = {x for x in os.environ.get("SYNC_REPOS", "").split() if x} or {
    "rhel-8-for-x86_64-baseos-rpms",
    "rhel-8-for-x86_64-appstream-rpms",
    "codeready-builder-for-rhel-8-x86_64-rpms",
}
wanted.add("codeready-builder-for-rhel-8-x86_64-rpms")
if not path.is_file():
    raise SystemExit("missing /etc/yum.repos.d/redhat.repo")
out, section = [], None
for line in path.read_text().splitlines(True):
    m = re.match(r"^\[(.+)\]\s*$", line)
    if m:
        section = m.group(1); out.append(line); continue
    if section in wanted and re.match(r"(?i)^\s*enabled\s*=", line):
        out.append("enabled = 1\n"); continue
    out.append(line)
path.write_text("".join(out))
print("enabled:", ", ".join(sorted(wanted)))
PY
    if command -v crb >/dev/null 2>&1; then crb enable || true
    else dnf config-manager --set-enabled codeready-builder-for-rhel-8-x86_64-rpms 2>/dev/null || true
    fi
  '
fi

# --- ONE dnf install for any missing tools + release RPMs (always checked) ---
echo "==> Tools + third-party releases (one dnf install if anything missing)"
docker exec -u 0 \
  -e "SKIP_EPEL=${SKIP_EPEL}" \
  -e "SKIP_RPMFUSION=${SKIP_RPMFUSION}" \
  -e "RPMFUSION_SKIP_NONFREE=${RPMFUSION_SKIP_NONFREE}" \
  -e "RPMFUSION_FREE_URL=${RPMFUSION_FREE_URL}" \
  -e "RPMFUSION_NONFREE_URL=${RPMFUSION_NONFREE_URL}" \
  -e "EPEL_RELEASE_URL=${EPEL_RELEASE_URL}" \
  -e "MARKER=${MARKER}" \
  "$CONTAINER_NAME" bash -lc '
  set -euo pipefail
  to_install=()
  have_epel_url=0

  for p in dnf-plugins-core yum-utils createrepo_c rsync findutils; do
    rpm -q "$p" >/dev/null 2>&1 || to_install+=("$p")
  done

  want_epel=0
  [[ "${SKIP_EPEL}" != "1" || "${SKIP_RPMFUSION}" != "1" ]] && want_epel=1
  if [[ "$want_epel" -eq 1 ]] && ! rpm -q epel-release >/dev/null 2>&1; then
    to_install+=("${EPEL_RELEASE_URL}")
    have_epel_url=1
  fi

  if [[ "${SKIP_RPMFUSION}" != "1" ]]; then
    if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
      to_install+=("${RPMFUSION_FREE_URL}")
    fi
    if [[ "${RPMFUSION_SKIP_NONFREE}" != "1" ]] && ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
      to_install+=("${RPMFUSION_NONFREE_URL}")
    fi
  fi

  if [[ ${#to_install[@]} -eq 0 ]]; then
    echo "    nothing missing — skip dnf install"
  else
    echo "    ONE dnf install: ${to_install[*]}"
    dnf -y install "${to_install[@]}" \
      --enablerepo=rhel-8-for-x86_64-baseos-rpms \
      --enablerepo=rhel-8-for-x86_64-appstream-rpms \
      --enablerepo=codeready-builder-for-rhel-8-x86_64-rpms \
      --nogpgcheck || \
    dnf -y install "${to_install[@]}" \
      --enablerepo=rhel-8-for-x86_64-baseos-rpms \
      --enablerepo=rhel-8-for-x86_64-appstream-rpms \
      --nogpgcheck
  fi
  mkdir -p /var/lib
  date -Is > "$MARKER"
'

# --- Age-gated metadata refresh ---
docker exec -u 0 \
  -e "METADATA_MARKER=${METADATA_MARKER}" \
  -e "METADATA_REFRESH_HOURS=${METADATA_REFRESH_HOURS}" \
  "$CONTAINER_NAME" bash -lc '
  set -euo pipefail
  hours="${METADATA_REFRESH_HOURS:-6}"
  if [[ "$hours" == "0" ]]; then
    echo "==> METADATA_REFRESH_HOURS=0 — dnf makecache --refresh"
    dnf clean expire-cache >/dev/null 2>&1 || true
    dnf makecache --refresh || true
    date -Is > "$METADATA_MARKER"
    exit 0
  fi
  need=1
  if [[ -f "$METADATA_MARKER" ]]; then
    age=$(( ($(date +%s) - $(stat -c %Y "$METADATA_MARKER" 2>/dev/null || echo 0)) / 3600 ))
    if [[ $age -lt $hours ]]; then
      echo "==> Metadata age ${age}h < ${hours}h — skip makecache"
      need=0
    else
      echo "==> Metadata age ${age}h >= ${hours}h — refresh"
    fi
  else
    echo "==> No metadata timestamp — refresh"
  fi
  if [[ $need -eq 1 ]]; then
    dnf clean expire-cache >/dev/null 2>&1 || true
    dnf makecache --refresh || true
    date -Is > "$METADATA_MARKER"
  fi
'

echo "==> Container ready: $CONTAINER_NAME"
