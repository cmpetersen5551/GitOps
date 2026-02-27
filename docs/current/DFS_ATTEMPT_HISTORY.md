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
767d937  Implement DaemonSet architecture — uses CIFS/SMB (rclone serve smb)
edd0d35  Switch DaemonSet from CIFS to NFS — rclone v1.73.1 has no serve smb
f3e6287  Fix DaemonSet nodeAffinity selectors
ac257b1  Fix DaemonSet nodeAffinity (label key correction)
4665f76  Fix rclone serve nfs command in decypharr-streaming
6b633a6  (docs only) Incorrect pivot doc: DaemonSet not working — WRONG conclusion
64f462b  ← FIX: correct mountpoint check + port options → DaemonSet working ✅
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

**None of these helped in the in-pod sidecar context.** The emptyDir volume isolation was the true root cause for the sidecar approach — the NFS mount was happening in the sidecar's namespace but not propagating to the main container. A "deadlock" was observed in some runs but may have been an artifact of the emptyDir isolation making the NFS server appear unresponsive (the server was receiving the connection but the client side was stuck due to peer group issues).

**Important retroactive correction**: `rclone serve nfs` was NOT deadlocking in the DaemonSet context (Attempts 7/8). The NFS server was healthy and responsive throughout. The "deadlock" conclusion from this period was specific to the emptyDir sidecar architecture — do not apply it to `rclone serve nfs` in general.

**Key learning**: Extensive time was spent tuning the client while the real problem (emptyDir peer group isolation) made it impossible to tell whether the server was healthy or not. The right diagnostic question was "can a *fresh test pod* mount the NFS share directly?" — not "are our mount options correct?"

### Important Side Learning: emptyDir mount detection

Commit `7e0dbf4` documented an important subtlety: `emptyDir: {medium: Memory}` creates a real tmpfs mountpoint at `/mnt/dfs` inside the container. This caused `mountpoint -q /mnt/dfs` to return success even when no NFS mount was present (it detected the tmpfs, not the NFS). This prevented the NFS mount command from ever running.

Fix: revert to plain `emptyDir: {}` so `/mnt/dfs` is a plain bind-mount directory, and detect NFS presence with `grep -qs 'decypharr-streaming-nfs.*nfs' /proc/mounts` (check for NFS explicitly, not just any mountpoint). This same lesson recurred in Attempt 8 for a different reason — see below.

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

**This was the final sidecar-based attempt.** After this, the architecture changed entirely to a DaemonSet approach (Attempt 7).

**Root cause of the oversight**: The focus was on why NFS wasn't working (perceived server deadlock → protocol change) without recognizing that the protocol choice determined whether the *client* mount was FUSE or kernel-level.

---

## Attempt 7: DaemonSet with CIFS/SMB (Immediately Abandoned)

**Commits**: `767d937`, `edd0d35`  
**Date**: Feb 26, 2026

### What Was Tried

Introduced the DaemonSet architecture (from `docs/current/DFS_RESEARCH_AND_OPTIONS.md` Option 10). Initial implementation used `rclone serve smb` (server) + `mount -t cifs` (DaemonSet client), which was the original plan.

Commit `767d937` implemented:
- `infrastructure/dfs-mounter/daemonset.yaml` — privileged DaemonSet, CIFS mount loop
- `decypharr-streaming` — switched to `rclone serve smb --addr 0.0.0.0:445`
- Sonarr/Radarr — switched from sidecar to `hostPath: /mnt/decypharr-dfs` + `HostToContainer`

### Why It Was Abandoned Immediately

**`rclone serve smb` does not exist in rclone v1.73.1** (the version in `cy01/blackhole:beta`). Available `rclone serve` subcommands: dlna, docker, ftp, http, **nfs**, restic, s3, sftp, webdav. No smb.

Commit `edd0d35` immediately switched server to `rclone serve nfs --addr 0.0.0.0:2049` and DaemonSet client to `mount -t nfs`. The DaemonSet architecture was kept.

**Key learning**: Always check available `rclone serve` subcommands for the specific image version before designing around them.

---

## Attempt 8: DaemonSet with NFS — Script Bugs Prevented Mount

**Commits**: `edd0d35`, `f3e6287`, `ac257b1`, `4665f76`, `6b633a6`  
**Date**: Feb 26–27, 2026

### What Was Tried

The NFS-based DaemonSet was deployed and appeared to be running (`kubectl get pods` showed Running/Healthy). Sonarr and Radarr were updated to hostPath + HostToContainer. However `/mnt/dfs` in both pods was empty.

Several fixup commits addressed nodeAffinity labels and the `rclone serve nfs` command format, but the empty-mount symptom persisted. A documentation commit (`6b633a6`) incorrectly concluded the DaemonSet architecture "does not work" and suggested pivoting to direct Kubernetes NFS volumes in Sonarr/Radarr (this change was never applied to the manifests).

