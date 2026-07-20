#!/usr/bin/env bash
# Step 01: Fetch all offline content for the air-gap USB (connected build host).
#
# Refactored to minimize dnf install calls and consolidate repo setup.
#
# Flow:
#   a) Ensure container exists and is running
#   b) Register with RHSM + enable all needed repos (RHEL, EPEL, RPM Fusion) in one pass
#   c) Check if metadata needs refresh (based on age threshold)
#   d) Install all needed tools + release packages in ONE dnf install call
#   e) Execute actual content fetches (reposync, dnf download, pip download)
#   f) Verify offline dependency closure
#   g) Stop container (unless --keep-running)
#
# Usage:
#   ./scripts/01-fetch-offline-content.sh
#   ./scripts/01-fetch-offline-content.sh --skip-wheels
#   ./scripts/01-fetch-offline-content.sh --skip-check
#   ./scripts/01-fetch-offline-content.sh --keep-running   # leave container up
#   ./scripts/01-fetch-offline-content.sh --remove-container  # stop+rm (full reset)
#   ./scripts/01-fetch-offline-content.sh --only-check
#   FORCE_CONTAINER_SETUP=1 ./scripts/01-fetch-offline-content.sh  # re-register/tools
#   RECREATE_CONTAINER=1 ./scripts/01-fetch-offline-content.sh     # docker rm + new
#   METADATA_REFRESH_HOURS=12 ./scripts/01-fetch-offline-content.sh  # custom staleness
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -f "$ROOT/config.env" ]]; then
  set +u
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  set -u
fi

