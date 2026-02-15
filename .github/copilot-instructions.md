# Copilot Instructions for GitOps Cluster

This document provides essential context for AI assistants working with this GitOps repository.

## Cluster Overview

**Type**: k3s homelab with Docker/Proxmox/Unraid backend  
**Nodes**: 4 (cp1 control plane, w1/w2 storage, w3 edge)  
**GitOps**: Flux v2 (manifests in `clusters/homelab/`)  
**Current Status**: ✅ Operational with Longhorn 2-node HA  
**Repository**: cmpetersen5551/GitOps (branch: v2)

## Critical Architecture Decisions

### Storage (HA-First Design)
- **Primary**: Longhorn 2-node HA (w1, w2) for configs and critical workloads
  - 2 replicas per volume (one on each storage node)
  - `replicaSoftAntiAffinity: false` (required for 2-node)
  - Zero-copy failover between nodes
  
- **Secondary**: NFS on Unraid (SPOF, acceptable for media/transcode)
  - Media library: ro access from all nodes
  - Transcode cache: rw access for sonarr/prowlarr

### Applications
- **Sonarr**: Running on k3s-w1 with Longhorn PVC for config
- **Prowlarr**: StatefulSet ready, currently 0 replicas
- Both use required node affinity + taint tolerations for storage nodes

### Node Infrastructure (Manual Outside GitOps)
Node labels and taints are infrastructure configuration applied manually, documented in `docs/LONGHORN_NODE_SETUP.md`:
```bash
# Storage nodes (w1, w2) require:
kubectl label node k3s-w1 node.longhorn.io/storage=enabled node.longhorn.io/create-default-disk=true
kubectl taint node k3s-w1 node.longhorn.io/storage=enabled:NoSchedule --overwrite
```

**Key Learning**: The `create-default-disk=true` label is REQUIRED for Longhorn disk auto-creation; the other controls nodeSelector and taint behavior.

## Essential Commands

### Cluster Health
```bash
# Check all nodes
kubectl get nodes -L node.longhorn.io/storage

# Verify Longhorn volumes
kubectl get volumes.longhorn.io -n longhorn-system

# Check pod placement
kubectl get pods -n media -o wide

# Flux sync status
flux get all
```

### Common Tasks
```bash
# Force Flux reconciliation
flux reconcile kustomization apps --with-source

# Watch media pods
kubectl get pods -n media -w

# Port-forward Longhorn UI (if needed)
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# Check volume replicas
kubectl get nodes.longhorn.io k3s-w1 k3s-w2 -n longhorn-system -o json | \
  jq '.items[] | {name:.metadata.name, replicas:.status.diskStatus}'
```

### Debugging
```bash
# Pod logs (e.g., Sonarr)
kubectl logs -n media sonarr-0

# Describe pod for scheduling issues
kubectl describe pod sonarr-0 -n media

# Check PVC events
kubectl describe pvc config-sonarr-0 -n media | tail -20

# Check Longhorn manager logs
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100 | grep -i error
```

## File Structure

```
clusters/homelab/
├── apps/
│   └── media/                    # Media applications (Sonarr, Prowlarr)
│       ├── sonarr/statefulset.yaml  (Longhorn-backed)
│       └── prowlarr/statefulset.yaml (Longhorn-backed)
├── infrastructure/
│   ├── longhorn/                 # HA storage (helmrelease + node config)
│   ├── metallb/                  # BGP load balancer
│   ├── traefik/                  # Reverse proxy
│   └── ... other services
├── docs/                         # Network/BGP reference (Unifi UDM)
└── flux-system/                  # Flux sync config (auto-generated)

docs/                            # Documentation root
├── LONGHORN_HA_MIGRATION.md     # Current HA architecture + learnings
├── CLUSTER_STATE_SUMMARY.md     # Health snapshot + test checklist
├── LONGHORN_NODE_SETUP.md       # Node configuration run-book
├── NFS_STORAGE.md               # NFS mount documentation
└── archive/                     # Historical planning docs (SeaweedFS, etc)
```

