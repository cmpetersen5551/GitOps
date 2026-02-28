# Options Status Summary — What's Been Tried, What Remains

**Date**: 2026-02-28  
**Purpose**: Quick reference showing which alternatives have been explored and why they were eliminated.

---

## Timeline of Approaches (Feb 2026)

```
EA96938  ❌ kubelet-level NFS volume mounts
  └─ Issue: kubelet uses host DNS, doesn't resolve ClusterIP
  
275e46f  ❌ Raw ClusterIP for kubelet NFS
  └─ Issue: kube-proxy IPs don't work in host network namespace

7FF8B89  ❌ Fix NFS export path (rclone serve nfs /mnt/dfs exports as /)
  └─ Made some progress but still fundamentally broken

8D10195  ⚠️ In-pod dfs-mounter sidecar with emptyDir mount propagation
  └─ Architectural idea good, but ran into peer group isolation

82695f8  ⚠️ Attempt privileged capability for Bidirectional propagation
  └─ Didn't solve the deeper peer group issue

C24819C  ❌ memory-backed emptyDir (per Kubernetes docs)
  └─ FAILED in practice: kubelet creates separate peer groups per container anyway
  └─ Confirmed by inspecting /proc/PID/mountinfo: peer group 549 vs 303 disconnected

6FC2751  ✅ Colocate rclone in SAME container as Decypharr
  └─ SUCCESS: Same mount namespace = no propagation needed
  └─ rclone serve nfs works here

7E0DBF4+ ⚠️ Extensive NFS mount option iterations (25+ commits)
  └─ ISSUE: emptyDir sidecar + NFS deadlock observed (later understood as peer group limitation, not NFS bug)
  └─ Also discovered: `mountpoint -q` false-positive on emptyDir creates tmpfs

6762381  ❌ Pivot to SFTP + sshfs client
  └─ CRITICAL DISCOVERY: sshfs is FUSE-based!
  └─ Recreates the original peer group propagation problem
  └─ sshfs FUSE mount in sidecar never appeared in main container

767D937  ❌ Switch to CIFS in DaemonSet (rclone serve smb doesn't exist in v1.73.1)
  └─ rclone v1.73.1 has NO serve smb subcommand
  └─ Immediately abandoned (next commit)

EDD0D35  ⚠️ Switch back to NFS but use DaemonSet architecture instead of sidecars
  └─ DaemonSet runs on each host, not per container
  └─ mount -t nfs (kernel mount, not FUSE!) ← This is the key insight
  └─ Propagates through hostPath correctly
  └─ WORKS! But...

(Next 25 commits) ⚠️ NFS DaemonSet works until Feb 25, then issues surface
  └─ mount detection bugs (mountpoint -q false-positive on hostPath)
  └─ NFS option tuning attempts

2026-02-26  ✅ PIVOT to SMB/CIFS DaemonSet
  └─ CIFS kernel client has automatic server reconnect (NFS doesn't)
  └─ NFS soft mounts become permanently stale when server restarts
  └─ CIFS solves the stale mount problem
  └─ Commits: `767d937` → `edd0d35` → actual CIFS deployment

2026-02-28  🔧 Add LD_PRELOAD nlink shim to Samba
  └─ Samba treating st_nlink=0 as deleted inode
  └─ Fix: patch stat() syscalls to set st_nlink=2 (dirs) or 1 (files)
  └─ Commits: `64f462b`, extended to files in later commit
  └─ WORKING SOLUTION ✅
```

---

## All Alternatives Evaluated

### By Status

#### ❌ Ruled Out Completely (Won't Revisit)

| Option | Attempted | Reason | Impact |
|--------|-----------|--------|--------|
| **Kubelet-level NFS** | ✅ Yes (Feb) | DNS + IP namespace issues (unfixable in k8s) | Couldn't mount at all |
| **Direct hostPath FUSE propagation** | ✅ Yes (early Feb) | FUSE mounts don't propagate through container peer groups (fundamental k8s limitation) | No data access |
| **EmptyDir sidecar + rclone NFS** | ✅ Yes (Feb) | Peer group isolation (kubelet creates separate peer groups per container) | Empty mount on sidecar |
| **Memory-backed emptyDir** | ✅ Yes (Feb) | Same peer group issue despite Kubernetes docs suggesting it should work | Confirmed with /proc/mountinfo |
| **SFTP + sshfs** | ✅ Yes (Feb) | sshfs is FUSE → recreates peer group problem | Was trying to escape FUSE but reintroduced it |
| **SeaweedFS CSI + decypharr** | ✅ Researched (archived) | CSI drivers provision volumes but don't solve FUSE sharing between pods | Doesn't apply to our problem |
| **Zurg + Unraid** | ❌ Not tried (user constraint) | User committed to Decypharr; also Unraid SPOF | Ruled out by requirements |
| **STRM files only** | ❌ Not viable | Plex doesn't reliably support .strm files; loses byte-access for GPU transcode | Not compatible with Plex |

