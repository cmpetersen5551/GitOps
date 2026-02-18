# Unraid NFS Exports & Kubernetes Integration

**Status**: ✅ Media share (ro) operational in k3s | ⏳ Transcode share pending  
**Last Updated**: 2026-02-17

---

## Current Implementation (2026-02-17)

### Deployed Shares
- ✅ **Media** (`/mnt/user/media`) - Mounted read-only in Sonarr, Radarr, Decypharr at `/mnt/media`
  - PV: `pv-nfs-media` (1Ti, ReadOnlyMany)
  - PVC: `pvc-media-nfs` 
  - Accessible from all media pods
  
- ⏳ **Transcode** (`/mnt/user/transcode`) - Pending NFS export on Unraid
  - PV: `pv-nfs-transcode` (200Gi, ReadWriteMany) - configured but not mounted yet
  - PVC: `pvc-transcode-nfs` - defined, waiting for export

### StorageClass
- ✅ **nfs-unraid** - kubernetes.io/nfs provisioner created
  - Server: 192.168.1.29
  - Default path: /mnt/user (auto-expanded per PV needs)

---

## Unraid NFS Configuration

### Enable NFS Export for Media Share

1. **Unraid WebUI** → Shares → Select "media" share
2. **NFS Security Settings**:
   - Share name: `media`
   - Export: **Yes** (enable)
   - Security: **Public** (homelab default; use credentials for production)
3. Click **DONE** to apply

### Future: Enable NFS Export for Transcode Cache

```
Repeat same steps for "transcode" share:
- Share name: transcode
- Export: Yes
- Security: Public
```

---

## Manual NFS Mounting (Reference)

This is for testing. Kubernetes handles all mounting automatically via PVs/PVCs.

```bash
# Test mount from external host
mkdir -p /mnt/unraid/media /mnt/unraid/transcode
mount -t nfs 192.168.1.29:/mnt/user/media /mnt/unraid/media
mount -t nfs 192.168.1.29:/mnt/user/transcode /mnt/unraid/transcode

# Verify
ls /mnt/unraid/media
ls /mnt/unraid/transcode

# Unmount when done
umount /mnt/unraid/media
umount /mnt/unraid/transcode
```

---

## Kubernetes PVC/PV Configuration

**Media (Read-Only)**:
```yaml
# PV: pv-nfs-media
accessModes: [ReadOnlyMany]
storageClassName: nfs-unraid
nfs:
  server: 192.168.1.29
  path: /mnt/user/media
  readOnly: true

# PVC: pvc-media-nfs
accessModes: [ReadOnlyMany]
storageClassName: nfs-unraid
volumeName: pv-nfs-media
```

**Transcode (Read-Write, shared)**:
```yaml
# PV: pv-nfs-transcode
accessModes: [ReadWriteMany]
storageClassName: nfs-unraid
nfs:
  server: 192.168.1.29
  path: /mnt/user/transcode
  readOnly: false

# PVC: pvc-transcode-nfs
accessModes: [ReadWriteMany]
storageClassName: nfs-unraid
volumeName: pv-nfs-transcode
```

---

## Pod Integration

### Mount Points (Unified Across All Pods)

```
/mnt/media       ← Unraid permanent media library (read-only)
/mnt/transcode   ← Unraid cache directory (read-write, when enabled)
```

### Current Pod Usage

| Pod | Media Mount | Transcode Mount | Status |
|-----|------------|-----------------|--------|
| Sonarr | `/mnt/media` ✅ | `/mnt/transcode` ⏳ | Ready for config |
| Radarr | `/mnt/media` ✅ | `/mnt/transcode` ⏳ | Ready for config |
| Decypharr | `/mnt/media` ✅ | `/mnt/transcode` ⏳ | Accessible |

---

## Troubleshooting

### PVC Stuck in Pending State
```bash
# Check PV binding
kubectl get pv pv-nfs-media

# Check StorageClass exists
kubectl get storageclass nfs-unraid

# Force bind (if needed)
kubectl patch pvc pvc-media-nfs -p '{"spec":{"volumeName":"pv-nfs-media"}}'
```

### Mount Access Denied
```bash
# Check pod events
kubectl describe pod sonarr-0 -n media | grep -A 5 "FailedMount"

# Test NFS export from cluster node
kubectl debug node/k3s-w1 -it --image=alpine -- \
  mount -t nfs 192.168.1.29:/mnt/user/media /test && ls /test
```

### Verify Mount in Running Pod
```bash
# Check if mounted
kubectl exec -n media sonarr-0 -- mount | grep /mnt/media

# List contents
kubectl exec -n media sonarr-0 -- ls -lh /mnt/media
```

---

## References

- **Learnings & Best Practices**: [NFS_INTEGRATION_LEARNINGS.md](./NFS_INTEGRATION_LEARNINGS.md) - Deep dive into design decisions
- **Implementation Plan**: [MEDIA_STACK_IMPLEMENTATION_PLAN.md](./MEDIA_STACK_IMPLEMENTATION_PLAN.md) - Phase 5 deployment details
- **Kubernetes NFS**: https://kubernetes.io/docs/concepts/storage/persistent-volumes/#nfs

---

## Notes

- `pv-nfs-media.yaml` is ReadOnlyMany - safe for concurrent pod access
- `pv-nfs-transcode.yaml` is ReadWriteMany - for shared cache writes
- Both use `reclaimPolicy: Retain` - don't auto-delete when PVCs removed
- NFS performance suitable for sequential media reads, not database workloads
- For application state/configs, use Longhorn (block storage) instead
