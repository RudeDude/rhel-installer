# RHEL 8.10 Air-Gapped Automated Installer

Build a **customized, offline, kickstart-automated** RHEL 8.10 installer on a ~230 GB USB drive:

- FIPS/STIG Image Builder base (`liveimg`) + interactive disk selection
- Server with GUI and extra packages from offline repos after base install
- Latest security updates on the media via `dnf reposync` (BaseOS + AppStream + CRB)
- No internet required during install or later local package installs

## Architecture

### Your 3.1 GB ISOs are Image Builder installers (not package DVDs)

`rhel-8.10-fips-stig.iso` and `rhel-8-nofips-nostig.iso`:

- Contain `liveimg.tar.gz` + stock `osbuild.ks` (`liveimg --url=...`)
- **No** on-media `BaseOS/` / `AppStream/` package trees
- FIPS ISO already boots with `fips=1` and STIG-related kernel parameters

Workflow:

1. **Boot/install** the prebuilt rootfs from `liveimg.tar.gz` (custom kickstart replaces `osbuild.ks`)
2. **Interactive partitioning** in Anaconda
3. **`%post` + USB offline repos** install GUI, extras, and current errata

Do **not** rebuild one giant multi‑GB package ISO when errata change. Use a **two-region USB**:

| Region | Size | Purpose |
|--------|------|---------|
| Start of disk | ~3–4 GB | Customized FIPS/STIG isohybrid installer (kickstart injected) |
| Rest of disk `LABEL=RHEL8OFFLINE` | remainder | Offline RPM trees + EPEL + Python wheels |

```
USB
├── [isohybrid liveimg installer + /ks/ks.cfg]
└── LABEL=RHEL8OFFLINE
    ├── BaseOS/
    ├── AppStream/
    ├── CodeReadyBuilder/
    ├── EPEL/                   # required RPMs: htop, nload, pv, keepassxc, rdesktop
    ├── python-wheels/          # pre-staged PyPI wheels (pipx + deps)
    ├── ks/ks.cfg
    └── scripts/post-install-extra.sh
```

### Media in this directory

| File | Size | Notes |
|------|------|--------|
| `rhel-8.10-fips-stig.iso` | ~3.1 GB | **Default installer** — liveimg + FIPS/STIG boot args |
| `rhel-8-nofips-nostig.iso` | ~3.1 GB | Same layout, without FIPS/STIG cmdline |
| `rhel-8.10-x86_64-boot.iso` | ~1 GB | Traditional package installer (`KS_INSTALL_MODE=packages`) |

## Prerequisites

- Red Hat Developer (or Customer) subscription — org + **activation key** or username/password
- Docker on the build host (Ubuntu is fine)
- ~40–80 GB free for a full newest-only reposync (measured ~31 GB for BaseOS+AppStream+CRB)
- Tools: `xorriso`, `sgdisk`/`parted`, `mkfs.ext4`, `rsync`, `dd`

### Container image / registry

Prefer the **public** UBI image (no `registry.redhat.io` login required for the base image):

```bash
REPOSYNC_IMAGE="registry.access.redhat.com/ubi8/ubi:8.10"
```

That is what `config.env` / the Dockerfile use after the last fixes. Full RHEL package CDN access still requires registering the container with `subscription-manager` (activation key works with SCA orgs).

### Offline content sources (RHEL **and** EPEL)

**RHEL 8 CDN** (full newest-only mirror via `./scripts/01-reposync.sh`):

- `rhel-8-for-x86_64-baseos-rpms`
- `rhel-8-for-x86_64-appstream-rpms`
- `codeready-builder-for-rhel-8-x86_64-rpms`

**EPEL 8** is **required** for this project’s baseline tools that Red Hat does not ship in those repos, including at least:

- `htop`, `nload`, `pv`
- `keepassxc` (KeepassX successor), `rdesktop`

Those are listed in `packages/epel-extra.txt` and pulled with a **targeted** download (not a full EPEL Everything mirror):

```bash
./scripts/02-fetch-epel-packages.sh   # -> out/offline-repo/EPEL/ (~150 MB with deps for current list)
```

