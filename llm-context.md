# LLM resume context (session notes)

Dense notes for a new agent. Prefer this + `README.md` + `docs/*` over chat history.

## Architecture (fixed)

- **Base:** Image Builder **liveimg** ISO (`rhel-8.10-fips-stig.iso`), not a package DVD. Rootfs from `liveimg.tar.gz`; extras/errata from USB offline tree.
- **USB:** two-region — (1) isohybrid installer at start, (2) ext4 `LABEL=RHEL8OFFLINE` for BaseOS/AppStream/CRB/EPEL/wheels/docs/scripts.
- **Do not** rebuild multi‑GB package ISO for errata; rsync repos to data partition.
- **Pipeline order:** `01-fetch-offline-content` (RHEL+EPEL+Fusion+wheels+check; **stops** Docker, keeps container) → `02-build-kickstart-iso` → `03-prepare-usb` → `04-update-usb`. Helpers under `scripts/lib/`.
- **Container reuse:** `lib/ensure-container.sh` starts existing stopped container; skips re-register/repo/tools when `/var/lib/airgap-container-ready` exists. Default end of 01: `docker stop` not `rm`. `--remove-container` / `RECREATE_CONTAINER=1` / `FORCE_CONTAINER_SETUP=1` for full reset.
- **Target helpers only** (not 01–08): listed in `scripts/target-scripts.list`. Install path: single `install-airgap-helpers.sh`.

## Design decisions

| Topic | Decision |
|-------|----------|
| Partitioning | Interactive Anaconda (no clearpart by default) |
| Post-install packages | **Two scripts** (not one): `copy-offline-mirror-from-usb.sh` (USB→local, helpers, dnf local) then user umount/unplug then `install-from-local-mirror.sh` (long dnf/GUI/wheels). Never unmount mid-script while still executing from USB. |
| EPEL | Targeted fetch (`epel-extra.txt`), not full EPEL mirror (~150MB) |
| RPM Fusion | Targeted fetch (`rpmfusion-extra.txt` → `out/offline-repo/RPMFusion/`) via `02b`; free+nonfree release RPMs in container; needs EPEL+CRB |
| pipx | **No** RHEL/EPEL8 RPM; offline **wheels** via `python3.11 -m pip --no-index` |
| ntp | Use **chrony**, not `ntpdate` (missing offline) |
| keepass | **keepassxc** (not keepassx) |
| Target docs | Canonical `/root/README.md` from `docs/ROOT-HOME-README.md`; other docs under `/root/airgap-docs/` + `/usr/local/share/airgap/docs/` |
| Helper source of truth | Real scripts under `scripts/`; kickstart **embeds** core ones (authorize, mount, enable-repos, status, grub-timeout, root README) so they work pre-USB |
| dnf offline | Prefer local `file:///var/lib/offline-repos`; fall back USB. RHSM noise expected offline — disable plugin / `repos --disable='*'` |
| USB STIG policy | Stop/disable USBGuard for air-gap workflow (not mask); authorize HID+storage |
| GRUB | STIG often `GRUB_TIMEOUT=-1` (forever); force positive timeout via `configure-grub-timeout.sh` (default 5s, `KS_GRUB_TIMEOUT`) |
| Incremental updates | Build: `04-update-usb.sh`; target: `update-target-repo-from-usb.sh` (rsync + reinstall helpers) |
| Config secrets | `config.env` (gitignored); example is `config.env.example` |

## Confirmed findings (target STIG/FIPS)

