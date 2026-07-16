# Step 07 — USB write review (`/dev/sdb`)

Run this **after** all fetch + kickstart steps:

```text
01-reposync.sh
02-fetch-epel-packages.sh
03-fetch-python-wheels.sh
04-check-offline-deps.sh      # optional
05-generate-kickstart.sh
06-inject-kickstart.sh
07-prepare-usb.sh             # this step
```

## Script

`scripts/07-prepare-usb.sh`

## What is written

1. Custom (or stock) isohybrid installer ISO to the start of the USB  
2. Large ext4 partition `LABEL=RHEL8OFFLINE` containing:
   - `BaseOS/`, `AppStream/`, `CodeReadyBuilder/`
   - `EPEL/` (required extras)
   - `python-wheels/` (pipx + deps)
   - `packages/*.txt`
   - `docs/` including **`OFFLINE-INSTALL.md`**
   - `scripts/post-install-extra.sh`
   - `ks/ks.cfg`
   - `README-ON-MEDIA.txt` / root `OFFLINE-INSTALL.md`

## Review (no write)

```bash
./scripts/07-prepare-usb.sh --dry-run /dev/sdb
```

## Destructive write

```bash
sudo ./scripts/07-prepare-usb.sh /dev/sdb
# type YES
```

See also `docs/OFFLINE-INSTALL.md` (copied onto the stick for air-gapped use).
