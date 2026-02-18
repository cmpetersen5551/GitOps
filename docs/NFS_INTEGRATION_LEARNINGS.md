# NFS Storage Integration - Learnings & Best Practices

**Date**: 2026-02-17  
**Context**: Integrated Unraid NFS media share with k3s media stack (Sonarr, Radarr, Decypharr)  
**Status**: ✅ Operational

---

## Overview

Kubernetes NFS integration requires careful planning around StorageClasses, PersistentVolumes (PVs), and pod mount strategies. This document captures key learnings from integrating Unraid NFS shares into a k3s homelab.

---

## Key Discoveries

### 1. StorageClass is Essential for Kubernetes-Native NFS

**Problem**: PVs and PVCs were created but Kubernetes had no "provisioner" for the storage class `nfs-unraid`.

**Solution**: Create explicit StorageClass resource:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-unraid
provisioner: kubernetes.io/nfs
parameters:
  server: 192.168.1.29
  path: /mnt/user
  readOnly: "false"
allowVolumeExpansion: false
reclaimPolicy: Retain
volumeBindingMode: Immediate
```

**Key Points**:
- Provisioner: `kubernetes.io/nfs` (built-in, no external driver needed for homelab)
- Server/path: Must match your Unraid NFS export exactly
- `reclaimPolicy: Retain` - don't delete PVs when PVCs are removed
- `volumeBindingMode: Immediate` - bind volumes immediately (important for static PVs)

**Verification**:
```bash
kubectl get storageclass nfs-unraid
# Should show: Custom kubernetes.io/nfs provisioner
```

### 2. Access Denied Errors: Permission and Export Configuration

**Problem Encountered**:
```
mount.nfs: access denied by server while mounting 192.168.1.29:/mnt/user/transcode
```

**Root Cause**: NFS export not configured on Unraid.

**Solution Applied**:
1. Unraid UI → Shares → Select share (e.g., "media")
2. NFS Security Settings:
   - Share name: `media`
   - Export: **Yes** (must be enabled)
   - Security: **Public** (for homelab; use credential-based for production)
3. Apply settings

**Best Practice**: 
- Test NFS mount from another host first:
  ```bash
  mount -t nfs 192.168.1.29:/mnt/user/media /mnt/test
  ls /mnt/test  # Should list media contents
  umount /mnt/test
  ```
- Only then configure Kubernetes pods

### 3. ReadOnlyMany vs ReadWriteMany: Access Mode Strategy

**Decision Matrix**:
| Share | Purpose | Access Mode | Reason |
|-------|---------|------------|--------|
| Media | Permanent library | ROX (ReadOnlyMany) | No pod modifies library; safe for concurrent access |
| Transcode | Cache directory | RWX (ReadWriteMany) | Multiple pods write temp files; requires RWX |
| Config | App settings | RWO (ReadWriteOnce) | Should use Longhorn instead; NFS not suitable for state |

**Lesson**: Don't use NFS for application state (configs). Use block storage (Longhorn) instead. NFS is best for shared read-only data or caches.

### 4. Unified Mount Paths Across Containers

**Pattern Adopted**:
```
All pods mount Unraid shares at the SAME paths:
- /mnt/media     (read-only library from Unraid)
- /mnt/transcode (cache, when available)
```

**Benefits**:
- Symlinks work consistently across pods (e.g., Decypharr creates links → Plex reads them)
- Simplified pod configuration (all containers see the same paths)
- Easy to understand: single source of truth

**Implementation**:
```yaml
volumes:
  - name: media-nfs
    persistentVolumeClaim:
      claimName: pvc-media-nfs
      
volumeMounts:
  - name: media-nfs
    mountPath: /mnt/media
    readOnly: true  # Explicitly document access mode
```

### 5. PV/PVC Binding: Static Binding for Pre-Existing NFS Exports

**Challenge**: Unraid media share already exists; we're not creating new volumes.

**Solution**: Create **static** PersistentVolumes:
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-nfs-media
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadOnlyMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs-unraid
  nfs:
    server: 192.168.1.29
    path: /mnt/user/media
    readOnly: true
```

