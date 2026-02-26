# DFS Access Architecture Plan: DaemonSet + Shared Bind Mount + Kernel CIFS

**Date**: 2026-02-25  
**Status**: 🔵 Planned — Ready for Implementation  
**Decision**: Option D — DaemonSet with host-level kernel CIFS mount  
**Supersedes**: `docs/DFS_MOUNT_STRATEGY.md` (outdated)

---

## Architecture Summary

Decypharr-streaming mounts RealDebrid as a FUSE filesystem (`/mnt/dfs`) inside its container and re-exports it via `rclone serve smb`. A privileged DaemonSet on every storage node (w1, w2) and GPU node (w3) mounts that SMB share into the **host's** mount namespace at `/mnt/decypharr-dfs` via `mount -t cifs` (Linux kernel CIFS module). All application pods (Sonarr, Radarr, Plex, ClusterPlex workers) access `/mnt/dfs` via a simple `hostPath` volume — no sidecar, no privilege, no network forwarding logic.

```
┌─────────────────────────────────────────────────────────────────┐
│ decypharr-streaming-0 pod (w1 or w2)                            │
│                                                                  │
│  [decypharr container] (privileged, SYS_ADMIN)                  │
│   /usr/bin/decypharr --config /config                           │
│       → FUSE mounts RealDebrid DFS at /mnt/dfs                  │
│   rclone serve smb /mnt/dfs --addr=0.0.0.0:445 --no-auth       │
│       → exposes /mnt/dfs as SMB share on port 445               │
│                                                                  │
│   Service: decypharr-streaming-smb.media.svc.cluster.local:445  │
└────────────────────────┬────────────────────────────────────────┘
                         │ SMB (kernel CIFS, ClusterIP via pod netns)
┌────────────────────────▼────────────────────────────────────────┐
│ dfs-mounter DaemonSet pod (w1, w2, w3 — one per node)           │
│                                                                  │
│  (privileged)                                                    │
│  Uses pod network namespace → CoreDNS resolves ClusterIP        │
│  mount -t cifs //decypharr-streaming-smb.media.svc.../  \       │
│    /mnt/decypharr-dfs -o guest,vers=3.0                         │
│  Propagates via hostPath Bidirectional → host mount namespace    │
│                                                                  │
│  Reconnect loop: mountpoint -q / timeout 3 ls → remount on fail │
└────────────────────────┬────────────────────────────────────────┘
                         │ host namespace: /mnt/decypharr-dfs (CIFS mounted)
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
- **hostPath + Bidirectional on k3s**: `/mnt` lives on the root filesystem which is `rprivate` on k3s. Bidirectional propagation cannot cross a private peer group boundary. Confirmed via `cat /proc/self/mountinfo | grep ' /mnt '` returning nothing on k3s nodes.
- **emptyDir Bidirectional**: Each container in a pod gets a separate bind-mount of the same directory in different mount peer groups. FUSE mounts created in one container never appear in another — confirmed by inspecting `/proc/PID/mountinfo`.
- **rclone serve nfs**: go-nfs library deadlocks when backed by a FUSE directory. Confirmed in production.
- **rclone serve sftp + sshfs**: sshfs is itself a FUSE filesystem, so the sidecar still cannot propagate it to the main container for the same reason emptyDir fails.

### Why This Works

**The DaemonSet's hostPath volume is pre-made shared.** Before the DaemonSet runs, the node prep step creates `/mnt/decypharr-dfs` as a dedicated `shared` bind mount — explicitly breaking it out of the root filesystem's private peer group. A hostPath volume against a `shared` bind mount correctly enables Bidirectional propagation.

**`mount -t cifs` is a kernel VFS operation**, not FUSE. The kernel CIFS module mounts synchronously into the VFS layer. It propagates through shared peer groups like any other kernel mount. Once mounted in the DaemonSet pod's namespace via Bidirectional, it appears in the host's mount namespace at `/mnt/decypharr-dfs`.

**App pods use `HostToContainer`** — a read-only view of what the host already has mounted. No privilege required. No sidecar required. No race conditions.

**The DaemonSet is the single source of truth** for mount lifecycle on each node. If decypharr-streaming restarts or fails over, only the DaemonSet reconnect loop needs to re-establish the CIFS mount. All app pods continue uninterrupted as soon as the DaemonSet remounts (typically <15s).

**ClusterPlex workers on w3** get the same DaemonSet. Since it uses CoreDNS via pod network namespace, it resolves the ClusterIP service name correctly regardless of which node (w1 or w2) decypharr-streaming is actually running on. Cross-node access works transparently via kube-proxy.

---

## HA Behavior

| Scenario | Behavior |
|---|---|
| Normal operation (w1) | DaemonSet on w1 has CIFS mount. Sonarr/Radarr/Plex use hostPath. |
| w1 fails (→ w2) | Decypharr-streaming reschedules to w2. DaemonSet on w2 detects stale mount (timeout ls), force-unmounts, remounts via CIFS to w2's pod. App pods on w2 see brief stale then populated `/mnt/dfs`. App pods on w1 become irrelevant (w1 down). |
| w1 recovers | Descheduler migrates decypharr-streaming back to w1. DaemonSet on w1 reconnects. App pods follow via existing node affinity. |
| Decypharr-streaming crashes (pod restart, same node) | DaemonSet detects stale mount within 15s, remounts. App pods see brief empty `/mnt/dfs`. SMB reconnection is fast — no pod restart needed for Sonarr/Radarr. |
| DaemonSet pod restarts | Privileged pod restarts, immediately remounts CIFS. Host mount restored within seconds. |

---

## Prerequisites

### One-Time Node Preparation (Manual, Documented in LONGHORN_NODE_SETUP.md)

Run on **w1, w2, and w3** before deploying the DaemonSet:

```bash
# Create the shared bind mount point for decypharr DFS
sudo mkdir -p /mnt/decypharr-dfs
sudo mount --bind /mnt/decypharr-dfs /mnt/decypharr-dfs
sudo mount --make-shared /mnt/decypharr-dfs
```

**Make it persistent across reboots** — add to `/etc/fstab` on each node:
```
/mnt/decypharr-dfs  /mnt/decypharr-dfs  none  bind,shared  0  0
```

Or via a systemd mount unit (preferred for k3s nodes):
```ini
# /etc/systemd/system/mnt-decypharr\x2ddfs.mount
[Unit]
Description=Shared bind mount for Decypharr DFS
Before=k3s.service

