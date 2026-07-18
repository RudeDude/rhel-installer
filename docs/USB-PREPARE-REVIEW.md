# USB prepare review

## Pipeline (build host)

```text
01-fetch-offline-content.sh   # RHEL + EPEL + RPM Fusion + wheels + dep check; stops Docker
02-build-kickstart-iso.sh     # generate ks + inject ISO
03-prepare-usb.sh             # this step (first full write)
04-update-usb.sh              # later incremental updates
```

## Script

`scripts/03-prepare-usb.sh`

Writes the hybrid installer + offline data partition (`LABEL=RHEL8OFFLINE`).

Includes:

- BaseOS / AppStream / CodeReadyBuilder / EPEL / RPMFusion / python-wheels
- `packages/`, `docs/`, target `scripts/`, `ks/ks.cfg`
- `docs/ROOT-HOME-README.md` (becomes `/root/README.md` on target)

## Dry-run

```bash
./scripts/03-prepare-usb.sh --dry-run /dev/sdb
```

## Write

```bash
sudo ./scripts/03-prepare-usb.sh /dev/sdb
# type YES when prompted
```
