# Offline / air-gapped install reference

This document is copied onto the USB and onto the target system under
`/var/lib/offline-repos/`, `/root/airgap-docs/`, and `/usr/local/share/airgap/docs/`
for use **without internet**.

**Primary operator guide on the target:** **`/root/README.md`**  
(source: `docs/ROOT-HOME-README.md` — installed at kickstart time and refreshed by helpers).

USB media label: **`RHEL8OFFLINE`** (unless you changed `USB_REPO_LABEL`).

Permanent local mirror (after post-install): **`/var/lib/offline-repos`**

---

## 1. After first boot (USB still inserted)

### STIG / FIPS: USB “not authorized for usage”

Hardened images often set `usbcore.authorized_default=0` and/or USBGuard.  
`dmesg` shows: **`device is not authorized for usage`** and the stick never appears as a block device.

**Fix first (helper is embedded by kickstart and also on the USB):**

```bash
sudo authorize-offline-usb.sh
# or, if only on the stick and you can get a shell copy another way:
#   sudo bash /path/to/authorize-offline-usb.sh
```

That stops/disables USBGuard, sets `authorized_default=1`, authorizes devices, and loads `usbhid` / `usb_storage` / `uas`.

### Mount offline media

```bash
sudo mount-offline-usb.sh
# equivalent: sudo mkdir -p /mnt/rhel8offline && sudo mount -L RHEL8OFFLINE /mnt/rhel8offline
```

### Run first-time setup (two scripts — required)

**Step 1 — USB inserted** (run from the stick; copies only):

```bash
sudo bash /mnt/rhel8offline/scripts/copy-offline-mirror-from-usb.sh
sudo umount /mnt/rhel8offline
# unplug USB
```

That script: authorize/mount helpers as needed, install helpers/docs early, rsync
mirror to **`/var/lib/offline-repos/`**, configure `offline-local.repo`, install
helpers again from the **local** copy. It does **not** unmount for you and does
**not** install packages (so removing the USB cannot kill a running install script).

**Step 2 — USB removed** (run from local disk):

```bash
sudo install-from-local-mirror.sh
# or: sudo /usr/local/sbin/install-from-local-mirror.sh
# or: sudo bash /var/lib/offline-repos/scripts/install-from-local-mirror.sh
```

`dnf upgrade` + packages + EPEL + pipx wheels + Server with GUI from **local disk only**.

Optional env vars:

| Variable | Default | Meaning |
|----------|---------|---------|
| `LOCAL_REPO_ROOT` | `/var/lib/offline-repos` | Where to store / read the mirror |
| `USB_REPO_LABEL` | `RHEL8OFFLINE` | USB filesystem label (step 1) |
| `SKIP_REPO_COPY=1` | off | Step 1: skip rsync if local mirror looks complete |

Example:

```bash
sudo LOCAL_REPO_ROOT=/data/offline-repos bash /mnt/rhel8offline/scripts/copy-offline-mirror-from-usb.sh
sudo LOCAL_REPO_ROOT=/data/offline-repos install-from-local-mirror.sh
```

---

## 2. Day-to-day offline `dnf` (no USB)

```bash
sudo offline-repo-status.sh      # show mirror size / paths
sudo enable-offline-repos.sh     # rewrite .repo file if needed
sudo dnf install <package>
sudo dnf upgrade
sudo dnf search <name>
```

Repo file: `/etc/yum.repos.d/offline-local.repo`

| Repo id | Path |
|---------|------|
| `offline-local-baseos` | `file:///var/lib/offline-repos/BaseOS` |
| `offline-local-appstream` | `…/AppStream` |
| `offline-local-crb` | `…/CodeReadyBuilder` |
| `offline-local-epel` | `…/EPEL` |
| `offline-local-rpmfusion` | `…/RPMFusion` |

Also see: **`/root/README.md`** (full guide) and `/root/README-OFFLINE-REPOS.txt` (short pointer).

---

## 3. Offline Python / pipx

Wheels live on disk after post-install:

```bash
python3.11 -m pip install --no-index \
  --find-links=/var/lib/offline-repos/python-wheels \
  -r /var/lib/offline-repos/python-wheels/requirements.txt
```