[Mount]
What=/mnt/decypharr-dfs
Where=/mnt/decypharr-dfs
Type=none
Options=bind,shared

[Install]
WantedBy=multi-user.target
```

### Cluster Requirements

- `cifs-utils` / `cifs.ko` kernel module available on all storage and GPU nodes (standard on Ubuntu/Debian-based k3s)
- rclone in `cy01/blackhole:beta` supports `serve smb` (verify: `rclone serve smb --help`, available since rclone 1.64)
- MetalLB: **not required** (DaemonSet uses pod network namespace → CoreDNS → ClusterIP)

---

## Implementation Plan

### Phase 1 — Decypharr-Streaming Changes

**File**: `clusters/homelab/apps/media/decypharr-streaming/statefulset.yaml`

Changes:
1. Change `rclone serve sftp` → `rclone serve smb --addr=0.0.0.0:445 --no-auth`
2. Update containerPort from 2022 → 445 (name: `smb`)

**File**: `clusters/homelab/apps/media/decypharr-streaming/service-nfs.yaml`

Changes:
1. Rename file to `service-smb.yaml`
2. Update service name: `decypharr-streaming-smb`
3. Update port: 445, name: `smb`

**File**: `clusters/homelab/apps/media/decypharr-streaming/kustomization.yaml`

Changes:
1. Update reference from `service-nfs.yaml` → `service-smb.yaml`

### Phase 2 — New DaemonSet for Host-Level CIFS Mount

**New file**: `clusters/homelab/infrastructure/dfs-mounter/daemonset.yaml`

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dfs-mounter
  namespace: media
spec:
  selector:
    matchLabels:
      app: dfs-mounter
  template:
    metadata:
      labels:
        app: dfs-mounter
    spec:
      hostPID: false
      hostNetwork: false   # Use pod network → CoreDNS works
      tolerations:
        - key: node.longhorn.io/storage
          operator: Exists
          effect: NoSchedule
        - key: node.kubernetes.io/gpu   # w3 taint (if present)
          operator: Exists
          effect: NoSchedule
      containers:
        - name: dfs-mounter
          image: alpine:3.19
          securityContext:
            privileged: true
          command: ["/bin/sh", "-c"]
          args:
            - |
              apk add --no-cache cifs-utils --quiet
              mkdir -p /mnt/decypharr-dfs
              while true; do
                # Check if mounted and responsive
                if mountpoint -q /mnt/decypharr-dfs 2>/dev/null; then
                  if ! timeout 3 ls /mnt/decypharr-dfs >/dev/null 2>&1; then
                    echo "CIFS mount stale, force-unmounting..."
                    umount -f /mnt/decypharr-dfs 2>/dev/null || umount -l /mnt/decypharr-dfs 2>/dev/null || true
                  fi
                fi
                # Mount if not mounted
                if ! mountpoint -q /mnt/decypharr-dfs 2>/dev/null; then
                  echo "Mounting DFS via CIFS..."
                  mount -t cifs \
                    //decypharr-streaming-smb.media.svc.cluster.local/ \
                    /mnt/decypharr-dfs \
                    -o guest,vers=3.0,uid=1000,gid=1000 \
                    && echo "DFS mounted" || echo "Mount failed, retrying in 15s..."
                fi
                sleep 15
              done
          volumeMounts:
            - name: dfs-host
              mountPath: /mnt/decypharr-dfs
              mountPropagation: Bidirectional
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
      volumes:
        - name: dfs-host
          hostPath:
            path: /mnt/decypharr-dfs
            type: Directory    # Must pre-exist as shared bind mount (see node prep)
```

