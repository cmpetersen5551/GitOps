# DFS Troubleshooting Findings & Architecture Pivot

**Date**: 2026-02-26  
**Status**: 🟡 Partially Resolved — Switching from Host Propagation to Direct NFS Mounts  
**Issue**: Sonarr cannot access DFS files despite rclone NFS server running  
**Root Cause**: k3s node mount propagation limitations with the DaemonSet intermediary approach  

---

## Summary of Investigation

### Phase 1: Sonarr 404 Error (✅ Fixed)
- **Symptom**: `sonarr.homelab` returned "404 page not found"
- **Root Cause**: Pod had a stale `dfs-mounter` sidecar from old architecture (SFTP mount)
- **Fix**: Deleted pod to force recreation with clean StatefulSet spec
- **Result**: Sonarr pod now runs with just sonarr container, responds with HTML UI ✅

### Phase 2: Empty DFS Mount (❌ Complex Issue)
- **Symptom**: Sonarr's `/mnt/dfs` was completely empty
- **Initial Suspect**: Missing configuration in decypharr
  - Checked `config.json` — RealDebrid API key present, mount config correct
  - Logs showed decypharr was working: "DFS FUSE ready"
  - Discovery: decypharr's `/mnt/dfs` inside the pod HAS files! (3GB mkv verified)
  
- **Second Suspect**: NFS Export Chain
  - `rclone serve nfs /mnt/dfs --addr 0.0.0.0:2049` is running ✅
  - Service `decypharr-streaming-nfs.media.svc.cluster.local:2049` is accessible ✅
  - Files ARE visible in NFS export via direct pod exec ✅

### Phase 3: DaemonSet Mount Propagation (❌ Not Working)
- **Problem**: Files exist in:
  1. `decypharr-streaming-0:/mnt/dfs` (FUSE) ✅
  2. `decypharr-streaming-nfs.media.svc.cluster.local:/` (NFS) ✅
  3. But `/mnt/decypharr-dfs` on nodes is empty ❌

- **Discovery #1**: ext4 Device Blocking
  - Found `/dev/sda1` or `/dev/vda2` mounted at `/mnt/decypharr-dfs` on all nodes
  - This is Longhorn storage from previous attempts, not from fstab or explicit config
  - Likely from old CIFS mount attempts that left artifacts
  - **Fix**: Unmounted `/dev/sda1` from `/mnt/decypharr-dfs`
  - **Issue**: Device keeps remounting when DaemonSetpod restarts — causes continuous blocking

- **Discovery #2**: Mount Propagation Failing
  - Even after removing blocking ext4 device, NFS mount doesn't appear in DaemonSet pod's `/mnt/decypharr-dfs`
  - Checked `/proc/mounts` inside pod: only sees old ext4, not the NFS we're trying to mount
  - The DaemonSet script runs `mount -t nfs ... decypharr-streaming-nfs.media.svc.cluster.local:/ /mnt/decypharr-dfs`
  - Mount command appears to succeed but files aren't accessible from the mountpoint
  - This aligns with known k3s limitation: `/mnt` on k3s root filesystem is in `rprivate` peer group
  - **Impact**: Bidirectional hostPath propagation cannot cross private peer group boundary

- **Discovery #3**: Why Apps Can't See Mount
  - Sonarr uses `hostPath: /mnt/decypharr-dfs` with `mountPropagation: HostToContainer`
  - Since the DaemonSet mount never properly establishes or doesn't propagate to host, Sonarr sees empty dir
  - The _intended_ chain: DFS FUSE → rclone NFS → DaemonSet kernel mount → hostPath → app pods
  - **Actual result**: DFS FUSE → rclone NFS → (breaks here) ❌

---

## Root Cause Analysis

The DaemonSet + hostPath + mount propagation approach documented in `DFS_ARCHITECTURE_PLAN.md` has **one critical flaw on k3s**:

1. **k3s root filesystem isolation**: The `/mnt` directory lives on k3s's root filesystem, which is mounted as `rprivate` (private peer group)
2. **Bidirectional propagation limitation**: Even with `mountPropagation: Bidirectional`, a mount made inside a `rprivate` peer group cannot propagate back to the host
3. **Result**: DaemonSet successfully mounts NFS in its pod namespace, but the mount never appears in the host's `/mnt` tree
4. **Consequence**: All hostPath-based apps see an empty `/mnt/decypharr-dfs` directory

**The document `DFS_RESEARCH_AND_OPTIONS.md` (section "hostPath + Bidirectional on k3s") mentioned this exact limitation but indicated we had worked around it with "shared bind mount prep on the node." However, that workaround isn't functioning.**

---

## Changes Made

