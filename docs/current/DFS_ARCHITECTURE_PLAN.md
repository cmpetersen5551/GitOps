# DFS Access Architecture Plan: DaemonSet + Kernel NFS Mount

**Date**: 2026-02-25 (updated 2026-02-27)  
**Status**: ✅ IMPLEMENTED AND WORKING (commit `64f462b`)  
**Decision**: DaemonSet with host-level kernel NFS mount (via `rclone serve nfs`)  
**Supersedes**: `docs/DFS_MOUNT_STRATEGY.md` (outdated)

---

## Architecture Summary

Decypharr-streaming mounts RealDebrid as a FUSE filesystem (`/mnt/dfs`) inside its container and re-exports it via `rclone serve nfs`. A privileged DaemonSet on every storage node (w1, w2) and GPU node (w3) mounts that NFS share into the **host's** mount namespace at `/mnt/decypharr-dfs` via `mount -t nfs` (Linux kernel NFS client). All application pods (Sonarr, Radarr, Plex, ClusterPlex workers) access `/mnt/dfs` via a simple `hostPath` volume — no sidecar, no privilege, no network forwarding logic.

```
┌─────────────────────────────────────────────────────────────────┐
│ decypharr-streaming-0 pod (w1 or w2)                            │
│                                                                  │
│  [decypharr container] (privileged, SYS_ADMIN)                  │
│   /usr/bin/decypharr --config /config                           │
│       → FUSE mounts RealDebrid DFS at /mnt/dfs                  │
│   rclone serve nfs /mnt/dfs --addr 0.0.0.0:2049                 │
│       → exposes /mnt/dfs as NFS share on port 2049              │
│                                                                  │
│   Service: decypharr-streaming-nfs.media.svc.cluster.local:2049 │
└────────────────────────┬────────────────────────────────────────┘
                         │ NFS (kernel client, ClusterIP via pod netns)
┌────────────────────────▼────────────────────────────────────────┐
│ dfs-mounter DaemonSet pod (w1, w2, w3 — one per node)           │
│                                                                  │
│  (privileged)                                                    │
│  Uses pod network namespace → CoreDNS resolves ClusterIP        │
│  mount -t nfs -o vers=3,port=2049,mountport=2049,tcp,nolock,... │
│    decypharr-streaming-nfs.media.svc.cluster.local:/            │
│    /mnt/decypharr-dfs                                           │
│  Propagates via hostPath Bidirectional → host mount namespace    │
│                                                                  │
│  Reconnect loop: grep /proc/mounts / timeout 3 ls → remount    │
└────────────────────────┬────────────────────────────────────────┘
                         │ host namespace: /mnt/decypharr-dfs (NFS mounted)
┌────────────────────────▼────────────────────────────────────────┐
│ App pods: Sonarr, Radarr, Plex, ClusterPlex Worker              │
│                                                                  │
│  hostPath: /mnt/decypharr-dfs → /mnt/dfs                        │
│  mountPropagation: HostToContainer                               │
│  Zero sidecar. Zero privilege. 6 lines of YAML.                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Why This Architecture

### Problem Statement

Decypharr's DFS is a FUSE filesystem created within a single container's mount namespace. Multiple Kubernetes pods (Sonarr, Radarr, Plex, ClusterPlex workers on a separate node) all need read access to the same FUSE-mounted tree. Kubernetes provides no native mechanism to share a live FUSE mount across pods or containers.

### Why Not Simpler Approaches

See `docs/current/DFS_RESEARCH_AND_OPTIONS.md` for full analysis of all options considered.

**Short version of ruled-out approaches:**
- **emptyDir Bidirectional (container-to-container)**: Each container in a pod gets a separate bind-mount of the same directory in different mount peer groups. FUSE mounts created in one container never appear in another — confirmed by inspecting `/proc/PID/mountinfo`.
- **rclone serve sftp + sshfs**: sshfs is itself a FUSE filesystem, so the sidecar still cannot propagate it to the main container for the same reason emptyDir fails.
- **rclone serve smb**: `rclone serve smb` is not available in rclone v1.73.1 (the version shipped in `cy01/blackhole:beta`). Available subcommands are: dlna, docker, ftp, http, nfs, restic, s3, sftp, webdav.

### Why This Works

**containerd/kubelet already creates a `shared` peer group for hostPath volumes.** No node-level preparation is required. When kubelet bind-mounts `/mnt/decypharr-dfs` into the DaemonSet pod for a `hostPath` volume with `mountPropagation: Bidirectional`, the backing hostPath directory is placed in the host's `shared:1` peer group by containerd. This means a kernel VFS mount made inside the DaemonSet pod at that path propagates back to the host's mount namespace automatically.

**`mount -t nfs` is a kernel VFS operation**, not FUSE. The kernel NFS client mounts synchronously into the VFS layer. Once mounted in the DaemonSet pod's namespace via Bidirectional, it appears in the host's mount namespace at `/mnt/decypharr-dfs`.

**App pods use `HostToContainer`** — a read-only view of what the host already has mounted. No privilege required. No sidecar required. No race conditions.

**The DaemonSet is the single source of truth** for mount lifecycle on each node. If decypharr-streaming restarts or fails over, only the DaemonSet reconnect loop needs to re-establish the NFS mount. All app pods continue uninterrupted as soon as the DaemonSet remounts (typically <15s).

**ClusterPlex workers on w3** get the same DaemonSet. Since it uses CoreDNS via pod network namespace, it resolves the ClusterIP service name correctly regardless of which node (w1 or w2) decypharr-streaming is actually running on. Cross-node access works transparently via kube-proxy.

### Critical Mount Detection Detail

The DaemonSet script must check for an **NFS mount specifically** using `/proc/mounts`, not `mountpoint -q`. The hostPath bind-mount itself is already a mountpoint, so `mountpoint -q /mnt/decypharr-dfs` always returns true — which would prevent the NFS mount from ever being attempted.

```bash
# WRONG — always true (hostPath is a mountpoint)
if ! mountpoint -q /mnt/decypharr-dfs; then mount ...; fi