Treat `out/offline-repo/EPEL/` as part of the USB offline tree (`LABEL=RHEL8OFFLINE`), same as BaseOS/AppStream/CRB.

## Quick workflow

```bash
cd /path/to/rhel-installer

# 1. Configure (do not commit secrets)
cp config.env.example config.env
chmod 600 config.env
# Edit at least:
#   RH_ORG_ID + RH_ACTIVATION_KEY   (or RH_USER + RH_PASSWORD)
#   KS_ROOT_PASSWORD_HASH / KS_USER_PASSWORD_HASH  (single-quoted!)
#   USB_DEVICE="/dev/sdb"   # your stick
#   KS_TIMEZONE, hostname, etc.

# Password hashes (use single quotes in config.env so bash does not expand $6$...):
#   openssl passwd -6 'YourPassword'
#   KS_ROOT_PASSWORD_HASH='$6$rounds=...'

# --- All fetch steps before USB prepare ---
# 01 RHEL repos (tens of GB)
./scripts/01-reposync.sh
./scripts/status-reposync.sh

# 02 EPEL RPMs (htop, nload, pv, keepassxc, rdesktop, …)
./scripts/02-fetch-epel-packages.sh

# 03 Python wheels (pipx + deps, …)
./scripts/03-fetch-python-wheels.sh

# 04 Optional offline dep check
# ./scripts/04-check-offline-deps.sh

# 05–06 Kickstart + custom ISO
./scripts/05-generate-kickstart.sh
./scripts/06-inject-kickstart.sh      # -> out/rhel-8.10-airgap-ks.iso

# 07 Write USB (DESTRUCTIVE) — copies RPMs, EPEL, wheels, and offline docs
./scripts/07-prepare-usb.sh --dry-run /dev/sdb
sudo ./scripts/07-prepare-usb.sh /dev/sdb
# type YES when prompted
```

### Useful prepare-usb flags

| Flag | Meaning |
|------|---------|
| `--dry-run` | Preflight + plan only (no root, no writes) |
| `--yes` | Skip interactive `YES` prompt |
| `--allow-incomplete-repo` | Write even if reposync still running / partial |
| `--allow-stock-iso` | Use stock FIPS ISO if custom kickstart ISO is missing |

See also `docs/USB-PREPARE-REVIEW.md`.

## Package strategy (liveimg mode)

1. **Installer** delivers the Image Builder rootfs (`liveimg`), not a classic `%packages` DVD install.
2. **Kickstart `%post`** mounts `LABEL=RHEL8OFFLINE`, enables file:// repos (RHEL + required EPEL tree), runs `dnf upgrade` / installs your lists, and can `groupinstall "Server with GUI"`.
3. **Offline RHEL tree** is a full newest-only (`dnf reposync -n`) mirror of BaseOS + AppStream + CRB — primary security-update channel on the stick.
4. **Offline EPEL tree** is a **required** targeted RPM set (`htop`, `nload`, `pv`, `keepassxc`, `rdesktop`, …) via `packages/epel-extra.txt`.
5. **Offline Python wheels** are a **required** path for PyPI-only tools (**pipx** has no RHEL/EPEL 8 RPM). List them in `packages/python-extra.txt`, fetch with `./scripts/03-fetch-python-wheels.sh`.
6. **`scripts/post-install-extra.sh`** installs RPMs from offline dnf repos, then installs wheels with `python3.11 -m pip --no-index --find-links=…`.

Package name notes: `docs/PACKAGE-NOTES.md`.

Lists / config:

| What | File / script |
|------|----------------|
| RHEL RPMs | `packages/required.txt`, `recommended.txt` |
| EPEL RPMs | `packages/epel-extra.txt` → `./scripts/02-fetch-epel-packages.sh` |
| PyPI / wheels | `packages/python-extra.txt` → `./scripts/03-fetch-python-wheels.sh` |
| Config | `PYTHON_EXTRA_FILE`, `PYTHON_WHEEL_DIR`, `PYTHON_PIP` in `config.env` |

**Adding more packages later:** see **`docs/ADDING-PACKAGES.md`** (RPM vs EPEL vs wheel paths).

