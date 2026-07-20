# 01-fetch-offline-content.sh Refactoring

## Summary

Refactored `01-fetch-offline-content.sh` to consolidate setup logic and reduce `dnf install` calls from **4-5 separate calls** down to **1 single call**.

## Key Changes

### Before (Old Architecture)
The old design scattered setup across multiple lib scripts:

1. **ensure-container.sh**: `dnf install` tools (dnf-plugins-core, yum-utils, createrepo_c, rsync, findutils)
2. **fetch-epel.sh**: `dnf install` epel-release
3. **fetch-rpmfusion.sh**: `dnf install` epel-release (again), rpmfusion-free-release, rpmfusion-nonfree-release

**Total: 4-5 separate `dnf install` calls** (with potential duplicate epel-release installs)

### After (New Architecture)

The refactored script follows a clear flow:

#### a) Setup Container
- Ensure container exists and is running
- Reuse existing stopped containers when possible

#### b) Setup All Repos + Install Everything Once
- Register with RHSM (unchanged)
- Enable all needed RHEL repos via Python patch (fast, unchanged)
- **NEW**: Build a single unified list of ALL packages to install:
  - Tools: dnf-plugins-core, yum-utils, createrepo_c, rsync, findutils
  - Release packages: epel-release, rpmfusion-free-release, rpmfusion-nonfree-release
- **Install everything in ONE `dnf install` call**

#### c) Check Metadata Freshness
- **NEW**: Track when `dnf makecache` was last run
- Only refresh if older than `METADATA_REFRESH_HOURS` (default: 6 hours)
- Avoids redundant metadata downloads on repeat runs

#### d) Execute Content Fetches
- RHEL reposync (moved inline from lib/reposync.sh)
- EPEL download (moved inline from lib/fetch-epel.sh)
- RPM Fusion download (moved inline from lib/fetch-rpmfusion.sh)
- Python wheels (still calls lib/fetch-python-wheels.sh - no container dnf calls)

#### e) Verify
- Offline dependency check (still calls lib/check-offline-deps.sh)

#### f) Cleanup
- Stop container (unless --keep-running)

## Benefits

### 1. Fewer `dnf install` Calls
- **Before**: 4-5 separate calls
- **After**: 1 single call
- **Impact**: Faster execution, less repository metadata processing

### 2. No Duplicate Package Installs
- Old code could install `epel-release` twice (once in fetch-epel, once in fetch-rpmfusion)
- New code checks what's needed and installs once

### 3. Metadata Staleness Check
- **New feature**: `METADATA_REFRESH_HOURS` (default 6)
- Timestamp tracked in `/var/lib/airgap-metadata-refreshed`
- Skip expensive `dnf makecache --refresh` if metadata is fresh
- Configurable via environment variable

### 4. Reduced Code Duplication
- Repo setup logic consolidated in main script
- No need to scatter `rpm -q package || dnf install` checks across 3 files
- Easier to maintain and understand

### 5. Better Progress Visibility
- Clear section headers show flow: setup → metadata check → fetch → verify
- Single consolidated setup phase is easier to debug

## Configuration

### New Environment Variables

```bash
# Refresh dnf metadata only if older than this (hours)
METADATA_REFRESH_HOURS=6          # default: 6 hours

# Existing variables still work
FORCE_CONTAINER_SETUP=1           # force re-registration
RECREATE_CONTAINER=1              # docker rm + fresh container
```

### Usage (Unchanged)

```bash
./scripts/01-fetch-offline-content.sh
./scripts/01-fetch-offline-content.sh --skip-wheels
./scripts/01-fetch-offline-content.sh --keep-running
./scripts/01-fetch-offline-content.sh --only-check
METADATA_REFRESH_HOURS=12 ./scripts/01-fetch-offline-content.sh
```

## Migration Path

### Option 1: Direct Replacement
1. Backup old script: `mv 01-fetch-offline-content.sh 01-fetch-offline-content-OLD.sh`
2. Rename refactored: `mv 01-fetch-offline-content-REFACTORED.sh 01-fetch-offline-content.sh`
3. Make executable: `chmod +x 01-fetch-offline-content.sh`

### Option 2: Side-by-Side Testing
1. Test refactored version: `./scripts/01-fetch-offline-content-REFACTORED.sh`
2. Compare results with old version
3. When satisfied, replace as in Option 1

### What to Test
- [ ] Fresh container creation (RECREATE_CONTAINER=1)
- [ ] Reusing stopped container
- [ ] EPEL package fetch
- [ ] RPM Fusion package fetch
- [ ] Python wheels
- [ ] Offline dependency check
- [ ] Metadata refresh behavior (run twice within 6 hours, verify only first run refreshes)

## Files Affected

### Modified
- `scripts/01-fetch-offline-content.sh` (refactored)

### Can Be Deprecated (Logic Moved Inline)
- `scripts/lib/ensure-container.sh` — container setup logic moved to main script
- `scripts/lib/reposync.sh` — reposync logic moved inline
- `scripts/lib/fetch-epel.sh` — EPEL fetch moved inline
- `scripts/lib/fetch-rpmfusion.sh` — RPM Fusion fetch moved inline

### Still Used
- `scripts/lib/fetch-python-wheels.sh` — runs on build host, no container calls
- `scripts/lib/check-offline-deps.sh` — verification logic, kept separate
- `scripts/lib/generate-kickstart.sh` — used by script 02
- `scripts/lib/inject-kickstart.sh` — used by script 02
- `scripts/lib/rebuild-offline-repodata.sh` — standalone utility

## Performance Comparison

### Before (Separate Calls)
```
1. dnf install dnf-plugins-core yum-utils createrepo_c rsync findutils
2. dnf install epel-release
3. dnf install epel-release  (duplicate check, possibly skipped)
4. dnf install rpmfusion-free-release
5. dnf install rpmfusion-nonfree-release
```
Each call triggers:
- Repository metadata load
- Dependency resolution
- Transaction check
- Installation

### After (Single Call)
```
1. dnf install dnf-plugins-core yum-utils createrepo_c rsync findutils \
               epel-release rpmfusion-free-release rpmfusion-nonfree-release
```
One transaction:
- Repository metadata loaded once
- Dependencies resolved together
- Single transaction check
- All packages installed in one pass

**Estimated time savings: 30-60 seconds on repeated runs**

## Rollback

If issues arise:

```bash
# Restore old version
mv 01-fetch-offline-content-OLD.sh 01-fetch-offline-content.sh

# Or start fresh
RECREATE_CONTAINER=1 ./scripts/01-fetch-offline-content.sh
```

## Future Enhancements

Potential additional optimizations:

1. **Parallel downloads**: Use `dnf -y install --downloadonly` followed by parallel `dnf download` for EPEL/Fusion
2. **Delta RPMs**: Enable drpms for incremental updates
3. **Cache layer**: Add a `.cached-packages` marker to skip re-downloading unchanged RPMs
4. **Progress bars**: Add visual feedback for long-running operations

## Questions?

- Old behavior preserved? **Yes** - all existing flags and env vars work
- Breaking changes? **No** - fully backward compatible
- Performance impact? **Positive** - faster, fewer redundant operations
- New dependencies? **No** - uses same tools as before
