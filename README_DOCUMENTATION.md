# Documentation Index

## Active (Current Architecture)

✅ **[LONGHORN_HA_MIGRATION.md](./LONGHORN_HA_MIGRATION.md)**
- Current architecture, lessons learned, and reference guide
- **Status**: Live HA configuration with Sonarr on Longhorn, 2-node replication

✅ **[clusters/homelab/infrastructure/longhorn/NODE_SETUP.md](./clusters/homelab/infrastructure/longhorn/NODE_SETUP.md)**
- Node configuration requirements for Longhorn storage HA
- Labels, taints, and disk setup for w1/w2

## Archive (Planning & Historical)

📦 **SeaweedFS Planning** (Superseded by Longhorn)
- `SEAWEEDFS_ANALYSIS_AND_PLAN.md`
- `SEAWEEDFS_HA_ARCHITECTURE.md`
- `SEAWEEDFS_CSI_DEPLOYMENT_PLAN.md`
- `SEAWEEDFS_CSI_IMPLEMENTATION.md`
- `SEAWEEDFS_ISSUES_AND_FINDINGS.md`
- `SEAWEEDFS_ROOT_CAUSE_ANALYSIS.md`
- `SEAWEEDFS_CONFIG_CLARIFICATION.md`
- `CSI_IMPLEMENTATION_SUMMARY.md`

📋 **HA Path Planning** (Historical exploration)
- `ACTIVE_PASSIVE_HA_PLAN.md`
- `INCREMENTAL_HA_PATH.md`
- `STATEFULSET_AND_STORAGE_SIMPLIFICATION_PLAN.md`
- `CLUSTERPLEX_HA_IMPLEMENTATION_PLAN.md`
- `REVIEW_FINDINGS.md`
- `COMPLETE_ORIGINAL_ARCHITECTURE.md`

---

## GitOps Configuration Structure

```
clusters/homelab/
├── infrastructure/
│   ├── longhorn/                    ← ACTIVE
│   │   ├── helmrelease.yaml         (Flux HelmRelease)
│   │   ├── helmrepository.yaml      (Longhorn Helm repo)
│   │   ├── kustomization.yaml       (Kustomization)
│   │   ├── namespace.yaml           (longhorn-system ns)
│   │   ├── storageclass-simple.yaml (2-node optimized)
│   │   └── NODE_SETUP.md            (Node config run-book)
│   │
│   └── seaweedfs/                   ← REMOVED (was: CSI driver patterns)
│
└── apps/media/
    ├── sonarr/                      ← ACTIVE
    │   └── statefulset.yaml         (Longhorn-backed PVC)
    │
    └── prowlarr/                    ← ACTIVE (0 replicas)
        └── statefulset.yaml         (Longhorn-backed PVC)
```

---

## What Changed (This Session)

| Removed | Added | Modified |
|---------|-------|----------|
| SeaweedFS infrastructure | `LONGHORN_HA_MIGRATION.md` | Sonarr StatefulSet (Longhorn) |
| SeaweedFS CSI driver | Longhorn StorageClass | Prowlarr StatefulSet (Longhorn) |
| 5 SeaweedFS manifests | NODE_SETUP.md | kustomization.yaml (removed seaweedfs) |
| seaweedfs namespace | longhorn-simple SC | node affinity + tolerations |

---

## Quick Links

### Deploy & Monitor
- **Longhorn UI**: `kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80`
- **Check Volumes**: `kubectl get volumes.longhorn.io -n longhorn-system`
- **Check Replicas**: `kubectl get nodes.longhorn.io -n longhorn-system`

### Key Concepts
- **2-Node HA**: Requires `replicaSoftAntiAffinity: false` in Longhorn Helm values
- **Node Requirements**: Must label w1/w2 with both `node.longhorn.io/storage=enabled` AND `node.longhorn.io/create-default-disk=true`
- **Pod Scheduling**: Uses `requiredDuringScheduling` affinity + `NoSchedule` taint tolerations

### Next Steps
- [ ] Test w1 failure → Sonarr reschedules to w2
- [ ] Verify config data integrity post-failover
- [ ] Scale Prowlarr to 1 replica and test
- [ ] Set up Longhorn backup for external storage
- [ ] Configure monitoring for volume health

---

**Last Updated**: 2026-02-15  
**Status**: Documentation polished, cluster cleaned, ready for HA testing
