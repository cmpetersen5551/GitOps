# DFS Mount Sharing: Alternative Architectures Analysis (2026-02-28)

**Status**: Research document — comprehensive comparison of approaches to share decypharr's FUSE mount across pods with HA support

**Goal**: Evaluate alternatives to current SMB/LD_PRELOAD shim architecture and identify paths to improve reliability, maintainability, and consistency for 2-node HA cluster.

---

## Current Architecture Concerns

### What's Working
✅ **Functionally complete**: Sonarr, Radarr, Plex can access RealDebrid content via symlinks  
✅ **HA-aware**: Pod failover w1→w2 works (Longhorn volume reattaches, descheduler brings back)  
✅ **Resilient**: CIFS kernel client auto-reconnects if SMB service restarts  

### What's Worrying

| Concern | Impact | Severity |
|---------|--------|----------|
| **LD_PRELOAD C code shim** | Maintenance burden, fragility, syscall patching is fragile | Medium |
| **Layering complexity** | FUSE → Samba → CIFS → hostPath → consumers (4 layers!) | Medium |
| **Mount propagation brittle** | Host requires manual `--make-shared` setup on `/mnt`; if reverted, mount breaks | Medium-High |
| **Potential stat() inconsistency** | C shim patches only SMB layer; other tools (strace, etc.) see wrong st_nlink | Low-Medium |
| **DFS-Mounter daemonset** | Extra pods running everywhere; if CIFS mount fails, hard to debug | Low |
| **Service dependency chain** | Consumer pods depend on decypharr pod before DFS-mounter mounts; brief outages during pod restart | Low-Medium |

### Reliability/Consistency Questions

1. **What if a pod restarts while consumer is still reading a symlink?** 
   - Symlink target becomes unavailable, app gets I/O error
   - CIFS should handle this gracefully with soft mount, but...
   
2. **What about cross-pod file consistency?**
   - If Sonarr creates a symlink on w1, and reads it from w2 via CIFS mount, is stat() consistent?
   - Current setup: works, but depends on CIFS caching and mount options

3. **Does st_nlink=1 (via shim) survive all layers?**
   - LD_PRELOAD patches Samba's stat calls
   - But what about other syscalls or tools that check metadata directly?
   - Current evidence: works for Sonarr/Radarr symlink following, but fragile

4. **What happens during network blip on DFS-mounter?**
   - CIFS mount becomes "soft" and fails-fast
   - Consumer app sees I/O error, either retries or fails
   - Not ideal; tools designed for NFS assume "hard" mounts won't fail

---

## Architecture Overview: Layering

```
Current Stack (FUSE→SMB→CIFS):
┌─────────────────────────────────────────────────────────────────┐
│  decypharr-streaming pod (FUSE + Samba + LD_PRELOAD shim)      │
│                                                                 │
│  /mnt/dfs (FUSE mount)                                          │
│    ↓ [stat() → st_nlink=0]                                      │
│  LD_PRELOAD shim [patches st_nlink → 1 or 2]                   │
│    ↓                                                             │
│  smbd (Samba) [exports as SMB share]                            │
└─────────────────────────────────────────────────────────────────┘
         ↓ SMB protocol (port 445)
┌─────────────────────────────────────────────────────────────────┐
│  dfs-mounter daemonset (CIFS kernel client)                     │
│                                                                 │
│  mount -t cifs //service/dfs /mnt/decypharr-dfs                │
│    ↓ [CIFS mount point]                                         │
│  hostPath with Bidirectional propagation                        │
└─────────────────────────────────────────────────────────────────┘
         ↓ host kernel (mount namespace propagation)
┌─────────────────────────────────────────────────────────────────┐
│  consumer pods (Sonarr, Radarr, Plex)                           │
│                                                                 │
│  hostPath bind-mount from /mnt/decypharr-dfs → /mnt/dfs        │
│    ↓                                                             │
│  Symlink following, stat() calls, etc.                          │
└─────────────────────────────────────────────────────────────────┘

⚠️ Every layer adds potential for inconsistency or failure points
```

---

## Alternative Architectures

### OPTION A: Direct hostPath (Skip SMB/CIFS Layer)

**Idea**: Mount FUSE directly from decypharr pod to host, then bind-mount to consumer pods via hostPath — **no SMB/Samba/CIFS intermediate layer**.

```
decypharr-streaming pod:
  /mnt/dfs (FUSE mount) → [hostPath: Bidirectional]

Host kernel:
  /mnt/decypharr-dfs (FUSE mount from pod)

Consumer pods:
  hostPath bind-mount /mnt/decypharr-dfs → /mnt/dfs (read-only)
```

