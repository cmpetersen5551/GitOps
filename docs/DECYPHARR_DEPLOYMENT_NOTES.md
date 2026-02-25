# Decypharr Deployment Notes

**Date**: 2026-02-24 (Updated)  
**Status**: ✅ DEPLOYED - Two separate instances (streaming + download)

## Architecture Overview

**Dual Decypharr Architecture**: Separate StatefulSets for streaming (RealDebrid) and download (Usenet/Torrent):

1. **Decypharr-Streaming**: RealDebrid/Alldebrid provider
   - Container: decypharr (FUSE client for DFS mount)
   - Sidecar: rclone-nfs-server (exposes DFS as NFS for Sonarr/Radarr/Plex)
   - Storage: DFS cache (emptyDir), streaming-media (RWX PVC)
   - Status: ✅ Running 2/2 on k3s-w1

2. **Decypharr-Download**: Usenet/Torrent provider
   - Container: decypharr (Usenet/Torrent configuration)
   - Storage: Unraid media mount (read-only)
   - Status: ✅ Running 1/1 on k3s-w1

## Streaming Instance Overview (Primary for RealDebrid)

Decypharr-Streaming is deployed as a StatefulSet with two containers:
1. **decypharr**: Main application (DFS FUSE mount + symlink management)
2. **rclone-nfs-server**: Sidecar exposing DFS cache as NFS for remote access (Sonarr, Radarr, ClusterPlex workers)

## Deployment Summary

- **Image**: `cy01/blackhole:latest` (official Docker Hub image)
- **Port**: 8282 (web UI + API)
- **NFS Export**: Port 2049 (rclone sidecar)
- **Storage**:
  - Config: `config-decypharr-0` (10Gi Longhorn RWO)
  - Streaming Media: `pvc-streaming-media` (1Gi Longhorn RWX - for symlinks)
  - DFS Cache: EmptyDir (500Gi ephemeral storage)
- **Node Affinity**: Requires storage nodes (w1/w2), prefers w1
- **Tolerations**: `node.longhorn.io/storage=enabled:NoSchedule`

## Critical Fix Applied (2026-02-18): Longhorn RWX Volume Scheduling

### Issue

Decypharr pod was stuck in `ContainerCreating` because:
1. Decypharr pod scheduled to k3s-w1 (storage node) ✅
2. RWX volume attached to **k3s-cp1** (control plane, no storage) ❌
3. CSI driver couldn't mount volume on cp1 (no Longhorn instance manager)
4. Pod couldn't start, RWX volume stuck "attaching"

### Root Cause

Longhorn's **share-manager pods** (which create the NFSv4 share for RWX volumes) were scheduling to ANY node, including cp1.
- StorageClass parameters like `diskSelector` and `nodeSelector` do NOT control share-manager placement
- System-managed components (share-manager, instance-manager, CSI driver) need separate nodeSelector configuration
- Without it, share-manager could run on cp1, causing volume attachment failures on storage nodes

### Solution Applied

**Updated HelmRelease** (`clusters/homelab/infrastructure/longhorn/helmrelease.yaml`):

```yaml
defaultSettings:
  taintToleration: "node.longhorn.io/storage=enabled:NoSchedule"
  
  # CRITICAL: Restrict system-managed components to storage nodes only
  systemManagedComponentsNodeSelector: "node.longhorn.io/storage:enabled"
```

This ensures:
- ✅ Share-manager pods run ONLY on w1/w2 (labeled with `node.longhorn.io/storage=enabled`)
- ✅ Instance-manager pods run ONLY on w1/w2
- ✅ CSI driver pods can run on all nodes (unchanged)
- ✅ RWX volumes attach to the correct storage node

**Removed invalid StorageClass parameter**:
```yaml
# REMOVED - This doesn't control share-manager placement
diskSelector: '{"node.longhorn.io/storage":"enabled"}'
```

### Verification

**Before fix**:
```
Volume: pvc-c3493aa8-5df2-4ec2-be07-7517cf4be8b0
Node ID: k3s-cp1          ← Wrong!
State: attaching          ← Stuck
Robustness: unknown
```

**After fix**:
```
Volume: pvc-6d1828bc-24c7-4d67-b446-7584883668f5
Node ID: k3s-w2           ← Correct storage node
State: attached           ← Success
Robustness: healthy
```

