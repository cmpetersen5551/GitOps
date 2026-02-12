# SeaweedFS High Availability Solution Plan

## Executive Summary

**Root Cause**: SeaweedFS volume servers are using `local-path` storage via StatefulSet PVCs. When a node fails, the pod **cannot** migrate to another node because StatefulSets require the same PVC to reattach, which is bound to storage on the failed node.

**The Paradox**: SeaweedFS is designed as a distributed storage system (like Cassandra or Ceph) that:
- Uses **local disks** on each node for performance
- Provides HA through **application-level replication** (our "002" setting = 3 copies across racks)
- Does **NOT** require network-attached storage for the volume servers themselves

However, Kubernetes StatefulSets + PVCs create a pod-to-disk binding that **prevents pod migration** when a node fails.

---

## Understanding SeaweedFS Architecture

### How SeaweedFS Provides HA:

1. **Volume Servers** store data chunks on local disks
2. **Replication** (e.g., "002" = 3 copies) distributes chunks across different nodes/racks
3. When a volume server goes down:
   - **Other replicas** continue to serve the data
   - Reads are automatically redirected to available replicas
   - Once the replica count drops below threshold, **automatic rebalancing** kicks in

### The Key Insight:

**SeaweedFS volume servers using local storage is CORRECT.** The problem is **how Kubernetes manages that local storage**.

---

## The Problem with StatefulSets + PVCs

