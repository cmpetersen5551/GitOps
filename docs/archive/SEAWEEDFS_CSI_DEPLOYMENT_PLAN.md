# SeaweedFS CSI Driver Implementation Plan

## Current State Analysis

### What We Have
1. ✅ **SeaweedFS Backend (Running)**
   - 3 Master pods (StatefulSet)
   - 1 Filer pod (StatefulSet)  
   - 2 Volume server pods (StatefulSet)
   - Services: `seaweedfs-filer-client.seaweedfs:8888`

2. ✅ **RBAC Resources (Already Applied)**
   - ServiceAccounts: `seaweedfs-csi-controller`, `seaweedfs-csi-node`
   - ClusterRoles: `seaweedfs`, `seaweedfs-csi-controller`, `seaweedfs-csi-node`
   - ClusterRoleBindings: Corresponding bindings exist

3. ✅ **StorageClass (Already Applied)**
   - Name: `seaweedfs`
   - Provisioner: `seaweedfs-csi-driver`
   - VolumeBindingMode: `Immediate`
   - Parameters: `diskType: hdd`, `path: /buckets`, `replication: "010"`

4. ✅ **Git Structure**
   - `infrastructure/seaweedfs/` - Backend Helm release
   - `infrastructure/seaweedfs-csi/` - CSI driver manifests (created)
   - `cluster/infrastructure-seaweedfs-csi-kustomization.yaml` - Flux Kustomization (created)

### What's Missing (THE PROBLEM)
1. ❌ **No CSI Driver Pods Running**
   - No `seaweedfs-controller` Deployment
   - No `seaweedfs-node` DaemonSet
   - No `seaweedfs-mount` DaemonSet

2. ❌ **No CSIDriver Resource Registered**
   ```bash
   kubectl get csidriver
   # Output: No resources found
   ```

3. ❌ **Flux Not Deploying CSI Kustomization**
   - `infrastructure-seaweedfs-csi` Kustomization CR NOT in cluster
   - Root kustomization.yaml (`clusters/homelab/kustomization.yaml`) DOES NOT include `infrastructure-seaweedfs-csi-kustomization.yaml`

### Root Cause
**The Flux Kustomization CR for seaweedfs-csi is not being applied because it's not referenced in the root kustomization.yaml.**

## What SeaweedFS CSI Driver Actually Needs

Based on official docs and manifest analysis:

1. **DaemonSet: `seaweedfs-mount`**
   - Runs on all nodes
   - Provides FUSE mount capability
   - Uses image: `chrislusf/seaweedfs-csi-driver:latest` or specific version
   - Mounts: `/var/lib/kubelet/plugins`, `/var/lib/kubelet/pods`, `/dev`
   - Requires privileged mode and `SYS_ADMIN` capability

2. **DaemonSet: `seaweedfs-node`**
   - Runs on all nodes
   - Contains 3 containers:
     - `csi-seaweedfs-plugin` - Node plugin
     - `driver-registrar` - Registers with kubelet
     - `livenessprobe` - Health monitoring
   - Connects to Filer via `SEAWEEDFS_FILER` env var

3. **Deployment: `seaweedfs-controller`**
   - 1 replica (leader-elected)
   - Contains 5 containers:
     - `csi-seaweedfs-plugin` - Controller plugin
     - `csi-provisioner` - PVC → PV provisioning
     - `csi-attacher` - Volume attachment
     - `csi-resizer` - Volume expansion
     - `livenessprobe` - Health monitoring

4. **CSIDriver Resource**
   - Registers `seaweedfs-csi-driver` with Kubernetes
   - Metadata: `name: seaweedfs-csi-driver`

## Implementation Plan

### Step 1: Add CSI Kustomization to Root (CRITICAL)
**File:** `clusters/homelab/kustomization.yaml`

**Action:** Add reference to CSI kustomization file so Flux applies it

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cluster/infrastructure-metallb.yaml
  - cluster/infrastructure-seaweedfs-helmrepository.yaml
  - cluster/infrastructure-seaweedfs-helmrelease.yaml
  - cluster/infrastructure-seaweedfs-values-configmap.yaml
  - cluster/infrastructure-seaweedfs-kustomization.yaml
  - cluster/infrastructure-seaweedfs-csi-kustomization.yaml  # ADD THIS LINE
  - cluster/infrastructure-traefik.yaml
  - cluster/apps-kustomization.yaml