**Impact**: 
- Decypharr pod now **2/2 Running** on k3s-w1
- Web UI accessible at http://decypharr.homelab
- All subsequent RWX volumes will attach correctly

See [LONGHORN_SYSTEM_COMPONENTS_SCHEDULING.md](./LONGHORN_SYSTEM_COMPONENTS_SCHEDULING.md) for detailed learning.

## Key Configuration Decisions

### 1. Image Selection

**Incorrect images found during debugging:**
- ❌ `ghcr.io/cowboy/decypharr:latest` - Returns 403 Forbidden (private or removed)
- ❌ `sirrobot01/decypharr:latest` - Does not exist / requires authorization

**Correct image:**
- ✅ `cy01/blackhole:latest` - Official public image ([documentation](https://sirrobot01.github.io/decypharr/beta/guides/installation/))

### 2. Port Configuration

- **Official Port**: 8282 (not 8080)
- Service port: 8282 → targetPort 8282
- Ingress backend: port 8282
- Reference: Official Docker Compose examples use port 8282

### 3. Health Probes - REMOVED

**Problem**: All Decypharr endpoints (including `/` and `/api/health`) return `401 Unauthorized` until initial authentication is configured via web UI.

**Solution**: Removed all health probes (liveness, readiness, startup):
- Kubernetes keeps pod running as long as process is alive
- Application manages its own lifecycle
- HTTP probes fail with `401` before auth setup completes
- Pod status: `2/2 Running` without external health checks

**Logs during failed probes:**
```
Warning  Unhealthy  7s (x4 over 37s)  kubelet  Startup probe failed: HTTP probe failed with statuscode: 401
```

### 4. Rclone NFS Server Configuration

**Removed invalid flag:**
- ❌ `--nfs-hide-dot-file=true` - Not a valid rclone flag (causes crash)
- ✅ Working command: `rclone serve nfs /mnt/dfs --addr=0.0.0.0:2049`

**Rclone warnings (expected):**
```
WARNING: NFS writes don't work without a cache, the filesystem will be served read-only
```
This is intentional - DFS cache should be read-only for safety (only Decypharr writes).

### 5. Streaming Media PVC Size

**Evolution:**
- Initial: 100Gi → Too large, caused scheduling failures (insufficient disk space)
- Revised: 10Gi → Still excessive for symlinks only
- **Final**: 1Gi → Appropriate size for symlink library (symlinks are ~100 bytes each)

**Rationale**: Decypharr creates symbolic links pointing to DFS cache (EmptyDir). The streaming-media PVC only stores the symlinks themselves, not the actual media files. Even 10,000 symlinks use < 1MB of space.

## Critical Infrastructure Requirement: nfs-common

### Problem Encountered

Initial deployment failed with error:
```
MountVolume.MountDevice failed for volume "pvc-919fcf01-2341-4589-915d-da12a26b0abd": 
mount failed: exit status 32
Output: fsconfig() failed: NFS: mount program didn't pass remote address
```

### Root Cause

Longhorn RWX volumes use **NFSv4 internally** via share-manager pods. The Longhorn CSI driver on each node requires the host's `mount.nfs` binary to mount these NFS exports.

**Debian 13 (trixie)** nodes did not have `nfs-common` package installed by default.

### Solution

Install `nfs-common` on **ALL storage nodes** (w1, w2):

```bash
# Via kubectl debug (one-time fix)
kubectl debug node/k3s-w1 -it --image=debian:trixie -- chroot /host bash -c \
  "apt-get update && apt-get install -y nfs-common"

kubectl debug node/k3s-w2 -it --image=debian:trixie -- chroot /host bash -c \
  "apt-get update && apt-get install -y nfs-common"
```

**Verification:**
```bash
kubectl debug node/k3s-w1 -it --image=debian:trixie -- chroot /host bash -c \
  "dpkg -l | grep nfs-common && mount.nfs --version"
```

### Why This Wasn't Obvious

- Longhorn documentation mentions NFS client requirements for RWX volumes, but it's not prominent
- Error message "mount program didn't pass remote address" is cryptic and doesn't mention missing packages
- k3s doesn't bundle NFS client utilities (unlike some Kubernetes distros)
- Traditional NFS PVs (like Unraid NFS) worked fine because they're handled differently by k3s

**References:**
- [Longhorn GitHub Issue #8508](https://github.com/longhorn/longhorn/issues/8508)
- [Longhorn RWX Volume Documentation](https://longhorn.io/docs/latest/volumes-and-nodes/rwx-volumes/)

### Long-term Solution

Add `nfs-common` installation to node provisioning playbook/automation. This is a **host-level requirement**, not a Kubernetes-level resource.

## NFS Version Selection

### Attempted Configurations

1. **Initial**: No NFS version specified → Used system default (likely 4.0)
   - **Result**: Mount failed (missing nfs-common)

2. **After research**: NFSv4.2 with explicit mount options
   ```yaml
   nfsOptions: "vers=4.2,soft,timeo=600,retrans=5"
   ```
   - **Result**: Same failure (root cause was nfs-common, not NFS version)

3. **Alternative**: NFSv4.1 (broader kernel compatibility)
   ```yaml
   nfsOptions: "vers=4.1,soft,timeo=600,retrans=5"
   ```
   - **Result**: Works after nfs-common installation

### Final Configuration

Using NFSv4.1 in `storageclass-rwx.yaml`:
```yaml
parameters:
  nfsOptions: "vers=4.1,soft,timeo=600,retrans=5"
```

**Note**: NFSv4.2 should also work now that nfs-common is installed. NFSv4.1 was chosen for maximum compatibility.

## Services

### 1. decypharr (ClusterIP - API/UI)
```yaml
ports:
  - name: http
    port: 8282
    targetPort: 8282
```

### 2. decypharr-nfs (ClusterIP - NFS Export)
```yaml
ports:
  - name: nfs
    port: 2049
    targetPort: 2049
```

**Purpose**: Exposes DFS cache for ClusterPlex workers on w3 (GPU node). Workers cannot access FUSE mounts across nodes, so they mount this NFS export instead.

## Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: decypharr
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
    - host: decypharr.homelab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: decypharr
                port:
                  number: 8282
```

**Access**: http://decypharr.homelab or `kubectl port-forward svc/decypharr 8282:8282 -n media`

## Initial Setup via Web UI

1. Access http://decypharr.homelab
2. **Setup Wizard** launches automatically on first run
3. Create admin credentials
4. Configure RealDebrid/AllDebrid API key
5. Configure UsenetExpress (optional)
6. Set library paths (defaults work for this deployment)
7. Complete setup

## Volume Mounts

### decypharr container
- `/config` → `config-decypharr-0` PVC (persistent config/database)
- `/mnt/dfs` → EmptyDir (DFS FUSE mount - ephemeral cache)
- `/mnt/streaming-media` → `pvc-streaming-media` (Longhorn RWX - symlink library)

### rclone-nfs-server container
- `/mnt/dfs` → EmptyDir (read-only - shares DFS cache via NFS)

## Security Context

- **Privileged**: `true` (required for FUSE mount)
- **Capabilities**: `SYS_ADMIN` (required for FUSE)
- **User**: root (0) initially, then drops to appuser (1000) via entrypoint script

## Known Issues / Gotchas

1. **401 on all endpoints before auth**: Normal behavior, not an error
2. **"mount program didn't pass remote address"**: Install nfs-common on nodes
3. **Pod stuck ContainerCreating**: Usually means PVC mount failure - check Longhorn and nfs-common
4. **Rclone "read-only" warning**: Expected and intentional for safety
5. **Image pull failures**: Use `cy01/blackhole:latest`, not `sirrobot01/decypharr` or `ghcr.io/cowboy/decypharr`

## Verification Checklist

```bash
# 1. Pod running with 2/2 containers
kubectl get pods -n media decypharr-0
# Expected: 2/2 Running

# 2. Streaming media PVC bound
kubectl get pvc -n media pvc-streaming-media
# Expected: Bound to longhorn-rwx volume

# 3. Streaming media mount accessible
kubectl exec decypharr-0 -n media -c decypharr -- ls -la /mnt/streaming-media
# Expected: Directory listing with lost+found

# 4. DFS mount present
kubectl exec decypharr-0 -n media -c decypharr -- mount | grep fuse
# Expected: /mnt/dfs with fuse type

# 5. NFS server responding
kubectl exec decypharr-0 -n media -c rclone-nfs-server -- netstat -tlnp | grep 2049
# Expected: Listening on :2049

# 6. Decypharr process running
kubectl exec decypharr-0 -n media -c decypharr -- ps aux | grep decypharr
# Expected: /usr/bin/decypharr process visible

# 7. Web UI accessible
curl -I http://decypharr.homelab 2>&1 | grep -E "HTTP|401"
# Expected: HTTP/1.1 401 Unauthorized (before auth setup)

# 8. Service endpoints healthy
kubectl get endpoints -n media decypharr decypharr-nfs
# Expected: Both show pod IP on respective ports
```

## Sonarr/Radarr Integration

### Mount Configuration

**Sonarr and Radarr require the following mounts** (as of 2026-02-24):

| Mount Path | Source | Provider | Purpose |
|-----------|--------|----------|---------|
| `/mnt/media` | `pvc-media-nfs` | decypharr-download | Unraid media (read-only) |
| `/mnt/dfs` | NFS via decypharr-streaming-nfs.media.svc | decypharr-streaming | RealDebrid downloads |
| `/mnt/streaming-media` | `pvc-streaming-media` | Longhorn RWX | Symlinks and streamed content |

**Volume Definition** (for Sonarr/Radarr StatefulSet):
```yaml
volumes:
  - name: media-nfs
    persistentVolumeClaim:
      claimName: pvc-media-nfs
  - name: streaming-media
    persistentVolumeClaim:
      claimName: pvc-streaming-media
  - name: dfs-nfs  # RealDebrid downloads via decypharr-streaming NFS
    nfs:
      server: decypharr-streaming-nfs.media.svc.cluster.local
      path: /
      readOnly: false

# Container volumeMounts:
volumeMounts:
  - name: config
    mountPath: /config
  - name: media-nfs
    mountPath: /mnt/media
  - name: dfs-nfs
    mountPath: /mnt/dfs
  - name: streaming-media
    mountPath: /mnt/streaming-media
```

### Data Flow

1. **Download Instance** → `/mnt/media` (Usenet/Torrent → Unraid)
2. **Streaming Instance** → `/mnt/dfs` (RealDebrid/Alldebrid cache)
3. **Sonarr/Radarr** → Can see both paths, choose download locations per show/movie
4. **Symlinks** → Created in `/mnt/streaming-media`, links point to either Unraid or RealDebrid

## Troubleshooting

### Pod won't start - Mount errors

**Check share-manager pod:**
```bash
kubectl get pods -n longhorn-system | grep share-manager | grep pvc-streaming-media
kubectl logs -n longhorn-system share-manager-pvc-XXX
```

**Check nfs-common on node:**
```bash
kubectl debug node/k3s-w1 -it --image=debian:trixie -- chroot /host bash -c \
  "dpkg -l | grep nfs-common || echo 'NOT INSTALLED'"
```

### Web UI returns 401

**This is normal before initial setup!** Health probes expect this. Access via ingress or port-forward to complete setup wizard.

### Rclone container crash loop

Check for invalid flags:
```bash
kubectl logs decypharr-0 -n media -c rclone-nfs-server --tail=20
```

Look for: `NOTICE: Fatal error: unknown flag`

## Performance Notes

- **Longhorn RWX overhead**: ~10-30% slower than direct block storage (RWO) due to NFSv4 layer
- **DFS cache**: Performance depends on EmptyDir backend (usually local SSD)
- **Symlink resolution**: Negligible overhead (<1ms per operation)
- **Network**: NFS export adds latency for remote workers (~1-2ms on gigabit)

## Related Documentation

- [LONGHORN_NODE_SETUP.md](./LONGHORN_NODE_SETUP.md) - Node labels, taints, and nfs-common requirement
- [MEDIA_STACK_IMPLEMENTATION_PLAN.md](./MEDIA_STACK_IMPLEMENTATION_PLAN.md) - Full deployment plan
- [LONGHORN_HA_MIGRATION.md](./LONGHORN_HA_MIGRATION.md) - HA architecture and failover behavior
