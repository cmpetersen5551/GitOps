# Implementation Summary: SeaweedFS CSI Driver Deployment

## Problem Statement
Sonarr PVC was stuck in `Pending` state because the SeaweedFS CSI driver was not installed. The SeaweedFS Helm chart only defines the storage backend (filer, master, volume servers) but does not include CSI driver components.

## Solution Implemented

### 1. Official CSI Driver Deployment
Deployed the **official SeaweedFS CSI driver** (chrislusf/seaweedfs-csi-driver) with all necessary components following Kubernetes CSI best practices:

#### Components
- **CSI Controller** (1 replica, leader-elected):
  - Provisioner: Creates PVs when PVCs are requested
  - Attacher: Manages volume attachment lifecycle
  - Resizer: Handles volume expansion
  - Liveness Probe: Health monitoring

- **CSI Node Plugin** (DaemonSet, one per node):
  - FUSE Mount daemon for volume mounting
  - Node plugin for local volume attachment
  - Driver registrar for kubelet integration
  - Health monitoring

### 2. Directory Structure
```
clusters/homelab/infrastructure/
├── seaweedfs/                          # Existing: Backend storage
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── rbac.yaml
│   └── storageclass.yaml (UPDATED)
├── seaweedfs-csi/                      # NEW: CSI driver
│   ├── kustomization.yaml
│   ├── csidriver.yaml
│   ├── controller.yaml
│   ├── node-and-mount.yaml
│   ├── serviceaccounts-and-rbac.yaml
│   └── namespace.yaml (reuses seaweedfs)
```

### 3. RBAC & Permissions
Comprehensive RBAC configuration with:
- ServiceAccounts for controller and node components
- ClusterRoles for provisioning, attachment, resizing, driver registration
- Leader election leases for HA controller
- Node-level permissions for mount operations

### 4. Storage Configuration

**StorageClass (`seaweedfs`)**
```yaml
provisioner: seaweedfs-csi-driver
parameters:
  mounter: "fuse"          # High-performance FUSE mounting
  volumeType: "file"
  replication: "1"
volumeBindingMode: WaitForFirstConsumer  # Topology-aware
allowVolumeExpansion: true
```

**Sonarr PVC**
```yaml
storageClassName: seaweedfs  # Uses CSI driver
accessModes: [ ReadWriteMany ]
resources:
  requests:
    storage: 5Gi
```

### 5. Deployment Order (GitOps Dependencies)

The seaweedfs-csi kustomization is placed **after** seaweedfs in the infrastructure hierarchy:
```
infrastructure/
├── metallb         (network)
├── traefik         (ingress)
├── seaweedfs       (Helm: backend + namespace + StorageClass)
└── seaweedfs-csi   (CSI driver - uses seaweedfs components)
```

This ensures:
1. SeaweedFS backend services are ready before CSI driver tries to connect
2. Namespace exists before CSI ServiceAccounts are created
3. StorageClass is available for PVC binding

## How It Works

1. **User applies PVC** → Kubernetes detects `storageClassName: seaweedfs`
2. **CSI Provisioner** → Creates volume in SeaweedFS Filer, creates PV
3. **Pod scheduled** → CSI Node plugin mounts volume via FUSE
4. **App ready** → Can read/write to mounted SeaweedFS volume

## Changes Made

### Files Created
- `clusters/homelab/infrastructure/seaweedfs-csi/kustomization.yaml`
- `clusters/homelab/infrastructure/seaweedfs-csi/csidriver.yaml`
- `clusters/homelab/infrastructure/seaweedfs-csi/controller.yaml`
- `clusters/homelab/infrastructure/seaweedfs-csi/node-and-mount.yaml`
- `clusters/homelab/infrastructure/seaweedfs-csi/serviceaccounts-and-rbac.yaml`
- `SEAWEEDFS_CSI_IMPLEMENTATION.md` (detailed guide)

### Files Modified
- `clusters/homelab/infrastructure/kustomization.yaml` (added CSI kustomization)
- `clusters/homelab/infrastructure/seaweedfs/storageclass.yaml` (updated for FUSE)

### Validation
✓ All kustomizations build successfully
✓ Kubernetes API validation passes
✓ YAML syntax valid
✓ No unresolved placeholders
✓ PV/PVC storage matching confirmed

## Expected Outcomes After Flux Reconciliation

1. **CSI Driver Pod Status**
   ```
   seaweedfs-controller-<hash>        Running (control plane)
   seaweedfs-node-<hash>             Running (one per node)
   seaweedfs-mount-<hash>            Running (one per node)
   ```

2. **Sonarr PVC Status**
   ```
   pvc-sonarr: Pending → Bound (successful provisioning)
   ```

3. **Sonarr Pod Status**
   ```
   sonarr-<hash>: Pending → Running (volume mounted)
   ```

## Monitoring Commands

```bash
# Check CSI driver status
kubectl get csidriver

# View controller pod
kubectl logs -n seaweedfs deployment/seaweedfs-controller -c csi-provisioner

# Check node plugin
kubectl logs -n seaweedfs -l app=seaweedfs-node -c csi-seaweedfs-plugin

# Watch Sonarr PVC
kubectl get pvc -n media -w

# Describe Sonarr PVC for provisioning events
kubectl describe pvc pvc-sonarr -n media
```

## Key Design Decisions

1. **FUSE Mounting**: Uses FUSE (Filesystem in Userspace) for better performance than WebDAV
2. **Topology-Aware**: `WaitForFirstConsumer` mode for optimal node placement
3. **Separate CSI Directory**: Isolates CSI driver from SeaweedFS backend for clarity
4. **Leader Election**: Controller uses HA leader election for reliability
5. **Official Driver**: Uses chrislusf/seaweedfs-csi-driver (official, maintained)

## What This Enables

✓ Dynamic PVC provisioning for stateful applications
✓ Sonarr can now use SeaweedFS for media storage
✓ Other apps can request storage dynamically
✓ Volume expansion support for growing storage needs
✓ High availability with replica support
✓ FUSE-based performance for I/O operations
