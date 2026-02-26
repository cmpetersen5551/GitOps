# DFS Mount: Attempt History & Failure Log

**Date**: 2026-02-25  
**Context**: Chronological record of every approach tried to share Decypharr's FUSE mount with Sonarr, Radarr, and other consumer pods. Pulled from git commit history and live debugging sessions.

---

## Timeline Overview

```
ea96938  Initial DFS mounts added to Sonarr (kubelet-level NFS) → ContainerCreating
275e46f  Try ClusterIP instead of DNS name for kubelet NFS → still fails
7ff8b89  Fix NFS export path → partial improvement
8d10195  Replace kubelet NFS with in-pod dfs-mounter sidecar → new approach
82695f8  Sidecar needs privileged for Bidirectional mountPropagation
c1a581e  Fix decypharr config persistence
c24819c  Switch to memory-backed emptyDir for FUSE propagation → fails
6fc2751  Colocate rclone NFS server inside decypharr container → eliminates sidecar in server
7e0dbf4  Fix NFS mount check (mountpoint -q vs grep)
49906c2  Update NFS mount options
4c433dc  Remove nolock option
73e4f5d  Add nolock back (Alpine compatibility)
17e6479  Switch to hard NFS mounts
00e4109  Back to soft mounts + mountpoint checks + stale detection
4e44120  Revert dfs-mounter changes (investigate startup failure)
00e8f40  Restore nfs4 soft mount
75b2862  Improve stale mount detection
643b49a  Reliability improvements
2fb8007  Remove readonly from media-nfs mounts
a20af23  Revert NFSv4 to NFSv3 (rclone compatibility)
d37fb27  Fix mount detection logic
629688f  Add required NFS port options (port=2049,mountport=2049,tcp)
6762381  ← PIVOT: Switch entire stack from NFS to SFTP (rclone serve nfs deadlock)
2c94eb1  Fix sshfs -f foreground flag (mount loop hung forever)
1f98f89  Add timeout + ConnectTimeout to sshfs
ab74472  Try sshpass with empty password + rclone --user/--pass flags
         ← CURRENT STATE (still broken — sshfs is FUSE)
```

---

## Attempt 1: kubelet-Level NFS Volume Mounts

**Commits**: `ea96938`, `275e46f`, `7ff8b89`  
**Dates**: Early Feb 2026

### What Was Tried

Added `nfs:` volume type directly to Sonarr/Radarr StatefulSets — kubelet-level mounts that happen before the container starts:

```yaml
volumes:
  - name: dfs
    nfs:
      server: decypharr-streaming-nfs.media.svc.cluster.local  # attempt 1
      path: /mnt/dfs
```

Then tried with raw ClusterIP (`10.43.200.129`):
```yaml
  - name: dfs
    nfs:
      server: 275e46f  # ClusterIP directly
      path: /
```

### Why It Failed

**Root cause**: kubelet uses the *host's* DNS resolver (`/etc/resolv.conf` on the node), not CoreDNS. The ClusterIP service `decypharr-streaming-nfs.media.svc.cluster.local` is:
1. Unresolvable by host DNS (CoreDNS only serves within pod network namespace)
2. Even with a raw ClusterIP, the virtual IP is managed by kube-proxy iptables rules in the pod network namespace — the host kernel's NFS client cannot reach it

Also: NFS mount path was wrong — `rclone serve nfs /mnt/dfs` exports `/mnt/dfs` as NFS root `/`. Mounting at `/mnt/dfs` would look for a subdirectory that doesn't exist.

**Result**: All pods stuck in `ContainerCreating`. NFS mount never completed.

**Learning**: kubelet-level volume mounts for ClusterIP services are impossible. The kubelet lives in host network namespace, not pod network namespace. Solution must perform the mount from within a running container (pod network namespace).

---

## Attempt 2: In-Pod dfs-mounter Sidecar (Initial)

**Commits**: `8d10195`, `82695f8`  
**Dates**: Feb 2026

### What Was Tried

Added a small Alpine sidecar container to Sonarr/Radarr that performs the NFS mount from within the pod's network namespace (where CoreDNS works and ClusterIP is reachable):

```yaml
- name: dfs-mounter
  image: alpine:3.19
  command: ["/bin/sh", "-c"]
  args:
    - apk add nfs-utils && mount -t nfs4 .../:/mnt/dfs && sleep infinity
  securityContext:
    privileged: true
  volumeMounts:
    - name: dfs-shared
      mountPath: /mnt/dfs
      mountPropagation: Bidirectional
- name: sonarr
  volumeMounts:
    - name: dfs-shared
      mountPath: /mnt/dfs
      mountPropagation: HostToContainer
```

### What Happened

Sidecar started. NFS mount attempted. But the NFS *server* (`rclone serve nfs` inside decypharr) was not yet stable — interactions with the FUSE filesystem caused problems. Also, the `dfs-shared` volume was initially `emptyDir` (plain), which worked for the mount propagation from sidecar to main container in some cases but detection logic was unreliable.

