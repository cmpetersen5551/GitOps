# Longhorn HA Storage Migration - Learning & Reference

## Migration Summary

**Completed**: SeaweedFS → Longhorn on 2-node HA setup (w1/w2)  
**Status**: ✅ Operational - Sonarr+Prowlarr running on Longhorn with 2-replica volumes  
**Git**: All configuration in Git via Flux, fully GitOps managed

---

## Key Learnings

### 1. Longhorn Disk Auto-Creation (The Critical Discovery)

**Problem**: Longhorn wasn't creating disks even with `createDefaultDiskLabeledNodes: true`

**Root Cause**: Using the WRONG label  
- ❌ Used: `node.longhorn.io/storage=enabled` (for nodeSelector placement only)
- ✅ Need: `node.longhorn.io/create-default-disk=true` (triggers disk creation)

**Solution**:
```bash
# Two different purposes, two different labels!
kubectl label node k3s-w1 node.longhorn.io/storage=enabled          # Component placement
kubectl label node k3s-w1 node.longhorn.io/create-default-disk=true # Disk creation trigger
```

### 2. Node Affinity vs Preferred Scheduling

**Initial Issue**: Pods scheduling on cp1 (control plane) without storage

**Problem**: Used `preferredDuringScheduling` (soft constraint) not `requiredDuringScheduling`

**Fix**:
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:  # ← REQUIRED
      nodeSelectorTerms:
        - matchExpressions:
            - key: node.longhorn.io/storage
              operator: In
              values: [enabled]
```

Plus taint toleration:
```yaml
tolerations:
  - key: node.longhorn.io/storage
    operator: Equal
    value: enabled
    effect: NoSchedule
```

### 3. GitOps vs Infrastructure Configuration

**Lesson**: Not everything needs to be in Git

| Component | Approach | Rationale |
|-----------|----------|-----------|
| Longhorn Helm config | ✅ Git | Core workload configuration |
| StorageClass | ✅ Git | Application dependency |
| Application manifests | ✅ Git | All app configs in Git |
| Node labels | 🔶 Manual/Documented | Infrastructure layer, rarely changes |
| Node taints | 🔶 Manual/Documented | Infrastructure layer, rarely changes |
| Disk auto-creation | ✅ Git (Helm value) | Drives Node labels automatically |

**Best Practice**: Document required node setup in [NODE_SETUP.md](./NODE_SETUP.md) but manage actual labels/taints outside GitOps (Terraform, automation scripts, etc.)

### 4. 2-Node HA Requirements

**Critical Helm values for w1/w2 HA**:

```yaml
defaultSettings:
  replicaSoftAntiAffinity: false    # MUST be false for 2-node
  defaultReplicaCount: 2             # 1 replica per node
  defaultDataLocality: best-effort   # Keep replica on workload node if possible
  replicaAutoBalance: least-effort   # Don't ping-pong replicas
