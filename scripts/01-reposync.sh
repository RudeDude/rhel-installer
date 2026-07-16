#!/usr/bin/env bash
# Sync RHEL 8 BaseOS + AppStream (+ CRB) to ./out/offline-repo using a registered container.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/config.env" ]]; then
  # Password hashes contain $... — disable nounset while sourcing
  # shellcheck disable=SC1091
  set +u
  source "$ROOT/config.env"
  set -u
else
  echo "Missing config.env — copy config.env.example and fill in RH credentials." >&2
  exit 1
fi

REPO_DIR="${REPO_DIR:-$ROOT/out/offline-repo}"
REPOSYNC_IMAGE="${REPOSYNC_IMAGE:-registry.access.redhat.com/ubi8/ubi:8.10}"
SYNC_REPOS="${SYNC_REPOS:-rhel-8-for-x86_64-baseos-rpms rhel-8-for-x86_64-appstream-rpms codeready-builder-for-rhel-8-x86_64-rpms}"
CONTAINER_NAME="${CONTAINER_NAME:-rhel8-reposync}"

mkdir -p "$REPO_DIR"

echo "==> Ensuring Docker image: $REPOSYNC_IMAGE"
if ! docker image inspect "$REPOSYNC_IMAGE" >/dev/null 2>&1; then
  docker pull "$REPOSYNC_IMAGE"
fi

# Build thin helper image with createrepo/yum-utils if Dockerfile present
HELPER_TAG="rhel8-reposync-helper:local"
if [[ -f "$ROOT/docker/Dockerfile.reposync" ]]; then
  echo "==> Building helper image $HELPER_TAG"
  docker build -t "$HELPER_TAG" -f "$ROOT/docker/Dockerfile.reposync" "$ROOT/docker"
  RUN_IMAGE="$HELPER_TAG"
else
  RUN_IMAGE="$REPOSYNC_IMAGE"
fi

# Map short directory names for Anaconda-friendly layout
# CDN repoid -> directory name under REPO_DIR
map_repo_dir() {
  case "$1" in
    *baseos*) echo "BaseOS" ;;
    *appstream*) echo "AppStream" ;;
    *codeready-builder*|*crb*) echo "CodeReadyBuilder" ;;
    *) echo "$1" ;;
  esac
}

echo "==> Starting container $CONTAINER_NAME (bind-mount $REPO_DIR -> /repo)"
# Remove stale container if any
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# Interactive register if no password / prefer manual
REGISTER_MODE="env"
if [[ -z "${RH_PASSWORD:-}" && -z "${RH_ACTIVATION_KEY:-}" ]]; then
  REGISTER_MODE="interactive"
fi

# Export so docker exec -e VAR and child processes see them
export RH_USER="${RH_USER:-}"
export RH_PASSWORD="${RH_PASSWORD:-}"
export RH_ORG_ID="${RH_ORG_ID:-}"
export RH_ACTIVATION_KEY="${RH_ACTIVATION_KEY:-}"

docker run -d --name "$CONTAINER_NAME" \
  -v "$REPO_DIR:/repo:Z" \
  -e "RH_USER=${RH_USER}" \
  -e "RH_PASSWORD=${RH_PASSWORD}" \
  -e "RH_ORG_ID=${RH_ORG_ID}" \
  -e "RH_ACTIVATION_KEY=${RH_ACTIVATION_KEY}" \
  "$RUN_IMAGE" sleep infinity

cleanup() {
  echo "==> Leaving container '$CONTAINER_NAME' running for debugging."
  echo "    Stop with: docker rm -f $CONTAINER_NAME"
}
trap cleanup EXIT

echo "==> Registering subscription inside container"
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
  # SCA orgs often need no attach; keep best-effort
  subscription-manager attach --auto 2>/dev/null || true
  subscription-manager refresh || true
  subscription-manager identity
'
reg_rc=$?
set -e

if [[ $reg_rc -eq 42 ]]; then
  echo "Register interactively, then re-run this script:" >&2
  echo "  docker exec -it $CONTAINER_NAME subscription-manager register" >&2
  exit 1