**Why this might work now** (when it failed before):
- Earlier attempts suffered from mount namespace isolation between containers
- But decypharr creates FUSE in its own container mount namespace
- Modern k3s/containerd support proper mount propagation with Bidirectional flag
- Worth retesting with careful host setup (`/mnt` in shared peer group)

**Why it initially failed** (history):
- Kubernetes volume mounts use separate bind-mounts for each container
- Each container's `/mnt` mount is in a different peer group
- FUSE mount created in container A's namespace doesn't propagate to container B's namespace
- BUT: hostPath volumes are different — they're mounted at the **host level**, not per-container
  
**How to make it work**:
1. Ensure host `/mnt` is in shared peer group: `mount --make-shared /mnt`
2. decypharr-streaming uses hostPath volume with `Bidirectional` propagation
3. Ensure Samba step is skipped entirely
4. FUSE mount at `/mnt/dfs` should propagate to `/mnt/decypharr-dfs` on host
5. Consumer pods bind-mount that directory via hostPath

**LD_PRELOAD shim**: Still needed! FUSE still reports st_nlink=0; no SMB layer to work around it.

**Pros**:
- Eliminates Samba/CIFS complexity (2 layers fewer)
- Lower overhead (no network protocol layer)
- Simpler debugging (direct kernel mounts, not SMB)
- Faster (no SMB negotiation, direct FUSE access)
- ✅ HA compatible: pod can move w1→w2, FUSE remounts automatically

**Cons**:
- ✅ Still requires LD_PRELOAD shim (FUSE st_nlink=0 problem remains)
- ❌ Requires host-level mount namespace management (admin must set up `/mnt` shared)
- ❌ FUSE propagation is inherently fragile (one of the reasons SMB was chosen initially)
- Potential stability issues if mount propagation breaks between restarts
- No built-in auth (FUSE mount is visible to all pods on cluster)

**Risk Assessment**: Medium-High complexity, potential for mount propagation issues to resurface.

**HA Score**: ⭐⭐⭐⭐ (pod failover works; HA is transparent)

---

### OPTION B: NFS via Rclone (Revisit with Native NFSv3 Server)

**Idea**: Instead of exporting FUSE via Samba, use `rclone serve nfs` to export the FUSE mount as NFSv3.

**Current issue with NFS** (from earlier attempts):
- kubelet can't resolve ClusterIP (`10.43.X.X`) — host DNS doesn't use CoreDNS
- Also: FUSE st_nlink=0 would cause same issues with NFS3 stat() as with SMB

**New approach**:
1. Keep decypharr's FUSE mount at `/mnt/dfs` (same as now)
2. Run `rclone serve nfs /mnt/dfs --addr=0.0.0.0:2049` in same pod
3. Assign a **MetalLB LoadBalancer IP** (real BGP-advertised IP) to the service
4. kubelet mounts via real IP (not ClusterIP): `mount -t nfs <LB-IP>:/mnt/dfs /mnt/decypharr-dfs`
5. Consumer pods bind-mount the CIFS mount as before

**Why this might work**:
- NFS3 is kernel-native, very stable
- Rclone's NFS server might handle st_nlink=0 differently than Samba
- MetalLB solves DNS resolution problem
- More "standard" than SMB

**LD_PRELOAD shim**: Unclear. Might still need it if rclone's NFS server also rejects st_nlink=0.

**Pros**:
- NFS is mature, kernel-native, industry standard
- Rclone is actively maintained, more flexible than Samba
- MetalLB integration is already present in your cluster
- ✅ HA compatible: pod moves, service IP stays same
- Better caching behavior than CIFS (clients can be more aggressive)

**Cons**:
- ❌ Consumes a MetalLB IP from limited pool (currently 10 IPs: 101-110)
- Rclone serve NFS might have edge cases (less battle-tested than Samba for this use)
- ✅ Still might need LD_PRELOAD if rclone NFS server has same st_nlink issue (must test)
- NFS soft mounts can be flaky during network hiccups (ESTALE errors)

**Cost**: MetalLB IP cost, Rclone reliability testing needed

**Risk Assessment**: Medium complexity, good upside if rclone handles st_nlink better.

**HA Score**: ⭐⭐⭐⭐⭐ (proper HA support, failover transparent)

---

### OPTION C: Store FUSE Cache in Longhorn (Kubernetes-Native Approach)

