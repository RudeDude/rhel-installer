# Air-gapped RHEL 8.10 — operator guide (root home)

This file is installed as **`/root/README.md`** on the target system as early as possible:

1. **Kickstart `%post`** — embedded copy (works even before USB is mounted)
2. **Media install** — `install-airgap-helpers.sh` from USB / local mirror
3. **`copy-offline-mirror-from-usb.sh` / `install-from-local-mirror.sh`** — two-step first setup

Full copies of all air-gap documentation also live under:

| Location | When available |
|----------|----------------|
| `/root/README.md` | Kickstart / first helper install |
| `/root/airgap-docs/` | After helpers install from media |
| `/usr/local/share/airgap/docs/` | System-wide copy |
| `/root/airgap-packages/` | Package list `.txt` files |
| `/var/lib/offline-repos/docs/` | After first post-install mirror copy |
| USB `docs/` and `OFFLINE-INSTALL.md` | Always on media |

USB label: **`RHEL8OFFLINE`**  
Local package mirror (after first post-install): **`/var/lib/offline-repos`**

---

## First login checklist

### 1. USB keyboard / storage blocked? (`device is not authorized for usage`)

```bash
sudo authorize-offline-usb.sh
# Stops/disables USBGuard, authorizes USB, loads usbhid + usb_storage + uas
```

### 2. First-time setup — two scripts (do not run packages from the USB)

USB still inserted:

```bash
sudo authorize-offline-usb.sh          # if needed
sudo mount-offline-usb.sh
sudo bash /mnt/rhel8offline/scripts/copy-offline-mirror-from-usb.sh
sudo umount /mnt/rhel8offline
# unplug the USB stick
```

Then from **local disk only** (long installs):

```bash
sudo install-from-local-mirror.sh
# or: sudo /usr/local/sbin/install-from-local-mirror.sh
# or: sudo bash /var/lib/offline-repos/scripts/install-from-local-mirror.sh
```

Step 1 copies repos to `/var/lib/offline-repos`, installs helpers/docs, configures dnf.  
Step 2 must not run from the USB path (script would vanish mid-install).

### 3. Day-to-day package management (no USB)

```bash
sudo offline-repo-status.sh
sudo enable-offline-repos.sh    # rewrite local file:// repos if needed
sudo dnf install <package>
sudo dnf upgrade
```

Repo file: `/etc/yum.repos.d/offline-local.repo`  
(`file:///var/lib/offline-repos/{BaseOS,AppStream,CodeReadyBuilder,EPEL}`)

“System not registered” from subscription-manager is **expected offline** and harmless.

### 4. Incremental updates later

**Build host** (internet):

```bash
./scripts/01-fetch-offline-content.sh              # as needed (stops the container when done)
sudo ./scripts/04-update-usb.sh --repos --device /dev/sdX
# kickstart/helpers only (no partition writes):
# ./scripts/02-build-kickstart-iso.sh && sudo ./scripts/04-update-usb.sh --ks --device /dev/sdX
# full installer reimage (only if hybrid ISO must change): 03-prepare-usb.sh
```

**Target**:

```bash
sudo authorize-offline-usb.sh
sudo mount-offline-usb.sh
sudo update-target-repo-from-usb.sh    # refreshes mirror + helpers + docs
sudo dnf upgrade
```

### 5. GRUB menu waits forever (no auto timeout)

Hardened / STIG images often set `GRUB_TIMEOUT=-1`. Fix (already applied by kickstart / post-install):

```bash
sudo configure-grub-timeout.sh        # default 5 seconds
# or:  sudo configure-grub-timeout.sh 10
sudo reboot
```

### 6. Python / pipx (offline wheels)

```bash
python3.11 -m pip install --no-index \
  --find-links=/var/lib/offline-repos/python-wheels \
  -r /var/lib/offline-repos/python-wheels/requirements.txt
```

(Already done by post-install for packages in `python-wheels/requirements.txt`.)

---

## Commands installed on the target

All under **`/usr/local/sbin/`** (on `PATH` for root). Also kept under
`/usr/local/share/airgap/scripts/` and `/var/lib/offline-repos/scripts/`.