#### ⚠️ Worked But Abandoned

| Option | Attempted | Result | Why Abandoned |
|--------|-----------|--------|---------------|
| **NFS DaemonSet** | ✅ Yes (Feb 25-26) | ✅ Worked (rclone serve nfs + kernel NFS client) | NFS soft mounts become permanently stale when server (decypharr pod) restarts; requires pod restart to recover; unacceptable for Plex |

#### ✅ Current Solution

| Option | Status | Details |
|--------|--------|---------|
| **CIFS DaemonSet** | ✅ **In Production** | Deployed Feb 26, 2026. CIFS has automatic server reconnect (solves NFS stale mount problem). Requires LD_PRELOAD shim for st_nlink=0 bug. |

#### ❓ Not Yet Explored (Still Viable)

| Option | Category | Complexity | Timeline | Notes |
|--------|----------|-----------|----------|-------|
| **Option D: Fix go-fuse upstream** | Root cause fix | Medium | 2-4 weeks | PR to hanwen/go-fuse to report correct st_nlink. Would eliminate LD_PRELOAD shim. Recommended next step. |
| **Option E: Decypharr CSI Driver** | Rearchitecture | Very High | 2-3 weeks prototype | Would be Kubernetes-native, scalable to many apps. Overkill for 2-3 apps. Consider if scaling to 5+. |
| **Option F: WebDAV export** | Alternative protocol | Medium | 1-2 weeks test | Different protocol layer (HTTP vs SMB). Might bypass st_nlink issue. Performance lower than kernel mounts. Unproven with Plex. |
| **Option G: Patch Samba directly** | Workaround | Low | 2-3 hours | Build Samba with custom patch instead of LD_PRELOAD. Not recommended (LD_PRELOAD is simpler). |

---

## Key Technical Insights (Learned the Hard Way)

### 1. FUSE vs. Kernel VFS Mounts
- **FUSE mounts** (`sshfs`, `s3fs`, `goofys`, `go-fuse`) — Do NOT propagate through Kubernetes container mount peer groups
- **Kernel VFS mounts** (`mount -t nfs`, `mount -t cifs`, `mount -t ext4`) — Propagate correctly through `hostPath: Bidirectional`

**This is why NFS and CIFS DaemonSet approaches work but sidecar approaches don't.**

### 2. Kubernetes Mount Propagation Reality
- Kubernetes docs recommend `emptyDir: {medium: Memory}` (tmpfs) for Bidirectional propagation
- In practice: `kubelet` creates **separate bind-mounts** for each container of the same tmpfs
- Each bind-mount lands in a different mount peer group (ID 549 vs 303 observed)
- **FUSE mounts don't cross peer group boundaries**, so propagation fails
- This is a fundamental k8s design, not a configuration error

### 3. Mount Detection Bug
- `mountpoint -q /mnt/dfs` on a `hostPath` volume is ALWAYS true
- hostPath volumes are kernel mountpoints themselves
- For accurate "is my desired filesystem mounted", use: `grep -q 'specific-fs-identifier /mnt/dfs' /proc/mounts`

### 4. NFS Soft Mount Stale State
- When NFS server disappears (pod restart), kernel marks mount as broken  
- Any I/O returns `ESTALE` immediately
- Retry logic doesn't reconnect; mount is permanently broken
- Only fix: `umount` + `mount` again (pod restart in k8s context)
- SMB/CIFS auto-reconnects; no pod restart needed

### 5. rclone serve smb Doesn't Exist
- `rclone serve` subcommands: dlna, docker, ftp, http, **nfs**, restic, s3, sftp, webdav
- NO `serve smb` — this is a community request, not implemented in official rclone
- Initially assumed it existed (commit 767d937), immediately abandoned (commit edd0d35)

