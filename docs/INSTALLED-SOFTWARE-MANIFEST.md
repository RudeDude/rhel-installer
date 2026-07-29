# Default installed software manifest

This document is the **default software set** installed on the target by this
repository's process. It is **not** an inventory of every RPM on the offline
mirror (BaseOS/AppStream/CRB trees are much larger).

**Source of truth:** package list files under `packages/` (regenerate after changes):

```bash
./scripts/lib/generate-installed-manifest.sh
```

Generated: 2026-07-29T16:19Z

---

## How default install works

| Phase | What runs | What gets installed from this manifest |
|-------|-----------|----------------------------------------|
| Kickstart (`liveimg` default) | Anaconda + `%post` (if USB mounted) | Best-effort: required (+ recommended) RPM names, GUI group |
| **STEP 1** | `airgap-setup-1-copy-mirror.sh` | *None* (copies mirror + helpers only) |
| **STEP 2** | `airgap-setup-2-install.sh` | **Full default set:** required, recommended, EPEL extra, RPM Fusion extra, Python wheels, Server with GUI |

Defaults assume:

- `INCLUDE_RECOMMENDED=yes` (config.env)
- Offline trees for EPEL and RPM Fusion are present on the media
- Python wheels were staged by `01-fetch-offline-content.sh`

---

## Intentionally **not** in this default set

| List / content | Why excluded |
|----------------|--------------|
| `packages/available-manual.txt` | Operator installs when needed (`dnf install …`) |
| `packages/rke2-extra.txt` | RKE2 mirror only; `dnf install rke2-server` / `rke2-agent` when needed |
| Full BaseOS / AppStream / CRB package sets | Provide deps and updates; not all installed |
| Third-party binaries (kubectl, helm, …) | Outside RPM lists — see `docs/STIG-THIRD-PARTY-TOOLS.md` |

---

## Environment / comps groups

Installed by kickstart (non-liveimg) and/or STEP 2:

```
dnf groupinstall "Server with GUI"
# fallback: dnf install @graphical-server-environment
```

Also listed in `packages/groups.txt` for reference:

```
graphical-server-environment
hardware-monitoring
standard
system-tools
```

## RHEL RPMs — required (packages/required.txt)

Always installed by STEP 2. Also used for kickstart %post package install when media is available.

```
bc
bind-utils
bzip2
chrony
curl
freerdp
gedit
git
gitk
git-lfs
gzip
iproute
iputils
java-11-openjdk
java-11-openjdk-devel
java-11-openjdk-headless
java-17-openjdk
java-17-openjdk-devel
java-17-openjdk-headless
java-1.8.0-openjdk
java-1.8.0-openjdk-devel
java-1.8.0-openjdk-headless
jq
nano
net-tools
nmap-ncat
openssh
openssh-clients
openssh-server
python3
python3.11
python3.11-pip
python3.11-setuptools
python3-devel
python3-pip
python3-setuptools
rsync
socat
tar
tcpdump
tmux
tree
unzip
util-linux
util-linux-user
vim-enhanced
wget
wireshark
wireshark-cli
xz
zip
```

_Count: 51_

## RHEL RPMs — recommended (packages/recommended.txt)

Included because INCLUDE_RECOMMENDED=yes (default). Set to no in config.env to omit from generated kickstart intent.

```
ansible-core
bash-completion
diffutils
evince
file
firefox
gnome-system-monitor
gnome-terminal
gstreamer1-plugins-bad-free
gstreamer1-plugins-base
gstreamer1-plugins-good
gstreamer1-plugins-good-gtk
iotop
less
lsof
man-db
man-pages
procps-ng
psmisc
strace
sysstat
which
```

_Count: 22_

## EPEL RPMs (packages/epel-extra.txt)

Installed by STEP 2 when EPEL/ is on the local mirror.

```
ansible
htop
keepassxc
nload
pv
rdesktop
```

_Count: 6_

## RPM Fusion RPMs (packages/rpmfusion-extra.txt)

Installed by STEP 2 when RPMFusion/ is on the local mirror.

```
exfatprogs
ffmpeg
fuse-exfat
gstreamer1-libav
gstreamer1-plugins-bad-nonfree
gstreamer1-plugins-ugly
vlc
```

_Count: 7_

## Python packages — wheels (packages/python-extra.txt)

Installed by STEP 2 with:

```bash
python3.11 -m pip install --no-index --find-links=/var/lib/offline-repos/python-wheels -r requirements.txt
```

Fetch also stages pip bootstrap wheels (pip, setuptools, wheel) when PYTHON_INCLUDE_PIP_BOOTSTRAP=yes (default); those are install tools, not extra apps.

```
bitarray
bitstring
numpy
pipx
scapy
```

_Count: 5_

## Flat list — all default RPM names (unique, sorted)

Union of required + recommended + epel-extra + rpmfusion-extra (no groups, no Python).

```
ansible
ansible-core
bash-completion
bc
bind-utils
bzip2
chrony
curl
diffutils
evince
exfatprogs
ffmpeg
file
firefox
freerdp
fuse-exfat
gedit
git
gitk
git-lfs
gnome-system-monitor
gnome-terminal
gstreamer1-libav
gstreamer1-plugins-bad-free
gstreamer1-plugins-bad-nonfree
gstreamer1-plugins-base
gstreamer1-plugins-good
gstreamer1-plugins-good-gtk
gstreamer1-plugins-ugly
gzip
htop
iotop
iproute
iputils
java-11-openjdk
java-11-openjdk-devel
java-11-openjdk-headless
java-17-openjdk
java-17-openjdk-devel
java-17-openjdk-headless
java-1.8.0-openjdk
java-1.8.0-openjdk-devel
java-1.8.0-openjdk-headless
jq
keepassxc
less
lsof
man-db
man-pages
nano
net-tools
nload
nmap-ncat
openssh
openssh-clients
openssh-server
procps-ng
psmisc
pv
python3
python3.11
python3.11-pip
python3.11-setuptools
python3-devel
python3-pip
python3-setuptools
rdesktop
rsync
socat
strace
sysstat
tar
tcpdump
tmux
tree
unzip
util-linux
util-linux-user
vim-enhanced
vlc
wget
which
wireshark
wireshark-cli
xz
zip
```

_Default RPM names: 86 · Default Python requirements: 5_

---

*Regenerate after editing packages/*.txt: `./scripts/lib/generate-installed-manifest.sh`*
