# DFS Sharing: Research, Options Explored & Decisions

**Date**: 2026-02-25  
**Context**: How to share Decypharr's FUSE-mounted RealDebrid DFS with Sonarr, Radarr, Plex, and ClusterPlex workers in a Kubernetes cluster.

---

## The Core Problem

Decypharr mounts RealDebrid as a FUSE filesystem inside its container at `/mnt/dfs`. Multiple other pods need read access to that same filesystem. Kubernetes was not designed for inter-pod FUSE sharing — every solution is a workaround for this fundamental mismatch.

### Why FUSE Sharing Is Hard in Kubernetes

FUSE (Filesystem in Userspace) mounts are created by a userspace process using `/dev/fuse` and the kernel's `libfuse` integration. The critical property: **a FUSE mount belongs to a specific mount namespace and mount peer group**. It cannot be directly accessed from a different namespace without explicit propagation through shared peer groups.

Kubernetes isolates each container in its own mount namespace. Volume mounts shared between containers (`emptyDir`, `hostPath`) use bind mounts — but each container's bind mount of the same volume lands in a *separate mount peer group* (confirmed by inspecting `/proc/PID/mountinfo`). Even with `mountPropagation: Bidirectional`, a FUSE mount created in one container propagates to *kubelet's intermediate path* but not into the other container's peer group.