1. **USB “device is not authorized for usage”** — `usbcore.authorized_default=0` and/or USBGuard. Working fix: stop/disable USBGuard + `authorized_default=1` + authorize devices + `modprobe usbhid uas usb_storage`. HID rules alone were insufficient without stopping USBGuard.
2. **No USB keyboard** until same authorize path (need `usbhid`).
3. **GRUB menu never auto-boots** — `GRUB_TIMEOUT=-1` / recordfail; fix with `configure-grub-timeout.sh`.
4. **Hybrid USB partition** — isohybrid embeds GPT only spanning ~ISO size; data partition after ISO needs `sgdisk -e` (fix GPT) then create ext4 labeled `RHEL8OFFLINE`. Using parted alone / wrong type broke layout (“Invalid partition data”).
5. **`04-update-usb` is mount-only** — never dd, never sgdisk -n/parted, never mkfs, never GPT repair. Updates data partition via mount+rsync; `--boot` only mounts existing small vfat ESP and copies files. ISO9660 hybrid body is RO → full installer image replace = **03-prepare-usb only**. Lost data partition entry → 07 (not 08).
6. **Kickstart updates:** Default `KS_BOOT_SOURCE=data` → `inst.ks=hd:LABEL=RHEL8OFFLINE:/ks/ks.cfg`. `02-build-kickstart-iso` + `04-update-usb --ks`. No boot rewrite for ks.
7. **Repos sizes (approx):** RHEL newest-only ~31G; EPEL selected ~148M; wheels ~3.3M.

## Bugs / pitfalls fixed (build host)

| Issue | Fix |
|-------|-----|
| `config.env` `$6$…` password hashes expand under `set -u`/bash | Source with `set +u`; store hashes carefully; prefer single-quoted hashes |
| Docker RH creds empty | Pass `-e "VAR=$VAR"` explicitly from host |
| `subscription-manager repos --disable='*'` very slow | Prefer patching/disabling `redhat.repo` or plugin; don’t rely on full disable for speed |
| `dnf reposync --repoid` + `--disablerepo` incompatible | Don’t combine; use containerized reposync pattern in `01` |
| `reposync -n` + `--download-metadata` | CDN repodata lists RPMs not on disk → offline dnf “incorrect checksum”. **Always rebuild repodata from on-disk RPMs** after sync (`01` now does; repair: `rebuild-offline-repodata.sh`) |
| `pipx` / `ntpdate` missing as RPMs | Wheels + chrony |
| Kickstart/helper drift | One list `target-scripts.list`; no duplicate enable-repos heredocs in post-install |

## Key paths

```
scripts/01–04*.sh          build host (lib/ holds substeps)
scripts/target-scripts.list
scripts/install-airgap-helpers.sh
scripts/copy-offline-mirror-from-usb.sh
scripts/install-from-local-mirror.sh
scripts/authorize-offline-usb.sh
scripts/configure-grub-timeout.sh
scripts/update-target-repo-from-usb.sh
kickstart/ks.cfg.template  → out/ks.cfg via 05
docs/ROOT-HOME-README.md   → /root/README.md
out/offline-repo/          staged mirror + scripts/docs/packages
```

## Early install order (target)

1. Kickstart embeds helpers + `/root/README.md` (pre-USB)
2. Mount media → `install-airgap-helpers.sh`
3. `copy-offline-mirror-from-usb`: helpers before rsync; again after local mirror; **stop** for user umount
4. `install-from-local-mirror`: packages from local only; GRUB timeout; refuse if script path is still on USB
5. GRUB timeout also applied in kickstart

## Gaps / resume work

- Re-test full install after GRUB + early-helper embed changes (`02-build-kickstart-iso` + `04-update-usb` or re-`03-prepare-usb`).
- Existing installed systems: run `configure-grub-timeout.sh` + `install-airgap-helpers.sh` from USB if media updated.
- `config.env` may lack `KS_GRUB_TIMEOUT` (05 defaults to 5).
- Keep package lists in sync: `packages/*.txt` vs hard-coded dnf lists in `install-from-local-mirror.sh` / `%post` package list from 05.
- Do not put exploit/malware tooling here; offline media is STIG-oriented air-gap ops only.

## Doc map

| File | Role |
|------|------|
| `README.md` | Build-host overview |
| `docs/OFFLINE-INSTALL.md` | Target offline ops detail |
| `docs/ROOT-HOME-README.md` | Target `/root/README.md` |
| `docs/ADDING-PACKAGES.md` | Adding RPMs/wheels |
| `docs/PACKAGE-NOTES.md` | Name substitutions |
| `llm-context.md` | This file — session decisions not fully elsewhere |