elif [[ $reg_rc -ne 0 ]]; then
  echo "Registration failed (exit $reg_rc)." >&2
  docker logs "$CONTAINER_NAME" 2>&1 | tail -20 || true
  echo "Try: docker exec -it $CONTAINER_NAME subscription-manager register --org=ORG --activationkey=KEY" >&2
  exit 1
fi

echo "==> Enabling repos + installing sync tools: $SYNC_REPOS"
# NOTE: avoid `subscription-manager repos --enable/--disable` on developer accounts —
# it walks thousands of product repos and can take many minutes. Patch redhat.repo
# enabled= flags directly, then use dnf with --repoid= (which implies only that repo).
docker exec -u 0 "$CONTAINER_NAME" bash -lc "
  set -euo pipefail
  /usr/libexec/platform-python - <<'PY'
from pathlib import Path
import os, re
path = Path('/etc/yum.repos.d/redhat.repo')
wanted = set(os.environ.get('SYNC_REPOS', '').split())
if not wanted:
    wanted = {
        'rhel-8-for-x86_64-baseos-rpms',
        'rhel-8-for-x86_64-appstream-rpms',
        'codeready-builder-for-rhel-8-x86_64-rpms',
    }
out=[]; section=None
for line in path.read_text().splitlines(True):
    m=re.match(r'^\[(.+)\]\s*$', line)
    if m:
        section=m.group(1); out.append(line); continue
    if section in wanted and re.match(r'(?i)^\s*enabled\s*=', line):
        out.append('enabled = 1\n'); continue
    out.append(line)
path.write_text(''.join(out))
print('enabled:', ', '.join(sorted(wanted)))
PY
  dnf -y install dnf-plugins-core yum-utils createrepo_c rsync findutils \
    --disablerepo='*' \
    --enablerepo=rhel-8-for-x86_64-baseos-rpms \
    --enablerepo=rhel-8-for-x86_64-appstream-rpms || \
    dnf -y install dnf-plugins-core yum-utils rsync findutils \
      --disablerepo='*' \
      --enablerepo=rhel-8-for-x86_64-baseos-rpms \
      --enablerepo=rhel-8-for-x86_64-appstream-rpms
  dnf clean all || true
" 

echo "==> reposync (this can take a long time and tens of GB)"
for repoid in $SYNC_REPOS; do
  dest="$(map_repo_dir "$repoid")"
  echo "---- sync $repoid -> /repo/$dest ----"
  docker exec -u 0 "$CONTAINER_NAME" bash -lc "
    set -euo pipefail
    mkdir -p /repo/$dest
    # --repoid selects the repo; do NOT also pass --disablerepo (mutually exclusive)
    # --download-metadata is critical for modular AppStream content
    # -n = newest only (still includes current errata packages for each NEVRA stream)
    dnf reposync \
      --repoid=$repoid \
      --download-path=/repo/$dest \
      --downloadcomps \
      --download-metadata \
      --norepopath \
      -n

    if [[ ! -d /repo/$dest/repodata ]]; then
      createrepo_c /repo/$dest
    fi
    echo \"size=\$(du -sh /repo/$dest | cut -f1) rpms=\$(find /repo/$dest -name '*.rpm' | wc -l)\"
  "
done

echo "==> Writing media layout marker"
cat > "$REPO_DIR/README-ON-MEDIA.txt" <<EOF
RHEL 8 offline repository tree
Generated: $(date -Is)
Repos: $SYNC_REPOS

Expected kickstart harddrive dir=/ with children:
  BaseOS/  AppStream/  [CodeReadyBuilder/]

On installed systems:
  sudo enable-offline-repos.sh
  sudo dnf install <package>
EOF

# Optional: flatten if dnf reposync created repoid subdirs despite --norepopath
echo "==> Repo sizes:"
du -sh "$REPO_DIR"/* 2>/dev/null || du -sh "$REPO_DIR"

echo
echo "DONE. Offline repo at: $REPO_DIR"
echo "Next: ./scripts/02-fetch-epel-packages.sh then 03-fetch-python-wheels.sh"