### Phase 3 — Sonarr & Radarr Simplification

**Files**: `sonarr/statefulset.yaml`, `radarr/statefulset.yaml`

Changes:
1. Remove `dfs-mounter` sidecar container entirely
2. Remove `dfs-shared` emptyDir volume
3. Add `hostPath` volume:
   ```yaml
   - name: dfs
     hostPath:
       path: /mnt/decypharr-dfs
       type: Directory
   ```
4. Add volumeMount to main container:
   ```yaml
   - name: dfs
     mountPath: /mnt/dfs
     mountPropagation: HostToContainer
   ```
5. Add preferred podAffinity for `app: decypharr-streaming` (topologyKey: `kubernetes.io/hostname`) — ensures co-location when possible but doesn't block startup when decypharr-streaming is down

### Phase 4 — Plex (Future)

When Plex is deployed, its StatefulSet gets the same 6-line hostPath block as Sonarr/Radarr. No additional infrastructure needed. ClusterPlex workers on w3 use the same block — the DaemonSet is already running on w3.

---

## File Structure Changes

```
clusters/homelab/
├── infrastructure/
│   └── dfs-mounter/              ← NEW
│       ├── kustomization.yaml
│       ├── daemonset.yaml
│       └── rbac.yaml             ← ServiceAccount if needed
├── apps/media/
│   ├── decypharr-streaming/
│   │   ├── statefulset.yaml      ← rclone serve smb (change from sftp)
│   │   ├── service-smb.yaml      ← renamed from service-nfs.yaml, port 445
│   │   └── kustomization.yaml    ← update service reference
│   ├── sonarr/
│   │   └── statefulset.yaml      ← remove sidecar, add hostPath
│   └── radarr/
│       └── statefulset.yaml      ← remove sidecar, add hostPath
```

---

## Verification Checklist

After implementation, verify in this order:

```bash
# 1. Node prep verified
ssh k3s-w1 "cat /proc/self/mountinfo | grep decypharr-dfs"
# Expected: an entry with 'shared:' in propagation field

# 2. DaemonSet pods running on all nodes
kubectl get pods -n media -l app=dfs-mounter -o wide
# Expected: one pod on w1, one on w2, one on w3

# 3. DaemonSet has CIFS mounted
kubectl logs -n media -l app=dfs-mounter | grep "DFS mounted"

# 4. Host-level mount visible on w1
ssh k3s-w1 "ls /mnt/decypharr-dfs"
# Expected: RealDebrid DFS content

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