**Idea**: Instead of directly sharing FUSE mount, have decypharr write its cache to a **Longhorn PVC**, then share the PVC with consumer pods.

```
decypharr-streaming pod:
  ├─ FUSE mount → RealDebrid API (ephemeral?)
  └─ Longhorn PVC /mnt/cache → Store downloaded content

Consumer pods (Sonarr, Radarr):
  └─ Same Longhorn PVC /mnt/cache → Read content
```

**How it works**:
1. Modify decypharr to cache files to Longhorn PVC instead of (or in addition to) FUSE mount
2. Multiple consumer pods attach same PVC (requires RWX StorageClass — Longhorn doesn't support this natively)
3. All pods see same files, symlinks work across pods

**Issues**:
- Longhorn doesn't support ReadWriteMany (RWX) access mode
- Would need to add NFS or Samba **within the cluster** to export Longhorn volume as RWX
- That would recreate the same sharing problem we're trying to solve!

**Pros**:
- ✅ Kubernetes-native: uses standard PVC API
- ✅ Native HA: Longhorn handles replica management
- ✅ No FUSE propagation complexity
- ✅ No SMB/NFS intermediate layers
- ✅ Zero-copy failover between nodes

**Cons**:
- ❌ Requires Longhorn RWX support (not available; would require external storage plugin)
- ❌ Requires modifying decypharr behavior (if source code accessible)
- ❌ Cache files stored differently (writes instead of lazy mounts) — more I/O overhead
- Doesn't align with RealDebrid model (API-based symlink mounting, not prefetch cache)

**Risk Assessment**: High complexity, architectural mismatch with decypharr's design.

**HA Score**: ⭐⭐⭐⭐⭐ (if RWX could work, HA would be perfect)

---

### OPTION D: Fix Root Cause — Patch hanwen/go-fuse st_nlink Behavior

**Idea**: Submit PR or fork hanwen/go-fuse to report correct st_nlink values for FUSE entries.

**Current behavior** (line in go-fuse):
```go
// hanwen/go-fuse returns st_nlink=0 for all entries
// This matches tmpfs, but breaks servers expecting valid link counts
```

**The fix**:
```go
// Changed to report:
// - Directories: st_nlink = 2 (self + parent link)
// - Regular files: st_nlink = 1 (single link)
// This matches standard filesystem behavior
```

**How this helps**:
- Eliminates need for LD_PRELOAD shim entirely
- Decypharr's FUSE mount would report correct st_nlink
- SMB/NFS/any protocol would work without patching
- Cleaner, more maintainable solution

**Challenges**:
- Requires contributing to hanwen/go-fuse upstream
- Or maintaining a fork (maintenance burden)
- Must verify it doesn't break other use cases (tmpfs compatibility)
- Decypharr maintainers would need to adopt updated go-fuse

**Pros**:
- ✅ Eliminates LD_PRELOAD shim entirely
- ✅ Works with any export protocol (Samba, NFS, WebDAV, etc.)
- ✅ Cleaner, more maintainable long-term
- ✅ Helps entire FUSE community (not just your use case)

**Cons**:
- ❌ Requires upstream collaboration (slow, uncertain)
- ❌ Maintenance burden if maintaining fork
- ❌ Blocked on hanwen/go-fuse maintainer response
- Doesn't solve problem immediately

**Risk Assessment**: Low technical risk, high process risk (upstream coordination).

**HA Score**: ⭐⭐⭐⭐⭐ (once fixed, any architecture works)

---

### OPTION E: Custom CSI Driver for Decypharr

**Idea**: Build a Kubernetes CSI driver that natively interfaces with decypharr, providing volumes to consumer pods without FUSE sharing.

```
CSI Controller:
  ├─ Interfaces with decypharr API
  └─ Creates/deletes RealDebrid mount points

CSI Node Plugin (on each host):
  ├─ Mounts decypharr content locally
  └─ Exports to pods via standard volume mount
```

**How it works**:
1. Consumer pod requests a PVC for RealDebrid content
2. CSI controller contacts decypharr API, sets up content link
3. CSI node plugin on the pod's host mounts that content locally
4. Pod gets standard Kubernetes volume mount (no hostPath complexity)

**Key insight**: Instead of sharing decypharr's single FUSE mount, each pod gets its own CSI-provisioned volume.

**Pros**:
- ✅ Kubernetes-native: uses standard CSI/PVC API
- ✅ No FUSE sharing/propagation complexity
- ✅ Proper HA support: CSI driver handles failover
- ✅ No LD_PRELOAD shim needed (CSI driver controls mount behavior)
- ✅ Scales cleanly (each pod gets independent volume)
- ✅ Applications don't need to know about RealDebrid (transparent)

**Cons**:
- ❌ Requires implementing a CSI driver (significant development effort)
- ❌ Need to understand decypharr API (if closed source, not possible)
- ❌ Maintenance burden: CSI driver must be maintained alongside cluster
- Might be overkill for a homelab (complex for the value)
- Long development timeline

**Risk Assessment**: High complexity, but solid architecture if you have time to build it.

**HA Score**: ⭐⭐⭐⭐⭐ (CSI drivers are designed for HA)

---

### OPTION F: WebDAV Export (Alternative Protocol Layer)

**Idea**: Export decypharr FUSE mount via WebDAV (HTTP-based file access) instead of SMB/NFS.

```
decypharr-streaming pod:
  /mnt/dfs (FUSE) → [caddy/lighttpd WebDAV server] → dav.media.svc.cluster.local

Consumer pods:
  mount -t davfs dav.media.svc.cluster.local /mnt/dfs
  (or use simple HTTP client for file access)
```

**How it works**:
1. Run a lightweight WebDAV server (caddy, lighttpd, etc.) in decypharr-streaming pod
2. Server exports `/mnt/dfs` (FUSE mount) over HTTP/WebDAV on port 80
3. Consumer pods use `davfs` (WebDAV FUSE) or HTTP client to access files
4. No SMB, no CIFS, no kernel NFS complexity

**Pros**:
- ✅ Different protocol layer (might avoid st_nlink issues entirely)
- ✅ HTTP is more standard than SMB for internet-connected clusters
- ✅ Built-in auth/TLS support (better security than guest SMB)
- ✅ Lighter weight than Samba
- ✅ HA compatible: service failover transparent to clients

**Cons**:
- ❌ WebDAV is less performant than kernel-level mounts
- ❌ Requires `davfs` FUSE client on consumer pods (adds complexity)
- ❌ Potential symlink issues (HTTP/WebDAV might not handle symlinks identically)
- ❌ Still relies on FUSE client library (might have same issues as Samba)
- Less mature than SMB/NFS in Kubernetes contexts

**Risk Assessment**: Medium complexity, different failure modes (HTTP reliability vs SMB stability).

**HA Score**: ⭐⭐⭐⭐ (HTTP failover transparent, but WebDAV client reliability?)

---

### OPTION G: iSCSI Block Device Export

**Idea**: Export decypharr FUSE mount as a block device via iSCSI, mount at block level on nodes.

```
decypharr-streaming pod:
  /mnt/dfs (FUSE) → [loopback device + iSCSI target] → iSCSI LUN

Node kernel:
  [iSCSI initiator] → blocks device → /dev/sda1 → mount /mnt/decypharr-dfs

Consumer pods:
  hostPath bind-mount /mnt/decypharr-dfs
```

**How it works**:
1. decypharr creates a loopback device from its FUSE mount
2. Exports that via iSCSI target (tgt, LIO, or similar)
3. Nodes' iSCSI initiators connect to the target
4. Standard block device mounted on each node

**Pros**:
- ✅ Block-level consistency guarantees
- ✅ Standard iSCSI protocol (widely supported)
- ✅ No SMB/NFS quirks (block device abstraction)
- ✅ HA compatible: nodes fail over to alternate target path

**Cons**:
- ❌ Loopback → iSCSI → loopback adds significant overhead
- ❌ Not designed for FUSE mounts (loopback might not handle sparse/dynamic FUSE well)
- ❌ iSCSI configuration complex in Kubernetes
- ❌ Single pod serving block device is a SPOF
- Potential performance issues (block device + FUSE = extra indirection)

**Risk Assessment**: Very complex, architectural mismatch (block devices not meant for FUSE).

**HA Score**: ⭐⭐⭐ (iSCSI failover possible but complex in k8s)

---

### OPTION H: Bypass FUSE — Direct RealDebrid Integration

**Idea**: Skip decypharr FUSE mounting entirely. Have Sonarr/Radarr communicate directly with RealDebrid API (if possible) or use decypharr gRPC API.

```
Consumer pods (Sonarr/Radarr):
  ├─ Query RealDebrid API directly (or via decypharr API)
  ├─ Create symlinks to remote content
  └─ No local FUSE mount needed
```

**Requirements**:
- Sonarr/Radarr (or their plugins) can understand RealDebrid API
- Or decypharr exposes gRPC/REST API that clients can use
- Build custom sidecar/middleware to handle RealDebrid logic

**Pros**:
- ✅ Eliminates all FUSE/SMB/NFS complexity
- ✅ No mount propagation issues
- ✅ Simpler HA (no shared mounts to worry about)
- ✅ Cleaner architecture (API over filesystem)

**Cons**:
- ❌ Requires customizing Sonarr/Radarr with RealDebrid awareness
- ❌ Not possible if RealDebrid API is closed/limited
- ❌ Requires rewriting symlink/import logic
- ❌ Breaks applications' assumption of standard filesystem interface
- High development effort, uncertain if feasible

**Risk Assessment**: High architectural risk, depends on RealDebrid API availability.

**HA Score**: ⭐⭐⭐⭐⭐ (no mounts to fail over, trivially HA-safe)

---

## Comparison Matrix

| Criteria | Current (SMB/LD_PRELOAD) | A: Direct hostPath | B: NFS via Rclone | C: Longhorn RWX | D: Fix go-fuse | E: CSI Driver | F: WebDAV | G: iSCSI | H: Direct API |
|----------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **Reliability** | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| **HA Support** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Maintainability** | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | N/A | ⭐⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ |
| **Complexity** | Medium | Medium | Low | High | Very High | Very High | Medium | High | Very High |
| **Implementation Cost** | ✅ Already done | 🔧 Low | 🔧 Medium (MetalLB config) | ❌ Not feasible | 📅 Long-term | 📅 Long-term | 🔧 Medium | 📅 Long-term | 📅 Long-term |
| **Urgency** | ✅ Done | This month | This month | — | Q2 2026 | Q2+ 2026 | Future | Future | Future |
| **LD_PRELOAD Shim Needed?** | ✅ Yes | ✅ Yes | ❓ Unclear | ✅ No | ❌ No | ❌ No | ❓ Unclear | ❌ No | ❌ No |
| **MetalLB IP Cost** | — | — | 1 IP | — | — | — | Optional | Optional | — |
| **Requires Host Setup** | ✅ Yes (`--make-shared`) | ✅ Yes (`--make-shared`) | — | — | — | Optional | — | ✅ iSCSI config | — |
| **Mount Propagation Risk** | Medium | High | Low | None | None | None | None | Medium | None |

---

## Recommendations

### Short-term (This Month)

**Keep current SMB/LD_PRELOAD setup**, but:

1. **Document reliability constraints** [1-2 hours]
   - Clearly note that LD_PRELOAD shim is a workaround, not a long-term solution
   - Document host mount setup in NODE_SETUP.md (already partial)
   - Add failover test checklist to CLUSTER_STATE_SUMMARY.md

2. **Test failover scenarios** [2-4 hours]
   - Simulate w1 node death: Does descheduler properly move decypharr to w2? Do consumers see data?
   - Simulate network blip on DFS-mounter: Do consumers gracefully handle I/O errors?
   - Simulate decypharr pod restart: How long are consumers blocked? (measure against RPO/RTO)

3. **Consider OPTION B (NFS via Rclone)** if you have 4-6 hours to spare
   - Test if rclone serve nfs handles st_nlink=0 better than Samba
   - If yes, migrate to NFS + MetalLB (simpler, more standard)
   - Rclone is actively maintained (better long-term than custom Samba config)

### Medium-term (Next Quarter)

**OPTION D (Fix go-fuse upstream)**
- Open issue on hanwen/go-fuse: "FUSE client reporting st_nlink=0 breaks SMB/NFS servers"
- Propose PR with st_nlink fix
- If accepted: simplify LD_PRELOAD shim or remove it entirely
- If rejected: maintain fork in your infrastructure repo (less ideal, but manageable)

**OPTION E (CSI Driver)** if you want "right-to-left" architecture
- Start design doc: "Decypharr CSI Driver" (1-2 weeks research)
- If feasible: prototype during Q2 (2-3 week sprint)
- Would be a significant improvement to long-term maintainability

### Long-term (2026 Q3+)

**Revisit architecture quarterly**:
- Monitor if decypharr/hanwen/go-fuse release fixes
- Evaluate new Kubernetes features (ephemeral volumes, etc.)
- Consider whether OPTION E (CSI) is worth the effort

---

## Decision: What to Do Now?

### Best Path Forward (My Recommendation)

**Invest 4-6 hours in OPTION B (NFS via Rclone)**:

1. **Test rclone serve nfs with st_nlink behavior** (1-2 hours)
   ```bash
   # Create test FUSE mount with st_nlink=0
   # Serve via rclone nfs
   # Check if clients can stat files via NFS
   # Compare to current Samba behavior
   ```

2. **If rclone eliminates st_nlink issue**:
   - Remove LD_PRELOAD shim (cleaner! ✅)
   - Migrate to MetalLB IP + NFSv3 (more standard ✅)
   - Simpler debugging (NFS is well-known ✅)
   - **Cost**: 1 MetalLB IP from pool of 10 (acceptable)

3. **If rclone doesn't help**:
   - Keep current SMB setup
   - Invest time in OPTION D (upstream PR to fix go-fuse)
   - Long-term goal: eliminate LD_PRELOAD shim

### Why Not Other Options?

- **OPTION A (Direct hostPath)**: Work already done (choose B or D instead)
- **OPTION C (Longhorn RWX)**: Not feasible (Longhorn doesn't support RWX)
- **OPTION E (CSI)**: Not urgent (current setup works, CSI is future-proofing)
- **OPTION F (WebDAV)**: Less proven than NFS (WebDAV in k8s less common)
- **OPTION G (iSCSI)**: Architectural mismatch (block devices not meant for FUSE)
- **OPTION H (Direct API)**: Requires app rewrites (high friction)

---

## Risk Assessment: Current Setup vs. Alternatives

### Current Setup (SMB/LD_PRELOAD) Risk Profile

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| LD_PRELOAD shim has bug (edge case) | Medium | Medium (fileops fail) | Test coverage, update C code |
| SMB protocol incompatibility | Low | Medium (consumers offline) | Keep monitoring hanwen/go-fuse issues |
| CIFS mount becomes stale during failover | Low | Medium (brief I/O errors) | `soft` mount + apps retry logic |
| Host `/mnt` mount propagation reverted | Very Low | High (all mounts break) | Document as critical infrastructure |
| DFS-mounter daemonset pod crashes | Very Low | Medium (remounts within 30s) | Component is stable, low risk |

### OPTION B (NFS via Rclone) Risk Profile

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Rclone NFS server has unknown bug | Medium | Medium (need fallback) | Test before migrating |
| MetalLB allocation mistake | Very Low | Low (IP contention) | Careful IP management |
| NFSv3 less secure than SMB auth | Low | Low (homelab, internal network) | Not a concern for homelab |
| Rclone not actively maintained | Low | Medium (unfixed bugs) | BUT: Very mature project, low risk |

**Verdict**: OPTION B is slightly lower risk long-term (rclone is more actively maintained than Samba, NFS is more standard).

---

## Action Items to Investigate

1. **Test rclone serve nfs st_nlink behavior** (Priority: HIGH)
   - Does rclone's NFS server report correct st_nlink for FUSE entries?
   - Can Samba client correctly stat symlink targets via NFS?
   - Compare latency/throughput to current SMB setup

2. **Review hanwen/go-fuse GitHub issues** (Priority: MEDIUM)
   - Check if st_nlink=0 issue is documented
   - Are there existing PRs to fix this?
   - What's maintainer stance (likely to accept changes)?

3. **Test failover scenarios** (Priority: MEDIUM)
   - Simulate w1 failure, verify decypharr moves to w2
   - Check if consumer pods can still access content
   - Measure failover time (target: <2 min)

4. **Document risk constraints** (Priority: HIGH)
   - Add "Reliability Assumptions" section to DFS_IMPLEMENTATION_STATUS.md
   - List known limitations of current approach
   - Set expectations for when HA failover might cause brief I/O errors

---

## References

- **hanwen/go-fuse**: https://github.com/hanwen/go-fuse (FUSE binding library)
- **Rclone serve nfs**: https://rclone.org/commands/rclone_serve_nfs/
- **Samba NFS Bridge**: https://wiki.samba.org/index.php/Samba_NFS_Sharing
- **Kubernetes Mount Propagation**: https://kubernetes.io/docs/concepts/storage/volumes/#mount-propagation
- **FUSE Documentation**: https://www.kernel.org/doc/html/latest/filesystems/fuse.html

---

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-28 | Keep current SMB/LD_PRELOAD | Functional, tested, known behavior |
| 2026-02-28 | Research OPTION B (NFS) | Better long-term (rclone, standard protocol) |
| 2026-02-28 | Document reliability concerns | HA confidence requires transparency |

---

**Next Update**: After testing OPTION B (NFS) and failover scenarios (target: March 2026)