| Command | Purpose |
|---------|---------|
| `authorize-offline-usb.sh` | USBGuard off + authorize HID/storage |
| `mount-offline-usb.sh` | `mount -L RHEL8OFFLINE` helper |
| `enable-offline-repos.sh` | Point dnf at **local** mirror (or USB if no local yet) |
| `offline-repo-status.sh` | Show mirror paths/sizes + helper/doc presence |
| `update-target-repo-from-usb.sh` | Incremental USB → local mirror sync + helper refresh |
| `copy-offline-mirror-from-usb.sh` | Step 1: USB → local mirror + helpers (run from USB) |
| `install-from-local-mirror.sh` | Step 2: dnf/GUI/wheels from local disk only |
| `install-airgap-helpers.sh` | Re-install helpers/docs from a media path |
| `configure-grub-timeout.sh` | Fix GRUB menu waiting forever (STIG `timeout=-1`) |

---

## Documentation index (everything shipped to the air-gap)

| Doc | On media | On target after helpers / post-install |
|-----|----------|----------------------------------------|
| **This guide** (`ROOT-HOME-README.md`) | `docs/ROOT-HOME-README.md` | **`/root/README.md`** + share/airgap-docs |
| Offline ops (detail) | `docs/OFFLINE-INSTALL.md`, partition root | `/root/OFFLINE-INSTALL.md`, share, airgap-docs |
| Adding packages | `docs/ADDING-PACKAGES.md` | share + airgap-docs |
| Package name notes | `docs/PACKAGE-NOTES.md` | share + airgap-docs |
| USB prepare (build host) | `docs/USB-PREPARE-REVIEW.md` | share + airgap-docs |
| Project overview | `docs/PROJECT-README.md` (from repo README) | share + airgap-docs |
| Media splash | `README-ON-MEDIA.txt` | often under share/docs |
| Package lists | `packages/*.txt` | `/root/airgap-packages/`, share, local mirror |
| Kickstart used | `ks/ks.cfg` | `/var/lib/offline-repos/ks/ks.cfg` |
| Kickstart log | — | `/root/ks-post.log` |
| Short pointer | — | `/root/README-OFFLINE-REPOS.txt` (points here) |

Also on USB root: `OFFLINE-INSTALL.md`, `README-ON-MEDIA.txt`.

### Package lists (what was planned for this media)

```text
/root/airgap-packages/required.txt
/root/airgap-packages/recommended.txt
/root/airgap-packages/epel-extra.txt
/root/airgap-packages/python-extra.txt
/root/airgap-packages/groups.txt
```

(Same files under `/var/lib/offline-repos/packages/` after copy.)

---

## Layout after post-install

```text
/var/lib/offline-repos/
  BaseOS/  AppStream/  CodeReadyBuilder/  EPEL/
  python-wheels/
  packages/  docs/  scripts/  ks/
  OFFLINE-INSTALL.md

/usr/local/sbin/                 # helpers above
/usr/local/share/airgap/
  scripts/  docs/  packages/
/root/README.md                  # this file
/root/airgap-docs/               # full doc set
/root/airgap-packages/           # package list copies
/root/README-OFFLINE-REPOS.txt   # short pointer → this file
/root/OFFLINE-INSTALL.md         # detailed offline ops
/etc/yum.repos.d/offline-local.repo
/etc/motd.d/99-airgap
```

---

## Troubleshooting

| Symptom | Action |
|---------|--------|
| dmesg: not authorized for usage | `sudo authorize-offline-usb.sh` |
| No USB keyboard | Same; USBGuard must be stopped |
| `dnf` wants network | `sudo enable-offline-repos.sh` |
| Missing htop etc. | Need EPEL under local mirror |
| Missing pipx | Need `python-wheels/` + python3.11 |
| Disk full during copy | Free ~35GB+ or `LOCAL_REPO_ROOT=/big/fs` |
| Helpers/docs missing | `sudo install-airgap-helpers.sh /var/lib/offline-repos` (or USB path) |
| GRUB kernel menu never auto-boots | STIG often sets `GRUB_TIMEOUT=-1`. Run: `sudo configure-grub-timeout.sh` (default 5s), then reboot |
| `mount -L RHEL8OFFLINE` fails; only small parts | Offline-repo partition missing. Build host: reimage with `03-prepare-usb` (08 never rewrites partitions). Or mount UUID from `blkid` |

---

*Generated for air-gap RHEL 8.10 custom installer media. Keep this file with the system.*
