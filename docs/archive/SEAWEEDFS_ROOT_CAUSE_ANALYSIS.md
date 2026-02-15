# SeaweedFS Root Cause Analysis and Resolution Plan

## Current State Assessment

### What We Have
1. **Topology**: 3 nodes (k3s-cp1, k3s-w1, k3s-w2)
   - 3 master pods (one on each node)
   - 2 volume servers (k3s-w1, k3s-w2) with `sw-volume=true` label
   - Node labels:
     - k3s-w1: `topology.kubernetes.io/rack=rack-1`, `sw-volume=true`
     - k3s-w2: `topology.kubernetes.io/rack=rack-2`, `sw-volume=true`

2. **Current Configuration**:
   - `global.replicationPlacement: "01"` in values.yaml
   - `master.defaultReplication: "000"` (hardcoded in Helm chart template)
   - StorageClass: `replication: "01"`

3. **SeaweedFS CSI Driver**: Installed and configured separately

### The Problems

#### 1. **Helm Chart Hardcoding Issue**
The SeaweedFS Helm chart (v3.68.0) **hardcodes** `-defaultReplication=000` in the master StatefulSet template. The `global.replicationPlacement` and `master.extraEnvironmentVars` do NOT override this command-line argument.

**Evidence**:
```bash
kubectl get sts -n seaweedfs seaweedfs-master -o yaml | grep defaultReplication
# Shows: -defaultReplication=000
```

**Why This Matters**: According to SeaweedFS documentation:
- Master's `-defaultReplication` flag sets the DEFAULT replication for ALL volumes
- This can be overridden per-request via the API
- CSI driver passes `replication` parameter from StorageClass to the API
- BUT: If the master is told "use replication 01" and only 2 volume servers exist across 2 racks, it SHOULD work
- The issue is that volumes may have been created with `-defaultReplication=000` and later requests with "01" fail

#### 2. **Replication Semantics**
From SeaweedFS docs:
- Replication format: `XYZ`
  - `X` = replicas in OTHER data centers
  - `Y` = replicas in OTHER racks in same DC
  - `Z` = replicas in OTHER servers in same rack
- `"000"` = NO replication (1 copy total)
- `"001"` = 1 replica on SAME rack (needs 2+ servers in same rack)
- `"010"` = 1 replica on DIFFERENT rack in same DC (needs 2+ racks)
- `"01"` = Same as `"010"` (leading zero can be omitted)

**Our Topology**:
- 1 data center (implicit)
- 2 racks (rack-1, rack-2)
- 1 volume server per rack

**Correct Replication**: `"010"` or `"01"` - One replica on a different rack

#### 3. **CSI Driver and StorageClass**
From CSI driver docs:
```yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: seaweedfs-special
provisioner: seaweedfs-csi-driver
parameters:
  collection: mycollection
  replication: "011"  # Passed to SeaweedFS API
  diskType: "ssd"
```

The CSI driver:
1. Receives PVC creation request
2. Connects to SeaweedFS filer
3. Requests volume assignment from master with specified replication
4. Master assigns volume ID based on replication topology
5. CSI mounts the volume via FUSE

#### 4. **Current Errors**
```
no more writable volumes! replication:010 collection: dataCenter:DefaultDataCenter
DefaultDataCenter:Only has 1 racks, not enough for 2.
```

**Root Cause**: 
- The `topology.kubernetes.io/rack` labels are NOT being read by SeaweedFS volume servers
- SeaweedFS sees only 1 rack ("DefaultDataCenter") instead of 2 (rack-1, rack-2)
- Volume servers need to be started with `-rack` and `-dataCenter` flags

### Missing Pieces

#### 1. **Volume Server Rack Configuration**
SeaweedFS volume servers need explicit rack/datacenter flags:
```bash
./weed volume -rack=rack1 -dataCenter=dc1 ...
```

In Helm values.yaml:
```yaml
volume:
  rack: "rack1"
  dataCenter: "dc1"
```

BUT: We have 2 volume servers and can't set different racks for each with the current Helm chart structure!

#### 2. **Helm Chart Limitations**
The standard `volume` section creates a SINGLE DaemonSet/StatefulSet. We CANNOT have different rack values per pod.

