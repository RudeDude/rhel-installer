#!/usr/bin/env bash
# Quick progress snapshot for the offline repo download.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REPO_DIR="${REPO_DIR:-$ROOT/out/offline-repo}"
LATEST="${1:-}"
if [[ -z "$LATEST" && -f out/logs/LATEST_DOWNLOAD ]]; then
  LATEST="$(cat out/logs/LATEST_DOWNLOAD)"
fi
if [[ -z "$LATEST" ]]; then
  LATEST="$(ls -t out/logs/download-*.log 2>/dev/null | head -1 || true)"
fi

echo "=== $(date -Is) ==="
if docker ps --format '{{.Names}}' | grep -qx rhel8-reposync; then
  echo "container: rhel8-reposync UP"
  docker top rhel8-reposync 2>/dev/null | awk 'NR==1 || /dnf|reposync/' | head -8
else
  echo "container: not running"
fi

echo
echo "repo dir: $REPO_DIR"
du -sh "$REPO_DIR" 2>/dev/null || true
for d in BaseOS AppStream CodeReadyBuilder; do
  if [[ -d "$REPO_DIR/$d" ]]; then
    rpms=$(find "$REPO_DIR/$d" -name '*.rpm' 2>/dev/null | wc -l)
    sz=$(du -sh "$REPO_DIR/$d" 2>/dev/null | awk '{print $1}')
    echo "  $d: $sz  rpms=$rpms"
  else
    echo "  $d: (missing)"
  fi
done

if [[ -n "$LATEST" && -f "$LATEST" ]]; then
  echo
  echo "log: $LATEST"
  if grep -q ALL_SYNC_COMPLETE "$LATEST"; then
    echo "status: COMPLETE"
  elif grep -qE 'Command line error|Error:' "$LATEST"; then
    echo "status: error present in log (see tail)"
  else
    echo "status: in progress"
  fi
  echo "--- tail ---"
  tail -15 "$LATEST"
fi

df -h "$ROOT" | tail -1
