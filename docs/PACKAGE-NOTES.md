# Package name notes (RHEL 8.10)

| You asked for | RHEL 8 package / notes |
|---------------|-------------------------|
| chrony | `chrony` (preferred NTP client/server) |
| ntpdate | `ntpdate` (legacy one-shot; optional if chrony is enough) |
| nano | `nano` |
| bc | `bc` |
| socat | `socat` |
| jq | `jq` |
| python 3 + pip + pipx | `python3`, `python3-pip`, `python3-setuptools`, `pipx` |
| tcpdump | `tcpdump` |
| java 8 | `java-1.8.0-openjdk` (+ `-devel` / `-headless` as needed) |
| java 11 | `java-11-openjdk` (+ `-devel` / `-headless`) |
| vim | `vim-enhanced` (not just `vim`) |
| tmux | `tmux` |
| net-tools | `net-tools` (`ifconfig`, `netstat`, …) |
| gedit | `gedit` (needs GUI groups) |
| tree | `tree` |
| util-linux-extra | **Debian name** — on RHEL use `util-linux`, `util-linux-user` |

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

EPEL is **not** covered by Red Hat subscription repos. If you need packages only in EPEL (e.g. some extras), mirror EPEL separately from `https://dl.fedoraproject.org/pub/epel/8/Everything/x86_64/` on a connected machine and drop it beside AppStream as `EPEL/`.
