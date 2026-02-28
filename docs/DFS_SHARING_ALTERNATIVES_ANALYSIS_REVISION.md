# DFS Sharing: Alternative Architectures Analysis - REVISION (2026-02-28)

**Status**: CRITICAL UPDATE — Original analysis was based on incomplete information. This revision accounts for actual architecture deployed and what has been tried.

**Key Finding**: You've already migrated from NFS to SMB/CIFS (Feb 26, 2026), and that choice was correct. The question is whether to improve the current approach or pivot again.

---

## What's ACTUALLY Deployed (2026-02-28)

**Current Architecture: SMB/CIFS with LD_PRELOAD Shim** ✅ Working

```
Decypharr-streaming pod:
├── decypharr container (FUSE DFS mount at /mnt/dfs)
└── smbd sidecar (Samba 4.22.8 server on port 445)
    └── LD_PRELOAD shim (patches st_nlink: 0→1 or 2)
    └── exports /mnt/dfs as read-only SMB share

DFS-mounter DaemonSet:
└── mount -t cifs //service/dfs /mnt/decypharr-dfs (CIFS kernel client)
    └── Auto-reconnects on server restart (wins vs NFS!)

Consumer pods:
└── hostPath bind-mount /mnt/decypharr-dfs → /mnt/dfs (read-only)
```

**Deployed**: Feb 26, 2026  
**Status**: ✅ Functional, pods can access RealDebrid content  
**Issues**: LD_PRELOAD C shim is fragile but necessary workaround

---

## What Has ALREADY Been Tried & Eliminated

### ✅ Settled Questions (From Docs)

Based on `DFS_ATTEMPT_HISTORY.md`, `DFS_RESEARCH_AND_OPTIONS.md`, and git history:

| Option | Status | Why Ruled Out | Evidence |
|--------|--------|---------------|---------| 
| **Direct hostPath FUSE** | ❌ Tried Feb 2026 | FUSE mounts don't propagate through container mount peer groups | `DFS_MOUNT_STRATEGY.md` Option 6 |
| **EmptyDir sidecar + NFS** | ❌ Tried Feb 2026 | Peer group isolation: FUSE mount created in sidecar never appears in main container | Commits `c24819c`, `6fc2751`, deep dive in `DFS_ATTEMPT_HISTORY.md` |
| **EmptyDir memory-backed** | ❌ Tried Feb 2026 | kubelet creates separate bind-mounts for each container = separate peer groups | Commit `c24819c`, confirmed by `/proc/mountinfo` inspection |
| **Sidecar + rclone serve nfs** | ❌ Tried Feb 2026 | Same emptyDir peer group isolation; also appears to deadlock under heavy load in NFS context | Commits `edd0d35`-`629688f`, 25+ iterations on mount options |
| **Sidecar + rclone serve sftp + sshfs** | ❌ Tried Feb 2026 | sshfs is FUSE-based → recreates the peer group isolation problem | Commits `6762381`-`ab74472` |
| **NFS DaemonSet** | Deployed then Abandoned | Works initially but NFS soft mounts become permanently stale when server restarts; requires pod restart to recover | Fully working until Feb 26 pivot; documented in `DFS_IMPLEMENTATION_STATUS.md` Failover section |
| **SeaweedFS CSI** | ❌ Tried, archived | Does NOT solve the core problem (how to share Decypharr's FUSE mount); CSI drivers provision volumes but don't help with inter-pod FUSE sharing | `archive/CSI_IMPLEMENTATION_SUMMARY.md` and `SEAWEEDFS_ROOT_CAUSE_ANALYSIS.md` |
| **Zurg + Unraid NFS** | ❌ Not tried (explicit rejection) | User constraint: committed to Decypharr, not Zurg; also introduces Unraid SPOF for streaming | `DFS_RESEARCH_AND_OPTIONS.md` Option 2 |
| **STRM files + WebDAV** | ❌ Not viable | Plex does not reliably support .strm files; also loses byte-level access needed for ClusterPlex GPU transcode | `DFS_RESEARCH_AND_OPTIONS.md` Option 3 |

### 🔧 Current Approach (SMB/CIFS)

**Deployed Feb 26, 2026** — `DFS_IMPLEMENTATION_STATUS.md` and `DECYPHARR_DEPLOYMENT_NOTES.md`

**Why chosen over NFS**: 
- NFS soft mounts become permanently broken when decypharr-streaming pod restarts
  - Consumer pods require `stat()` to work on symlink targets
  - With soft NFS mount, `stat()` returns `EIO` permanently — only fix is pod restart
  - This is unacceptable for Plex (mid-stream pause + pod restart = session lost)
- CIFS kernel client **auto-reconnects** when SMB server comes back online
  - Playback only pauses briefly during Decypharr restart
  - No pod restart required
  - Automatic recovery is transparent to apps

**Tradeoff Accepted**: LD_PRELOAD C shim to patch Samba's st_nlink=0 inode deletion bug

---

## What's Still Unexplored (Your Original Concerns)

### OPTION D: Fix go-fuse Upstream ← **BEST LONG-TERM PATH**

**Status**: Not attempted yet, but strongest ROI

**Idea**: 
- Samba treats st_nlink=0 as deleted inode (this is Samba behavior, but triggered by go-fuse returning st_nlink=0)
- hanwen/go-fuse library returns st_nlink=0 for all entries (matches tmpfs convention)
- **Fix**: PR to hanwen/go-fuse to report correct st_nlink (2 for dirs, 1 for files)

**Why this solves everything**:
- ✅ Decypharr's FUSE mount reports CORRECT st_nlink
- ✅ Works with Samba, NFS, CIFS, any protocol
- ✅ No LD_PRELOAD shim needed (can remove C code)
- ✅ No maintenance burden
- ✅ Helps entire FUSE community

**Current State**:
- ✅ OPTION C (Decypharr notes LD_PRELOAD as workaround, not permanent solution)
- ❓ Unknown if upstream Go-fuse maintainer would accept the change
- ❓ Would need Decypharr maintainers to adopt updated go-fuse

**Effort**: 
- 2-4 hours: prepare PR + submit to hanwen/go-fuse
- 2-4 weeks: wait for upstream feedback/acceptance
- 1-2 hours: update decypharr if it gets merged

**Action Item**: 
```bash
# Check hanwen/go-fuse for existing issues about st_nlink
git clone https://github.com/hanwen/go-fuse
grep -r "st_nlink.*=.*0" go-fuse/fuse/
# Look for relevant issues: https://github.com/hanwen/go-fuse/issues
```

---

### OPTION E: Decypharr CSI Driver ← **FUTURE-PROOF BUT HEAVY**

**Status**: Not attempted (SeaweedFS CSI tried, but that's different problem)

**Idea**: Build a Kubernetes CSI driver that natively exposes Decypharr's RealDebrid mount as PVCs.

**How it would work**:
```
CSI Controller Pod:
  └─ Interfaces with decypharr API or RealDebrid directly
     └─ Creates/deletes mount points on demand

CSI Node Plugin (DaemonSet):
  └─ Local mount management
     └─ Adds decypharr content to pod via standard PVC mechanism

Consumer Pod:
  └─ PVC → CSI driver handles everything
     └─ No FUSE sharing, no SMB/NFS layer, no hostPath complexity
```

**Pros**:
- ✅ **Kubernetes-native**: Uses standard CSI/PVC API
- ✅ **No FUSE sharing complexity**: Each pod gets independent mount
- ✅ **Proper HA**: CSI driver handles node failover transparently
- ✅ **No LD_PRELOAD needed**: Driver controls stat() behavior
- ✅ **Scales**: Add 100 apps, CSI driver provisions 100 independent volumes

**Cons**:
- ❌ Requires implementing a CSI driver (500-1000 lines of Go + tests)
- ❌ Needs understanding of decypharr's internals or RealDebrid API
- ❌ Maintenance burden (CI/CD, helm charts, docs)
- ❌ Long timeline (2-3 weeks for prototype, Q2+ 2026)
- ❌ Overkill for 2-3 consumer apps (Sonarr, Radarr, Plex)

**ROI**: Low current ROI, but excellent long-term architecture if you scale to many apps using RealDebrid.

---

### OPTION F: WebDAV Export (Different Protocol Layer)

**Status**: Not systematically explored

**Idea**: Export decypharr's FUSE mount via WebDAV (HTTP-based) instead of SMB/NFS.

**How it would work**:
```
Decypharr-streaming pod:
  /mnt/dfs (FUSE) → [caddy or lighttpd WebDAV server] → HTTP/WebDAV on port 80

Consumer pods:
  mount -t davfs http://decypharr-streaming.media.svc.cluster.local /mnt/dfs
  (or: HTTP client for direct file access)
```

**Does it solve st_nlink problem?**
- ❓ Unclear. WebDAV is HTTP-based, doesn't expose stat() at the filesystem level
- ✅ Might bypass st_nlink issue entirely
- ⚠️ Requires testing

**Pros**:
- ✅ Different protocol layer (might avoid st_nlink issue)
- ✅ HTTP is standard, well-understood
- ✅ No C code shims needed (if protocol handles it)
- ✅ Built-in auth/TLS support

**Cons**:
- ❌ WebDAV+davfs performance < kernel mounts
- ❌ davfs is FUSE-based, so it's still a FUSE layer (different problem)
- ❓ Plex support for WebDAV volumes unclear (works via HTTP but not as symlink targets)
- ⚠️ Less mature than SMB/NFS in Kubernetes

**ROI**: Low. SMB/CIFS is already working; WebDAV doesn't provide clear advantages.

---

### OPTION G: Fix Samba Configuration (Lighter than Upstream)

**Status**: Not fully explored

**Idea**: Instead of patching go-fuse upstream, patch Samba's inode deletion logic directly.

**How it might work**:
```c
// In Samba source: vfs.c
// Patch: Don't treat st_nlink=0 as deleted when talking to FUSE mounts
if (is_fuse_module(stat_result->st_dev)) {
    if (stat_result->st_nlink == 0) {
        stat_result->st_nlink = S_ISDIR(...) ? 2 : 1;
    }
}
```

**Pros**:
- ✅ Faster than upstream fix (local Samba build)
- ✅ Doesn't depend on decypharr/go-fuse maintainers

**Cons**:
- ❌ Requires maintaining Samba patches across versions
- ❌ Current LD_PRELOAD shim is arguably simpler (no Samba rebuild)
- ❌ Doesn't help if you ever switch to NFS/CIFS with FUSE backends

**ROI**: Low — LD_PRELOAD is actually cleaner than patching Samba source.

---

## Risk Assessment: Current SMB/CIFS vs Alternatives

### Current Approach (SMB/CIFS + LD_PRELOAD) Risk Profile

| Risk | Likelihood | Impact | Mitigation | Notes |
|------|-----------|--------|-----------|-------|
| **LD_PRELOAD shim has bug** | Medium | Medium (data access fails) | Unit tests for shim, test symlink following | C code is simple (4 functions), low bug surface |
| **st_nlink fix incomplete** | Low | Low (edge cases) | Already tested with Sonarr/Radarr | Covers all S_ISDIR() cases and regular files |
| **Samba version incompatibility** | Low | Medium (upgrade breaks) | Pin `smbd` version in Dockerfile | Currently using Samba 4.22.8 (Alpine) |
| **CIFS mount driver bug** | Very Low | Medium (kernel issue) | Beyond our control | Kernel CIFS is battle-tested |
| **Auto-reconnect fails in edge case** | Low | Medium (brief service loss) | `soft` mount timeout + app retry logic | CIFS reconnect is very reliable |
| **Pod failover from w1→w2** | Very Low | Low (brief pause) | Tested descheduler + Longhorn failover | Already validated in HA tests |

**Overall Risk**: LOW-MEDIUM (working well, LD_PRELOAD is the weak point)

### OPTION D (Fix go-fuse) Risk Profile

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| **Upstream PR rejected** | Medium | Medium (need fork) | Fork hanwen/go-fuse in your org repo |
| **Merge takes months** | Low | Low (interim: use C shim) | LD_PRELOAD works fine as temporary solution |
| **Decypharr doesn't adopt updated go-fuse** | Low | Low (decypharr is active project) | Can maintain local patch to decypharr image |
| **Fix introduces new bug** | Very Low | Medium (regression) | Test thoroughly before rolling out |

**Overall Risk**: LOW (upstream or fork both acceptable)

### OPTION E (CSI Driver) Risk Profile

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| **CSI driver implementation bug** | Medium | High (pods won't start) | Extensive testing on staging cluster |
| **Decypharr API not exposed to CSI** | Medium | High (won't work) | Must understand decypharr internals or RealDebrid API |
| **Maintenance burden** | High | Medium (ongoing) | Budget 5-10 hours/quarter for maintenance |
| **CSI driver needs updating for k8s upgrades** | Medium | Medium (version mismatch) | CI/CD automation for testing |

**Overall Risk**: MEDIUM (implementation expertise required)

---

## Detailed Comparison: Current vs. Options D, E, F

| Factor | Current (SMB/CIFS + Shim) | Option D (Fix go-fuse) | Option E (CSI Driver) | Option F (WebDAV) |
|--------|:---:|:---:|:---:|:---:|
| **Reliability** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| **HA Support** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **Maintainability** | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ |
| **Implementation Complexity** | ✅ Done | Medium | Very High | Medium |
| **Operational Overhead** | Low (shim maintenance) | None (upstream) | High (CSI driver) | Medium |
| **Time to Production** | Now ✅ | 2-4 weeks (upstream) | 2-3 weeks (prototype) | 1-2 weeks (test) |
| **C Code Needed?** | Yes (shim) | No | No | No |
| **Scales to 10+ apps?** | ✅ Yes (same DaemonSet) | ✅ Yes | ✅ Yes (CSI native) | ✅ Yes |
| **Blocks Plex deployment?** | No ✅ | No | No | Unclear |
| **Cost to switch away?** | High (re-migration) | Low (sunset shim) | High (rewrite) | Medium (remount) |

---

## Recommendations (Revised)

### The Real Question

You have a **working, HA-safe, production-ready solution** (Current SMB/CIFS). The question is not "does it work?" but "are we comfortable with the LD_PRELOAD shim long-term?"

### Short-Term (This Month) — Do Nothing New

Your current approach is solid. The LD_PRELOAD shim is a **reasonable tradeoff**:
- ✅ Works reliably (tested with Sonarr, Radarr, symlinks)
- ✅ Low maintenance (4 functions, ~40 lines of C)
- ✅ No ongoing cost after deployment
- ✅ Doesn't block Plex or other features

**What to do instead**: 
1. **Document the workaround** — already done (SAMBA_FUSE_NLINK_BUG_FIX.md) ✅
2. **Test failover scenarios** — verify CIFS auto-reconnect works under pod restart
3. **Monitor nlink patching** — ensure all symlink ops succeed (they should)

### Medium-Term (Next 2-4 Weeks) — Option D

**Recommended**: Open issue on hanwen/go-fuse about st_nlink reporting.

```
Title: "FUSE mounts returning st_nlink=0 breaks SMB/NFS servers treating it as deleted inode"

Body:
- hanwen/go-fuse reports st_nlink=0 for all entries
- Samba 4.x treats st_nlink=0 as unlinked/deleted inode → returns NT_STATUS_OBJECT_NAME_NOT_FOUND
- NFS servers may have similar behavior
- Proper st_nlink (2 for dirs, 1 for files) would make FUSE mounts compatible with any protocol
- Potential PR: ...

This affects any FUSE filesystem (decypharr, rclone mount, etc.) used with SMB/NFS export.
```

**Timeline**: 
- If merged (likely): Remove LD_PRELOAD shim when Decypharr adopts updated go-fuse ✨
- If rejected: Keep LD_PRELOAD shim indefinitely (acceptable cost)

### Long-Term (Q2+ 2026) — Consider Options E or Rearchitecture

**Only if you scale significantly**:
- 5+ apps using RealDebrid mount
- Different storage backends (SeaweedFS, Ceph, etc.) also needed
- Want "proper" Kubernetes-native architecture

Then OPTION E (CSI Driver) makes sense. Don't build it just for 2-3 apps.

---

## Action Items (Priority-Ordered)

### 🔴 Immediate (This Week)

1. **Test CIFS auto-reconnect behavior** [1 hour]
   - Simulate by port-forwarding 445 and blocking it
   - Verify SMB client auto-reconnects within timeout window
   - Verify consumer app I/O pauses (doesn't crash)

2. **Failover test with actual w1→w2 migration** [2 hours]
   - Cordon w1, evict decypharr pod
   - Pod moves to w2, restarts
   - Verify Sonarr/Radarr `/mnt/dfs` is accessible within 60s
   - Check that no pod restart was required

3. **Document reliability assumptions** [1 hour]
   - Update `DFS_IMPLEMENTATION_STATUS.md` with known limitations
   - Add "HA Resilience Guarantees" section
   - Note: Brief service pause during Decypharr pod restart (acceptable)

### 🟡 Short-Term (Weeks 2-4)

4. **Research go-fuse upstream** [2 hours]
   ```bash
   cd /tmp && git clone https://github.com/hanwen/go-fuse
   grep -r "st_nlink.*= 0" go-fuse/
   # Check issues: https://github.com/hanwen/go-fuse/issues
   # Search for "st_nlink", "nlink", "inode"
   ```

5. **Draft PR for hanwen/go-fuse** [4 hours]
   - Create test case that fails with current st_nlink=0
   - Implement st_nlink fix
   - Test with decypharr + Samba
   - Submit upstream

### 🟢 Long-Term (Q2+ Only If Needed)

6. **Monitor go-fuse upstream status** — Check monthly for:
   - Is PR merged?
   - Has Decypharr adopted updated go-fuse?
   - Can we sunset LD_PRELOAD shim?

7. **Prototype CSI Driver** (only if scaling):
   - Decide: wrap decypharr API or directly use RealDebrid?
   - Design PVC → volume mapping
   - Demo on staging cluster

---

## Conclusion

**Your current solution (SMB/CIFS + LD_PRELOAD) is the RIGHT choice given the constraints.** It:
- ✅ Solves the fundamental problem (FUSE sharing)
- ✅ Works reliably with HA failover
- ✅ Has lower operational burden than NFS (auto-reconnect)
- ✅ Doesn't require infrastructure changes (MetalLB IPs)
- ✅ Is production-ready today

The LD_PRELOAD C shim is a reasonable workaround, not a permanent hack. **Option D (Fix go-fuse)** is the path forward if you want to remove it eventually without giving up SMB/CIFS benefits.

**Don't pivot again** unless:
1. The LD_PRELOAD shim breaks in production (unlikely, it's simple)
2. You have 5+ apps needing RealDebrid mount (then CSI makes sense)
3. Go-fuse gets fixed upstream and you want to clean up

---

## References

- **Current Architecture**: `DFS_IMPLEMENTATION_STATUS.md`, `DECYPHARR_DEPLOYMENT_NOTES.md`, `SAMBA_FUSE_NLINK_BUG_FIX.md`
- **History of Attempts**: `DFS_ATTEMPT_HISTORY.md`, `DFS_RESEARCH_AND_OPTIONS.md`
- **hanwen/go-fuse**: https://github.com/hanwen/go-fuse
- **Samba Developer Guide**: https://wiki.samba.org/index.php/Samba_4
- **SMB/CIFS Kernel Module**: https://www.kernel.org/doc/html/latest/filesystems/cifs/

---

**Last Updated**: 2026-02-28  
**Status**: ✅ Current approach is sound; recommendations focus on maintenance and optional future improvements