# CORRECT — checks specifically for NFS filesystem type
if ! grep -q '/mnt/decypharr-dfs nfs' /proc/mounts; then mount ...; fi
```

### Critical NFS Mount Options

rclone's NFS server does **not** run a portmapper/rpcbind daemon. The Linux kernel NFS client contacts portmapper (port 111) by default before mounting. Without explicit port options, the mount command hangs indefinitely. Required options:

```
vers=3,port=2049,mountport=2049,tcp,nolock,soft,timeo=10,retrans=3
```

- `port=2049,mountport=2049`: bypass portmapper, contact NFS server directly on port 2049
- `tcp`: force TCP (rclone serve nfs uses TCP)
- `nolock`: disable NLM locking (rclone's go-nfs doesn't implement NLM)
- `soft,timeo=10,retrans=3`: allow timeout/retry rather than hanging indefinitely on server failure

---

## HA Behavior

| Scenario | Behavior |
|---|---|
| Normal operation (w1) | DaemonSet on w1 has NFS mount. Sonarr/Radarr/Plex use hostPath. |
| w1 fails (→ w2) | Decypharr-streaming reschedules to w2. DaemonSet on w2 detects stale NFS (timeout ls), force-unmounts, remounts via NFS to w2's pod. App pods on w2 see brief stale then populated `/mnt/dfs`. App pods on w1 become irrelevant (w1 down). |
| w1 recovers | Descheduler migrates decypharr-streaming back to w1. DaemonSet on w1 reconnects. App pods follow via existing node affinity. |
| Decypharr-streaming crashes (pod restart, same node) | DaemonSet detects stale mount within 15s, remounts. App pods see brief empty `/mnt/dfs`. NFS reconnection is fast — no pod restart needed for Sonarr/Radarr. |
| DaemonSet pod restarts | Privileged pod restarts, immediately remounts NFS. Host mount restored within seconds. |

---

## Prerequisites

### Node Preparation

**No manual node preparation required.** The directory `/mnt/decypharr-dfs` must exist on each node, but containerd/kubelet places hostPath volumes into the host's `shared:1` peer group automatically. The DaemonSet creates the directory in its startup script if it's missing.

Verify the directory exists across all storage/GPU nodes:
```bash
ssh root@k3s-w1 "mkdir -p /mnt/decypharr-dfs"
ssh root@k3s-w2 "mkdir -p /mnt/decypharr-dfs"
ssh root@k3s-w3 "mkdir -p /mnt/decypharr-dfs"
```

### Cluster Requirements

- `nfs-utils` available in the Alpine DaemonSet image (installed via `apk add --no-cache nfs-utils` at pod startup)
- rclone in `cy01/blackhole:beta` v1.73.1 supports `serve nfs` ✅
- MetalLB: **not required** (DaemonSet uses pod network namespace → CoreDNS → ClusterIP)

---

## Implementation (All Phases Complete)

### Decypharr-Streaming

**File**: `clusters/homelab/apps/media/decypharr-streaming/statefulset.yaml`

The decypharr container runs both the DFS FUSE mount and an rclone NFS server in the same container (same mount namespace — no propagation needed):

```bash
/usr/bin/decypharr --config /config &
until grep -q ' /mnt/dfs ' /proc/mounts; do sleep 2; done
rclone serve nfs /mnt/dfs --addr 0.0.0.0:2049
```

Service: `decypharr-streaming-nfs.media.svc.cluster.local:2049`

### DaemonSet — Host-Level NFS Mount

**File**: `clusters/homelab/infrastructure/dfs-mounter/daemonset.yaml`

Key points in the working script:
- Use `grep -q '/mnt/decypharr-dfs nfs' /proc/mounts` (NOT `mountpoint -q`)
- Require `port=2049,mountport=2049,tcp,nolock` mount options

```bash
apk add --no-cache nfs-utils --quiet
mkdir -p /mnt/decypharr-dfs
while true; do
  if grep -q '/mnt/decypharr-dfs nfs' /proc/mounts 2>/dev/null; then
    if ! timeout 3 ls /mnt/decypharr-dfs >/dev/null 2>&1; then
      echo "NFS mount stale, force-unmounting..."
      umount -f /mnt/decypharr-dfs 2>/dev/null || umount -l /mnt/decypharr-dfs 2>/dev/null || true
    fi
  fi
  if ! grep -q '/mnt/decypharr-dfs nfs' /proc/mounts 2>/dev/null; then
    echo "Mounting DFS via NFS..."
    mount -t nfs \
      -o vers=3,port=2049,mountport=2049,tcp,nolock,soft,timeo=10,retrans=3,rsize=32768,wsize=32768 \
      decypharr-streaming-nfs.media.svc.cluster.local:/ \
      /mnt/decypharr-dfs \
      && echo "DFS mounted" || echo "Mount failed, retrying in 15s..."
  fi
  sleep 15
