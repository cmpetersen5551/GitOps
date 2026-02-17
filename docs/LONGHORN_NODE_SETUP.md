# Longhorn Node Setup

This document describes the required node configuration for Longhorn storage on w1 and w2.

## Prerequisites

### NFS Client Utilities (CRITICAL for RWX Volumes)

Longhorn RWX volumes use NFSv4 internally via share-manager pods. **All nodes that will mount RWX volumes MUST have NFS client utilities installed.**

**For Debian/Ubuntu:**
```bash
# SSH to each node and install nfs-common
apt-get update && apt-get install -y nfs-common

# Verify installation
dpkg -l | grep nfs-common
mount.nfs --version
```

**For RHEL/CentOS/Rocky:**
```bash
yum install -y nfs-utils
```

**Why this matters:**
- Without `nfs-common`, RWX volume mounts fail with: `mount failed: NFS: mount program didn't pass remote address`
- This is a **host-level dependency**, not a Kubernetes resource
- Must be installed on **ALL nodes** (control plane + workers) that will use RWX volumes
- Longhorn's CSI driver relies on the host's `mount.nfs` binary to mount share-manager NFS exports

See [GitHub Issue #8508](https://github.com/longhorn/longhorn/issues/8508) for background.

## Required Node Labels

Node labels are considered infrastructure and are applied outside of Flux GitOps:

### Storage Nodes (w1 and w2)

```bash
# Label for Longhorn component placement (manager/UI)
kubectl label node k3s-w1 node.longhorn.io/storage=enabled
kubectl label node k3s-w2 node.longhorn.io/storage=enabled

# Label for automatic disk creation (REQUIRED!)
kubectl label node k3s-w1 node.longhorn.io/create-default-disk=true
kubectl label node k3s-w2 node.longhorn.io/create-default-disk=true
```

## Required Node Taints

Taints ensure storage workloads only run on designated nodes:

```bash
kubectl taint node k3s-w1 node.longhorn.io/storage=enabled:NoSchedule --overwrite
kubectl taint node k3s-w2 node.longhorn.io/storage=enabled:NoSchedule --overwrite
```

## Verification

After applying labels and taints:

```bash
# Verify labels
kubectl get nodes k3s-w1 k3s-w2 --show-labels | grep longhorn

# Verify Longhorn detected and created disks
kubectl get nodes.longhorn.io -n longhorn-system

# Check disk status
kubectl get nodes.longhorn.io k3s-w1 k3s-w2 -n longhorn-system -o json | \
  jq '.items[] | {name: .metadata.name, disks: .spec.disks}'
```

## How It Works

1. **`node.longhorn.io/storage=enabled`**: Controls where Longhorn manager/UI pods are scheduled (via nodeSelector in HelmRelease)
2. **`node.longhorn.io/create-default-disk=true`**: Triggers automatic disk creation at `/var/lib/longhorn` when `createDefaultDiskLabeledNodes: true`
3. **Taint**: Prevents non-storage workloads from scheduling on storage nodes (optional but recommended)

## Longhorn Settings

The HelmRelease configures:
- `createDefaultDiskLabeledNodes: true` - Only create disks on labeled nodes
- `defaultDataPath: /var/lib/longhorn` - Where disks are created
- `defaultReplicaCount: 2` - 2 replicas for HA across w1/w2
- `replicaSoftAntiAffinity: false` - Required for 2-node HA

See [helmrelease.yaml](./helmrelease.yaml) for full configuration.