**Missing**: decypharr-streaming didn't have rclone in the same container yet — the rclone-nfs-server sidecar was a separate container that couldn't see the FUSE mount (the emptyDir propagation problem). This was not yet understood.

**Result**: Partial progress — sidecar concept correct, but both server side and client side had issues.

---

## Attempt 3: Memory-Backed emptyDir for FUSE Propagation

**Commit**: `c24819c`  
**Date**: Feb 25, 2026

### What Was Tried

The Kubernetes documentation and issue #95049 suggested `emptyDir: {medium: Memory}` (tmpfs) as the recommended approach for mount propagation. The theory: kubelet creates the tmpfs and marks it `rshared`, enabling correct Bidirectional propagation.

Changed all `dfs-shared` emptyDirs to:
```yaml
- name: dfs-shared
  emptyDir:
    medium: Memory
```

### Why It Failed

Confirmed failure by inspecting `/proc/PID/mountinfo` inside the live containers. Despite both containers having the same tmpfs as backing, kubelet creates a **separate bind-mount** of the tmpfs into each container. Each bind-mount lands in a different mount peer group (observed peer group IDs 549 and 303 for decypharr and rclone respectively).

The FUSE mount created by Decypharr propagated into kubelet's intermediate path for container A, but never crossed into container B's mount peer group. Container B saw an empty directory.

**Root cause confirmed**: Kubernetes container runtime creates per-container peer groups for volume bind-mounts. This is intentional isolation that happens to break FUSE propagation. The Kubernetes docs recommendation does not apply to intra-pod container sharing — only to host propagation scenarios.

**Result**: Same failure. rclone sidecar still saw empty `/mnt/dfs`.

**Key learning**: mount propagation between containers in the same pod is fundamentally broken for FUSE mounts regardless of volume type.

---

## Attempt 4: Colocate rclone NFS Server in Decypharr Container

**Commit**: `6fc2751`  
**Date**: Feb 25, 2026

### What Was Tried

Since FUSE cannot propagate between containers, collocate both processes in the same container (same mount namespace — no propagation needed):

```bash
# In decypharr container startup script:
/usr/bin/decypharr --config /config &
DECYPHARR_PID=$!
until grep -q ' /mnt/dfs ' /proc/mounts; do sleep 2; done
rclone serve nfs /mnt/dfs --addr=0.0.0.0:2049   # same container, same namespace
```

`cy01/blackhole:beta` already ships rclone at `/usr/local/bin/rclone` — no image change needed.

### Result

**Server side: SOLVED.** rclone can now directly read `/mnt/dfs` — no propagation needed. The NFS server starts and can serve the FUSE content.

**Client side: NEW PROBLEM.** The go-nfs library (used by `rclone serve nfs`) deadlocked when consumer pods started making heavy NFS requests against a FUSE-backed export. The NFS server process would hang after some operations, making `/mnt/dfs` in consumer pods unresponsive.

This was confirmed over multiple iterations — the deadlock was reproducible and not fixed by NFS mount option changes.

---

## Attempt 5: NFS Mount Option Iterations (Many Commits)

**Commits**: `7e0dbf4`, `49906c2`, `4c433dc`, `73e4f5d`, `17e6479`, `00e4109`, `4e44120`, `00e8f40`, `75b2862`, `643b49a`, `a20af23`, `d37fb27`, `629688f`  
**Date**: Feb 25, 2026

### What Was Tried

Extensive iteration on the `mount -t nfs` command in the dfs-mounter sidecar, attempting to work around the go-nfs deadlock via mount options:

| Commit | Change | Reason |
|---|---|---|
| `7173117` | Switch nfs4 → nfs vers=3 | rclone serve nfs uses NFSv3 |
| `7e0dbf4` | Fix mount detection (mountpoint -q → grep) | medium:Memory emptyDir creates its own mountpoint, blocking NFS check |
| `49906c2` | Various option updates | Stability |
| `4c433dc` | Remove `nolock` | Better file sync |
| `73e4f5d` | Re-add `nolock` | Alpine NFS client compatibility |
| `17e6479` | Switch to `hard` mounts | More reliable operations |
| `00e4109` | Switch back to `soft` mounts | Hard mounts block pod eviction during failover |
| `4e44120` | Revert all changes | Investigate startup failure regression |
| `00e8f40` | Restore nfs4 soft | Before hard mount regression |
| `75b2862` | mountpoint -q + stale detection | Better reliability |
| `643b49a` | Reliability pass | Readonly media-nfs mounts |
| `a20af23` | nfs4 → nfs vers=3 again | rclone serve nfs uses NFSv3 |
| `d37fb27` | Fix mount detection pattern | Detect NFS specifically not any mountpoint |
| `629688f` | Add `port=2049,mountport=2049,tcp,nolock` | Required for rclone's NFS server port |

### Result

**None of these helped.** The root problem was the `rclone serve nfs` go-nfs server deadlocking on FUSE-backed directories — not client mount options. Mount options only affect how the NFS client behaves once connected. They cannot fix a server-side deadlock.