### 6. Samba's st_nlink=0 Semantics
- Samba 4.x treats st_nlink=0 as an **unlinked/deleted inode marker**
- Not just a file metadata field; it's inode deletion state
- Any inode (file or directory) with st_nlink=0 returns `NT_STATUS_OBJECT_NAME_NOT_FOUND` at the SMB protocol level
- This is Samba-specific behavior (not part of SMB spec), triggered by FUSE returning st_nlink=0

---

## Lessons for Future Storage/FUSE Work

1. **Always verify if a filesystem is FUSE or kernel-based before choosing it**
   - `sshfs` is FUSE (learned the hard way at attempt 6)
   - `davfs` is FUSE (if you try WebDAV approach)
   - `s3fs`, `goofys`, most userspace filesystems are FUSE

2. **FUSE + Kubernetes + mount propagation = architectural mismatch**
   - Don't try to share FUSE mounts between containers
   - Re-export FUSE as a network protocol (NFS, SMB, WebDAV) instead
   - Use kernel mounts to access the re-export

3. **NFS soft mounts have stale state issues; CIFS auto-reconnects**
   - If you need reliability during server restarts, use CIFS/SMB
   - NFS is simpler infrastructure (no Samba), but operationally more fragile

4. **Test mount detection scripts carefully**
   - `mountpoint -q` is not reliable on hostPath volumes
   - Use `grep /proc/mounts` to detect specific filesystem types
   - Test in actual container environment, not just bash

5. **When making Samba workarounds, document the root cause**
   - The st_nlink=0 issue is go-fuse-specific, not a general Samba limitation
   - If fixed upstream, the workaround becomes unnecessary

---

## What Would Happen If You Revisited Each Option Now (Feb 28)

### Option A: Try Direct hostPath FUSE Again
**Outcome**: Same failure as early February. FUSE propagation through container mount namespaces is fundamentally broken in Kubernetes. No new insights would change this.

**Not recommended**: Don't waste time retrying.

### Option B: Switch Back to NFS (without fixes)
**Outcome**: Same as Feb 25. NFS DaemonSet works until decypharr pod restarts, then Sonarr/Radarr get `ESTALE` errors and need to restart. Plex mid-stream pause + restart = session lost.

**Not recommended**: CIFS solves this problem better.

### Option C: Revisit SeaweedFS CSI
**Outcome**: SeaweedFS CSI is for distribu proofs, not FUSE sharing. You'd still have the problem of how Decypharr shares its FUSE with other pods.

**Not recommended**: Wrong tool for this job.

### Option D: Fix go-fuse (UP STR EAM)
**Outcome**: ✅ Viable. Could eliminate LD_PRELOAD shim. Worth trying.

**Recommended**: Open PR with hanwen/go-fuse maintainers.

### Option E: Build a CSI Driver
**Outcome**: ✅ Viable if you scale. Would be clean, Kubernetes-native. But overkill for 2-3 apps.

**Recommended**: Only if you add 5+ RealDebrid-dependent apps.

### Option F: WebDAV
**Outcome**: ❓ Unknown. Different protocol might avoid st_nlink issues, but performance trade-offs. Unproven with Plex symlinks.

**Recommended**: Low priority; CIFS + fix go-fuse is better path forward.

---

## Decision Framework (Updated)

**If you want to keep status quo**: ✅ Current SMB/CIFS is stable. Monitor for go-fuse upstream fix.

**If you want to remove C shim**: → **Option D** (Fix go-fuse, 2-4 week timeline)

**If you want long-term cleanliness**: → **Option D** (upstream), then **Option E** if you scale beyond 3 apps

**If you want "Kubernetes-native" today**: → **Option E** (CSI), but high implementation cost

**If you want to prove concept of alternatives**: → Test **Option F** (WebDAV) in staging, but don't roll to production unless it's dramatically better

---

## Recommendation Summary

✅ **Current approach (SMB/CIFS + LD_PRELOAD) is the right choice.**

**Keep it and**:
1. Test HA failover + CIFS auto-reconnect behavior (1-2 hours)
2. Research go-fuse upstream (1-2 hours)
3. Open PR with hanwen/go-fuse if issue not already reported (4 hours)
4. Once merged, remove LD_PRELOAD shim (1-2 hours)

**Don't**:
- ❌ Try direct hostPath FUSE again (won't work)
- ❌ Switch back to NFS (CIFS is better)
- ❌ Rush to CSI driver (overkill for 2-3 apps)
- ❌ Build SMB from scratch (rclone has no serve smb; use samba package instead)

---

**Last Updated**: 2026-02-28  
**Status**: All viable paths identified; current approach validated