done
```

### Sonarr & Radarr

**Files**: `sonarr/statefulset.yaml`, `radarr/statefulset.yaml`

Simple hostPath volume — no sidecar, no privilege:

```yaml
volumes:
  - name: dfs
    hostPath:
      path: /mnt/decypharr-dfs
      type: Directory
containers:
  - name: sonarr
    volumeMounts:
      - name: dfs
        mountPath: /mnt/dfs
        mountPropagation: HostToContainer
```

### Plex (Future)

When Plex is deployed, add the same 6-line hostPath block. ClusterPlex workers on w3 get the DaemonSet automatically (it already runs on w3).

---

## File Structure

```
clusters/homelab/
├── infrastructure/
│   └── dfs-mounter/              ← DaemonSet (w1, w2, w3)
│       ├── kustomization.yaml
│       └── daemonset.yaml        ← NFS mount loop, fixed script (commit 64f462b)
├── apps/media/
│   ├── decypharr-streaming/
│   │   ├── statefulset.yaml      ← rclone serve nfs (colocated, same container)
│   │   ├── service-nfs.yaml      ← ClusterIP, port 2049
│   │   └── kustomization.yaml
│   ├── sonarr/
│   │   └── statefulset.yaml      ← hostPath + HostToContainer
│   └── radarr/
│       └── statefulset.yaml      ← hostPath + HostToContainer
```

---

## Verification Checklist

```bash
# 1. DaemonSet pods running on all nodes
kubectl get pods -n media -l app=dfs-mounter -o wide
# Expected: one pod on w1, one on w2, one on w3

