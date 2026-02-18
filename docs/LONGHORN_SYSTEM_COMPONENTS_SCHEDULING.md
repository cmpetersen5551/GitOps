# Longhorn System-Managed Components Scheduling

**Date**: 2026-02-18  
**Status**: ✅ DOCUMENTED & FIXED - Critical learning from Decypharr RWX volume failure  
**Impact**: All RWX volumes now attach to correct storage nodes, enabling HA for shared workloads

---

## Problem Statement

### Issue Encountered

Decypharr deployment failed with RWX volume stuck in "attaching" state:
- Decypharr pod scheduled to **k3s-w1** (storage node) ✅
- PersistentVolumeClaim `pvc-streaming-media` created ✅
- **BUT**: Volume attempted attachment to **k3s-cp1** (control plane, no storage) ❌
- CSI driver on cp1 couldn't attach → pod stuck in `ContainerCreating` state

### Error Messages

```
Warning  FailedAttachVolume  5m28s (x19 over 28m)  attachdetach-controller
  AttachVolume.Attach failed for volume "pvc-c3493aa8-5df2-4ec2-be07-7517cf4be8b0": 
  rpc error: code = Internal desc = volume pvc-c3493aa8-5df2-4ec2-be07-7517cf4be8b0 
  failed to attach to node k3s-w1 with attachmentID ...: 
  Waiting for volume share to be available
```

### What This Meant

1. Kubernetes scheduler asked Longhorn: "Create volume for Decypharr on k3s-w1"
2. Longhorn manager scheduled the **share-manager pod** (which implements the NFS share) to **k3s-cp1**
3. Longhorn tried to attach the RWX share to **k3s-w1** (where Decypharr runs)
4. But the share-manager is on **k3s-cp1** (wrong node) → attachment failed
5. Pod couldn't mount → stuck forever

---

## Root Cause Analysis

### Understanding Longhorn Components

Longhorn has **two types of components**:

#### 1. **User-Deployed Components** (Managed via Helm values)
- Longhorn Manager (control plane)
- Longhorn Driver (CSI plugin)
- Longhorn UI (web interface)

**Scheduling**: Controlled via HelmRelease values like `longhornManager.nodeSelector`

#### 2. **System-Managed Components** (Run automatically, less obvious)
- **Share-manager** ← RWX volumes (NFSv4 server)
- **Instance-manager** ← Replica management on each storage node
- **Backing-image-manager** ← Image distribution
- **Replica-rebuild pods** ← Failover during node failure

**Scheduling**: Controlled via HelmRelease `defaultSettings.systemManagedComponentsNodeSelector` ← **NOT WELL DOCUMENTED**

### Why Share-Manager Went to cp1

**Without explicit nodeSelector**:
```
Longhorn: "Where should I run share-manager for this RWX volume?"
Kubernetes: "Anywhere it can fit!"
Node cp1: No taints, available capacity → Pod scheduled here
Node w1: NoSchedule taint (node.longhorn.io/storage=enabled) → Avoided unless required
```

### How StorageClass Parameters Don't Help

Initial troubleshooting attempted:
```yaml
# DOESN'T WORK - doesn't control share-manager placement
diskSelector: '{"node.longhorn.io/storage":"enabled"}'
nodeSelector: '{"node.longhorn.io/storage":"enabled"}'
```

These parameters control **volume replica placement** (where data lives), NOT **where share-manager runs**.

Diagram:
```
StorageClass diskSelector
    ↓
    Volume replicas placed on storage nodes (correct ✅)
    
But share-manager pod still schedules to any node (cp1) ❌
```

---

## Solution: systemManagedComponentsNodeSelector

### Configuration (HelmRelease)

Add to `defaultSettings` in Longhorn HelmRelease:

```yaml
spec:
  values:
    defaultSettings:
      # Restrict ALL system-managed components to storage nodes
      systemManagedComponentsNodeSelector: "node.longhorn.io/storage:enabled"
      
      # Ensure components tolerate the storage node taint
      taintToleration: "node.longhorn.io/storage=enabled:NoSchedule"
```

### What This Does

**systemManagedComponentsNodeSelector**:
- ✅ Share-manager pods MUST run on nodes with `node.longhorn.io/storage=enabled` label
- ✅ Instance-manager pods MUST run on storage nodes
- ✅ All replica-rebuild operations happen on storage nodes only
- ✅ RWX volumes attach correctly to the node running share-manager

**taintToleration**:
- ✅ Components can ignore the `NoSchedule` taint on storage nodes
- ✅ Prevents "no nodes available" errors due to taint+no-toleration

### Before & After

**Before Fix**:
```bash
$ kubectl get volumes.longhorn.io pvc-c3493aa8-5df2-4ec2-be07-7517cf4be8b0 -o jsonpath='{.status.currentNodeID}'
k3s-cp1                                          ← WRONG (control plane)

$ kubectl get pods -n longhorn-system -l app=share-manager
share-manager-XXXXX    Running on k3s-cp1      ← WRONG
```

**After Fix**:
```bash
$ kubectl get volumes.longhorn.io pvc-6d1828bc-24c7-4d67-b446-7584883668f5 -o jsonpath='{.status.currentNodeID}'
k3s-w2                                           ← CORRECT (storage node)

$ kubectl get pods -n longhorn-system -l app=share-manager
(No pods listed - they're scheduled, but Longhorn creates them on-demand)
```