# Config
REPO_DIR="${REPO_DIR:-$ROOT/out/offline-repo}"
[[ "$REPO_DIR" != /* ]] && REPO_DIR="$ROOT/${REPO_DIR#./}"
REPOSYNC_IMAGE="${REPOSYNC_IMAGE:-registry.access.redhat.com/ubi8/ubi:8.10}"
SYNC_REPOS="${SYNC_REPOS:-rhel-8-for-x86_64-baseos-rpms rhel-8-for-x86_64-appstream-rpms codeready-builder-for-rhel-8-x86_64-rpms}"
CONTAINER_NAME="${CONTAINER_NAME:-rhel8-reposync}"
FORCE_CONTAINER_SETUP="${FORCE_CONTAINER_SETUP:-0}"
RECREATE_CONTAINER="${RECREATE_CONTAINER:-0}"
HELPER_TAG="rhel8-reposync-helper:local"
MARKER=/var/lib/airgap-container-ready
METADATA_MARKER=/var/lib/airgap-metadata-refreshed
METADATA_REFRESH_HOURS="${METADATA_REFRESH_HOURS:-6}"
RPMFUSION_SKIP_NONFREE="${RPMFUSION_SKIP_NONFREE:-0}"
RPMFUSION_FREE_URL="${RPMFUSION_FREE_URL:-https://mirrors.rpmfusion.org/free/el/rpmfusion-free-release-8.noarch.rpm}"
RPMFUSION_NONFREE_URL="${RPMFUSION_NONFREE_URL:-https://mirrors.rpmfusion.org/nonfree/el/rpmfusion-nonfree-release-8.noarch.rpm}"

export RH_USER="${RH_USER:-}"
export RH_PASSWORD="${RH_PASSWORD:-}"
export RH_ORG_ID="${RH_ORG_ID:-}"
export RH_ACTIVATION_KEY="${RH_ACTIVATION_KEY:-}"

# Python wheel config
PYTHON_EXTRA_FILE="${PYTHON_EXTRA_FILE:-$ROOT/packages/python-extra.txt}"
PYTHON_WHEEL_DIR="${PYTHON_WHEEL_DIR:-$REPO_DIR/python-wheels}"
PYTHON_PIP="${PYTHON_PIP:-python3 -m pip}"
PYTHON_TARGET_VERSION="${PYTHON_TARGET_VERSION:-311}"
PYTHON_INCLUDE_PIP_BOOTSTRAP="${PYTHON_INCLUDE_PIP_BOOTSTRAP:-yes}"
PYTHON_VERIFY_OFFLINE="${PYTHON_VERIFY_OFFLINE:-yes}"

# CLI flags
SKIP_REPOSYNC=0
SKIP_EPEL=0
SKIP_RPMFUSION=0
SKIP_WHEELS=0
SKIP_CHECK=0
KEEP_RUNNING=0
REMOVE_CONTAINER=0
ONLY_CHECK=0

usage() {
  cat <<EOF
Usage: $0 [options]

  --skip-reposync     Skip RHEL reposync (use existing BaseOS/AppStream/CRB trees)
  --skip-epel         Skip EPEL package fetch
  --skip-rpmfusion    Skip RPM Fusion package fetch
  --skip-wheels       Skip Python wheel fetch
  --skip-check        Skip offline dependency check
  --keep-running      Leave container running after finish (default: stop, keep image+state)
  --remove-container  docker rm the container after stop (loses registration; rare)
  --only-check        Only run offline dep check (starts container if needed, then stops)
  -h, --help

Environment:
  METADATA_REFRESH_HOURS  (default 6) — refresh dnf metadata if older than this
  FORCE_CONTAINER_SETUP   (default 0) — force re-registration/repo setup even if ready marker exists
  RECREATE_CONTAINER      (default 0) — docker rm and create fresh container

Default: stop the container when done, but do not remove it (next run is faster).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-reposync) SKIP_REPOSYNC=1; shift ;;
    --skip-epel) SKIP_EPEL=1; shift ;;
    --skip-rpmfusion) SKIP_RPMFUSION=1; shift ;;
    --skip-wheels) SKIP_WHEELS=1; shift ;;
    --skip-check) SKIP_CHECK=1; shift ;;
    --keep-running|--keep-container) KEEP_RUNNING=1; shift ;;
    --remove-container) REMOVE_CONTAINER=1; shift ;;
    --only-check) ONLY_CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

stop_container() {
  if [[ "$KEEP_RUNNING" -eq 1 ]]; then
    echo "==> Leaving container $CONTAINER_NAME running (--keep-running)"
    return 0
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "==> Stopping container $CONTAINER_NAME (preserved for next run)"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    echo "    stopped (registration/repos retained). Start again via next 01 run."
  elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    echo "==> Container $CONTAINER_NAME already stopped"
  else
    echo "==> No container $CONTAINER_NAME present"
  fi
  if [[ "$REMOVE_CONTAINER" -eq 1 ]]; then
    echo "==> Removing container $CONTAINER_NAME (--remove-container)"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}

cleanup_on_exit() {
  local ec=$?
  stop_container
  exit "$ec"
}
trap cleanup_on_exit EXIT

echo "############################################################"
echo "# 01-fetch-offline-content — refactored single-pass setup #"
echo "############################################################"
echo "Project: $ROOT"
echo

# ============================================================================
# a) ENSURE CONTAINER EXISTS AND IS RUNNING
# ============================================================================
mkdir -p "$REPO_DIR"

if [[ -f "$ROOT/docker/Dockerfile.reposync" ]]; then
  if ! docker image inspect "$HELPER_TAG" >/dev/null 2>&1; then
    echo "==> Building helper image $HELPER_TAG (first time)"
    docker build -t "$HELPER_TAG" -f "$ROOT/docker/Dockerfile.reposync" "$ROOT/docker"
  fi
  RUN_IMAGE="$HELPER_TAG"
else
  if ! docker image inspect "$REPOSYNC_IMAGE" >/dev/null 2>&1; then
    echo "==> Pulling $REPOSYNC_IMAGE"
    docker pull "$REPOSYNC_IMAGE"
  fi
  RUN_IMAGE="$REPOSYNC_IMAGE"
fi

if [[ "$RECREATE_CONTAINER" == "1" ]]; then
  echo "==> RECREATE_CONTAINER=1 — removing $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "==> Reusing running container: $CONTAINER_NAME"
elif docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "==> Starting existing container: $CONTAINER_NAME (keeps registration/repos)"
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

# ============================================================================
# b) REGISTER + ENABLE ALL REPOS + INSTALL ALL TOOLS/RELEASE PACKAGES (ONCE)
# ============================================================================
need_setup=1
if [[ "$FORCE_CONTAINER_SETUP" != "1" ]]; then
  if docker exec -u 0 "$CONTAINER_NAME" test -f "$MARKER" 2>/dev/null; then
    if docker exec -u 0 "$CONTAINER_NAME" subscription-manager identity >/dev/null 2>&1; then
      echo "==> Container already set up (marker $MARKER + subscription present)"
      # Still ensure repos are enabled (light touch)
      docker exec -u 0 "$CONTAINER_NAME" bash -lc '
        if command -v crb >/dev/null 2>&1; then
          crb enable >/dev/null 2>&1 || true
        fi
      ' 2>/dev/null || true
      need_setup=0
    else
      echo "==> Marker present but not registered — re-running setup"
    fi
  fi
fi

if [[ "$need_setup" -eq 1 ]]; then
  echo "==> Full container setup: register + enable repos + install all tools/releases in ONE pass"

  # Step 1: Register with RHSM
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

  # Step 2: Enable BaseOS/AppStream/CRB repos via Python patch (fast)
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
  '

  # Step 3: Build list of ALL packages to install (tools + EPEL + RPM Fusion releases)
  # This consolidates what was previously 4 separate dnf install calls into ONE
  docker exec -u 0 \
    -e "SKIP_EPEL=${SKIP_EPEL}" \
    -e "SKIP_RPMFUSION=${SKIP_RPMFUSION}" \
    -e "RPMFUSION_SKIP_NONFREE=${RPMFUSION_SKIP_NONFREE}" \
    -e "RPMFUSION_FREE_URL=${RPMFUSION_FREE_URL}" \
    -e "RPMFUSION_NONFREE_URL=${RPMFUSION_NONFREE_URL}" \
    "$CONTAINER_NAME" bash -lc '
    set -euo pipefail

    # Determine what tools are missing
    need_tools=()
    for p in dnf-plugins-core yum-utils createrepo_c rsync findutils; do
      rpm -q "$p" >/dev/null 2>&1 || need_tools+=("$p")
    done

    # Determine what release packages are missing
    need_releases=()

    if [[ "${SKIP_EPEL}" != "1" ]]; then
      if ! rpm -q epel-release >/dev/null 2>&1; then
        need_releases+=("https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm")
      fi
    fi

    if [[ "${SKIP_RPMFUSION}" != "1" ]]; then
      # RPM Fusion requires EPEL, so ensure epel-release is in the list
      if ! rpm -q epel-release >/dev/null 2>&1; then
        if [[ ! " ${need_releases[*]} " =~ " https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm " ]]; then
          need_releases+=("https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm")
        fi
      fi

      if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
        need_releases+=("${RPMFUSION_FREE_URL}")
      fi

      if [[ "${RPMFUSION_SKIP_NONFREE}" != "1" ]]; then
        if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then
          need_releases+=("${RPMFUSION_NONFREE_URL}")
        fi
      fi
    fi

    # SINGLE dnf install with all tools + release packages
    to_install=("${need_tools[@]}" "${need_releases[@]}")

    if [[ ${#to_install[@]} -gt 0 ]]; then
      echo "==> Installing ALL tools + release packages in ONE dnf call:"
      echo "    Tools: ${need_tools[*]:-none}"
      echo "    Releases: ${need_releases[*]:-none}"

      # Install everything together
      dnf -y install "${to_install[@]}" \
        --disablerepo="*" \
        --enablerepo=rhel-8-for-x86_64-baseos-rpms \
        --enablerepo=rhel-8-for-x86_64-appstream-rpms \
        --enablerepo=codeready-builder-for-rhel-8-x86_64-rpms \
        --nogpgcheck || \
      dnf -y install "${to_install[@]}" \
        --disablerepo="*" \
        --enablerepo=rhel-8-for-x86_64-baseos-rpms \
        --enablerepo=rhel-8-for-x86_64-appstream-rpms \
        --nogpgcheck
    else
      echo "==> All tools and release packages already installed — skip"
    fi

    # Mark container as ready
    mkdir -p /var/lib
    date -Is > '"$MARKER"'
    echo "Wrote '"$MARKER"'"
  '
fi

# ============================================================================
# c) CHECK METADATA FRESHNESS + REFRESH IF STALE
# ============================================================================
echo
echo "==> Checking dnf metadata age (refresh if older than ${METADATA_REFRESH_HOURS}h)"
docker exec -u 0 \
  -e "METADATA_MARKER=${METADATA_MARKER}" \
  -e "METADATA_REFRESH_HOURS=${METADATA_REFRESH_HOURS}" \
  "$CONTAINER_NAME" bash -lc '
  set -euo pipefail
  need_refresh=1
  if [[ -f "'"$METADATA_MARKER"'" ]]; then
    age_sec=$(( $(date +%s) - $(stat -c %Y "'"$METADATA_MARKER"'" 2>/dev/null || echo 0) ))
    age_hours=$(( age_sec / 3600 ))
    if [[ $age_hours -lt ${METADATA_REFRESH_HOURS} ]]; then
      echo "Metadata age: ${age_hours}h (< ${METADATA_REFRESH_HOURS}h threshold) — skip refresh"
      need_refresh=0
    else
      echo "Metadata age: ${age_hours}h (>= ${METADATA_REFRESH_HOURS}h threshold) — refreshing"
    fi
  else
    echo "No metadata timestamp — refreshing"
  fi

  if [[ $need_refresh -eq 1 ]]; then
    dnf clean expire-cache
    dnf makecache --refresh
    date -Is > "'"$METADATA_MARKER"'"
    echo "Metadata refreshed; timestamp: '"$METADATA_MARKER"'"
  fi
'

# If --only-check, run the check and exit
if [[ "$ONLY_CHECK" -eq 1 ]]; then
  echo
  echo "==> Running offline dependency check only (--only-check)"
  # Inline the check logic here
  source "$ROOT/scripts/lib/check-offline-deps.sh"
  exit 0
fi

# ============================================================================
# d) EXECUTE CONTENT FETCHES
# ============================================================================

if [[ "$SKIP_REPOSYNC" -eq 0 ]]; then
  echo
  echo "==== RHEL reposync (BaseOS / AppStream / CRB) ===="
  # Inline reposync logic (no separate dnf install calls needed)
  map_repo_dir() {
    case "$1" in
      *baseos*) echo "BaseOS" ;;
      *appstream*) echo "AppStream" ;;
      *codeready-builder*|*crb*) echo "CodeReadyBuilder" ;;
      *) echo "$1" ;;
    esac
  }

  echo "==> reposync (incremental newest-only; can take a while)"
  for repoid in $SYNC_REPOS; do
    dest="$(map_repo_dir "$repoid")"
    echo "---- sync $repoid -> /repo/$dest ----"
    docker exec -u 0 "$CONTAINER_NAME" bash -lc "
      set -euo pipefail
      mkdir -p /repo/$dest
      dnf reposync \
        --repoid=$repoid \
        --download-path=/repo/$dest \
        --downloadcomps \
        --download-metadata \
        --norepopath \
        -n

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

  cat > "$REPO_DIR/README-ON-MEDIA.txt" <<EOF
RHEL 8 offline repository tree
Generated: $(date -Is)
Repos: $SYNC_REPOS

Expected layout: BaseOS/ AppStream/ CodeReadyBuilder/ [EPEL/] [RPMFusion/] [python-wheels/]
EOF

  echo "==> Repo sizes:"
  du -sh "$REPO_DIR"/* 2>/dev/null || du -sh "$REPO_DIR"
else
  echo
  echo "==== RHEL reposync — SKIPPED ===="
fi

if [[ "$SKIP_EPEL" -eq 0 ]]; then
  echo
  echo "==== EPEL packages (packages/epel-extra.txt) ===="
  PKG_FILE="$ROOT/packages/epel-extra.txt"
  EPEL_DIR="$REPO_DIR/EPEL"

  if [[ ! -f "$PKG_FILE" ]]; then
    echo "Package list not found: $PKG_FILE" >&2
    exit 1
  fi

  mapfile -t PKGS < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PKG_FILE")
  if [[ ${#PKGS[@]} -gt 0 ]]; then
    echo "Packages to fetch from EPEL: ${PKGS[*]}"
    mkdir -p "$EPEL_DIR/Packages"

    pkg_args="${PKGS[*]}"
    echo "==> dnf download --resolve --alldeps -> /repo/EPEL/Packages"
    docker exec -u 0 "$CONTAINER_NAME" bash -lc "
      set -euo pipefail
      mkdir -p /repo/EPEL/Packages
      cd /repo/EPEL/Packages
      dnf -y download --resolve --alldeps \
        --setopt=reposdir=/etc/yum.repos.d \
        $pkg_args
      find /repo/EPEL -name '*.rpm' -type f ! -path '/repo/EPEL/Packages/*' \
        -exec mv -n {} /repo/EPEL/Packages/ \\; 2>/dev/null || true
      pruned=0
      for rpm in /repo/EPEL/Packages/*.rpm; do
        [[ -f \"\$rpm\" ]] || continue
        base=\$(basename \"\$rpm\")
        if find /repo/BaseOS /repo/AppStream /repo/CodeReadyBuilder -name \"\$base\" 2>/dev/null | grep -q .; then
          rm -f \"\$rpm\"
          pruned=\$((pruned+1))
        fi
      done
      echo \"  pruned \$pruned RHEL-duplicate RPMs from EPEL tree\"
      createrepo_c /repo/EPEL
      echo \"EPEL: \$(du -sh /repo/EPEL | cut -f1)  rpms=\$(find /repo/EPEL/Packages -name '*.rpm' | wc -l)\"
    "
    echo "Done. Offline EPEL content: $EPEL_DIR"
  fi
else
  echo
  echo "==== EPEL packages — SKIPPED ===="
fi

if [[ "$SKIP_RPMFUSION" -eq 0 ]]; then
  echo
  echo "==== RPM Fusion packages (packages/rpmfusion-extra.txt) ===="
  PKG_FILE="$ROOT/packages/rpmfusion-extra.txt"
  FUSION_DIR="$REPO_DIR/RPMFusion"

  if [[ ! -f "$PKG_FILE" ]]; then
    echo "Package list not found: $PKG_FILE" >&2
    exit 1
  fi

  mapfile -t PKGS < <(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$PKG_FILE")
  if [[ ${#PKGS[@]} -gt 0 ]]; then
    echo "Packages to fetch from RPM Fusion: ${PKGS[*]}"
    mkdir -p "$FUSION_DIR/Packages"

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
  fi
else
  echo
  echo "==== RPM Fusion packages — SKIPPED ===="
fi

if [[ "$SKIP_WHEELS" -eq 0 ]]; then
  echo
  echo "==== Python wheels (packages/python-extra.txt) ===="
  # Python wheels run on the BUILD HOST, not in container
  # So we source the existing script (it's already optimal - no container dnf calls)
  bash "$ROOT/scripts/lib/fetch-python-wheels.sh"
else
  echo
  echo "==== Python wheels — SKIPPED ===="
fi

# ============================================================================
# e) VERIFY OFFLINE DEPENDENCY CLOSURE
# ============================================================================
if [[ "$SKIP_CHECK" -eq 0 ]]; then
  echo
  echo "==== Offline dependency check ===="
  bash "$ROOT/scripts/lib/check-offline-deps.sh"
else
  echo
  echo "==== Offline dependency check — SKIPPED ===="
fi

echo
echo "############################################################"
echo "# Offline content fetch complete                           #"
echo "############################################################"
echo "Tree: $REPO_DIR"
du -sh "$REPO_DIR" 2>/dev/null || true
echo
echo "Next:"
echo "  ./scripts/02-build-kickstart-iso.sh"
echo "  sudo ./scripts/03-prepare-usb.sh /dev/sdX"
# trap stops container (unless --keep-running)
