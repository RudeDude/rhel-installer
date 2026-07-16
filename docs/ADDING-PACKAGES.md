# Adding packages after the initial offline sync

There are two different problems people mix up:

1. **Remember to install the package** on the air-gapped machine (kickstart `%post` / `post-install-extra.sh`)
2. **Have the RPM (and deps) on the USB** so offline `dnf install` can succeed

For packages already in your mirrored **BaseOS / AppStream / CRB** trees, (2) is already done.  
For packages only in **EPEL** (or other third-party repos), you must add a separate offline tree.

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
2. Optionally mirror the same names in `scripts/post-install-extra.sh` (first-boot helper).
3. Rebuild kickstart (and ISO if you inject it):

   ```bash
   ./scripts/02-generate-kickstart.sh
   ./scripts/03-inject-kickstart.sh
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
   ./scripts/05-fetch-epel-packages.sh
   ```

   This installs `epel-release` **inside the container only**, runs `dnf download --resolve`, and builds:

   ```text
   out/offline-repo/EPEL/
     Packages/*.rpm
     repodata/
   ```

3. Also list the package in `required.txt` or `recommended.txt` if you want kickstart/`post-install-extra.sh` to install it automatically (once EPEL is enabled offline).
4. Re-write the USB (or rsync only the new `EPEL/` tree onto the existing `RHEL8OFFLINE` partition).
5. On the installed system, enable the EPEL file repo (example):

   ```ini
   # /etc/yum.repos.d/offline-epel.repo
   [offline-epel]
   name=Offline EPEL 8
   baseurl=file:///mnt/rhel8offline/EPEL
   enabled=1
   gpgcheck=0
   ```

   Then: `sudo dnf install htop nload`

> Full EPEL “Everything” is large (tens of GB). Prefer **targeted** `dnf download --resolve` of the packages you need rather than mirroring all of EPEL.

## C. Refresh security updates later (re-sync)

When you want newer errata on the stick:

```bash
# Container still registered, or re-run registration via 01-reposync.sh
./scripts/01-reposync.sh
# dnf reposync -n is incremental-ish: re-downloads newer packages into out/offline-repo/
./scripts/status-reposync.sh
sudo ./scripts/04-prepare-usb.sh /dev/sdb   # or rsync out/offline-repo/ onto the existing USB partition
```

You do **not** need to change package lists just to pick up newer NEVRAs of packages you already install by name.

## D. Checklist for “I thought of another tool”

| Step | Action |
|------|--------|
| 1 | Find real package name (`dnf search` / `dnf provides`) |
| 2 | Is it in BaseOS/AppStream/CRB offline trees? (`find out/offline-repo -name 'foo*.rpm'`) |
| 3a | **Yes** → add to `required.txt` or `recommended.txt` → regenerate kickstart |
| 3b | **No / EPEL** → add to `epel-extra.txt` → `./scripts/05-fetch-epel-packages.sh` |
| 4 | Update USB offline partition (full step 4 or targeted rsync) |
| 5 | Install offline on the target (`dnf install …`) |

## Files involved

| File | Role |
|------|------|
| `packages/required.txt` | Baseline package names for kickstart generation |
| `packages/recommended.txt` | Optional extras (`INCLUDE_RECOMMENDED`) |
| `packages/epel-extra.txt` | Names to pull from EPEL into `out/offline-repo/EPEL` |
| `packages/groups.txt` | Comps groups (mostly package-mode installs) |
| `scripts/02-generate-kickstart.sh` | Builds `out/ks.cfg` from lists + template |
| `scripts/05-fetch-epel-packages.sh` | Resolves/downloads EPEL extras |
| `scripts/post-install-extra.sh` | First-boot offline install helper on the target |
| `scripts/01-reposync.sh` | Full BaseOS/AppStream/CRB mirror |
