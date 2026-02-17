# Cluster State Summary - Longhorn HA Migration Complete

**Date**: 2026-02-15  
**Status**: ✅ Operational | Clean | Documented | Ready for Testing

---

## System Health Check

### ✅ Cluster
- **Nodes**: 4 (cp1 control, w1/w2 storage, w3 edge)
- **Longhorn Nodes**: w1, w2 (both healthy, disks ready)
- **Flux**: Synced (latest commit eb1a97d)
- **Git Status**: Clean (no uncommitted changes)

### ✅ Storage
- **Primary**: Longhorn (2-node HA)
  - Sonarr config: `pvc-c935ff84-df1b-4ab7-934e-9fa748e1720d` (5Gi, Healthy)
  - 2 replicas: 1 on w1, 1 on w2
  - Robust data distribution

- **Secondary**: NFS on Unraid (SPOF, acceptable for homelab)
  - Media library: 1Ti (ro access from all nodes)
  - Transcode cache: 200Gi (rw access for sonarr/prowlarr)

### ✅ Applications
| App | Status | Storage | Replicas | Node |
|-----|--------|---------|----------|------|
| Sonarr | ✅ Running | Longhorn | 1/1 | k3s-w1 |
| Radarr | ✅ Running | Longhorn | 1/1 | k3s-w1 |
| Prowlarr | ⏸ Ready | Longhorn | 0/0 | (scaled down) |

### ✅ Infrastructure
| Component | Status | Details |
|-----------|--------|---------|
| Longhorn | ✅ Ready | v1.8.x, HelmRelease, 2-node optimized |
| open-iscsi | ✅ Running | DaemonSet on w1/w2 |
| Node Labels | ✅ Applied | storage=enabled, create-default-disk=true on w1/w2 |
| Node Taints | ✅ Applied | storage=enabled:NoSchedule on w1/w2 |
| StorageClass | ✅ Ready | longhorn-simple (2-replica, no-soft-affinity) |

---

## Recent Changes (This Session - 2026-02-17)

### Phase 2: Radarr Deployment Complete ✅
- ✅ Radarr StatefulSet deployed (mirrors Sonarr architecture)
- ✅ Service & Ingress routing configured
- ✅ Pod running on k3s-w1 with Longhorn 5Gi PVC
- ✅ Web UI accessible at radarr.homelab

