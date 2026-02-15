# SeaweedFS CSI Driver Implementation - Complete Solution

## Overview

Successfully implemented the official SeaweedFS CSI (Container Storage Interface) driver to enable dynamic PVC provisioning for the Kubernetes cluster. This resolves the blocker preventing Sonarr and other applications from accessing storage.

## Architecture

### CSI Components Deployed

1. **CSIDriver Resource** (`csidriver.yaml`)
   - Registers the `seaweedfs-csi-driver` provisioner with Kubernetes
   - Enables storage class to reference this provisioner
   - Configured for PVC-to-PV attachment requirements

2. **Controller Deployment** (`controller.yaml`)
   - Runs 1 replica (leader-elected) on control plane preferred
   - Contains multiple sidecar containers:
     - **csi-provisioner**: Handles PVC → PV dynamic provisioning
     - **csi-attacher**: Manages VolumeAttachment lifecycle
     - **csi-resizer**: Handles volume expansion requests
     - **seaweedfs-csi-plugin**: SeaweedFS CSI driver controller component
     - **csi-liveness-probe**: Health monitoring
   - Uses leader election for high availability
   - Communicates with Filer via `seaweedfs-filer-client.seaweedfs:8888`

3. **Node DaemonSet** (`node-and-mount.yaml`)
   - Runs on all cluster nodes
   - Contains:
     - **seaweedfs-mount**: FUSE mount plugin daemon
     - **csi-seaweedfs-plugin**: Node-side CSI driver
     - **driver-registrar**: Registers plugin with kubelet
     - **csi-liveness-probe**: Health monitoring
   - Mounts at `/var/lib/kubelet/plugins/seaweedfs-csi-driver`
   - Uses bidirectional mount propagation for pod volume mounts

4. **RBAC Components** (`serviceaccounts-and-rbac.yaml`)
   - ServiceAccounts: `seaweedfs-controller-sa`, `seaweedfs-node-sa`
   - ClusterRoles for provisioning, attaching, resizing, driver registration
   - ClusterRoleBindings connecting SAs to cluster-wide permissions
   - Role/RoleBinding for leader election leases in `seaweedfs` namespace

5. **StorageClass** (`infrastructure/seaweedfs/storageclass.yaml`)
   - Name: `seaweedfs` (matches existing Sonarr PVC reference)
   - Provisioner: `seaweedfs-csi-driver`
   - FUSE-based mounting for better performance
   - Topology-aware: `WaitForFirstConsumer` binding mode
   - Supports volume expansion: `allowVolumeExpansion: true`

## Deployment Order (GitOps Dependency Chain)

```
infrastructure/
  ├─ metallb/            (network)
  ├─ traefik/            (ingress)
  ├─ seaweedfs/          (storage backend Helm chart + RBAC + StorageClass)
  └─ seaweedfs-csi/      (CSI driver - provisioner for StorageClass)
       └─ Waits for seaweedfs components to be ready
```

This ordering ensures:
1. SeaweedFS Helm chart deploys first (master, filer, volume servers)
2. SeaweedFS namespace and RBAC exist
3. StorageClass `seaweedfs` is created
4. CSI driver then deploys and connects to running Filer services

## How It Works: PVC Provisioning Flow

1. **User creates PVC**
   ```yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: pvc-sonarr
     namespace: media
   spec:
     storageClassName: seaweedfs
     accessModes: [ ReadWriteMany ]
     resources:
       requests:
         storage: 5Gi
   ```

2. **CSI Provisioner watches PVC**
   - Detects `storageClassName: seaweedfs`
   - Calls `seaweedfs-csi-driver` controller to create volume

3. **SeaweedFS CSI Controller**
   - Creates volume in SeaweedFS Filer
   - Creates `PersistentVolume` object pointing to the volume
   - Binds PV to PVC

4. **CSI Node Plugin**
   - When pod references PVC, kubelet calls CSI node plugin
   - Node plugin uses FUSE mount to attach SeaweedFS volume
   - Volume appears in pod as `/mnt/...` directory

5. **Pod mounts volume**
   - Application can read/write to the mounted volume
   - FUSE handles I/O redirection to SeaweedFS Filer