**This is a fundamental Kubernetes limitation, not a configuration error.** Referenced in [kubernetes/kubernetes#95049](https://github.com/kubernetes/kubernetes/issues/95049) by maintainer @jsafrane.

---

## Constraint Set (Our Specific Cluster)

| Constraint | Implication |
|---|---|
| k3s nodes — `/mnt` is on root filesystem (`rprivate` peer group) | hostPath at `/mnt/*` cannot propagate FUSE mounts |
| 2-node HA storage (w1 primary, w2 failover) | Any solution must survive pod migration between nodes |
| w3 is a separate physical node (GPU, ClusterPlex) | Solution must work cross-node, not just w1/w2 |
| Privileged containers: acceptable | Not a constraint |
| Decypharr: non-negotiable | Must use Decypharr, not Zurg or other tools |
| Unraid SPOF for streaming: NOT acceptable | Cannot offload FUSE to Unraid NFS |
| MetalLB pool: 10 IPs, partially consumed | Should avoid burning IPs unnecessarily |
| Stable/scalable/reliable over quick fix | Solution must be production-quality, not a hack |

---

## Decypharr's Built-In Options

Decypharr (cy01/blackhole:beta) offers four ways to expose content:

### 1. DFS (Custom VFS — FUSE)
- Decypharr mounts RealDebrid directly as a FUSE filesystem at a configured `mount_path`
- Requires: `privileged: true`, `SYS_ADMIN` capability, `/dev/fuse` device
- This is what we use (`/mnt/dfs`)
- **Problem**: FUSE — sharing it with other pods is the entire problem this document addresses

### 2. Embedded Rclone (FUSE)
- Decypharr spins up an embedded rclone VFS mount
- Also FUSE — same sharing problem
- **Ruled out**: same class of problem as DFS

### 3. External Rclone (FUSE)
- Connect to an existing `rclone rcd` instance
- Still FUSE — mount lives in rclone process
- **Ruled out**: same class of problem

### 4. WebDAV Server (HTTP, No FUSE)
- Decypharr exposes files via HTTP WebDAV on its own port (8282/webdav/)
- No FUSE. Any pod can do a kernel `mount -t davfs` or HTTP request
- **Limitation**: Plex has limited `.strm` file support (community reports inconsistent behavior). WebDAV as a mount is via `davfs2` which is fuse-based on Linux. HTTP streaming works but Plex treats remote HTTP sources differently from local files — affects transcoding, chapter detection, extras detection.
- **Not recommended** for Plex streaming use case

---

## Full Option Analysis

### Option 1: Unraid as DFS Bridge
**Approach**: Run Decypharr on Unraid (Docker). Unraid mounts RealDebrid DFS via FUSE and NFS-exports it. K8s gets a plain NFS PV, same as the existing media library. No FUSE in K8s at all.

**Status**: ❌ Ruled out by user requirement — Unraid SPOF for streaming is not acceptable (Unraid is already accepted SPOF for the media library, but streaming must be independent).

---

### Option 2: Zurg + Unraid (Community Standard)
**Approach**: Replace Decypharr with Zurg (HTTP/WebDAV RealDebrid proxy, community standard in debrid/arr stacks). Run on Unraid. rclone mounts Zurg output. NFS-export to K8s.

**Status**: ❌ Ruled out — user committed to Decypharr, not open to Zurg.

Also shares the Unraid SPOF problem.

---

### Option 3: STRM Files (No FUSE Sharing)
**Approach**: Configure Decypharr `download_action: strm`. Instead of symlinks pointing to `/mnt/dfs`, Decypharr writes `.strm` files containing WebDAV URLs (`http://decypharr:8282/webdav/...`). Sonarr/Radarr import `.strm` files. Plex plays via HTTP.

**Status**: ❌ Ruled out — Plex does not reliably support `.strm` files. Community reports inconsistent behavior. This also changes the streaming model from local-file to HTTP-remote, which affects ClusterPlex GPU transcoding on w3 (worker needs byte-level file access for transcode).

Decypharr docs note WebDAV as lower performance than DFS for streaming.

---

### Option 4: rclone CSI Driver
**Approach**: Install a rclone CSI driver in the cluster. Create an RWX PVC backed by rclone that mounts RealDebrid. All pods mount the PVC.

**Status**: ❌ Not applicable. CSI drivers solve "how does a pod get a volume." They don't solve "how does Decypharr's specific FUSE process share its mount with other pods." Decypharr is not a CSI driver — it's an application with its own FUSE lifecycle.

---

### Option 5: meta-fuse-csi-plugin / smarter-device-manager
**Approach**: Use a FUSE CSI plugin to expose `/dev/fuse` as a K8s resource. Allows FUSE mounts without `privileged: true` in app pods.

**Status**: ❌ Not applicable for our problem. These tools solve "how does a pod do its own FUSE mount without privilege." Our problem is sharing ONE Decypharr FUSE mount with multiple OTHER pods that are not doing FUSE themselves. No CSI FUSE plugin solves inter-pod FUSE sharing.

---

### Option 6: hostPath + Bidirectional (Tried — Failed)
**Approach**: Give Decypharr a `hostPath` volume at `/mnt/k8s/decypharr-streaming-dfs` with `mountPropagation: Bidirectional`. Decypharr mounts FUSE inside the container → propagates to host → other pods use `HostToContainer` on same hostPath.

**Status**: ❌ Failed in practice. Root cause: `/mnt/k8s/` sits on the k3s root filesystem which is `rprivate` (private peer group). `Bidirectional` requires the parent mount to be in a `shared` or `rshared` peer group for propagation to cross the container boundary into the host namespace.

**Confirmed**: `ssh k3s-w1 "cat /proc/self/mountinfo | grep ' /mnt '"` returned nothing — `/mnt` is not a separate mount. No subdirectory of `/mnt` can be used for hostPath propagation without explicit `mount --make-shared` preparation.

---

### Option 7: emptyDir (Plain) + Bidirectional Between Containers
**Approach**: Use a plain `emptyDir` volume shared between Decypharr and a sidecar (e.g., rclone NFS server). Decypharr creates FUSE mount → sidecar reads it.

**Status**: ❌ Fundamentally broken. kubelet creates a separate bind-mount of the emptyDir into each container. Each bind-mount lands in a different mount peer group. The FUSE mount from container A never appears in container B. Confirmed by inspecting `/proc/PID/mountinfo` on the live cluster — FUSE peer group 549 (Decypharr) vs peer group 303 (rclone sidecar) were disconnected.

This is the documented Kubernetes limitation from issue #95049.

---

### Option 8: emptyDir medium:Memory + Bidirectional
**Approach**: Same as Option 7 but with `emptyDir: {medium: Memory}`. Kubernetes docs suggest tmpfs emptyDirs are correctly marked `rshared` by kubelet.

**Status**: ❌ Failed in practice. Despite docs recommending this, kubelet still creates separate bind-mounts per container from the same tmpfs backing store. Peer group IDs differed between containers. The Kubernetes docs recommendation appears to be aspirational or context-specific and does not apply to intra-pod container sharing.

---

### Option 9: Colocate rclone in Same Container as Decypharr
**Approach**: Instead of a sidecar, run rclone in the same container as Decypharr. Same container = same mount namespace = no propagation needed. Decypharr creates FUSE at `/mnt/dfs`, rclone reads it directly and re-exports as NFS/SFTP.

**Status**: ✅ This is **solved** — the issue is what to re-export as. This is already implemented in `decypharr-streaming`. The problem is how consumer pods (Sonarr, Radarr, Plex) access the re-export.

Suboptions for the re-export:

#### 9a: rclone serve nfs (go-nfs) + kernel NFS sidecar
- **Status**: ❌ `rclone serve nfs` uses the `go-nfs` library which **deadlocks** when the underlying filesystem is FUSE. Observed in production — rclone process hangs after a few operations. Multiple NFS option iterations (nfs4, nfs vers=3, nolock, soft/hard, port=2049/mountport=2049/tcp) did not help because the problem was server-side deadlock, not client mount options.

#### 9b: rclone serve sftp + sshfs sidecar
- **Status**: ❌ Current state — broken by design. sshfs is a FUSE filesystem. The sidecar creates a FUSE mount and tries to propagate it to the main container via emptyDir Bidirectional. This is the same inter-container FUSE sharing problem. FUSE never propagates. Sonarr/Radarr `/mnt/dfs` is empty.

#### 9c: rclone serve smb + kernel CIFS sidecar ← **Proposed**
- `rclone serve smb` is a completely different implementation (Go SMB2 library). Not go-nfs. No known FUSE-backed deadlock.
- `mount -t cifs` is the Linux kernel CIFS/SMB module — not FUSE. Kernel VFS mounts propagate correctly.
- **Untested in this cluster.** Solid theoretical basis. Selected as Phase 1 of the implementation.

---

### Option 10: DaemonSet + Shared Bind Mount + Kernel CIFS ← **CHOSEN**
**Approach**: Node-level preparation creates `/mnt/decypharr-dfs` as a `shared` bind mount on each node. A privileged DaemonSet runs on all storage and GPU nodes, mounts the CIFS share into this pre-shared directory using `mount -t cifs`. App pods use a simple `hostPath: /mnt/decypharr-dfs` with `HostToContainer`. No sidecar. No privilege in app pods.

**Why this is correct:**
1. The shared bind mount preparation explicitly fixes the peer group problem — `/mnt/decypharr-dfs` is in a `shared` peer group, not `rprivate`
2. `mount -t cifs` in the DaemonSet propagates through the shared mount to the host namespace
3. App pods read from host namespace via `HostToContainer` — a read-only view that requires no capability
4. One DaemonSet serves all app pods on the node — no per-pod sidecar duplication
5. Works for w3/ClusterPlex cross-node — DaemonSet runs on w3, uses pod network namespace for CoreDNS resolution

See `docs/current/DFS_ARCHITECTURE_PLAN.md` for the full implementation specification.

---

## Decision Matrix

| Option | FUSE sharing needed | K8s complexity | Per-pod overhead | w3 support | Plex support | Status |
|---|---|---|---|---|---|---|
| 1. Unraid bridge | None | Minimal | None | ✅ | ✅ | ❌ Unraid SPOF |
| 2. Zurg + Unraid | None | Minimal | None | ✅ | ✅ | ❌ Zurg rejected |
| 3. STRM files | None | None | None | ✅ | ❌ Limited | ❌ Plex compat |
| 4. rclone CSI | N/A wrong problem | Complex | None | ✅ | ✅ | ❌ Wrong problem |
| 6. hostPath Bidirectional | Yes | Low | None | ❌ w3 moot | ✅ | ❌ rprivate k3s |
| 7/8. emptyDir sidecar | Yes | Medium | Sidecar per pod | ✅ | ✅ | ❌ FUSE no propagate |
| 9a. NFS sidecar | Avoids via re-export | Medium | Sidecar per pod | ✅ | ✅ | ❌ go-nfs deadlock |
| 9b. SFTP/sshfs sidecar | Yes (still FUSE) | Medium | Sidecar per pod | ✅ | ✅ | ❌ sshfs is FUSE |
| 9c. SMB sidecar | Avoids via re-export | Medium | Sidecar per pod | ✅ | ✅ | 🔵 Phase 1 (untested) |
| **10. DaemonSet+CIFS** | Avoids via re-export | Low-Medium | None (hostPath) | ✅ | ✅ | ✅ **CHOSEN** |

---

## Key Technical Insights

1. **The NFS deadlock and the propagation problem are separate bugs.** The NFS sidecar approach was abandoned because `rclone serve nfs` (go-nfs) deadlocked — not because kernel NFS client propagation failed. These must not be conflated in future debugging.

2. **SSHFS is FUSE.** Switching from NFS client to SFTP/sshfs did not escape the propagation problem. It recreated the same FUSE propagation issue with an additional network hop.

3. **The Decypharr official Docker example shows `/mnt/:/mnt:rshared`.** This is why it works in Docker — the entire `/mnt` tree is mounted with shared propagation at the Docker level. K8s does not replicate this automatically.

4. **`mount --make-shared` on a specific directory is the correct K8s equivalent.** CSI drivers that propagate FUSE (like gcsfuse CSI) do exactly this preparation before exposing a hostPath volume for propagation.

5. **Kernel VFS mounts (NFS, CIFS) propagate; FUSE mounts do not (in practice).** Even though propagation is theoretically possible for FUSE via shared peer groups, the Kubernetes container runtime creates peer group configurations that prevent it from working in practice with emptyDir and standard hostPath.
