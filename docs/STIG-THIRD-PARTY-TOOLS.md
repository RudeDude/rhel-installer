# STIG / fapolicyd — third-party tools (offline reference)

STIG RHEL 8 images typically run **fapolicyd** with a deny-by-default policy for
executing untrusted files. RPMs installed under `/usr` via `dnf` are generally
trusted. Tools installed by tarball, self-extractors, or scripts under `$HOME`
often are **not** — for example Hauler writing helpers under `~/.hauler`.

This guide is for air-gapped operators who install **kubectl, helm, helmfile,
k9s, hauler, crane, kustomize**, RKE2 bits, etc. outside the RHEL installer RPM
lists.

Related: container-related **RPMs** that are on the offline mirror but not
auto-installed are listed in `packages/available-manual.txt`.

---

## Prefer system-wide install paths

| Prefer | Avoid |
|--------|--------|
| `/usr/local/bin`, `/usr/local/sbin` | `~/bin`, `~/.local/bin` |
| `/opt/<tool>/…` | Self-extract under `$HOME` without trust |
| Official offline tarballs + checksums | `curl \| bash` on the target |

After any non-RPM install, **trust the binaries** with fapolicyd (below).

---

## Discover denials

```bash
systemctl status fapolicyd
sudo journalctl -u fapolicyd -b --no-pager | tail -80
# Often: dec=deny ... path=/home/.../.hauler/... or path=/usr/local/bin/...

# SELinux is a separate control:
sudo ausearch -m avc -ts recent 2>/dev/null | tail -20
```

Confirm the **path** of the blocked file before writing rules.

---

## Option A — Trust individual binaries (e.g. under `/usr/local/bin`)

Use when you place tools system-wide as single executables.

```bash
# Example after installing kubectl, helm, etc. into /usr/local/bin
sudo fapolicyd-cli --file add /usr/local/bin/kubectl --trust-file k8s-tools
sudo fapolicyd-cli --file add /usr/local/bin/helm --trust-file k8s-tools
sudo fapolicyd-cli --file add /usr/local/bin/helmfile --trust-file k8s-tools
sudo fapolicyd-cli --file add /usr/local/bin/k9s --trust-file k8s-tools
sudo fapolicyd-cli --file add /usr/local/bin/crane --trust-file k8s-tools
sudo fapolicyd-cli --file add /usr/local/bin/kustomize --trust-file k8s-tools
# hauler CLI if installed as a single binary:
sudo fapolicyd-cli --file add /usr/local/bin/hauler --trust-file k8s-tools

sudo fapolicyd-cli --update
sudo systemctl restart fapolicyd
```

Trust files land under `/etc/fapolicyd/trust.d/` (path, size, hash). Re-run
`--file add` after **upgrading** a binary (hash changes).

Also works for `/usr/sbin/...` if a tool installs there (same commands, adjust path).

---

## Option B — Trust a whole tree under `/opt` (good for kits / self-extract)

Use when a tool unpacks multiple helpers (Hauler store, versioned toolkits).

```bash
# Install/extract the third-party kit under /opt (not $HOME)
sudo mkdir -p /opt/hauler
# ... copy or extract hauler content into /opt/hauler ...

sudo fapolicyd-cli --file add /opt/hauler/ --trust-file hauler
sudo fapolicyd-cli --update
sudo systemctl restart fapolicyd
```

Prefer configuring the tool’s data/cache directory under `/opt/...` or
`/var/lib/...` if it supports it, so it does not re-extract into `~/.hauler`.

---

## When a helper still appears under `$HOME`

Some tools ignore install prefixes and still drop executables or scripts under
the user home (the Hauler `~/.hauler` case).

1. Prefer reconfigure/reinstall so artifacts live under `/opt` or `/usr/local`.
2. If unavoidable, trust the specific path (not all of `$HOME`):

```bash
sudo fapolicyd-cli --file add /home/USER/.hauler/ --trust-file hauler-home
sudo fapolicyd-cli --update
sudo systemctl restart fapolicyd
```

Document any home trust exception for your ATO; it is broader than Option A/B.

---

## Temporary diagnosis only (not for production STIG)

```bash
# fapolicyd.conf: permissive = 1   # collect denials, then set back to enforcing
sudo systemctl restart fapolicyd
# reproduce → journalctl -u fapolicyd
# restore enforcing + proper trust rules
```

Do **not** leave fapolicyd permissive long-term on a STIG system.

---

## SELinux (separate from fapolicyd)

If denials are AVC (not fapolicyd):

```bash
sudo ausearch -m avc -ts recent
# Fix with fcontext + restorecon; avoid setenforce 0 long-term
```

---

## Operator checklist

1. Install third-party tools under **`/usr/local`** or **`/opt`**.
2. Run **`fapolicyd-cli --file add`** on binaries or the tree.
3. **`fapolicyd-cli --update`** and **`systemctl restart fapolicyd`**.
4. Re-test the command; re-check journal if still denied.
5. After upgrades, re-add trust (hashes change).
6. Keep a note of trust files under `/etc/fapolicyd/trust.d/` for the next rebuild.

---

## Related paths on this air-gap media

| Item | Location |
|------|----------|
| This doc on media | `docs/STIG-THIRD-PARTY-TOOLS.md` |
| On target after helpers | `/usr/local/share/airgap/docs/`, `/root/airgap-docs/` |
| Manual RPM list (not auto-installed) | `packages/available-manual.txt` → `/root/airgap-packages/` |
| Offline dnf | `sudo enable-offline-repos.sh` then `sudo dnf install <pkg>` |