# 2. DaemonSet has NFS mounted (check logs)
kubectl logs -n media <dfs-mounter-pod-on-w1> | grep "DFS mounted"

# 3. NFS visible in DaemonSet pod
kubectl exec -n media <dfs-mounter-pod-on-w1> -- cat /proc/mounts | grep nfs
# Expected: decypharr-streaming-nfs...nfs vers=3...

# 4. Host-level mount visible on w1
ssh root@k3s-w1 "ls /mnt/decypharr-dfs"
# Expected: __all__ __bad__ nzbs torrents version.txt

# 5. Sonarr sees /mnt/dfs without sidecar
kubectl exec -n media sonarr-0 -- ls /mnt/dfs
# Expected: same DFS content

# 6. Existing symlinks still resolve
kubectl exec -n media sonarr-0 -- stat /mnt/streaming-media/$(ls /path/to/any/show)

# 7. Resilience: decypharr-streaming down
kubectl scale statefulset -n media decypharr-streaming --replicas=0
kubectl exec -n media sonarr-0 -- ls /mnt/dfs  # Empty, not error
# Confirm Sonarr still starts and handles requests normally
kubectl scale statefulset -n media decypharr-streaming --replicas=1
# Wait ~15s
kubectl exec -n media sonarr-0 -- ls /mnt/dfs  # Should repopulate

# 8. Failover test: cordon w1
kubectl cordon k3s-w1
kubectl delete pod -n media decypharr-streaming-0
# decypharr-streaming reschedules to w2
# DaemonSet on w2 remounts (~15s)
# Sonarr/Radarr (already on w2 or following) see /mnt/dfs populated
kubectl uncordon k3s-w1
```

---

## Symlink Strategy (Unchanged)

The symlink strategy for Sonarr/Radarr is **unchanged** from current:

- Sonarr/Radarr use Decypharr as a qBittorrent-compatible download client
- Decypharr `download_action: symlink` (in config.json)
- Completed torrents → Decypharr creates symlinks in `/mnt/streaming-media` → pointing to `/mnt/dfs/...`
- Sonarr/Radarr import from `/mnt/streaming-media` (the 1Gi Longhorn RWX PVC)
- Plex scans `/mnt/streaming-media`, follows symlinks → reads via `/mnt/dfs` → streams from RealDebrid

The RWX PVC `pvc-streaming-media` remains. The `dfs-mounter` DaemonSet is the only infrastructure change.

---

## Open Questions / Future Considerations

1. **rclone serve smb maturity**: `rclone serve smb` was added in rclone 1.64. The `cy01/blackhole:beta` image should include a current rclone version, but verify with `rclone --version` inside the container. If SMB has issues with FUSE-backed dirs (like go-nfs did), fall back to evaluating alternative server-side protocols.

2. **cifs.ko availability**: Verify the kernel module is available on all nodes before implementing: `ssh k3s-w1 "modprobe cifs && echo ok"`.

3. **CIFS auth**: Currently designed with `guest` (no auth). For a homelab cluster this is acceptable. If security is a concern, add basic credentials to rclone serve smb and mount -t cifs.

4. **Cache volume for DFS**: The current `decypharr-streaming` container uses an `emptyDir sizeLimit: 500Gi` for DFS cache (Decypharr's internal chunk cache). This is retained as-is — the DFS cache is Decypharr-internal, separate from the CIFS mount which exposes the live FUSE tree.