Our current configuration in [seaweed.yaml](clusters/homelab/infrastructure/seaweedfs/seaweed.yaml#L21-L27):

```yaml
storageClassName: local-path
```

**What happens on node failure:**

1. Worker node `w1` goes down
2. Volume server pod `seaweed-volume-0` bound to PVC on `w1`
3. StatefulSet tries to reschedule pod
4. **Pod CANNOT start** because:
   - It requires the same PVC (`mount0`)
   - PVC is bound to a PersistentVolume on the dead node
   - PV is not accessible from other nodes (`local-path` is node-local)
5. Pod stuck in `Pending` state until `w1` recovers

**Impact:**
- CSI driver tries to mount volumes stored on the down volume server
- Any PVCs that had chunks on the down server become inaccessible
- Workloads (like Sonarr) hang waiting for volume mounts

---

## Solution Options Analysis

### Option 1: Use `emptyDir` for Volume Server Storage (RECOMMENDED)

**How it works:**
- Volume servers use ephemeral `emptyDir` volumes (RAM or disk-backed)
- When a pod restarts or moves, it starts with **empty storage**
- SeaweedFS replication automatically rebalances data to the new volume server

**Pros:**
- ✅ Pods can freely migrate between nodes
- ✅ True HA: automatic failover on node failure
- ✅ Aligns with SeaweedFS's distributed design
- ✅ Simpler configuration (no PVCs)

**Cons:**
- ⚠️ Data on failed node is lost (but replicas exist elsewhere)
- ⚠️ Rebalancing generates network traffic
- ⚠️ Temporary capacity reduction (until rebalancing completes)

**When it works well:**
- Replication factor ≥ 2 (we have 3 with "002")
- Multiple volume servers (we have 3)
- Good network bandwidth between nodes
- Acceptable to lose data on failed node (replicas cover it)

**Configuration changes needed:**
- Remove `storageClassName` from Seaweed CRD
- Use `emptyDir` with `sizeLimit` to prevent runaway disk usage

---

### Option 2: Use NetworkedStorage for Volume Servers

**How it works:**
- Volume servers store data on NFS/Ceph/Longhorn
- PVCs use RWX or RWO networked storage
- Pods can reschedule because storage is network-accessible

**Pros:**
- ✅ Data persists on node failure
- ✅ Pods can migrate

**Cons:**
- ❌ **Defeats the purpose** of SeaweedFS distributed architecture
- ❌ Network storage becomes the bottleneck
- ❌ Increased latency (network hop for every I/O)
- ❌ Creates a SPOF (the network storage system)
- ❌ More complex infrastructure

**Verdict:** This is like using Ceph to back a Ceph volume server. Not recommended.

---

### Option 3: Use `hostPath` for Volume Server Storage

**How it works:**
- Volume servers mount host directories (e.g., `/mnt/seaweedfs-vol`)
- Data persists on the node's local disk
- No PVCs involved

**Pros:**
- ✅ Data persists on node restart
- ✅ Simpler than PVCs
- ✅ Good performance (local disk)

**Cons:**
- ⚠️ Pods pinned to nodes (can't migrate)
- ⚠️ Requires manual node affinity/anti-affinity
- ⚠️ Must pre-create directories on nodes
- ⚠️ Same pod-to-node binding issue as PVCs

**When it works:**
- Node failures are rare and brief
- Can tolerate brief storage outages
- Want data persistence for restarts

---

### Option 4: Accept Current Behavior (DO NOT RECOMMEND)

**What it means:**
- Keep StatefulSets with `local-path` PVCs
- Accept that pods can't migrate on node failure
- Rely on manual intervention to force-delete stuck pods

**Pros:**
- ✅ No changes needed

**Cons:**
- ❌ Not truly HA (defeating the stated goal)
- ❌ Manual intervention required for failover
- ❌ Extended downtime during node failures

---

## Recommended Implementation: `emptyDir` with Proper Configuration

### Step 1: Understand the Trade-off

With `emptyDir`:
- **Data on a failed node is lost** → Acceptable because we have 3 replicas
- **Rebalancing generates network traffic** → One-time cost, normal for distributed systems
- **Temporary capacity reduction** → Rebalancing typically completes in minutes to hours depending on data size

### Step 2: Modify the Seaweed CRD

Update [seaweed.yaml](clusters/homelab/infrastructure/seaweedfs/seaweed.yaml):

```yaml
apiVersion: seaweed.seaweedfs.com/v1
kind: Seaweed
metadata:
  name: seaweed
  namespace: seaweedfs
spec:
  image: chrislusf/seaweedfs:latest
  hostSuffix: cluster.homenet.city
  
  master:
    replicas: 3
    storageClassName: local-path  # Masters can use local-path (metadata is small)
    
  volume:
    replicas: 3
    # Remove storageClassName completely
    # storageClassName: local-path  
    
    volumeServerConfig:
      maxVolumeCounts: 0  # Auto-calculate based on disk space
    
    # Add emptyDir configuration
    volumes:
    - name: data
      emptyDir:
        sizeLimit: 50Gi  # Adjust based on your needs
    
    volumeMounts:
    - name: data
      mountPath: /data
    
    dataCenter: "homenet-dc1"
    rack: "default-rack_worker"
    
  filer:
    replicas: 1
    storageClassName: local-path  # Filer can use local-path (metadata + small DB)
    
  volumeServerDiskCount: 1
  ...
```

### Step 3: Update Volume Server Pod Affinity

Ensure volume servers spread across nodes:

```yaml
spec:
  volume:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
            - key: app
              operator: In
              values:
              - seaweed-volume
          topologyKey: kubernetes.io/hostname
```

### Step 4: Migration Steps

**⚠️ This will cause downtime - plan accordingly**

1. **Back up Filer metadata:**
   ```bash
   kubectl exec -n seaweedfs seaweed-filer-0 -- \
     weed shell -filer=localhost:8888 \
     "fs.meta.backup -v -o /backup"
   ```

2. **Scale down applications using SeaweedFS:**
   ```bash
   kubectl scale -n media deployment/sonarr --replicas=0
   kubectl scale -n media deployment/prowlarr --replicas=0
   ```

3. **Delete existing SeaweedFS CR:**
   ```bash
   kubectl delete -n seaweedfs seaweed seaweed
   ```
   This will delete StatefulSets and PVCs.

4. **Apply updated CRD** (with emptyDir config above)

5. **Wait for volume servers to come online:**
   ```bash
   kubectl get -n seaweedfs pods -l app=seaweed-volume -w
   ```

6. **Check volume server status:**
   ```bash
   kubectl port-forward -n seaweedfs svc/seaweed-master 9333:9333
   # Visit http://localhost:9333
   ```

7. **Restore Filer metadata** (if needed)

8. **Scale up applications:**
   ```bash
   kubectl scale -n media deployment/sonarr --replicas=1
   kubectl scale -n media deployment/prowlarr --replicas=1
   ```

### Step 5: Test Failover

```bash
# Trigger a node failure
kubectl drain w1 --ignore-daemonsets --delete-emptydir-data

# Watch pods reschedule
kubectl get pods -n seaweedfs -o wide -w
kubectl get pods -n media -o wide -w

# Verify Sonarr can access its data
kubectl logs -n media deployment/sonarr

# Bring node back
kubectl uncordon w1
```

---

## Alternative: Hybrid Approach

If you're uncomfortable with ephemeral storage:

### Use `hostPath` + Node Labels + Anti-Affinity

1. **Pre-create directories** on each worker:
   ```bash
   ssh w1 "sudo mkdir -p /mnt/seaweedfs && sudo chown 1000:1000 /mnt/seaweedfs"
   ssh w2 "sudo mkdir -p /mnt/seaweedfs && sudo chown 1000:1000 /mnt/seaweedfs"
   ssh w3 "sudo mkdir -p /mnt/seaweedfs && sudo chown 1000:1000 /mnt/seaweedfs"
   ```

2. **Configure Seaweed CRD:**
   ```yaml
   spec:
     volume:
       volumes:
       - name: data
         hostPath:
           path: /mnt/seaweedfs
           type: DirectoryOrCreate
       volumeMounts:
       - name: data
         mountPath: /data
       
       affinity:
         nodeAffinity:
           requiredDuringSchedulingIgnoredDuringExecution:
             nodeSelectorTerms:
             - matchExpressions:
               - key: role
                 operator: In
                 values:
                 - worker
         podAntiAffinity:
           requiredDuringSchedulingIgnoredDuringExecution:
           - labelSelector:
               matchExpressions:
               - key: app
                 operator: In
                 values:
                 - seaweed-volume
             topologyKey: kubernetes.io/hostname
   ```

**Trade-off:**
- ✅ Data persists on node restarts
- ⚠️ Pods **still** can't migrate on hard failure (but at least data is there when node recovers)

---

## Monitoring and Validation

After implementing the solution:

1. **Check volume distribution:**
   ```bash
   kubectl exec -n seaweedfs seaweed-master-0 -- \
     weed shell -master=localhost:9333 \
     "volume.list"
   ```

2. **Monitor replication status:**
   ```bash
   watch kubectl exec -n seaweedfs seaweed-master-0 -- \
     weed shell -master=localhost:9333 \
     "volume.fsck"
   ```

3. **Check that workloads can failover:**
   - Drain a node
   - Verify pods move
   - Verify data is accessible

---

## Recommendation

**Go with Option 1: `emptyDir` with proper configuration**

**Rationale:**
1. **Aligns with distributed storage principles** - SeaweedFS is designed for this
2. **True HA** - Pods can freely migrate on node failures
3. **Automatic recovery** - Rebalancing is built into SeaweedFS
4. **Simpler** - No PVC management, no storage class dependencies
5. **Battle-tested** - This is how many distributed systems run in Kubernetes (Cassandra, ElasticSearch, etc.)

**Requirements for success:**
- ✅ Replication factor ≥ 2 (we have 3 with "002")
- ✅ Multiple volume servers (we have 3)
- ✅ Tolerable data loss on node failure (replicas cover it)
- ✅ Good network for rebalancing

---

## Next Steps

1. **Review this plan** - Confirm you're comfortable with the `emptyDir` approach
2. **Schedule maintenance window** - Implementing this requires recreating SeaweedFS
3. **Implement the changes** - Follow Step 4 migration steps
4. **Test failover** - Follow Step 5 testing procedures
5. **Update documentation** - Record lessons learned

---

## References

- [SeaweedFS Production Setup](https://github.com/seaweedfs/seaweedfs/wiki/Production-Setup)
- [SeaweedFS Operator Repository](https://github.com/seaweedfs/seaweedfs-operator)
- [SeaweedFS Volume Management](https://github.com/seaweedfs/seaweedfs/wiki/Volume-Management)
- [Kubernetes StatefulSet Limitations](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/#limitations)

---

## Conclusion

The current configuration is **fundamentally incompatible with HA** because StatefulSets with node-local PVCs prevent pod migration.

**The fix**: Use `emptyDir` for volume servers and rely on SeaweedFS's built-in replication and rebalancing for HA - just like other distributed storage systems do.

Let me know when you're ready to proceed, and I'll help you implement this properly.