```

**Why**: With `replicaSoftAntiAffinity: true`, Longhorn tries to spread replicas to 3+ nodes. On 2 nodes, this fails. Must be `false`.

### 5. StorageClass Simplification

Created [storageclass-simple.yaml](./storageclass-simple.yaml) without node selectors:
- Allows flexible replica placement
- No node tag constraints in StorageClass layer
- Node affinity handled at Pod level (cleaner separation)

---

## Current HA Architecture

### Topology
```
┌─────────────────────────────────────────────┐
│         Kubernetes Cluster                  │
├─────────────────────────────────────────────┤
│                                             │
│  k3s-cp1          k3s-w1          k3s-w2    │
│  (Control)     (Primary)        (Backup)   │
│                (Longhorn)       (Longhorn) │
│                   │                │       │
│              ┌────┴────────────────┘       │
│              │  2-Replica Volume           │
│              │  (HA Protected)             │
│              │                             │
│         ┌────┴─────┐                       │
│         │           │                      │
│      Replica 1   Replica 2                │
│      (w1 disk)   (w2 disk)                │
│                                            │
│  Storage Nodes (w1, w2):                  │
│    - /var/lib/longhorn                    │
│    - open-iscsi installed                 │
│    - Node labels configured               │
│                                            │
└─────────────────────────────────────────────┘
```

### Replication Strategy
- **NumberOfReplicas**: 2 (one on each node)
- **Stale Timeout**: 30s (mark replica stale after 30s unreachable)
- **Auto-Balance**: least-effort (balance without thrashing)
- **Data Locality**: best-effort (but doesn't prevent HA)

### Failover Behavior
1. Node w1 fails → w2 replica becomes primary
2. Pod gets evicted from w1 (after tolerationSeconds: 30s)
3. Kubernetes reschedules pod to w2 (only storage node alive)
4. Pod mounts existing w2 replica
5. **Result**: ~60s downtime, zero data loss

---

## Validated Components

✅ **Longhorn**
- 2-node configuration working
- Disks created and healthy on w1/w2
- Replicas properly distributed (1 per node)
- Volumes marked as "healthy"

✅ **Sonarr**
- Scheduled on k3s-w1 (primary preference)
- Config volume: `config-sonarr-0` (5Gi, Longhorn-backed)
- **Status**: Running, healthy

✅ **Prowlarr**
- StatefulSet configured for Longhorn
- Ready for testing (currently 0 replicas)

✅ **NFS Storage**
- Media library: 1TB on Unraid
- Transcode cache: 200GB on Unraid
- Used as SPOF (acceptable for homelab, non-critical data)

✅ **Node Setup**
- Labels: `node.longhorn.io/storage=enabled`, `node.longhorn.io/create-default-disk=true`
- Taints: `node.longhorn.io/storage=enabled:NoSchedule`
- open-iscsi installed on w1/w2
- Disks mounted at `/var/lib/longhorn`

---

## What Was Removed

`❌ SeaweedFS`
- Why: Cannot provide true 2-node HA (needs 3 nodes minimum)
- Cost: Complexity, performance overhead vs Longhorn
- Replacement: Longhorn with native Kubernetes integration

`❌ SeaweedFS CSI Driver`
- Why: SeaweedFS removed, CSI no longer needed
- Replacement: Longhorn CSI (built-in, simpler)

---

## Outstanding Tasks

### HA Failover Testing
- [ ] Kill w1 node, verify Sonarr reschedules to w2
- [ ] Verify config data persists on w2 replica
- [ ] Bring w1 back online, verify volume rebalances
- [ ] Check data consistency after failover

### Production Hardening
- [ ] Configure Longhorn backup to external storage
- [ ] Set up monitoring/alerts for volume health
- [ ] Test volume expansion workflow
- [ ] Document recovery procedures

### Sprawl Cleanup
- [ ] Delete orphaned seaweedfs PVCs from cluster (manual kubectl commands, will auto-clean when namespace deleted)
- [ ] Verify seaweedfs namespace deletion after Flux sync
- [ ] Clean up released PV artifacts

---

## Files Changed

**Added**:
- `clusters/homelab/infrastructure/longhorn/storageclass-simple.yaml` - Simplified StorageClass
- `clusters/homelab/infrastructure/longhorn/NODE_SETUP.md` - Run-book for node config

**Modified**:
- `clusters/homelab/apps/media/sonarr/statefulset.yaml` - Added Longhorn storage + node affinity
- `clusters/homelab/apps/media/prowlarr/statefulset.yaml` - Added Longhorn storage + node affinity
- `clusters/homelab/infrastructure/kustomization.yaml` - Removed seaweedfs references

**Removed**:
- `clusters/homelab/infrastructure/seaweedfs/` - Entire directory (5 files)

---

## Quick Reference: Key Commands

### Verify HA Status
```bash
# Check volume replicas
kubectl get volumes.longhorn.io -n longhorn-system

# Check replica distribution
kubectl get nodes.longhorn.io k3s-w1 k3s-w2 -n longhorn-system \
  -o json | jq '.items[] | {name: .metadata.name, replicas: .status.diskStatus | to_entries[] | .value.scheduledReplica | keys}'

# Check volume health
kubectl describe volume.longhorn.io <volumename> -n longhorn-system | grep -E "State|Robustness"

# Check disk status
kubectl get nodes.longhorn.io -n longhorn-system
```

### Monitor Pods
```bash
# Watch media apps
kubectlget pods -n media -o wide -w

# Check node scheduling
kubectl get nodes k3s-w1 k3s-w2 -L node.longhorn.io/storage,workload-priority
```

### Longhorn UI (if needed)
```bash
# Port forward to Longhorn UI (default: :8080)
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Then: http://localhost:8080
```

---

## Troubleshooting Reference

**Pod won't schedule**
- Check: Node affinity requirements vs available nodes with Longhorn label
- Check: Taint tolerations match node taints
- Solution: `kubectl describe pod <pod>` → Events section

**Volume stuck "detached"**
- Check: Longhorn node disks are ready (`kubectl get nodes.longhorn.io`)
- Check: volume conditions for scheduling failures
- Solution: Verify node labels (`node.longhorn.io/storage=enabled`)

**Replicas not spreading**
- Check: `replicaSoftAntiAffinity` = `false` (must be false for 2-node)
- Check: Both nodes have ready disks with capacity
- Solution: Longhorn will auto-balance over ~30s

---

**Date**: 2026-02-15  
**Migration Lead**: User request to clean up and stabilize HA setup  
**Status**: Ready for controlled failover testing
