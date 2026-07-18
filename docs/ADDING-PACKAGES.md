# Adding packages after the initial offline sync

There are two different problems people mix up:

1. **Remember to install the package** on the air-gapped machine (kickstart `%post` / `install-from-local-mirror.sh`)
2. **Have the RPM (and deps) on the USB** so offline `dnf install` can succeed

For packages already in your mirrored **BaseOS / AppStream / CRB** trees, (2) is already done.  
For packages only in **EPEL** or **RPM Fusion**, add them to the matching list file and run the fetch script.

## RHEL package names for this request

| Wanted | RHEL / EPEL package | Already on media? |
|--------|---------------------|-------------------|
| htop | `htop` | **EPEL only** (not in BaseOS/AppStream/CRB) |
| nload | `nload` | **EPEL only** |
| rsync | `rsync` | Yes — BaseOS (already in `required.txt`) |
| sshd | `openssh-server` (+ `openssh`, `openssh-clients`) | Yes — BaseOS; usually preinstalled on Server images |

Kickstart already enables the `sshd` **service** when the package is present (`services --enabled=sshd,...`).

## A. Add a package that is already in BaseOS / AppStream / CRB

No re-download of the whole repo is required.

1. Append the **real RPM name** to a list file:
   - `packages/required.txt` — always installed in generated kickstart `%post` / intended baseline
   - `packages/recommended.txt` — when `INCLUDE_RECOMMENDED=yes` in `config.env`
2. Target install picks up list files automatically (`install-from-local-mirror.sh` reads `packages/*.txt` from the local mirror).
3. Rebuild kickstart (and ISO if you inject it):

   ```bash
   ./scripts/02-build-kickstart-iso.sh
   ./scripts/02-build-kickstart-iso.sh
   ```

4. On next USB write, the updated `ks.cfg` is copied automatically. The RPM is already under `out/offline-repo/`.

5. On an **already installed** air-gapped host (USB inserted):

   ```bash
   sudo enable-offline-repos.sh    # or mount LABEL=RHEL8OFFLINE and point dnf at file:// repos
   sudo dnf install <package>
   ```

### How to discover the correct name

On a registered RHEL 8 machine or inside `rhel8-reposync`:

```bash
dnf search htop
dnf provides '*/bin/nload'
dnf info rsync openssh-server
```

## B. Add a package that is only in EPEL (htop, nload, …)

1. Add the name to `packages/epel-extra.txt` (one per line).
2. With the registered reposync container running:

   ```bash
   ./scripts/01-fetch-offline-content.sh
   ```

   Builds:

   ```text
   out/offline-repo/EPEL/
     Packages/*.rpm
     repodata/
   ```

3. Update USB offline partition (full step 07 (prepare-usb) or rsync `EPEL/`).
4. On the installed system with offline repos enabled: `sudo dnf install htop nload …`

> Full EPEL “Everything” is large. Prefer **targeted** downloads.

## B2. Add a package from RPM Fusion (ffmpeg, codecs, …)

1. Add the name to **`packages/rpmfusion-extra.txt`**.
2. Ensure CRB + EPEL are available in the container, then:

   ```bash
   ./scripts/01-fetch-offline-content.sh                 # if needed (CRB)
   ./scripts/01-fetch-offline-content.sh      # EPEL deps for Fusion
   ./scripts/01-fetch-offline-content.sh
   ```

   Builds:

   ```text
   out/offline-repo/RPMFusion/
     Packages/*.rpm
     repodata/
     INVENTORY.txt
   ```

3. Push to USB: `sudo ./scripts/04-update-usb.sh --repos --device /dev/sdX`
4. On the target (after local mirror copy): `sudo dnf install ffmpeg`  
   (or re-run `install-from-local-mirror.sh` which installs `rpmfusion-extra.txt`)

Optional: `RPMFUSION_SKIP_NONFREE=1` for free-only. Default enables free + nonfree release repos.

## C. Add a Python package with no RPM (pipx, …) — pre-staged wheels

1. Add the requirement to **`packages/python-extra.txt`** (pip syntax; one per line), e.g. `pipx` or `requests==2.31.0`.
2. On the **connected build host**:

   ```bash
   ./scripts/01-fetch-offline-content.sh
   ```

   This runs `pip download` **with full dependency resolution** (never `--no-deps`),
   optionally stages `pip`/`setuptools`/`wheel`, then **verifies** offline install:

   ```bash
   pip install --no-index --find-links=python-wheels -r requirements.txt --dry-run
   # (in a temp venv; fails the script if any dep is missing)
   ```

   Config in `config.env` (optional):

   ```bash
   PYTHON_EXTRA_FILE="packages/python-extra.txt"
   PYTHON_WHEEL_DIR="out/offline-repo/python-wheels"
   PYTHON_PIP="python3 -m pip"
   PYTHON_TARGET_VERSION="311"          # match RHEL python3.11 tags
   PYTHON_INCLUDE_PIP_BOOTSTRAP="yes"
   PYTHON_VERIFY_OFFLINE="yes"
   ```

3. Ensure RHEL media includes a modern interpreter (in `required.txt`):

   - `python3.11`, `python3.11-pip`, `python3.11-setuptools`  
     (base `python3` on RHEL 8 is often 3.6 — too old for modern pipx)