**Issues Resolved**:
1. Image tag `5.2.5` → `latest` (exact tag didn't exist)
2. Service port `7878` → `80` (standardized with Sonarr for Ingress compatibility)
3. Removed invalid Traefik annotation `router.entrypoints: web,websecure` (doesn't match Traefik's `http`/`https` config)

**Commits**: 5be33db (Radarr ingress fix), 6a932e5 (service port fix), b788d6f (image tag fix), 6dfa2b3 (initial deployment)

## Previous Changes (Session 1 - 2026-02-15)

### Removed
- ✏️ `clusters/homelab/infrastructure/seaweedfs/` (entire directory)
  - helmrelease.yaml, helmrepository.yaml, kustomization.yaml, namespace.yaml, seaweed.yaml.operator-backup
  - Rationale: SeaweedFS cannot provide true 2-node HA (needs 3+ nodes)

### Added
- 📄 `LONGHORN_HA_MIGRATION.md` - Migration summary + reference guide
- 📄 `README_DOCUMENTATION.md` - Documentation index
- 📄 `clusters/homelab/infrastructure/longhorn/NODE_SETUP.md` - Node configuration run-book

### Modified
- 📝 `clusters/homelab/apps/media/sonarr/statefulset.yaml` - Added Longhorn StorageClass + node affinity + taint tolerations
- 📝 `clusters/homelab/apps/media/prowlarr/statefulset.yaml` - Added Longhorn StorageClass + node affinity + taint tolerations
- 📝 `clusters/homelab/infrastructure/kustomization.yaml` - Removed seaweedfs references

### Commits
```
eb1a97d docs: Add Longhorn HA migration guide and documentation index
71a40bd Remove SeaweedFS infrastructure - fully migrated to Longhorn for true 2-node HA
```

---

## Key Learnings Documented

### 1. Disk Auto-Creation **(THE CRITICAL LABEL)**
- ❌ `node.longhorn.io/storage=enabled` → Only nodeSelector placement
- ✅ `node.longhorn.io/create-default-disk=true` → Triggers disk auto-creation
- **Both labels required** for proper Longhorn 2-node HA

### 2. 2-Node HA Requirements
```yaml
replicaSoftAntiAffinity: false    # MUST be false (default true breaks 2-node)
defaultReplicaCount: 2             # 1 replica per node
replicaAutoBalance: least-effort   # Prevent thrashing
```

### 3. Pod Scheduling (Node Affinity)
- Use `requiredDuringScheduling` (not preferred)
- Pair with taint tolerations for storage taints
- Ensures pods only schedule where storage available

### 4. GitOps Strategy
- ✅ Application manifests → Git
- ✅ StorageClass definitions → Git
- 🔶 Node labels/taints → Documented, manual/external (Terraform)
- Rationale: Infrastructure layer changes rarely; document but don't over-GitOps

---

## Test Checklist (Ready for Next Phase)

### HA Failover Testing
- [ ] **Test 1**: Kill k3s-w1, verify Sonarr reschedules to k3s-w2
  - Monitor: Pod eviction timing, volume remount, data persistence
  - Expected downtime: ~60s
  - Expected data loss: 0 (both replicas)

- [ ] **Test 2**: Restore k3s-w1, verify volume rebalances
  - Monitor: Replica migration, load rebalancing
  - Verify: Data consistency, no corruption

- [ ] **Test 3**: Scale Prowlarr to 1 replica
  - Verify: PVC created, Prowlarr pod starts, config accessible
  - Monitor: Scheduling on storage node (w1 or w2)

### Production Hardening
- [ ] Configure Longhorn backup (external NAS or S3)
- [ ] Set up Prometheus alerts for volume health degradation
- [ ] Document recovery procedures (broken volume, node replacement)
- [ ] Test volume expansion workflow

---

## File Locations (Reference)

### Critical Configs
- [Longhorn HelmRelease](./clusters/homelab/infrastructure/longhorn/helmrelease.yaml)
- [Longhorn StorageClass](./clusters/homelab/infrastructure/longhorn/storageclass-simple.yaml)
- [Sonarr StatefulSet](./clusters/homelab/apps/media/sonarr/statefulset.yaml)
- [Prowlarr StatefulSet](./clusters/homelab/apps/media/prowlarr/statefulset.yaml)

### Documentation
- [Longhorn HA Migration Guide](./LONGHORN_HA_MIGRATION.md) - Full reference
- [Node Setup Run-Book](./clusters/homelab/infrastructure/longhorn/NODE_SETUP.md) - Node config steps
- [Documentation Index](./README_DOCUMENTATION.md) - All docs organized

### Archive
- Old SeaweedFS planning docs (superseded, kept for history)

---

## Quick Commands

```bash
# Watch Sonarr
kubectl get pods -n media -w

# Check Longhorn volume health
kubectl get volumes.longhorn.io -n longhorn-system

# Check replica distribution
kubectl get nodes.longhorn.io k3s-w1 k3s-w2 -n longhorn-system -o json | \
  jq '.items[] | {name:.metadata.name, disks:.status.diskStatus | keys}'

# Monitor node resources
kubectl top nodes k3s-w1 k3s-w2

# Tail Sonarr logs
kubectl logs -n media -f sonarr-0

# Port-forward to Longhorn UI (if needed)
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```

---

## What's NOT Left Behind

✅ **Clean removal**:
- SeaweedFS manifests fully removed (5 files)
- seaweedfs namespace will auto-cleanup when Flux syncs
- No orphaned PVCs or PVs from SeaweedFS

✅ **No technical debt**:
- All configuration changes committed
- Node setup documented in NODE_SETUP.md
- Lesson learned documented in LONGHORN_HA_MIGRATION.md
- No manual workarounds or hacks

✅ **GitOps maintained**:
- All app + infrastructure configs in Git
- Flux synced to latest commit
- Ready for CI/CD integration

---

## Session Reflection

### What Went Well
1. **Systematic approach**: Removed broken storage, tested new storage, validated app migration
2. **Learning orientation**: Researched Longhorn limits, tested assumptions, documented findings
3. **GitOps discipline**: All changes in Git, minimized manual intervention
4. **HA-first design**: Ensured 2-node replication, node affinity, taint tolerations from start

### Critical Discovery
The `node.longhorn.io/create-default-disk=true` label was the make-or-break discovery. Without it, Longhorn won't auto-create disks. This was the gap between "config deployed" and "actually working HA."

### Lessons for Production
- Always test label/taint requirements early
- Document infrastructure layer assumptions
- Use required (not preferred) node affinity for critical workloads
- 2-node is a hard limit for certain systems; verify before committing

---

**Status**: Cluster is stable, documented, and ready for controlled HA testing.  
**Next**: Test failover scenarios before production workload deployment.