(Already done by install-from-local-mirror.sh for packages listed in `python-wheels/requirements.txt`.)

---

## 4. USB media layout (for reference)

```text
/mnt/rhel8offline/   (or LABEL=RHEL8OFFLINE)
  BaseOS/  AppStream/  CodeReadyBuilder/
  EPEL/
  RPMFusion/            # ffmpeg, codecs (from 02b)
  python-wheels/
  packages/
  docs/                 # ROOT-HOME-README, OFFLINE-INSTALL, ADDING-PACKAGES, …
  scripts/              # all target helpers (see target-scripts.list)
  ks/ks.cfg
  OFFLINE-INSTALL.md   README-ON-MEDIA.txt
```

---

## 5. Incremental updates (no full USB reimage)

### On the connected build host

```bash
# 1) Refresh offline content (RHEL + EPEL + RPM Fusion + wheels + dep check)
./scripts/01-fetch-offline-content.sh

# 2) Push to existing USB (keeps data partition; does not wipe stick)
sudo ./scripts/04-update-usb.sh --repos --device /dev/sdb

# Kickstart / helpers only (no RPM rsync; no partition writes):
./scripts/02-build-kickstart-iso.sh
sudo ./scripts/04-update-usb.sh --ks --device /dev/sdb

# Optional: mount writable EFI/ESP and refresh boot *files* only (never dd/GPT):
sudo ./scripts/04-update-usb.sh --boot --device /dev/sdb
# Full installer ISO replace (rewrites partitions — first-image path only):
#   ./scripts/02-build-kickstart-iso.sh && sudo ./scripts/03-prepare-usb.sh --yes /dev/sdb
```

### On the air-gapped target

```bash
sudo authorize-offline-usb.sh
sudo mount-offline-usb.sh
sudo update-target-repo-from-usb.sh
# (or: sudo bash /mnt/rhel8offline/scripts/update-target-repo-from-usb.sh)
sudo dnf upgrade
sudo dnf install <new-package>
```

That update also re-runs `install-airgap-helpers.sh` so scripts/docs stay current.

Full detail: `docs/ADDING-PACKAGES.md` on the media / local mirror; operator index: `/root/README.md`.

---

## 6. Build-host pipeline (connected machine only)

```text
01-fetch-offline-content.sh   # RHEL + EPEL + RPM Fusion + wheels + check; stops Docker
02-build-kickstart-iso.sh     # generate ks.cfg + inject custom ISO
03-prepare-usb.sh             # first-time full write only
04-update-usb.sh              # later incremental USB updates
```

---

## 7. Troubleshooting

| Symptom | Check |
|---------|--------|
| **dmesg: device is not authorized for usage** | `sudo authorize-offline-usb.sh` then re-insert USB; check `lsblk` / `blkid -L RHEL8OFFLINE` |
| USB not in `lsblk` | Same as above; also `dmesg \| tail -50`, `systemctl status usbguard` |
| dnf tries to use network | `sudo enable-offline-repos.sh`; ensure only `offline-local*.repo` is enabled |
| No packages found | `sudo offline-repo-status.sh`; confirm BaseOS/AppStream under `/var/lib/offline-repos` |
| htop missing | EPEL tree must exist under local mirror |
| ffmpeg missing | RPMFusion tree + `01-fetch-offline-content.sh`; check `offline-repo-status.sh` |
| pipx missing | `python-wheels/` under local mirror; use python3.11 |
| Disk full on copy | Need ~35GB+ free on `/` (or set `LOCAL_REPO_ROOT` to a larger filesystem) |
| GRUB kernel menu never times out | STIG often sets `GRUB_TIMEOUT=-1`. Run `sudo configure-grub-timeout.sh` then reboot |
| Mount by label fails; only ~3G + ~20M parts | Offline-repo partition missing. `04-update-usb` never rewrites GPT — reimage: `sudo ./scripts/03-prepare-usb.sh --yes /dev/sdX` |
| Mount helper: label missing but UUID exists | `sudo mount-offline-usb.sh` probes UUID/PARTLABEL/content; or `mount -o ro UUID=… /mnt/rhel8offline` |

