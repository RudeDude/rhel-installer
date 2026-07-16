# Offline / air-gapped install reference

This document is copied onto the USB (`docs/OFFLINE-INSTALL.md`) for use **without internet**.

Media label for package repos: **`RHEL8OFFLINE`** (unless you changed `USB_REPO_LABEL`).

---

## 1. After first boot (USB still inserted)

### Mount offline media

```bash
sudo mkdir -p /mnt/rhel8offline
# Prefer the helper installed by kickstart %post when present:
sudo enable-offline-repos.sh
# Or manually:
sudo mount -L RHEL8OFFLINE /mnt/rhel8offline
```

### Expected layout on the data partition

```text
/mnt/rhel8offline/
  BaseOS/                 # RHEL BaseOS RPMs + repodata
  AppStream/
  CodeReadyBuilder/
  EPEL/                   # targeted EPEL RPMs (htop, nload, pv, …)
  python-wheels/          # pipx and other PyPI wheels + requirements.txt
  packages/               # package list files (what we intended to install)
  docs/                   # this file and related offline docs
  scripts/
    post-install-extra.sh # full post-install package pass
  ks/ks.cfg               # kickstart used at install (reference)
  README-ON-MEDIA.txt     # short pointer
```

### Run the post-install package pass

```bash
sudo bash /mnt/rhel8offline/scripts/post-install-extra.sh
```

That script:

1. Enables offline dnf repos (BaseOS, AppStream, CRB, EPEL if present)
2. `dnf upgrade` from media
3. Installs RHEL packages (tools, Java, wireshark, git, python3.11, …)
4. Installs EPEL packages (htop, nload, pv, keepassxc, rdesktop)
5. Installs Python wheels offline (`python3.11 -m pip --no-index --find-links=python-wheels`)
6. Installs Server with GUI if needed

---

## 2. Manual offline `dnf` usage

```bash
sudo enable-offline-repos.sh   # or configure file:// repos as in post-install-extra.sh
sudo dnf install <package>
sudo dnf upgrade
sudo dnf search <name>
```

Repo IDs (typical):

- `offline-baseos` → `file:///mnt/rhel8offline/BaseOS`
- `offline-appstream` → `…/AppStream`
- `offline-crb` → `…/CodeReadyBuilder`
- `offline-epel` → `…/EPEL` (enable only if tree exists)

---

## 3. Offline Python / pipx

Modern **pipx** is not an RHEL 8 / EPEL 8 RPM. Wheels are pre-staged:

```bash
sudo dnf install python3.11 python3.11-pip
python3.11 -m pip install --no-index \
  --find-links=/mnt/rhel8offline/python-wheels \
  -r /mnt/rhel8offline/python-wheels/requirements.txt
python3.11 -m pipx ensurepath
```

Add more PyPI packages on a **connected build host** by editing `packages/python-extra.txt` and re-running `./scripts/03-fetch-python-wheels.sh`, then refreshing the USB.

---

## 4. What is *not* available as RPM (RHEL 8)

| Name | Notes |
|------|--------|
| ntpdate | Use **chrony** / `chronyc` |
| pipx | Use **python-wheels** + python3.11 as above |
| keepassx | Use **keepassxc** (EPEL) |

See `docs/PACKAGE-NOTES.md` and `packages/*.txt` on this media.

---

## 5. Adding packages later (on a connected machine)

Rebuild/update media offline content, then re-copy the data partition or re-run USB prepare:

1. **RHEL RPM** already in BaseOS/AppStream/CRB → add to `packages/required.txt` → regenerate kickstart → re-write USB or run post-install with updated script  
2. **EPEL RPM** → `packages/epel-extra.txt` → `./scripts/02-fetch-epel-packages.sh`  
3. **PyPI** → `packages/python-extra.txt` → `./scripts/03-fetch-python-wheels.sh`  
4. Optional: `./scripts/04-check-offline-deps.sh`  
5. `./scripts/07-prepare-usb.sh` (or rsync updated trees onto `RHEL8OFFLINE`)

Full detail: `docs/ADDING-PACKAGES.md` on this stick.

---

## 6. Build-host pipeline (reference only — needs internet)

```text
01-reposync.sh              # RHEL BaseOS + AppStream + CRB
02-fetch-epel-packages.sh   # EPEL targeted RPMs
03-fetch-python-wheels.sh   # PyPI wheels
04-check-offline-deps.sh    # optional verification
05-generate-kickstart.sh
06-inject-kickstart.sh
07-prepare-usb.sh           # writes installer + copies ALL offline content
```

---

## 7. Troubleshooting

| Symptom | Check |
|---------|--------|
| `dnf` cannot find package | `ls /mnt/rhel8offline/{BaseOS,AppStream,EPEL}`; `dnf repolist` |
| `No match for argument: htop` | EPEL tree missing or repo disabled |
| pipx install fails | Need `python3.11` and `python-wheels/*.whl` on media |
| GUI missing | `sudo dnf groupinstall "Server with GUI"` with offline repos enabled |
| Kickstart did not auto-install extras | Run `scripts/post-install-extra.sh` from this USB |

Kickstart copy (if present): `ks/ks.cfg`  
Post-install log on installed system: `/root/ks-post.log`
