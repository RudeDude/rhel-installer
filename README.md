# RHEL 8.10 Air-Gapped Automated Installer

Build a **customized, offline, kickstart-automated** RHEL 8.10 installer on a ~230 GB USB drive:

- Server with GUI (GNOME desktop)
- Extra packages + full dependency trees
- Latest security updates baked into offline repos (via `dnf reposync`)
- No internet required during install or later local package installs

## Recommended architecture (fits your 230 GB USB)

### Critical discovery about your 3.1 GB ISOs

`rhel-8.10-fips-stig.iso` and `rhel-8-nofips-nostig.iso` are **Image Builder / osbuild installer ISOs**, not full package DVDs:

- They contain `liveimg.tar.gz` + a one-line `osbuild.ks` (`liveimg --url=...`)
- **No** `BaseOS/` or `AppStream/` package trees on those ISOs
- The FIPS ISO already boots with `fips=1` and STIG-related kernel parameters and points at `osbuild.ks`

So the workflow is:

1. **Boot/install** the prebuilt hardened rootfs from `liveimg.tar.gz` (your FIPS/STIG image)
2. **Interactive disk** selection in Anaconda (no autopart)
3. **`%post` + offline USB repos** install GUI, your package list, and latest errata from a full `dnf reposync`

Do **not** try to rebuild one giant multi‑GB package ISO every time errata change. Use a **two-region USB**:

| Region | Size | Purpose |
|--------|------|---------|
| Start of disk | ~3–4 GB | Customized FIPS/STIG isohybrid installer (kickstart injected) |
| Rest of disk `LABEL=RHEL8OFFLINE` | ~220 GB | Full offline RPM repos (BaseOS + AppStream + CRB) |

```
USB
├── [isohybrid liveimg installer + /ks/ks.cfg]
└── LABEL=RHEL8OFFLINE
    ├── BaseOS/                 # reposync (latest packages/errata)
    ├── AppStream/
    ├── CodeReadyBuilder/
    ├── ks/ks.cfg
    └── scripts/post-install-extra.sh
```

### Your existing media

| File | Size | Notes |
|------|------|--------|
| `rhel-8.10-fips-stig.iso` | ~3.1 GB | **Selected default** — liveimg + FIPS/STIG boot args |
| `rhel-8-nofips-nostig.iso` | ~3.1 GB | Same layout, without FIPS/STIG cmdline |
| `rhel-8.10-x86_64-boot.iso` | ~1 GB | Traditional package installer (use with `KS_INSTALL_MODE=packages`) |

## Prerequisites

- Red Hat Developer account (free): https://developers.redhat.com/
- Host with Docker (you have this on Ubuntu)
- ~80–120 GB free disk while syncing repos (then copy to USB)
- `xorriso` (present), optional: `isomd5sum`, `syslinux`, `gdisk`/`parted`, `rsync`

Login once to the container registry:

```bash
# On host
docker login registry.redhat.io
# username = RH customer/developer login
```

## Quick workflow

```bash
cd /home/djrude/src/rhel-installer

# 1. Configure credentials and choices
cp config.env.example config.env
# edit config.env  (do not commit secrets)

# 2. Sync full offline repos (BaseOS + AppStream + optional CRB)
./scripts/01-reposync.sh

# 3. Generate kickstart from template + package lists
./scripts/02-generate-kickstart.sh

# 4. Inject kickstart into a bootable ISO (uses boot.iso by default)
./scripts/03-inject-kickstart.sh

# 5. Partition USB and write boot ISO + offline repos
#    DESTRUCTIVE to the target device — double-check DEVICE=
./scripts/04-prepare-usb.sh /dev/sdX
```

## Package strategy

1. **During OS install (kickstart `%packages`)**  
   Install environment groups + your core package list so the machine boots usable offline.

2. **On media (full reposync)**  
   Entire BaseOS + AppStream (and CRB) with **current** errata. That is how you get “latest security updates on the stick” without inventing a second update channel.

3. **Optional post-install**  
   `scripts/post-install-extra.sh` can `dnf install` more packages from the USB after first boot (useful if kickstart group resolution differs, or for large optional sets).

## Space estimates (x86_64, approximate)

| Content | Typical size |
|---------|----------------|
| Boot ISO / p1 | 1–4 GB |
| BaseOS reposync | ~6–12 GB |
| AppStream reposync | ~35–55 GB |
| CodeReady Builder | ~5–15 GB |
| Headroom / extras | rest of USB |

Well within ~230 GB usable.

## FIPS / STIG note

- If you need **FIPS mode** and STIG-ish hardening at install time, prefer basing the **installer** on `rhel-8.10-fips-stig.iso` and enable FIPS in kickstart (`fips=1` boot arg + crypto policy).
- Offline **package repos** still come from normal RHEL 8 channels via `reposync` after subscription.
- Validate that your fips-stig ISO is a true installable tree (BaseOS/AppStream layout) before relying on it as the only content source.

## Directory layout (this project)

```
rhel-installer/
├── README.md
├── config.env.example
├── packages/
│   ├── required.txt          # your list (RHEL names)
│   ├── recommended.txt       # common air-gap extras (opt-in)
│   └── groups.txt            # comps groups for GUI + base
├── kickstart/
│   └── ks.cfg.template
├── docker/
│   └── Dockerfile.reposync
├── scripts/
│   ├── 01-reposync.sh
│   ├── 02-generate-kickstart.sh
│   ├── 03-inject-kickstart.sh
│   ├── 04-prepare-usb.sh
│   └── post-install-extra.sh
└── out/                      # generated ISO, ks, synced repos (gitignored)
```

## Security

- Never put RH passwords in git.
- Prefer `podman`/`docker` interactive register, or `config.env` with mode `0600`.
- Treat the finished USB as sensitive (full OS + errata + your kickstart credentials).