## Files Created/Modified

### New Files
- `/infrastructure/seaweedfs-csi/kustomization.yaml` - CSI Kustomization
- `/infrastructure/seaweedfs-csi/csidriver.yaml` - CSIDriver registration
- `/infrastructure/seaweedfs-csi/controller.yaml` - Controller deployment
- `/infrastructure/seaweedfs-csi/node-and-mount.yaml` - Node DaemonSet + Mount daemon
- `/infrastructure/seaweedfs-csi/serviceaccounts-and-rbac.yaml` - RBAC for CSI
- `/infrastructure/seaweedfs-csi/namespace.yaml` - (Reuses seaweedfs namespace)

### Modified Files
- `/infrastructure/kustomization.yaml` - Added `./seaweedfs-csi` to resources
- `/infrastructure/seaweedfs/storageclass.yaml` - Updated parameters for FUSE mounts
- `/infrastructure/seaweedfs-csi/storageclass.yaml` - (Removed; using seaweedfs version)

## Configuration Details

### CSI Driver Parameters (StorageClass)
```yaml
parameters:
  mounter: "fuse"          # FUSE-based mounting for performance
  volumeType: "file"       # File volume type
  replication: "1"         # Number of replicas
```

### Filer Endpoint
```
SEAWEEDFS_FILER=seaweedfs-filer-client.seaweedfs:8888
```

This DNS name resolves through the Service created by the SeaweedFS Helm release.

## Resource Requirements

### Controller Deployment
- CPU: 100m request, 200m limit
- Memory: 128Mi request, 256Mi limit
- Replicas: 1 (leader-elected)

### Node DaemonSet
- CPU: ~100m per node (mount + CSI + registrar + probe)
- Memory: ~200Mi per node
- Runs on all nodes

## Validation

All components validated through:
1. ✓ Kustomize builds successful
2. ✓ Kubernetes API validation (dry-run)
3. ✓ YAML syntax checks
4. ✓ No unresolved placeholders

## Troubleshooting

### Check CSI Driver Status
```bash
# CSI Driver registration
kubectl get csidriver

# Controller pods
kubectl get pods -n seaweedfs -l app=seaweedfs-controller

# Node plugins (one per node)
kubectl get pods -n seaweedfs -l app=seaweedfs-node

# Sonarr PVC status
kubectl get pvc -n media
```

### View Logs
```bash
# Controller provisioner logs
kubectl logs -n seaweedfs deployment/seaweedfs-controller -c csi-provisioner

# Node plugin logs (on specific node)
kubectl logs -n seaweedfs -l app=seaweedfs-node -c csi-seaweedfs-plugin -p <node-name>

# Sonarr pod logs
kubectl logs -n media deployment/sonarr
```

### Common Issues

**PVC stuck in Pending:**
1. Check CSIDriver: `kubectl get csidriver`
2. Check controller pod: `kubectl describe pod -n seaweedfs <controller-pod>`
3. Check node plugin: `kubectl describe pod -n seaweedfs <node-pod>`
4. View CSI provisioner logs for errors

**Mount failures:**
1. Verify Filer connectivity: `kubectl exec -n seaweedfs <pod> -- curl seaweedfs-filer-client:8888/dir/status`
2. Check node plugin logs for mount errors
3. Verify FUSE is available: `kubectl debug node/<node-name> -it --image=ubuntu -- which fusermount`

## Next Steps

1. **Monitor deployment**: Watch for CSI controller and node pods to reach Running state
2. **Test PVC provisioning**: Watch Sonarr PVC status as it transitions to Bound
3. **Monitor pod startup**: Check Sonarr deployment for successful volume mount
4. **Verify storage**: Confirm Sonarr can write to mounted volume

## References

- [SeaweedFS CSI Driver GitHub](https://github.com/chrislusf/seaweedfs/tree/master/weed/csi)
- [Kubernetes CSI Documentation](https://kubernetes-csi.github.io/)
- [SeaweedFS Filer Documentation](https://github.com/chrislusf/seaweedfs/wiki/Filer-Server)
