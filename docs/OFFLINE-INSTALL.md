# Offline / air-gapped install reference

This document is copied onto the USB and onto the target system under
`/var/lib/offline-repos/` (after post-install) for use **without internet**.

USB media label: **`RHEL8OFFLINE`** (unless you changed `USB_REPO_LABEL`).

Permanent local mirror (after post-install): **`/var/lib/offline-repos`**

---

## 1. After first boot (USB still inserted)

### Mount offline media (if not auto-mounted)

```bash
sudo mkdir -p /mnt/rhel8offline
sudo mount -L RHEL8OFFLINE /mnt/rhel8offline
```

### Run the post-install package pass (required)

```bash
sudo bash /mnt/rhel8offline/scripts/post-install-extra.sh
```

That script will:

1. Mount the USB offline partition  
2. **Copy the full repo mirror** to local disk: **`/var/lib/offline-repos/`**  
   (BaseOS, AppStream, CodeReadyBuilder, EPEL, python-wheels, docs, packages, scripts)  
3. **Configure permanent dnf sources** in `/etc/yum.repos.d/offline-local.repo`  
   with `baseurl=file:///var/lib/offline-repos/...`  
4. Disable CDN / other repos so dnf stays air-gapped  
5. Install tools, EPEL packages, pipx (wheels), Server with GUI  
6. Install helpers: `enable-offline-repos.sh`, `offline-repo-status.sh`  

**After this completes, you can remove the USB.** Future `dnf install` / `dnf upgrade` use the local disk copy only.

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

Also see: `/root/README-OFFLINE-REPOS.txt`

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
  packages/   docs/   scripts/post-install-extra.sh
  OFFLINE-INSTALL.md   README-ON-MEDIA.txt
```

---

## 5. Adding packages later

On a **connected build host**, update lists and re-fetch, then refresh the USB and re-run copy (or rsync new trees into `/var/lib/offline-repos` on the air-gapped host):

| Kind | List | Fetch script |
|------|------|----------------|
| RHEL RPM | `packages/required.txt` | already in full reposync |
| EPEL RPM | `packages/epel-extra.txt` | `./scripts/02-fetch-epel-packages.sh` |
| PyPI | `packages/python-extra.txt` | `./scripts/03-fetch-python-wheels.sh` |

Then `./scripts/07-prepare-usb.sh` and on the target either re-run post-install with USB, or:

```bash
sudo rsync -aH /mnt/rhel8offline/EPEL/ /var/lib/offline-repos/EPEL/
sudo enable-offline-repos.sh
sudo dnf install <new-package>
```

Full detail: `docs/ADDING-PACKAGES.md` on the media / local mirror.

---

## 6. Build-host pipeline (connected machine only)

```text
01-reposync.sh
02-fetch-epel-packages.sh
03-fetch-python-wheels.sh
04-check-offline-deps.sh      # optional
05-generate-kickstart.sh
06-inject-kickstart.sh
07-prepare-usb.sh
```

---

## 7. Troubleshooting

| Symptom | Check |
|---------|--------|
| dnf tries to use network | `sudo enable-offline-repos.sh`; ensure only `offline-local*.repo` is enabled |
| No packages found | `sudo offline-repo-status.sh`; confirm BaseOS/AppStream under `/var/lib/offline-repos` |
| htop missing | EPEL tree must exist under local mirror |
| pipx missing | `python-wheels/` under local mirror; use python3.11 |
| Disk full on copy | Need ~35GB+ free on `/` (or set `LOCAL_REPO_ROOT` to a larger filesystem) |
