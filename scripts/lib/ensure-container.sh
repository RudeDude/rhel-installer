#!/usr/bin/env bash
# Ensure the rhel8-reposync container is running with subscription + tools ready.
# Safe to call repeatedly: reuses a stopped container, skips re-register / reinstall
# when /var/lib/airgap-container-ready is present inside the container.
#
# Sourced or executed from other lib scripts. Does not stop the container.
#
# Env:
#   CONTAINER_NAME, REPO_DIR, REPOSYNC_IMAGE, RH_* credentials
#   FORCE_CONTAINER_SETUP=1  re-run registration/repo/tool setup even if ready
#   RECREATE_CONTAINER=1     docker rm and create a fresh container
set -euo pipefail

# Allow both `source` and direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _ENSURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
else
  _ENSURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
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
HELPER_TAG="rhel8-reposync-helper:local"
MARKER=/var/lib/airgap-container-ready

mkdir -p "$REPO_DIR"

export RH_USER="${RH_USER:-}"
export RH_PASSWORD="${RH_PASSWORD:-}"
export RH_ORG_ID="${RH_ORG_ID:-}"
export RH_ACTIVATION_KEY="${RH_ACTIVATION_KEY:-}"

# --- Image (build once) ---
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

# --- Container lifecycle: reuse > start > create ---
if [[ "$RECREATE_CONTAINER" == "1" ]]; then
  echo "==> RECREATE_CONTAINER=1 — removing $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "==> Reusing running container: $CONTAINER_NAME"
elif docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "==> Starting existing container: $CONTAINER_NAME (keeps registration/repos)"
  docker start "$CONTAINER_NAME" >/dev/null
  # wait for exec
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

# --- One-time (or forced) setup inside container ---
need_setup=1
if [[ "$FORCE_CONTAINER_SETUP" != "1" ]]; then
  if docker exec -u 0 "$CONTAINER_NAME" test -f "$MARKER" 2>/dev/null; then
    if docker exec -u 0 "$CONTAINER_NAME" subscription-manager identity >/dev/null 2>&1; then
      echo "==> Container already set up (marker $MARKER + subscription present) — skipping re-register/repo/tools"
      need_setup=0
    else
      echo "==> Marker present but not registered — re-running setup"
    fi
  fi
fi

if [[ "$need_setup" -eq 1 ]]; then
  echo "==> Registering subscription (if needed)"
  set +e
  docker exec -u 0 \
    -e "RH_USER=${RH_USER}" \
    -e "RH_PASSWORD=${RH_PASSWORD}" \
    -e "RH_ORG_ID=${RH_ORG_ID}" \
    -e "RH_ACTIVATION_KEY=${RH_ACTIVATION_KEY}" \
    "$CONTAINER_NAME" bash -lc '
    set -euo pipefail
    if subscription-manager identity >/dev/null 2>&1; then
      echo "Already registered:"
      subscription-manager identity || true
      exit 0
    fi
    if [[ -n "${RH_ACTIVATION_KEY:-}" && -n "${RH_ORG_ID:-}" ]]; then
      echo "Registering with org + activation key..."
      subscription-manager register --org="$RH_ORG_ID" --activationkey="$RH_ACTIVATION_KEY"
    elif [[ -n "${RH_USER:-}" && -n "${RH_PASSWORD:-}" ]]; then
      echo "Registering with username/password..."
      subscription-manager register --username="$RH_USER" --password="$RH_PASSWORD" --auto-attach
    else
      echo "No RH credentials in env."
      exit 42
    fi
    subscription-manager attach --auto 2>/dev/null || true
    subscription-manager refresh || true
    subscription-manager identity
  '
  reg_rc=$?
  set -e
  if [[ $reg_rc -eq 42 ]]; then
    echo "Register interactively, then re-run:" >&2
    echo "  docker start $CONTAINER_NAME" >&2
    echo "  docker exec -it $CONTAINER_NAME subscription-manager register" >&2
    exit 1
  elif [[ $reg_rc -ne 0 ]]; then
    echo "Registration failed (exit $reg_rc)." >&2
    exit 1
  fi

  echo "==> Enabling BaseOS/AppStream/CRB + installing tools (once)"
  docker exec -u 0 -e "SYNC_REPOS=${SYNC_REPOS}" "$CONTAINER_NAME" bash -lc '
    set -euo pipefail
    /usr/libexec/platform-python - <<'"'"'PY'"'"'
from pathlib import Path
import os, re
path = Path("/etc/yum.repos.d/redhat.repo")
wanted = {x for x in os.environ.get("SYNC_REPOS", "").split() if x}
if not wanted:
    wanted = {
        "rhel-8-for-x86_64-baseos-rpms",
        "rhel-8-for-x86_64-appstream-rpms",
        "codeready-builder-for-rhel-8-x86_64-rpms",
    }
wanted.add("codeready-builder-for-rhel-8-x86_64-rpms")
if not path.is_file():
    raise SystemExit("missing /etc/yum.repos.d/redhat.repo — register first")
out=[]; section=None
for line in path.read_text().splitlines(True):
    m=re.match(r"^\[(.+)\]\s*$", line)
    if m:
        section=m.group(1); out.append(line); continue
    if section in wanted and re.match(r"(?i)^\s*enabled\s*=", line):
        out.append("enabled = 1\n"); continue
    out.append(line)
path.write_text("".join(out))
print("redhat.repo enabled:", ", ".join(sorted(wanted)))
PY
    if command -v crb >/dev/null 2>&1; then
      crb enable || true
    else
      dnf config-manager --set-enabled codeready-builder-for-rhel-8-x86_64-rpms 2>/dev/null || true
    fi
    # Install tools only if missing
    need=()
    for p in dnf-plugins-core yum-utils createrepo_c rsync findutils; do
      rpm -q "$p" >/dev/null 2>&1 || need+=("$p")
    done
    if [[ ${#need[@]} -gt 0 ]]; then
      echo "Installing tools: ${need[*]}"
      dnf -y install "${need[@]}" \
        --disablerepo="*" \
        --enablerepo=rhel-8-for-x86_64-baseos-rpms \
        --enablerepo=rhel-8-for-x86_64-appstream-rpms \
        --enablerepo=codeready-builder-for-rhel-8-x86_64-rpms || \
      dnf -y install "${need[@]}" \
        --disablerepo="*" \
        --enablerepo=rhel-8-for-x86_64-baseos-rpms \
        --enablerepo=rhel-8-for-x86_64-appstream-rpms
    else
      echo "Tools already installed — skip"
    fi
    mkdir -p /var/lib
    date -Is > /var/lib/airgap-container-ready
    echo "Wrote /var/lib/airgap-container-ready"
  '
else
  # Light touch: ensure CRB still enabled without full dnf install
  docker exec -u 0 "$CONTAINER_NAME" bash -lc '
    if command -v crb >/dev/null 2>&1; then
      crb enable >/dev/null 2>&1 || true
    fi
  ' || true
fi

echo "==> Container ready: $CONTAINER_NAME"