## Key Learnings (Don't Repeat)

1. **Longhorn 2-Node HA**
   - ❌ Don't leave `replicaSoftAntiAffinity: true` (will fail to schedule replicas)
   - ❌ Don't forget `node.longhorn.io/create-default-disk=true` label
   - ✅ Do use `requiredDuringScheduling` affinity for storage workloads

2. **SeaweedFS Lesson** (Why We Switched)
   - SeaweedFS cannot provide true 2-node HA (minimum 3 nodes/racks required)
   - Longhorn is simpler, Kubernetes-native, zero-copy failover
   - Research before committing to storage backend

3. **GitOps Discipline**
   - ✅ All application + infrastructure configs in Git via Flux
   - 🔶 Node infrastructure (labels/taints) outside Git, documented in NODE_SETUP.md
   - Rationale: Infrastructure rarely changes; GitOps works best for deployment manifests

## Before Making Changes

1. **Always review cluster state first**
   ```bash
   flux get all                    # Flux sync status
   kubectl get nodes               # Node health
   kubectl get pvc -A              # Storage status
   ```

2. **Test changes on a feature branch** (if possible)
   - Push to feature branch, let Flux verify
   - Merge to v2 only after validation

3. **Document your changes**
   - All infrastructure changes must have corresponding entries in `docs/`
   - Commit messages should explain the "why" not just "what"

4. **When adding new workloads with storage**
   - Use Longhorn StorageClass (`longhorn-simple`) for HA
   - Add required node affinity:
     ```yaml
     affinity:
       nodeAffinity:
         requiredDuringSchedulingIgnoredDuringExecution:
           nodeSelectorTerms:
             - matchExpressions:
                 - key: node.longhorn.io/storage
                   operator: In
                   values: [enabled]
     ```
   - Add taint tolerations:
     ```yaml
     tolerations:
       - key: node.longhorn.io/storage
         operator: Equal
         value: enabled
         effect: NoSchedule
     ```

## Common Issues & Quick Fixes

**PVC stuck in "Unbound"**
- Check: Are w1/w2 ready? `kubectl get nodes.longhorn.io -n longhorn-system`
- Check: Does pod have node affinity? `kubectl describe pod <pod>`
- Fix: Verify node labels: `kubectl get nodes --show-labels | grep longhorn`

**Pod scheduling to wrong node**
- Cause: Using `preferredDuringScheduling` instead of `required`
- Fix: Update StatefulSet affinity to `requiredDuringScheduling`
- Verify: `kubectl describe pod <pod> | grep -A 10 "Node-Selectors"`

**Longhorn volume won't attach**
- Check: `kubectl logs -n longhorn-system -l app=longhorn-manager | grep error`
- Check: Disk status on storage nodes: `kubectl get nodes.longhorn.io -n longhorn-system -o json | jq '.items[].status.diskStatus'`
- Verify: `/var/lib/longhorn` path exists and has space

## When to Ask for Help

This document is a reference, but:
- **Complex HA scenarios**: See `docs/LONGHORN_HA_MIGRATION.md` (detailed)
- **Storage troubleshooting**: See `docs/CLUSTER_STATE_SUMMARY.md` (test checklist)
- **Node configuration**: See `docs/LONGHORN_NODE_SETUP.md` (complete run-book)
- **New applications**: Reference existing Sonarr/Prowlarr StatefulSets as templates

## Quick Contact Points

- **Longhorn Official Docs**: https://longhorn.io/docs/
- **Flux Documentation**: https://fluxcd.io/flux/
- **k3s Docs**: https://docs.k3s.io/
- **Your Local Cluster**: `kubectl config current-context` shows active cluster

---

**Repository**: https://github.com/cmpetersen5551/GitOps  
**Branch**: v2 (main HA development)  
**Last Updated**: 2026-02-15  
**Status**: ✅ Production-ready for HA testing