### Root Cause: Two Bugs in the DaemonSet Script

**Bug 1 — `mountpoint -q` false positive:**

The DaemonSet script checked `mountpoint -q /mnt/decypharr-dfs` to decide whether to mount. A Kubernetes `hostPath` volume creates a bind-mount of the host directory into the container. This bind-mount is already a kernel mountpoint, so `mountpoint -q` always returns true — regardless of whether NFS is mounted there. The NFS mount was **never attempted on any pod start or loop iteration** since the DaemonSet was first deployed.

**Bug 2 — Missing portmapper bypass options:**

The mount command lacked `port=2049,mountport=2049,tcp,nolock`. The Linux kernel NFS client contacts portmapper (port 111) by default. `rclone serve nfs` has no portmapper. Without these options, every mount attempt hung indefinitely waiting for port 111 — which would also explain why it appeared to work initially (the script ran, took a long time, then "succeeded" in the eyes of the health check while actually timing out).

### Diagnosis Method

Live inspection of the DaemonSet pod:
```bash
kubectl exec -n media dfs-mounter-<pod> -- cat /proc/mounts | grep decypharr
# Output: /dev/sda1 /mnt/decypharr-dfs ext4 ...   (no NFS entry)
```
Confirmed NFS was never mounted. Manual test:
```bash
mount -t nfs -o vers=3,soft,timeo=10 decypharr-streaming-nfs...:/ /mnt/decypharr-dfs
# → HANGS (Bug 2)
mount -t nfs -o vers=3,port=2049,mountport=2049,tcp,nolock,soft,timeo=10,retrans=3 ...
# → SUCCESS in ~1 second
```

---

## Resolution: Two Script Fixes (commit `64f462b`)

**Date**: Feb 27, 2026

### Changes Made

Fixed both bugs in `clusters/homelab/infrastructure/dfs-mounter/daemonset.yaml`:

1. Replaced `mountpoint -q` with `grep -q '/mnt/decypharr-dfs nfs' /proc/mounts`
2. Added `port=2049,mountport=2049,tcp,nolock` to mount options

Rolled the DaemonSet (`kubectl rollout restart`).

### End-to-End Verification

```bash
# DaemonSet log: "DFS mounted"
# Host-level:
ssh root@k3s-w1 "ls /mnt/decypharr-dfs/"
# __all__  __bad__  nzbs  torrents  version.txt ✅

# Sonarr:
kubectl exec -n media sonarr-0 -- ls /mnt/dfs/
# __all__  __bad__  nzbs  torrents  version.txt ✅

# Radarr:
kubectl exec -n media radarr-0 -- ls /mnt/dfs/
# __all__  __bad__  nzbs  torrents  version.txt ✅
```

No architecture changes needed. No StatefulSet changes needed. The DaemonSet + hostPath approach was and is correct.

---

## Lessons Learned

1. **"Running" and "Healthy" DaemonSet pods do not mean the mount succeeded.** Always verify the actual mount state with `cat /proc/mounts` inside the pod, not just pod status.

2. **`mountpoint -q` on a hostPath volume is always true.** The bind-mount of the host directory into the container is itself a mountpoint. Any script that uses `mountpoint -q` on a hostPath volume will be a no-op forever. Use `grep /proc/mounts` to check for a specific filesystem type instead.

3. **rclone serve nfs has no portmapper.** Always include `port=2049,mountport=2049,tcp,nolock` when mounting. Without these, the Linux kernel NFS client hangs indefinitely on port 111.

4. **Know whether a filesystem client is FUSE or kernel before choosing it.** sshfs, s3fs, goofys — all FUSE. `mount -t nfs`, `mount -t cifs`, `mount -t ext4` — all kernel. FUSE mounts cannot propagate between containers. Kernel mounts can.

5. **emptyDir peer group isolation is the fundamental barrier for in-pod sidecars.** Neither emptyDir plain, emptyDir Memory (tmpfs), nor Bidirectional propagation overcomes per-container peer group isolation for FUSE mounts. The DaemonSet hostPath approach avoids this entirely.

6. **containerd/kubelet handles hostPath peer group setup automatically.** No `mount --make-shared` node preparation is needed. The alleged k3s `/mnt` rprivate limitation was a misdiagnosis.

7. **Check rclone version capabilities before designing around a subcommand.** `rclone serve smb` was architected and implemented before verifying it existed in the deployed image version.

8. **Verify with a fresh test pod before concluding an approach is broken.** A one-line test pod (`kubectl run test --image=alpine --rm -it -- mount -t nfs options server:/ /tmp/test`) would have confirmed within 30 seconds whether the NFS server was healthy — before the entire emptyDir sidecar option space was exhausted.