**Then create PVC to bind to PV**:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-media-nfs
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: nfs-unraid
  resources:
    requests:
      storage: 1Ti
  volumeName: pv-nfs-media  # Bind to specific PV
```

**Key Detail**: `volumeName: pv-nfs-media` explicitly binds this PVC to the static PV.

### 6. Mount Timing: Order Matters with Combined Storage

**Challenge**: Pods have:
- **Config** on Longhorn (block storage, slow to mount)
- **Media** on NFS (network mount, can fail if network not ready)

**Solution**: Let Kubernetes handle ordering via resource requests and health probes:
- Longhorn volume mounts first (before container starts)
- NFS mounts second (during container startup)
- Health checks verify all mounts successful before marking pod Ready

**NO Need** for init containers for read-only shares—Kubernetes handles sequencing.

### 7. Kustomization Path References: Relative Paths Matter

**Problem Encountered**:
```
accumulating resources from '../../infrastructure/storage/nfs/storageclass.yaml': 
no such file or directory
```

**Root Cause**: Relative paths in Kustomization are relative to the kustomization.yaml location, not the working directory.

**Solution**: Place StorageClass in infrastructure layer where it logically belongs:
```
clusters/homelab/infrastructure/storage/nfs/
├── kustomization.yaml
├── pv-nfs-media.yaml
├── pv-nfs-transcode.yaml
└── storageclass.yaml  ← Define here
```

**Update kustomization**:
```yaml
# clusters/homelab/infrastructure/storage/nfs/kustomization.yaml
resources:
  - pv-nfs-media.yaml
  - pv-nfs-transcode.yaml
  - storageclass.yaml  # Referenced from same directory
```

**Lesson**: Don't use relative paths across layer boundaries in kustomize; place resources logically in their own layer.

---

## Recommended Configuration Checklist

### Before Deploying Pods with NFS

- [ ] NFS export is ENABLED on Unraid (Shares → NFS Security → Export: Yes)
- [ ] NFS export path is CORRECT (`/mnt/user/media`, not `/media`)
- [ ] Test mount from another host to verify connectivity
- [ ] StorageClass `nfs-unraid` is created in cluster
- [ ] PersistentVolume `pv-nfs-*` is created with correct server/path
- [ ] PersistentVolumeClaim is bound to PV (check `kubectl get pvc`)
- [ ] Firewall/network allows NFS traffic (ports 111, 2049, typically)

### For Each Pod Using NFS

- [ ] Volume is listed in `spec.volumes`
- [ ] Mount is listed in `spec.containers[].volumeMounts`
- [ ] `readOnly: true` is set for read-only mounts (library, media)
- [ ] `readOnly: false` or omitted for read-write mounts (cache)
- [ ] `mountPath` is consistent across all pods (e.g., always `/mnt/media`)

### Testing After Deployment

```bash
# Verify mount is active
kubectl exec -n media <pod-name> -- mount | grep /mnt/media

# Verify read access
kubectl exec -n media <pod-name> -- ls -lh /mnt/media

# Verify write access (if RWX)
kubectl exec -n media <pod-name> -- touch /mnt/transcode/test.txt
kubectl exec -n media <pod-name> -- rm /mnt/transcode/test.txt
```

---

## Common Issues & Resolutions

### Issue: "MountVolume.SetUp failed... access denied"

**Possible Causes**:
1. NFS export not enabled on Unraid
2. NFS path is incorrect (e.g., `/media` vs `/mnt/user/media`)
3. Firewall blocking NFS ports (111, 2049)

**Debugging**:
```bash
# Check pod events
kubectl describe pod <pod-name> -n media | grep -A 5 "Warning.*FailedMount"