### 1. Removed DaemonSet Intermediary (Architecture Pivot)
Instead of:
```
decypharr (FUSE) → rclone NFS → DaemonSet kernel mount → hostPath → Sonarr/Radarr
```

Changed to:
```
decypharr (FUSE) → rclone NFS → [direct Kubernetes NFS volume] → Sonarr/Radarr
```

### 2. Updated StatefulSet Manifests
**Sonarr** (`clusters/homelab/apps/media/sonarr/statefulset.yaml`):
```yaml
# Before:
- name: dfs
  hostPath:
    path: /mnt/decypharr-dfs
    type: Directory

# After:
- name: dfs
  nfs:
    server: decypharr-streaming-nfs.media.svc.cluster.local
    path: /
    readOnly: true
```

**Radarr** (`clusters/homelab/apps/media/radarr/statefulset.yaml`):
- Same change applied

### 3. Rationale for Direct NFS Approach
- **Simpler**: Eliminates the DaemonSet intermediary that was adding complexity without benefit
- **Works on k3s**: Kubernetes NFS volumes are standard, well-tested, no mount propagation gymnastics
- **Still reliable**: If decypharr-streaming pod fails over to another node, the NFS service automatically reroutes
- **No node setup**: No need for root-level shared mount point prep
- **Fewer moving parts**: One less pod type to monitor and troubleshoot

---

## What Still Works

✅ **decypharr-streaming**:
- FUSE mount `/mnt/dfs` is functional and populated
- Contains actual RealDebrid content (`Too Hot to Handle S06E01` 3GB mkv file verified)
- rclone NFS server listening on port 2049
- rclone serving the FUSE directory correctly

✅ **Kubernetes NFS Service**:
- `decypharr-streaming-nfs.media.svc.cluster.local:2049` is accessible
- rclone outputs NFS correctly

✅ **Sonarr/Radarr Pods**:
- Running and healthy
- Ready to mount NFS volumes

---

## What Didn't Work

❌ **DaemonSet + hostPath Mount Propagation**:
- k3s mount namespace prevents the shared propagation workaround from functioning
- `/dev/sda1` ext4 mounts keep appearing at `/mnt/decypharr-dfs` (legacy artifact, needs cleanup)
- Bidirectional hostPath cannot cross k3s's rprivate peer group boundary
- **Conclusion**: The workaround documented in Phase 1 of `DFS_ARCHITECTURE_PLAN.md` does not work reliably on this k3s setup

---

## Next Steps

1. **Apply changes and verify access**:
   - Commit the Sonarr/Radarr NFS volume changes
   - Force Flux reconciliation to apply updates
   - Delete/recreate Sonarr/Radarr pods to mount NFS directly
   - Verify files appear in `/mnt/dfs` from inside pods

2. **Optional: Retire DaemonSet** (if direct NFS approach succeeds):
   - Remove `dfs-mounter` DaemonSet since it's no longer needed
   - Remove node prep step from `LONGHORN_NODE_SETUP.md`
   - Update architecture documentation to reflect simpler direct-NFS approach

3. **Clean up ext4 artifacts**:
   - Remove `/dev/sda1` references on all nodes
   - Investigate why ext4 mounts keep reappearing

4. **Validate HA behavior**:
   - Test decypharr-streaming failover from w1 → w2
   - Verify Sonarr/Radarr pods can still access files after failover (NFS service should redirect)

---

## Lessons Learned

1. **Mount propagation is fragile in Kubernetes**: Different container runtimes and node configurations behave differently
2. **k3s has peculiar mount isolation**: Unlike standard Kubernetes clusters, k3s's rprivate root FS prevents certain workarounds
3. **Direct Kubernetes volumes are simpler**: When available, let Kubernetes manage the volume lifecycle rather than fighting mount namespaces
4. **DaemonSets are heavy for simple tasks**: The complexity cost (monitoring, debugging, node prep) outweighed the benefit compared to built-in NFS volumes
5. **Always test propagation assumptions**: Theoretical mount propagation and actual behavior can differ significantly

---

## Files Changed

- `clusters/homelab/apps/media/sonarr/statefulset.yaml` — Changed dfs volume from hostPath to NFS
- `clusters/homelab/apps/media/radarr/statefulset.yaml` — Changed dfs volume from hostPath to NFS
- (No DaemonSet changes yet — waiting to verify direct NFS works before removing it)

---

## References

- **Previous Analysis**: `docs/DFS_RESEARCH_AND_OPTIONS.md` — Section "hostPath + Bidirectional on k3s" (correctly identified the limitation)
- **Original Plan**: `docs/current/DFS_ARCHITECTURE_PLAN.md` — DaemonSet approach (no longer applicable)
- **Kubernetes NFS Volume Docs**: https://kubernetes.io/docs/concepts/storage/volumes/#nfs