**Key learning**: Extensive time was spent tuning the client while the server was fundamentally broken. The right diagnostic question was "is the NFS server healthy?" not "are our mount options correct?"

### Important Side Learning: emptyDir mount detection

Commit `7e0dbf4` documented an important subtlety: `emptyDir: {medium: Memory}` creates a real tmpfs mountpoint at `/mnt/dfs` inside the container. This caused `mountpoint -q /mnt/dfs` to return success even when no NFS mount was present (it detected the tmpfs, not the NFS). This prevented the NFS mount command from ever running.

Fix: revert to plain `emptyDir: {}` so `/mnt/dfs` is a plain bind-mount directory, and detect NFS presence with `grep -qs 'decypharr-streaming-nfs.*nfs' /proc/mounts` (check for NFS explicitly, not just any mountpoint).

---

## Attempt 6: Switch to rclone serve sftp + sshfs

**Commits**: `6762381`, `2c94eb1`, `1f98f89`, `ab74472`  
**Date**: Feb 25, 2026

### What Was Tried

Abandoned `rclone serve nfs` entirely due to the go-nfs deadlock. Hypothesis: SFTP is a more mature protocol (5+ years vs. go-nfs). Switch:
- Server: `rclone serve sftp /mnt/dfs --addr=0.0.0.0:2022 --no-auth`
- Client: `sshfs @decypharr-streaming-nfs.media.svc.cluster.local:/ /mnt/dfs`

Subsequent fixes:
- `2c94eb1`: Removed `-f` flag from sshfs (foreground mode caused mount command to never return, hanging the loop)
- `1f98f89`: Added `timeout 10` to sshfs, `ConnectTimeout=5` SSH option
- `ab74472`: Switched to `sshpass -p ''` + `rclone --user "" --pass ""` to handle auth handshake

### Why It Failed

**sshfs is a FUSE filesystem.** This was not recognized at the time. sshfs uses FUSE to present the remote SFTP filesystem locally. When the sidecar runs `sshfs ... /mnt/dfs`, it creates a FUSE mount in the sidecar container's mount namespace. This FUSE mount cannot propagate to the main container via `emptyDir Bidirectional` — for exactly the same reason documented in Attempt 3.

By switching from kernel NFS (`mount -t nfs`) to SSHFS (`sshfs`), the protocol changed but the fundamental FUSE propagation problem was reintroduced. The sidecar's `/mnt/dfs` is populated, but the main Sonarr/Radarr container's `/mnt/dfs` remains empty.

**Current state**: This is what is deployed right now (Feb 25, 2026). It does not work. `/mnt/dfs` in Sonarr/Radarr is empty.

**Root cause of the oversight**: The focus was on why NFS wasn't working (server deadlock → protocol change) without recognizing that the protocol choice determined whether the *client* mount was FUSE or kernel-level.

---

## Summary: What Was Never Tried

The following approach has not been tested and is the basis for the chosen architecture:

| What | Why it should work |
|---|---|
| `rclone serve smb` server-side | Different code path from go-nfs. No known FUSE-backed deadlock. SMB is a mature protocol. |
| `mount -t cifs` client-side | Kernel CIFS module — not FUSE. Kernel VFS mounts propagate correctly through shared peer groups. |
| `mount --make-shared /mnt/decypharr-dfs` node prep | Creates a dedicated shared peer group, breaking out of root `rprivate`. Enables hostPath propagation. |
| DaemonSet on per-node | Centralizes mount management, eliminates per-pod sidecar. Standard CSI-driver pattern. |

---

## Lessons Learned

1. **Diagnose server before tuning client.** Extensive NFS option iteration was wasted because the server was deadlocked. Check server health first (`rclone serve nfs` process responsive? NFS export accessible from a test pod?).

2. **Know whether a filesystem client is FUSE or kernel.** sshfs, s3fs, goofys — all FUSE. mount -t nfs, mount -t cifs, mount -t ext4 — all kernel. FUSE mounts cannot propagate between containers. Kernel mounts can (if peer groups are correct).

3. **emptyDir medium:Memory does NOT enable intra-pod FUSE propagation.** Despite Kubernetes documentation suggesting this, and despite it being theoretically correct, kubelet's container runtime implementation creates separate per-container peer groups that break it.

4. **hostPath propagation requires `shared` parent mount.** Any hostPath on k3s used for Bidirectional propagation must be on a directory that is a *separate* `shared` bind mount — not a directory on the root `rprivate` filesystem. Verify with `/proc/self/mountinfo` before assuming it will work.

5. **In-container colocation (same mount namespace) is the correct solution for the server side.** Confirmed and working. Decypharr + rclone in the same container, same mount namespace — no propagation needed.

6. **The consumer-side problem is separate from the server-side problem.** Solving server-side (colocated rclone) was correct and necessary, but insufficient. Consumer pods still need a propagation mechanism. The server-side fix enables the protocol re-export to work; the client-side architecture determines whether consumer pods can see it.