4. On the air-gapped host (USB mounted):

   ```bash
   sudo dnf install python3.11 python3.11-pip
   python3.11 -m pip install --no-index \
     --find-links=/mnt/rhel8offline/python-wheels \
     -r /mnt/rhel8offline/python-wheels/requirements.txt
   ```

   `install-from-local-mirror.sh` does this automatically when `python-wheels/` is on the media.

> Compiled extensions need manylinux wheels matching the target; pure-Python packages (like pipx) stage cleanly as `py3-none-any.whl`.

## D. Refresh security updates later (re-sync)

When you want newer errata on the stick:

```bash
# Container still registered, or re-run ./scripts/01-fetch-offline-content.sh
./scripts/01-fetch-offline-content.sh
# dnf reposync -n is incremental-ish: re-downloads newer packages into out/offline-repo/
./scripts/status-reposync.sh
sudo ./scripts/03-prepare-usb.sh /dev/sdb   # or rsync out/offline-repo/ onto the existing USB partition
```

You do **not** need to change package lists just to pick up newer NEVRAs of packages you already install by name.

## E. Checklist for “I thought of another tool”

| Step | Action |
|------|--------|
| 1 | Is it an **RPM** or a **PyPI** package? |
| 2a | RPM in BaseOS/AppStream/CRB? → `required.txt` / `recommended.txt` |
| 2b | RPM only in EPEL? → `epel-extra.txt` → `./scripts/01-fetch-offline-content.sh` |
| 2c | PyPI only? → `python-extra.txt` → `./scripts/01-fetch-offline-content.sh` |
| 3 | `./scripts/01-fetch-offline-content.sh --only-check` for RPMs |
| 4 | Update USB offline partition |
| 5 | Install offline (`dnf` and/or `python3.11 -m pip --no-index …`) |

## Will offline `dnf install` get all dependencies?

**Usually yes**, if the package exists in your offline trees and those trees are complete for that channel:

| Source | How deps are covered |
|--------|----------------------|
| BaseOS / AppStream / CRB | Full newest-only `reposync` mirrors the whole repo, so normal RPM dependencies for packages in those repos should resolve from the same media. |
| EPEL (targeted) | `./scripts/01-fetch-offline-content.sh` runs `dnf download --resolve --alldeps`, so listed EPEL packages **and** their dependencies are pulled into `out/offline-repo/EPEL/`. On the target, enable BaseOS+AppStream+CRB+EPEL together so dnf can take a dep from any of them. |

Caveats:

- The package name must actually exist on the media. Verified gaps:
  - **`ntpdate`**: not in RHEL 8 — use **chrony** (removed from our lists).
  - **`pipx`**: no RPM on RHEL 8 **or EPEL 8** — stage via **`packages/python-extra.txt`** + **`01-fetch-offline-content.sh`**.
- Modular streams / weak deps can still surprise you.
- **`Server with GUI`** pulls a large comps set — covered only because AppStream was fully mirrored.
- Always enable **all** offline repos when installing (RHEL + EPEL).

### How to verify with DNF (recommended)

On the **build host**, with the `rhel8-reposync` container and trees under `out/offline-repo/`:

```bash
./scripts/01-fetch-offline-content.sh --only-check
# Optional heavy check:
CHECK_GUI_GROUP=1 ./scripts/01-fetch-offline-content.sh --only-check
```

That points dnf at **only** `file:///repo/{BaseOS,AppStream,CodeReadyBuilder,EPEL}` (no CDN) and runs `dnf install --downloadonly` for the post-install package set. Exit 0 means the full dependency closure is available offline.

On an **installed air-gapped system** (USB mounted):

```bash
sudo enable-offline-repos.sh
sudo dnf install --downloadonly -y htop nload wireshark gitk java-17-openjdk-devel …
# or:
sudo dnf install --assumeno htop   # shows the transaction; look for "No match" / "nothing provides"
```

## Files involved

| File | Role |
|------|------|
| `packages/required.txt` | Baseline package names for kickstart generation |
| `packages/recommended.txt` | Optional extras (`INCLUDE_RECOMMENDED`) |
| `packages/epel-extra.txt` | EPEL RPMs → `out/offline-repo/EPEL` |
| `packages/rpmfusion-extra.txt` | RPM Fusion RPMs → `out/offline-repo/RPMFusion` |
| `packages/python-extra.txt` | PyPI names → wheels in `out/offline-repo/python-wheels` |
| `packages/groups.txt` | Comps groups (mostly package-mode installs) |
| `scripts/01-fetch-offline-content.sh` | RHEL + EPEL + Fusion + wheels + dep check; stops Docker |
| `scripts/02-build-kickstart-iso.sh` | Builds `out/ks.cfg` + custom boot ISO |
| `scripts/03-prepare-usb.sh` | Writes USB; copies **all** offline content + docs |
| `scripts/04-update-usb.sh` | Incremental USB content update (mount only) |
| `scripts/lib/*` | Implementation helpers for the numbered steps |
| `scripts/copy-offline-mirror-from-usb.sh` | Target step 1: USB → local mirror |
| `scripts/install-from-local-mirror.sh` | Target step 2: packages from local disk |