```

**Why:** Without this, Flux never sees the CSI Kustomization CR and doesn't apply the CSI manifests.

### Step 2: Verify CSI Manifests Are Correct
**Directory:** `clusters/homelab/infrastructure/seaweedfs-csi/`

**Files to check:**
- `controller.yaml` - Deployment with 5 containers
- `node-and-mount.yaml` - 2 DaemonSets (node + mount)
- `csidriver.yaml` - CSIDriver registration
- `serviceaccounts-and-rbac.yaml` - RBAC (already applied but checking)
- `kustomization.yaml` - Composes all resources

**Critical:** Ensure `SEAWEEDFS_FILER` env var points to correct filer service:
```yaml
value: "seaweedfs-filer-client.seaweedfs:8888"
```

### Step 3: Remove Duplicate StorageClass from CSI
**File:** `clusters/homelab/infrastructure/seaweedfs-csi/storageclass.yaml`

**Action:** Delete this file (already done in code)

**Why:** StorageClass `seaweedfs` already exists in `infrastructure/seaweedfs/storageclass.yaml`. Kubernetes doesn't allow duplicate StorageClasses with same name.

### Step 4: Commit and Push Changes
```bash
git add clusters/homelab/kustomization.yaml
git commit -m "fix: Add CSI kustomization to root so Flux applies it"
git push origin seaweedfs
```

### Step 5: Monitor Flux Reconciliation
```bash
# Force reconcile
flux reconcile kustomization flux-system -n flux-system --with-source

# Watch for CSI Kustomization to appear
watch 'flux get kustomizations -A'

# Check if CSI Kustomization CR appears
kubectl get kustomization infrastructure-seaweedfs-csi -n flux-system
```

### Step 6: Verify CSI Driver Deployment
```bash
# CSIDriver should register
kubectl get csidriver

# Controller deployment should appear
kubectl get deploy -n seaweedfs seaweedfs-controller

# Node and Mount DaemonSets should appear
kubectl get daemonset -n seaweedfs

# Pods should be Running
kubectl get pods -n seaweedfs
```

### Step 7: Test PVC Provisioning
```bash
# Watch Sonarr PVC
kubectl get pvc -n media pvc-sonarr -w

# Should transition from Pending → Bound
# Describe to see provisioning events
kubectl describe pvc pvc-sonarr -n media
```

### Step 8: Verify Sonarr Pod Starts
```bash
# Sonarr pod should start after PVC is Bound
kubectl get pods -n media

# Check logs for volume mount success
kubectl logs -n media deployment/sonarr
```

## Expected Timeline

1. **Immediate (< 1 min):** Add CSI kustomization to root, commit, push
2. **1-2 minutes:** Flux picks up change, creates CSI Kustomization CR
3. **2-3 minutes:** CSI controller and node pods start
4. **3-4 minutes:** PVC provisions, Sonarr pod starts
5. **5 minutes total:** Full system operational

## Rollback Plan

If CSI driver fails:

```bash
# Remove CSI kustomization from root
git revert <commit-hash>
git push origin seaweedfs

# Manually delete CSI resources if needed
kubectl delete kustomization infrastructure-seaweedfs-csi -n flux-system
kubectl delete daemonset -n seaweedfs seaweedfs-mount seaweedfs-node
kubectl delete deployment -n seaweedfs seaweedfs-controller
kubectl delete csidriver seaweedfs-csi-driver
```

## Troubleshooting Guide

### If CSIDriver doesn't register:
```bash
kubectl logs -n seaweedfs deployment/seaweedfs-controller -c csi-seaweedfs-plugin
```

### If Node pods fail:
```bash
kubectl describe daemonset -n seaweedfs seaweedfs-node
kubectl logs -n seaweedfs -l app=seaweedfs-node -c csi-seaweedfs-plugin
```

### If PVC stays Pending:
```bash
kubectl describe pvc pvc-sonarr -n media
kubectl logs -n seaweedfs deployment/seaweedfs-controller -c csi-provisioner
```

### If Mount fails:
```bash
kubectl logs -n seaweedfs -l app=seaweedfs-mount
kubectl describe pod -n media <sonarr-pod>
```

## Success Criteria

✅ CSIDriver resource exists: `kubectl get csidriver seaweedfs-csi-driver`
✅ Controller deployment running: 1/1 pods ready
✅ Node DaemonSet running: 2/2 pods ready (one per node)
✅ Mount DaemonSet running: 2/2 pods ready (one per node)
✅ Sonarr PVC status: Bound
✅ Sonarr pod status: Running
✅ Sonarr can write to mounted volume

## Key Insights

1. **We already have most components** - RBAC, ServiceAccounts, StorageClass exist
2. **The CSI manifests are correct** - They follow the official pattern
3. **The only missing piece** - Root kustomization.yaml doesn't reference the CSI kustomization file
4. **This is a GitOps wiring issue** - Not a CSI configuration problem

## Next Action

**ADD ONE LINE TO clusters/homelab/kustomization.yaml:**
```
- cluster/infrastructure-seaweedfs-csi-kustomization.yaml
```

This single change will trigger the entire CSI driver deployment.
