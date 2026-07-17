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
#
# CRB (CodeReady Builder) must be enabled: many AppStream/EPEL build-time deps and
# optional packages live there. `crb enable` is the supported shortcut when present;
# we also force-enable codeready-builder in redhat.repo so reposync always gets it.
docker exec -u 0 \
  -e "SYNC_REPOS=${SYNC_REPOS}" \
  "$CONTAINER_NAME" bash -lc '
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
# Always include CRB when doing a full offline mirror
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

  # Preferred RHEL helper (same effect as enabling codeready-builder)
  if command -v crb >/dev/null 2>&1; then
    echo "Running: crb enable"
    crb enable || true
  elif command -v dnf >/dev/null 2>&1; then
    dnf config-manager --set-enabled codeready-builder-for-rhel-8-x86_64-rpms 2>/dev/null || true
  fi

  # Confirm CRB is visible to dnf
  dnf repolist --enabled 2>/dev/null | grep -iE "codeready|crb" || \
    echo "WARN: CRB not listed in dnf repolist — check subscription entitlements" >&2

  dnf -y install dnf-plugins-core yum-utils createrepo_c rsync findutils \
    --disablerepo="*" \
    --enablerepo=rhel-8-for-x86_64-baseos-rpms \
    --enablerepo=rhel-8-for-x86_64-appstream-rpms \
    --enablerepo=codeready-builder-for-rhel-8-x86_64-rpms || \
    dnf -y install dnf-plugins-core yum-utils createrepo_c rsync findutils \
      --disablerepo="*" \
      --enablerepo=rhel-8-for-x86_64-baseos-rpms \
      --enablerepo=rhel-8-for-x86_64-appstream-rpms
  dnf clean all || true
'

echo "==> reposync (this can take a long time and tens of GB)"
# IMPORTANT: reposync -n (newest-only) + --download-metadata leaves CDN repodata
# listing packages that were never downloaded → "incorrect checksum" / missing RPM
# on offline dnf. Always rebuild package metadata from *on-disk* RPMs after sync,
# re-injecting modules.yaml (AppStream modular) and comps when present.
for repoid in $SYNC_REPOS; do
  dest="$(map_repo_dir "$repoid")"
  echo "---- sync $repoid -> /repo/$dest ----"
  docker exec -u 0 "$CONTAINER_NAME" bash -lc "
    set -euo pipefail
    mkdir -p /repo/$dest
    # --repoid selects the repo; do NOT also pass --disablerepo (mutually exclusive)
    # --download-metadata pulls modules/updateinfo; we rewrite primary/filelists after
    # -n = newest only
    dnf reposync \
      --repoid=$repoid \
      --download-path=/repo/$dest \
      --downloadcomps \
      --download-metadata \
      --norepopath \
      -n

    # Rebuild package metadata from RPMs on disk only.
    # Do NOT keep CDN primary/filelists (lists undownloaded NEVRAs after -n).
    # Do NOT re-inject modules.yaml (easy to corrupt; offline uses module_hotfixes=1).
    tmp=\$(mktemp -d)
    comps_src=\$(find /repo/$dest/repodata -name '*comps*.xml*' ! -name '*modules*' 2>/dev/null | head -1 || true)
    comps_arg=()
    if [[ -n \"\$comps_src\" && -f \"\$comps_src\" ]]; then
      case \"\$comps_src\" in
        *.gz) gunzip -c \"\$comps_src\" > \"\$tmp/comps.xml\" && comps_arg=(-g \"\$tmp/comps.xml\") ;;
        *.xml) comps_arg=(-g \"\$comps_src\") ;;
      esac
    fi
    echo \"Rebuilding repodata for /repo/$dest from on-disk RPMs...\"
    rm -f /repo/$dest/repodata/*modules* 2>/dev/null || true
    createrepo_c --workers \$(nproc 2>/dev/null || echo 2) \"\${comps_arg[@]}\" /repo/$dest
    rm -rf \"\$tmp\"
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
echo "Next: ./scripts/02-fetch-epel-packages.sh"
echo "      ./scripts/02b-fetch-rpmfusion-packages.sh   # ffmpeg / media from RPM Fusion"
echo "      ./scripts/03-fetch-python-wheels.sh"
