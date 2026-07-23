# Package name notes (RHEL 8.10)

| You asked for | RHEL 8 package / notes |
|---------------|-------------------------|
| chrony | `chrony` (preferred NTP client/server) |
| nano | `nano` |
| bc | `bc` |
| socat | `socat` |
| jq | `jq` |
| python 3 + pip | `python3`, `python3-pip`, `python3-setuptools` |
| python 3.11 (for pipx) | `python3.11`, `python3.11-pip`, `python3.11-setuptools` |
| pipx | **No RPM** — staged as **wheels** via `packages/python-extra.txt` + `./scripts/01-fetch-offline-content.sh` |
| tcpdump | `tcpdump` |
| java 8 | `java-1.8.0-openjdk` (+ `-devel` / `-headless` as needed) |
| java 11 | `java-11-openjdk` (+ `-devel` / `-headless`) |
| vim | `vim-enhanced` (not just `vim`) |
| tmux | `tmux` |
| net-tools | `net-tools` (`ifconfig`, `netstat`, …) |
| gedit | `gedit` (needs GUI groups) |
| tree | `tree` |
| util-linux-extra | **Debian name** — on RHEL use `util-linux`, `util-linux-user` |
| rsync | `rsync` (BaseOS; already in offline tree) |
| sshd | service name; package is `openssh-server` (+ `openssh`, `openssh-clients`) |
| htop | **`htop` — EPEL 8 only**, not in RHEL BaseOS/AppStream/CRB |
| nload | **`nload` — EPEL 8 only** |
| wireshark | `wireshark` + `wireshark-cli` (AppStream) |
| gitk | `gitk` (AppStream; with `git`) |
| git-lfs | `git-lfs` (AppStream) |
| openjdk-17-jdk | `java-17-openjdk-devel` (+ `java-17-openjdk`, `-headless`) |
| rdesktop | Classic client is **EPEL** `rdesktop`; RHEL AppStream has **`freerdp`** (`xfreerdp`) |
| keepassx | Abandoned upstream; use **EPEL `keepassxc`** (KeepassXC) |
| pv | **`pv` — EPEL 8 only** (pipe viewer) |
| pipx | **No RPM** on RHEL 8 / EPEL 8. **Pre-stage wheels** (`python-extra.txt` → `out/offline-repo/python-wheels/`). Install with `python3.11 -m pip install --no-index --find-links=…`. |
| ntpdate | **Removed** — not in RHEL 8; use `chrony` / `chronyc`. |
| ffmpeg | **RPM Fusion free** — `packages/rpmfusion-extra.txt` + `./scripts/01-fetch-offline-content.sh` |
| gstreamer1-plugins-base/good | RHEL AppStream — `packages/recommended.txt` |
| gstreamer1-plugins-ugly / libav | **RPM Fusion** — `packages/rpmfusion-extra.txt` |
| gstreamer1-plugins-bad-nonfree | **RPM Fusion nonfree** — same list/script |
| exFAT mount/tools | **RPM Fusion:** `fuse-exfat` (mount) + `exfatprogs` (mkfs/fsck) — `packages/rpmfusion-extra.txt` |
| Docker CLI on RHEL | **`podman-docker`** (AppStream) — see `packages/available-manual.txt` (**not** auto-installed) |
| Podman / buildah / skopeo / CNI | RHEL AppStream — `available-manual.txt` (manual `dnf install`) |
| kubectl helm helmfile k9s hauler crane kustomize | **No RHEL/EPEL RPM** in this pipeline — offline binary/third-party; fapolicyd: `docs/STIG-THIRD-PARTY-TOOLS.md` |

**Staging vs install:** `01-fetch-offline-content.sh` mirrors BaseOS/AppStream/CRB, stages EPEL list, and stages RPM Fusion list into `out/offline-repo/RPMFusion/`. Target install reads lists via `install-from-local-mirror.sh`.

See `docs/ADDING-PACKAGES.md` for how to add more packages and re-sync.

## Desktop group

Kickstart uses environment group:

```
@^graphical-server-environment
```

That is the RHEL “Server with GUI” equivalent (GNOME). Alternatives:

- `@^workstation-product-environment` — fuller workstation
- `@^server-product-environment` — no GUI

## Security updates on media

`dnf reposync` against CDN BaseOS + AppStream **already includes the latest published packages** for those repos (current errata), not the frozen GA DVD set. That is the correct way to put “latest security updates” on the stick.

You do **not** need a separate “updates” repo for RHEL 8 the way RHEL 7 had `rhel-7-server-rpms` + optional extras — current streams are rolling within the minor release channel you enable.

## Optional EPEL

EPEL is **not** covered by Red Hat subscription repos. Do **not** expect `htop` / `nload` from the RHEL reposync portion of `01-fetch-offline-content.sh` alone (that script also fetches EPEL when run fully).

Targeted fetch (recommended):

```bash
# edit packages/epel-extra.txt then:
./scripts/01-fetch-offline-content.sh
```

That builds `out/offline-repo/EPEL/` with resolved dependencies (much smaller than mirroring all of EPEL).

Full EPEL Everything mirrors are optional and large; only use them if you intentionally want a broad third-party set.
