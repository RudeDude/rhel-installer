#!/usr/bin/env bash
# Show local offline mirror layout and dnf repo pointers.
#
#   sudo offline-repo-status.sh
set -euo pipefail

LOCAL="${LOCAL_REPO_ROOT:-/var/lib/offline-repos}"
REPO_LOCAL=/etc/yum.repos.d/offline-local.repo
REPO_USB=/etc/yum.repos.d/offline-usb.repo

echo "Local offline mirror: $LOCAL"
if [[ -d "$LOCAL" ]]; then
  du -sh "$LOCAL" 2>/dev/null || true
  for d in BaseOS AppStream CodeReadyBuilder EPEL RPMFusion python-wheels packages docs scripts ks; do
    if [[ -e "$LOCAL/$d" ]]; then
      printf '  %-18s %s\n' "$d" "$(du -sh "$LOCAL/$d" 2>/dev/null | awk '{print $1}')"
    else
      printf '  %-18s MISSING\n' "$d"
    fi
  done
else
  echo "  (directory missing — run copy-offline-mirror-from-usb.sh with USB inserted)"
fi

echo
echo "Repo files:"
for rf in "$REPO_LOCAL" "$REPO_USB"; do
  if [[ -f "$rf" ]]; then
    echo "  $rf"
    grep -E '^\[[^]]+\]|^baseurl=|^enabled=' "$rf" 2>/dev/null | sed 's/^/    /' || true
  else
    echo "  $rf (absent)"
  fi
done

echo
echo "Helpers on PATH (/usr/local/sbin):"
for s in authorize-offline-usb.sh mount-offline-usb.sh enable-offline-repos.sh \
         offline-repo-status.sh configure-grub-timeout.sh update-target-repo-from-usb.sh \
         copy-offline-mirror-from-usb.sh install-from-local-mirror.sh \
         install-airgap-helpers.sh; do
  if [[ -x "/usr/local/sbin/$s" ]]; then
    echo "  OK  $s"
  else
    echo "  --  $s"
  fi
done

echo
echo "Docs:"
for p in /root/README.md /root/airgap-docs /usr/local/share/airgap/docs; do
  if [[ -e "$p" ]]; then
    echo "  OK  $p"
  else
    echo "  --  $p"
  fi
done
