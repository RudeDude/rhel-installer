# Quick Comparison: Old vs Refactored 01-fetch-offline-content.sh

## DNF Install Call Reduction

### OLD: 4-5 Separate Calls

```
ensure-container.sh:
  └─ dnf install dnf-plugins-core yum-utils createrepo_c rsync findutils

fetch-epel.sh:
  └─ dnf install https://dl.fedoraproject.org/.../epel-release-latest-8.noarch.rpm

fetch-rpmfusion.sh:
  ├─ dnf install https://dl.fedoraproject.org/.../epel-release-latest-8.noarch.rpm  (duplicate!)
  ├─ dnf install rpmfusion-free-release...
  └─ dnf install rpmfusion-nonfree-release...
```

### NEW: 1 Single Call

```
01-fetch-offline-content.sh:
  └─ dnf install dnf-plugins-core yum-utils createrepo_c rsync findutils \
                 epel-release rpmfusion-free-release rpmfusion-nonfree-release
```

## Script Structure Comparison

### OLD Structure
```
01-fetch-offline-content.sh (orchestrator)
├─ calls lib/ensure-container.sh     [sourced]
│  └─ register + enable repos + dnf install tools
├─ calls lib/reposync.sh             [bash]
│  ├─ sources lib/ensure-container.sh (again)
│  └─ dnf reposync
├─ calls lib/fetch-epel.sh           [bash]
│  ├─ sources lib/ensure-container.sh (again)
│  └─ dnf install epel-release + dnf download packages
├─ calls lib/fetch-rpmfusion.sh      [bash]
│  ├─ sources lib/ensure-container.sh (again)
│  └─ dnf install epel + fusion releases + dnf download
├─ calls lib/fetch-python-wheels.sh  [bash]
└─ calls lib/check-offline-deps.sh   [bash]
```

### NEW Structure
```
01-fetch-offline-content.sh (self-contained)
├─ Phase A: Container setup (inline)
├─ Phase B: Register + enable all repos + ONE dnf install (inline)
├─ Phase C: Metadata freshness check (NEW)
├─ Phase D: Content fetches (inline)
│  ├─ RHEL reposync (inline)
│  ├─ EPEL download (inline)
│  ├─ RPM Fusion download (inline)
│  └─ Python wheels (calls lib/fetch-python-wheels.sh)
└─ Phase E: Verify (calls lib/check-offline-deps.sh)
```

## Code Organization

### OLD: Scattered Logic
- Container setup: `lib/ensure-container.sh`
- RHEL sync: `lib/reposync.sh`
- EPEL setup: `lib/fetch-epel.sh`
- Fusion setup: `lib/fetch-rpmfusion.sh`
- Each file sources `ensure-container.sh` independently
- Package install logic duplicated across 3 files

### NEW: Consolidated
- All setup in one place (main script phases A-B)
- Fetch logic inline (main script phase D)
- No repeated sourcing of helpers
- Single unified package install

## New Features

1. **Metadata Staleness Tracking**
   - Timestamp: `/var/lib/airgap-metadata-refreshed`
   - Only refresh if older than `METADATA_REFRESH_HOURS` (default: 6)
   - Saves time on repeated runs

2. **Better Progress Reporting**
   - Clear phase headers
   - Single consolidated setup section
   - Easier to see what's happening

3. **Duplicate Prevention**
   - Detects if packages already installed
   - No duplicate EPEL install attempts
   - Single transaction for all packages

## Performance Impact

### Time Savings Per Run (Estimated)
- **First run**: ~10-20 seconds (single dnf transaction vs multiple)
- **Repeated runs**: ~30-60 seconds (metadata caching + single transaction)
- **Third+ run within 6 hours**: Additional ~10-20 seconds (skip metadata refresh)

### What Changed
- ✅ Container reuse: **Same** (already optimal)
- ✅ Repository metadata: **Better** (cached for 6 hours)
- ✅ Package installs: **Better** (1 call instead of 4-5)
- ✅ Duplicate detection: **Better** (unified check)
- ✅ Content downloads: **Same** (dnf download, reposync unchanged)

## Backward Compatibility

All existing flags still work:
```bash
--skip-reposync
--skip-epel
--skip-rpmfusion
--skip-wheels
--skip-check
--keep-running
--remove-container
--only-check
```

All environment variables still work:
```bash
FORCE_CONTAINER_SETUP=1
RECREATE_CONTAINER=1
CONTAINER_NAME=custom
REPO_DIR=custom/path
...
```

New optional variable:
```bash
METADATA_REFRESH_HOURS=12  # default: 6
```

## Testing Checklist

- [ ] Fresh run (no existing container)
- [ ] Reuse stopped container
- [ ] Skip reposync
- [ ] Skip EPEL
- [ ] Skip RPM Fusion
- [ ] Skip wheels
- [ ] Only check
- [ ] Metadata refresh on first run
- [ ] Metadata skip on second run (within 6h)
- [ ] Metadata refresh after 6h+
- [ ] Force container setup
- [ ] Recreate container

## Migration Steps

```bash
# 1. Backup current script
cp scripts/01-fetch-offline-content.sh scripts/01-fetch-offline-content-BACKUP.sh

# 2. Replace with refactored version
mv scripts/01-fetch-offline-content-REFACTORED.sh scripts/01-fetch-offline-content.sh

# 3. Test
./scripts/01-fetch-offline-content.sh

# 4. If issues, rollback
# mv scripts/01-fetch-offline-content-BACKUP.sh scripts/01-fetch-offline-content.sh
```
