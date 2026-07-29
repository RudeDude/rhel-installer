#!/usr/bin/env bash
# Generate docs/INSTALLED-SOFTWARE-MANIFEST.md from packages/*.txt lists.
# Documents only what is installed *by default* by this repo's process —
# not the full offline RPM mirror, and not manual-only lists.
#
#   ./scripts/lib/generate-installed-manifest.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OUT="${1:-$ROOT/docs/INSTALLED-SOFTWARE-MANIFEST.md}"
if [[ -f "$ROOT/config.env" ]]; then
  set +u
  # shellcheck disable=SC1091
  source "$ROOT/config.env"
  set -u
fi
INCLUDE_RECOMMENDED="${INCLUDE_RECOMMENDED:-yes}"

list_sorted() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  read_pkg_list "$f" | sed '/^$/d' | sort -u
}

count_lines() {
  local f="$1"
  [[ -f "$f" ]] || { echo 0; return; }
  list_sorted "$f" | wc -l
}

emit_section() {
  local title="$1" file="$2" note="$3"
  local n
  n="$(count_lines "$file")"
  printf '\n## %s\n\n' "$title"
  if [[ -n "$note" ]]; then
    printf '%s\n\n' "$note"
  fi
  printf '```\n'
  if [[ -f "$file" ]]; then
    list_sorted "$file"
  else
    printf '(missing: %s)\n' "$file"
  fi
  printf '```\n\n_Count: %s_\n' "$n"
}

GEN_TS="$(date -u +%Y-%m-%dT%H:%MZ)"
GROUPS_BODY="$(list_sorted "$ROOT/packages/groups.txt" || true)"

{
  cat <<EOF
# Default installed software manifest

This document is the **default software set** installed on the target by this
repository's process. It is **not** an inventory of every RPM on the offline
mirror (BaseOS/AppStream/CRB trees are much larger).

**Source of truth:** package list files under \`packages/\` (regenerate after changes):

\`\`\`bash
./scripts/lib/generate-installed-manifest.sh
\`\`\`

Generated: ${GEN_TS}

---

## How default install works

| Phase | What runs | What gets installed from this manifest |
|-------|-----------|----------------------------------------|
| Kickstart (\`liveimg\` default) | Anaconda + \`%post\` (if USB mounted) | Best-effort: required (+ recommended) RPM names, GUI group |
| **STEP 1** | \`airgap-setup-1-copy-mirror.sh\` | *None* (copies mirror + helpers only) |
| **STEP 2** | \`airgap-setup-2-install.sh\` | **Full default set:** required, recommended, EPEL extra, RPM Fusion extra, Python wheels, Server with GUI |

Defaults assume:

- \`INCLUDE_RECOMMENDED=yes\` (config.env)
- Offline trees for EPEL and RPM Fusion are present on the media
- Python wheels were staged by \`01-fetch-offline-content.sh\`

---

## Intentionally **not** in this default set

| List / content | Why excluded |
|----------------|--------------|
| \`packages/available-manual.txt\` | Operator installs when needed (\`dnf install …\`) |
| \`packages/rke2-extra.txt\` | RKE2 mirror only; \`dnf install rke2-server\` / \`rke2-agent\` when needed |
| Full BaseOS / AppStream / CRB package sets | Provide deps and updates; not all installed |
| Third-party binaries (kubectl, helm, …) | Outside RPM lists — see \`docs/STIG-THIRD-PARTY-TOOLS.md\` |

---

## Environment / comps groups

Installed by kickstart (non-liveimg) and/or STEP 2:

\`\`\`
dnf groupinstall "Server with GUI"
# fallback: dnf install @graphical-server-environment
\`\`\`

Also listed in \`packages/groups.txt\` for reference:

\`\`\`
${GROUPS_BODY}
\`\`\`
EOF

  emit_section \
    "RHEL RPMs — required (packages/required.txt)" \
    "$ROOT/packages/required.txt" \
    "Always installed by STEP 2. Also used for kickstart %post package install when media is available."

  if [[ "${INCLUDE_RECOMMENDED,,}" == "yes" || "$INCLUDE_RECOMMENDED" == "1" ]]; then
    emit_section \
      "RHEL RPMs — recommended (packages/recommended.txt)" \
      "$ROOT/packages/recommended.txt" \
      "Included because INCLUDE_RECOMMENDED=yes (default). Set to no in config.env to omit from generated kickstart intent."
  else
    printf '\n## RHEL RPMs — recommended (packages/recommended.txt)\n\n'
    printf '_Skipped: INCLUDE_RECOMMENDED=%s._\n' "$INCLUDE_RECOMMENDED"
  fi

  emit_section \
    "EPEL RPMs (packages/epel-extra.txt)" \
    "$ROOT/packages/epel-extra.txt" \
    "Installed by STEP 2 when EPEL/ is on the local mirror."

  emit_section \
    "RPM Fusion RPMs (packages/rpmfusion-extra.txt)" \
    "$ROOT/packages/rpmfusion-extra.txt" \
    "Installed by STEP 2 when RPMFusion/ is on the local mirror."

  emit_section \
    "Python packages — wheels (packages/python-extra.txt)" \
    "$ROOT/packages/python-extra.txt" \
    "Installed by STEP 2 with:

\`\`\`bash
python3.11 -m pip install --no-index --find-links=/var/lib/offline-repos/python-wheels -r requirements.txt
\`\`\`

Fetch also stages pip bootstrap wheels (pip, setuptools, wheel) when PYTHON_INCLUDE_PIP_BOOTSTRAP=yes (default); those are install tools, not extra apps."

  printf '\n## Flat list — all default RPM names (unique, sorted)\n\n'
  printf 'Union of required + recommended + epel-extra + rpmfusion-extra (no groups, no Python).\n\n'
  printf '```\n'
  {
    list_sorted "$ROOT/packages/required.txt"
    if [[ "${INCLUDE_RECOMMENDED,,}" == "yes" || "$INCLUDE_RECOMMENDED" == "1" ]]; then
      list_sorted "$ROOT/packages/recommended.txt"
    fi
    list_sorted "$ROOT/packages/epel-extra.txt"
    list_sorted "$ROOT/packages/rpmfusion-extra.txt"
  } | sort -u
  printf '```\n'

  rpm_n="$(
    {
      list_sorted "$ROOT/packages/required.txt"
      if [[ "${INCLUDE_RECOMMENDED,,}" == "yes" || "$INCLUDE_RECOMMENDED" == "1" ]]; then
        list_sorted "$ROOT/packages/recommended.txt"
      fi
      list_sorted "$ROOT/packages/epel-extra.txt"
      list_sorted "$ROOT/packages/rpmfusion-extra.txt"
    } | sort -u | wc -l
  )"
  py_n="$(count_lines "$ROOT/packages/python-extra.txt")"

  printf '\n_Default RPM names: %s · Default Python requirements: %s_\n\n' "$rpm_n" "$py_n"
  printf '%s\n\n' '---'
  printf '%s\n' '*Regenerate after editing packages/*.txt: `./scripts/lib/generate-installed-manifest.sh`*'
} > "$OUT"

echo "Wrote $OUT"
echo "  Default RPM names: $rpm_n"
echo "  Default Python requirements: $py_n"
