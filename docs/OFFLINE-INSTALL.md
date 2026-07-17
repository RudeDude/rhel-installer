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

### Run the post-install package pass (required)

```bash
sudo bash /mnt/rhel8offline/scripts/post-install-extra.sh
```

(`post-install-extra.sh` runs USB authorization, then **installs all helpers/docs from USB immediately**, before the long rsync.)

That script runs in two phases:

**Phase A (USB required — copy only)**  
1. Mount the USB offline partition  
2. **Install helpers + docs early** (`install-airgap-helpers.sh`)  
3. **Copy the full repo mirror** to local disk: **`/var/lib/offline-repos/`**  
4. **Configure permanent dnf sources** (`enable-offline-repos.sh` → `offline-local.repo`)  
5. **Unmount the USB** and print a clear “you may remove the stick now” banner  

**Phase B (USB not required — long installs)**  
6. `dnf upgrade` + package installs + EPEL + pipx wheels + Server with GUI  
   all from **local disk only**  

You can **unplug the USB as soon as Phase A finishes** (before the long package install / reboot). Future `dnf` continues to use the local mirror.

Optional env vars for the script:

| Variable | Default | Meaning |
|----------|---------|---------|
| `LOCAL_REPO_ROOT` | `/var/lib/offline-repos` | Where to store the mirror |
| `USB_REPO_LABEL` | `RHEL8OFFLINE` | USB filesystem label |
| `SKIP_REPO_COPY=1` | off | Skip re-copy if local mirror already looks complete |

Example:

```bash
sudo LOCAL_REPO_ROOT=/data/offline-repos bash /mnt/rhel8offline/scripts/post-install-extra.sh
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

Also see: **`/root/README.md`** (full guide) and `/root/README-OFFLINE-REPOS.txt` (short pointer).

---

## 3. Offline Python / pipx

Wheels live on disk after post-install:

```bash
python3.11 -m pip install --no-index \
  --find-links=/var/lib/offline-repos/python-wheels \
  -r /var/lib/offline-repos/python-wheels/requirements.txt
```

(Already done by post-install-extra.sh for packages listed in `python-wheels/requirements.txt`.)

---

## 4. USB media layout (for reference)

```text
/mnt/rhel8offline/   (or LABEL=RHEL8OFFLINE)
  BaseOS/  AppStream/  CodeReadyBuilder/
  EPEL/
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
# 1) Refresh content as needed
./scripts/01-reposync.sh                 # RHEL errata/packages
./scripts/02-fetch-epel-packages.sh      # if epel-extra.txt changed
./scripts/03-fetch-python-wheels.sh      # if python-extra.txt changed

# 2) Push to existing USB (keeps data partition; does not wipe stick)
./scripts/08-update-usb.sh --repos --device /dev/sdb

# Kickstart / helpers only (no RPM rsync; no partition writes):
./scripts/05-generate-kickstart.sh
sudo ./scripts/08-update-usb.sh --ks --device /dev/sdb

# Optional: mount writable EFI/ESP and refresh boot *files* only (never dd/GPT):
sudo ./scripts/08-update-usb.sh --boot --device /dev/sdb
# Full installer ISO replace (rewrites partitions — first-image path only):
#   ./scripts/06-inject-kickstart.sh && sudo ./scripts/07-prepare-usb.sh --yes /dev/sdb
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
01-reposync.sh
02-fetch-epel-packages.sh
03-fetch-python-wheels.sh
04-check-offline-deps.sh      # optional
05-generate-kickstart.sh
06-inject-kickstart.sh
07-prepare-usb.sh             # first-time full write only
08-update-usb.sh              # later incremental USB updates
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
| pipx missing | `python-wheels/` under local mirror; use python3.11 |
| Disk full on copy | Need ~35GB+ free on `/` (or set `LOCAL_REPO_ROOT` to a larger filesystem) |
| GRUB kernel menu never times out | STIG often sets `GRUB_TIMEOUT=-1`. Run `sudo configure-grub-timeout.sh` then reboot |
| Mount by label fails; only ~3G + ~20M parts | Offline-repo partition missing. `08-update-usb` never rewrites GPT — reimage: `sudo ./scripts/07-prepare-usb.sh --yes /dev/sdX` |
| Mount helper: label missing but UUID exists | `sudo mount-offline-usb.sh` probes UUID/PARTLABEL/content; or `mount -o ro UUID=… /mnt/rhel8offline` |