**Solution**: The Helm chart supports `volumes:` (plural) for topology-aware deployments:
```yaml
volumes:
  rack1:
    replicas: 1
    rack: "rack-1"
    dataCenter: "dc1"
    nodeSelector: |
      topology.kubernetes.io/rack: rack-1
  rack2:
    replicas: 1
    rack: "rack-2"
    dataCenter: "dc1"
    nodeSelector: |
      topology.kubernetes.io/rack: rack-2
```

This creates SEPARATE StatefulSets for each rack!

## Resolution Plan

### Phase 1: Fix Master Replication Default
**Problem**: Master defaultReplication is hardcoded to `000`
**Solution**: 
1. Keep the kubectl patch we applied (temporary)
2. OR: Submit PR to SeaweedFS Helm chart to make `master.defaultReplication` configurable
3. OR: Fork the Helm chart and fix it locally

### Phase 2: Configure Volume Servers with Proper Topology
**Problem**: Volume servers don't know their rack assignment
**Solution**: Use `volumes:` (plural) configuration in values.yaml

```yaml
# Disable single volume configuration
volume:
  enabled: false

# Enable multi-rack volume configuration
volumes:
  rack1:
    enabled: true
    replicas: 1
    rack: "rack-1"
    dataCenter: "dc1"
    port: 8080
    grpcPort: 18080
    nodeSelector: |
      sw-volume: "true"
      topology.kubernetes.io/rack: rack-1
    dataDirs:
      - name: data
        type: hostPath
        hostPathPrefix: /data/seaweed
        maxVolumes: 100
  rack2:
    enabled: true
    replicas: 1
    rack: "rack-2"
    dataCenter: "dc1"
    port: 8080
    grpcPort: 18080
    nodeSelector: |
      sw-volume: "true"
      topology.kubernetes.io/rack: rack-2
    dataDirs:
      - name: data
        type: hostPath
        hostPathPrefix: /data/seaweed
        maxVolumes: 100
```

### Phase 3: Set Correct Replication in Master and StorageClass
```yaml
global:
  replicationPlacement: "010"  # 1 replica on different rack

# After master fix:
master:
  defaultReplication: "010"

# StorageClass:
parameters:
  replication: "010"
```

### Phase 4: Clean Slate Test
1. Delete all existing PVCs and volumes
2. Restart all SeaweedFS pods
3. Verify topology with `weed shell > volume.list`
4. Create test PVC with Sonarr
5. Verify volume is created with correct replication

## Implementation Steps

### Step 1: Verify Node Labels
```bash
kubectl get nodes -L topology.kubernetes.io/rack,sw-volume
```

### Step 2: Update values.yaml with Multi-Rack Configuration
- Disable single `volume:` section
- Enable `volumes:` multi-rack configuration
- Set `global.replicationPlacement: "010"`

### Step 3: Update ConfigMap
- Mirror values.yaml changes to ConfigMap

### Step 4: Reconcile Helm Release
```bash
flux reconcile helmrelease seaweedfs -n flux-system --with-source
```

### Step 5: Delete Existing Volume Servers
```bash
kubectl delete sts -n seaweedfs seaweedfs-volume
```

### Step 6: Verify New Volume Servers
```bash
kubectl get pods -n seaweedfs -l app.kubernetes.io/component=volume
kubectl logs -n seaweedfs <volume-pod> | grep "rack\|dataCenter"
```

### Step 7: Access SeaweedFS Shell
```bash
kubectl exec -it -n seaweedfs seaweedfs-master-0 -- /bin/sh
weed shell
> cluster.status
> volume.list
```

Should show:
- 2 racks (rack-1, rack-2)
- Volume servers assigned to correct racks

### Step 8: Test with Sonarr
1. Delete existing Sonarr PVC
2. Recreate Sonarr deployment
3. Watch PVC binding
4. Verify Sonarr starts successfully

## Key Learnings

1. **SeaweedFS needs explicit rack/DC assignment** - Kubernetes labels are NOT automatically picked up
2. **Master defaultReplication is critical** - It sets the default for all volumes
3. **Helm chart has limitations** - The single `volume:` section can't do multi-rack
4. **Replication format matters** - `"010"` means different rack, `"001"` means same rack
5. **CSI driver passes replication** - But master must support the topology

## References
- [SeaweedFS Replication](https://github.com/seaweedfs/seaweedfs/wiki/Replication)
- [SeaweedFS CSI Driver](https://github.com/seaweedfs/seaweedfs-csi-driver)
- [Helm Chart values.yaml](https://github.com/seaweedfs/seaweedfs/tree/master/k8s/charts/seaweedfs/values.yaml)