# Check NFS mount from node
kubectl debug node/k3s-w1 -it --image=alpine -- mount -t nfs 192.168.1.29:/mnt/user/media /test
```

### Issue: PVC Stuck in "Pending"

**Possible Causes**:
1. PV not yet bound (check `kubectl get pv`)
2. Storage class mismatch
3. Access mode incompatible

**Resolution**:
```bash
# Check PV status
kubectl get pv pv-nfs-media

# Force PVC to bind by specifying volumeName
kubectl patch pvc pvc-media-nfs -p '{"spec":{"volumeName":"pv-nfs-media"}}'
```

### Issue: Pods Starting but NFS Not Mounted

**Possible Cause**: StorageClass missing or incorrectly named.

**Verification**:
```bash
kubectl get storageclass
# Should include: nfs-unraid   kubernetes.io/nfs
```

---

## Architecture Patterns

### Pattern 1: Permanent Media Library (Read-Only)

**Use Case**: TV shows, movies, music—never modified by apps, only read.

```yaml
accessModes: [ReadOnlyMany]  # Multiple pods, no writes
volumeMount:
  readOnly: true             # Explicitly enforce
```

### Pattern 2: Temporary Cache (Read-Write, Shared)

**Use Case**: Transcode cache, downloads directory—multiple apps write, no conflicts.

```yaml
accessModes: [ReadWriteMany]  # Multiple pods, concurrent writes
volumeMount:
  readOnly: false            # Allow writes
```

### Pattern 3: Hybrid Pod (Read Library, Write Cache)

**Use Case**: Sonarr with both media library + transcode cache.

```yaml
volumes:
  - name: media-nfs
    persistentVolumeClaim:
      claimName: pvc-media-nfs
  - name: transcode-nfs
    persistentVolumeClaim:
      claimName: pvc-transcode-nfs

volumeMounts:
  - name: media-nfs
    mountPath: /mnt/media
    readOnly: true           # Library is read-only
  - name: transcode-nfs
    mountPath: /mnt/transcode
    readOnly: false          # Cache is read-write
```

---

## Performance Considerations

### NFS Mount Latency

- **First mount**: 1-3 seconds (network lookup + FUSE mount)
- **Subsequent mounts**: <100ms (cached)
- **Best for**: Sequential reads (music, movies), metadata queries
- **Avoid for**: High-frequency small writes, database activity

### Scaling

- **Read throughput**: Limited by network link (1Gbps typical)
- **Concurrent connections**: 10+ pods per share is fine
- **Disk I/O**: Limited by Unraid array performance (typically 50-200 MB/s write, higher for reads)

### Optimization Tips

1. Use Longhorn for state (configs, databases)
2. Use NFS for media (read-only, large files)
3. Co-locate high-bandwidth pods on same node  
4. Consider local caching layers for frequently accessed files

---

## Future Enhancements

### When to Scale Beyond NFS

**Add NFS export for transcode cache**:
```bash
# On Unraid: Add NFS export for /mnt/user/transcode
# Parameters: Export: Yes, Security: Public (homelab)
```

**Add Longhorn RWX for distributed transcode** (if GPU transcoding via ClusterPlex):
```yaml
# Create longhorn-rwx StorageClass for transcode coordination
numberOfReplicas: 2
accessModes: [ReadWriteMany]
```

### Authentication for Production

If expanding beyond homelab:
```yaml
# Use Kerberos or credential-based auth
nfs:
  server: 192.168.1.29
  path: /mnt/user/media
  readOnly: true
  # Add secret reference for credentials (advanced)
```

---

**Related Documents**:
- [MEDIA_STACK_IMPLEMENTATION_PLAN.md](./MEDIA_STACK_IMPLEMENTATION_PLAN.md) - Phase 5 deployment details
- [LONGHORN_HA_MIGRATION.md](./LONGHORN_HA_MIGRATION.md) - Block storage strategy
- [NFS_STORAGE.md](./NFS_STORAGE.md) - Basic NFS setup reference

