# Step 4 — USB write review (`/dev/sdb`)

## Target device (detected)

| Field | Value |
|-------|--------|
| Device | `/dev/sdb` |
| Size | ~232.9 G |
| Model | SanDisk Extreme Pro DDE1 |
| Transport | USB |
| Current layout | `sdb1` vfat `RHEL-8-NOFI` (~98 G), `sdb2` ext3 `persistence` (~135 G) |

**Writing will erase the current RHEL/persistence layout on this stick.**

Host root filesystem is on LVM (`/dev/mapper/ubuntu--vg-ubuntu--lv`), not `sdb` — script also refuses if the target backs `/`.

## What the script does

Script: `scripts/04-prepare-usb.sh`

1. Preflight (USB?, not root disk?, ISO present?, repo present?, tools?)
2. `dd` isohybrid installer ISO to the **start** of `/dev/sdb`
3. Create an ext4 partition in the **remaining free space**, label `RHEL8OFFLINE`
4. `rsync` `out/offline-repo/` onto that partition
5. Copy `out/ks.cfg` + `scripts/post-install-extra.sh` if present

## Commands to review (no write)

```bash
cd /home/djrude/src/rhel-installer
./scripts/04-prepare-usb.sh --dry-run /dev/sdb
```

## Commands to write (destructive, needs sudo)

**Preferred** — after reposync finishes **and** custom kickstart ISO exists:

```bash
cd /home/djrude/src/rhel-installer
./scripts/status-reposync.sh          # confirm COMPLETE
# password hashes in config.env, then:
./scripts/02-generate-kickstart.sh
./scripts/03-inject-kickstart.sh
sudo ./scripts/04-prepare-usb.sh /dev/sdb
# type YES when prompted
```

**Partial / interim** (not ideal for final media):

```bash
# Stock FIPS ISO (no injected kickstart) + whatever RPMs are already downloaded
sudo ./scripts/04-prepare-usb.sh --allow-stock-iso --allow-incomplete-repo /dev/sdb
```

## Blockers before a “good” final write

1. **Offline repo still downloading** (AppStream in progress; CRB not started).  
   Real write refuses while `dnf reposync` is running unless `--allow-incomplete-repo`.
2. **Custom ISO missing** (`out/rhel-8.10-airgap-ks.iso`).  
   Needs `config.env` password hashes + steps 2–3.  
   Without that, only `--allow-stock-iso` uses `rhel-8.10-fips-stig.iso` (boots stock `osbuild.ks`, not your automated package %post).
3. **`out/ks.cfg` missing** until step 2.

## Config

`config.env` now includes:

```bash
USB_DEVICE="/dev/sdb"
USB_REPO_LABEL="RHEL8OFFLINE"
```

## After a successful write

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT /dev/sdb
sudo blkid /dev/sdb*
```

You should see the hybrid installer partitions plus a large ext4 `RHEL8OFFLINE` volume.