## Measured space (x86_64, newest-only reposync)

| Content | Measured / typical |
|---------|---------------------|
| FIPS installer ISO | ~3.1 GB |
| BaseOS | ~2.2 GB |
| AppStream | ~17 GB |
| CodeReady Builder | ~13 GB |
| EPEL (targeted required set) | ~0.15 GB |
| Python wheels (pipx + deps) | ~0.001 GB |
| **Offline tree total** | **~31 GB** (+ EPEL + wheels) |
| USB capacity | ~230 GB usable |

Earlier “AppStream 35–55 GB” estimates assumed older/fuller mirrors; with `-n` (newest NEVRA only) ~31 GB total is realistic.

## Operational notes from the last bugfix round

These are baked into the scripts; documented so future-you does not re-hit them:

| Issue | Fix |
|-------|-----|
| `config.env` password hashes with `"$6$..."` break under `set -u` | Use **single quotes**: `KS_*_PASSWORD_HASH='$6$...'`; scripts also `set +u` while sourcing |
| `docker exec -e VAR` without export cleared credentials | Scripts export and pass `-e "VAR=${VAR}"` explicitly |
| `subscription-manager repos --disable='*'` / `--enable` on developer catalogs is extremely slow | Patch `redhat.repo` `enabled=` flags with `platform-python`; do not walk the full product catalog |
| `dnf reposync --repoid` **cannot** combine with `--disablerepo` | Use `--repoid=` only |
| `createrepo_c` not on unregistered UBI | Install tools **after** subscription; Dockerfile only installs UBI-available packages |
| Public UBI pull | Prefer `registry.access.redhat.com/ubi8/ubi:8.10` over `registry.redhat.io` when you lack registry login |
| SCA orgs | `attach --auto` may be ignored; content still works after register + enable |
| Custom ISO volume label | Rebuild keeps stock volume id so `inst.stage2=hd:LABEL=RHEL-8-10-0-BaseOS-x86_64` still works |
| USB script | Preflight, USB transport check, refuse root disk, refuse tiny partitions, dry-run mode |

## FIPS / STIG

- Default installer source: `rhel-8.10-fips-stig.iso` (`SOURCE_ISO` in `config.env`)
- Kickstart can set `KS_ENABLE_FIPS=yes` (crypto policy / `fips-mode-setup` in `%post`)
- Boot args `fips=1` (and STIG-related args) are preserved when injecting kickstart (`PRESERVE_STIG_BOOT_ARGS=yes`)
- Offline **packages** still come from normal RHEL 8 CDN channels via reposync — not from the liveimg tarball alone

## Directory layout

```
rhel-installer/
├── README.md
├── config.env.example          # copy to config.env (gitignored)
├── docs/
│   ├── OFFLINE-INSTALL.md      # primary air-gap operator guide (copied to USB)
│   ├── ADDING-PACKAGES.md
│   ├── PACKAGE-NOTES.md
│   └── USB-PREPARE-REVIEW.md
├── packages/
│   ├── required.txt
│   ├── recommended.txt
│   ├── epel-extra.txt
│   ├── python-extra.txt
│   └── groups.txt
├── kickstart/
│   └── ks.cfg.template
├── docker/
│   └── Dockerfile.reposync
├── scripts/                    # numbered so all fetch precedes prepare-usb
│   ├── 01-reposync.sh
│   ├── 02-fetch-epel-packages.sh
│   ├── 03-fetch-python-wheels.sh
│   ├── 04-check-offline-deps.sh
│   ├── 05-generate-kickstart.sh
│   ├── 06-inject-kickstart.sh
│   ├── 07-prepare-usb.sh
│   ├── status-reposync.sh
│   └── post-install-extra.sh   # runs on the air-gapped host
└── out/                        # offline-repo (BaseOS/AppStream/CRB/EPEL/python-wheels), ISO, logs
```

## Security

- Never commit `config.env` (activation keys, password hashes).
- `chmod 600 config.env`
- Treat the finished USB as sensitive (full OS content + errata + kickstart credentials).
- Unregister/remove the reposync container when finished if you do not need re-syncs:  
  `docker rm -f rhel8-reposync`