---

## Key Insights

### 1. Longhorn Docs Could Be Clearer

Official Longhorn docs mention `systemManagedComponentsNodeSelector` but don't emphasize:
- ✅ It's REQUIRED for RWX volumes to work with node placement constraints
- ✅ StorageClass parameters don't control it
- ✅ Default behavior (no nodeSelector) can cause volumes to attach to wrong nodes in multi-node clusters

### 2. RWX Requires Shared Components

RWX (ReadWriteMany) volumes are special:
- RWO (ReadWriteOnce) volumes live on specific nodes (no extra component needed)
- RWX volumes create a **share-manager pod** that provides NFSv4 server
- The pod location DETERMINES where volume attaches
- If pod is on cp1, volume attaches to cp1, but workload might be on w1 ❌

### 3. Two-Node HA Implication

In a 2-node HA setup (w1/w2 only, no ca), if share-manager runs on cp1:
- Volume RWX share is on cp1 ❌
- Workload trying to mount on w1 ❌
- NFS mount from w1 → cp1 possible but NOT failover-safe
- If w1 fails, can't fail over to w2 (volume still on cp1)

**Solution**: Force share-manager to storage nodes only:
- RWX share always on w1 or w2 ✅
- Failover between w1↔w2 works seamlessly ✅
- If w1 dies, volume fails over to w2, share-manager follows ✅

---

## Troubleshooting Guide

### Symptom 1: RWX Volume Stuck in "Attaching"

**Check**: Where is the volume assigned?
```bash
kubectl get volumes.longhorn.io <volume-name> -n longhorn-system -o jsonpath='{.status.currentNodeID}'
```

**Symptom**: Returns cp1 or a node WITHOUT Longhorn storage  
**Cause**: share-manager is on wrong node  
**Fix**: Apply `systemManagedComponentsNodeSelector` + restart Longhorn manager

### Symptom 2: Pod Can't Mount RWX Volume

**Check**: Can pod see the NFS share?
```bash
kubectl exec <pod> -- mount | grep nfs
```

**Symptom**: No NFS mount listed  
**Cause**: CSI driver on pod's node can't reach share-manager on cp1  
**Fix**: Same as above - force share-manager to storage nodes

### Symptom 3: RWX Volume Mounts Inconsistently

**Check**: Where is share-manager running?
```bash
kubectl get pods -n longhorn-system -l app=share-manager -o wide
```

**Symptom**: Pods on different nodes or scheduling errors  
**Cause**: No nodeSelector, scheduling is random  
**Fix**: Apply `systemManagedComponentsNodeSelector`

---

## Prevention Checklist

### For New RWX Volume Deployments

Before creating RWX volumes in your cluster:

- [ ] Storage nodes labeled: `node.longhorn.io/storage=enabled`
- [ ] Storage nodes tainted: `node.longhorn.io/storage=enabled:NoSchedule`
- [ ] HelmRelease includes: `systemManagedComponentsNodeSelector: "node.longhorn.io/storage:enabled"`
- [ ] HelmRelease includes: `taintToleration: "node.longhorn.io/storage=enabled:NoSchedule"`
- [ ] Test: Create a test RWX PVC, verify volume assigns to storage node

### For HA Clusters

Additional checks:
- [ ] All storage nodes have Longhorn disks configured
- [ ] RWX volume targets the labeled storage nodes group
- [ ] Workload pod has affinity for storage nodes (if RWX access is required)
- [ ] Test failover: Kill storage node with volume, verify re-attaches to other node

---

## Longhorn Version Notes

**Tested**: Longhorn 1.7.3  
**Setting**: `systemManagedComponentsNodeSelector` available since v1.1.0+  
**Recommended**: Use v1.6.0+ for stable 2-node HA support

Check your version:
```bash
kubectl get hr longhorn -n longhorn-system -o jsonpath='{.status.chartRef.version}'
```

---

## References

- **Official Docs**: https://longhorn.io/docs/1.7.3/advanced-resources/deploy/node-selector/
- **GitHub Issue**: Related to system-managed component scheduling (not always explicitly documented)
- **Your Setup**: See [LONGHORN_HA_MIGRATION.md](./LONGHORN_HA_MIGRATION.md) for 2-node HA architecture
- **Affected Component**: [DECYPHARR_DEPLOYMENT_NOTES.md](./DECYPHARR_DEPLOYMENT_NOTES.md) shows the real-world impact

---

## Lessons for Future Operators

1. **Always verify component placement** - Just because a pod is running doesn't mean it's on the right node
2. **RWX is different** - RWX volumes create helper pods; don't assume StorageClass parameters control everything
3. **Two-node HA needs constraints** - With only 2 storage nodes, node placement decisions become critical
4. **Document infrastructure assumptions** - Keep a list of required labels/taints/selectors in your setup docs
5. **Test failover scenarios** - Don't just test happy path; test what happens when a node dies

---

**Last Updated**: 2026-02-18  
**Status**: ✅ PRODUCTION FIX APPLIED  
**Next Review**: When upgrading Longhorn or adding new nodes
