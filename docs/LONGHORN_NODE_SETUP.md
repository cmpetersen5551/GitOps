# Longhorn Node Setup

This document describes the required node configuration for Longhorn storage on w1 and w2.

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
