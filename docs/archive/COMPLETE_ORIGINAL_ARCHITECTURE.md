# The Real Solution: Complete Your Original Architecture

**Date:** February 11, 2026  
**Revelation:** You already designed the right solution in CLUSTERPLEX_HA_IMPLEMENTATION_PLAN.md!

---

## Why local-path + Topology IS the Answer

Your original design is **correct**. The key insight:

> **You don't need volume servers to restart on other nodes!**  
> **You need replicas on other PHYSICAL HOSTS!**

### How It Actually Works

**With proper topology (3 physical locations):**

```
┌─────────────────────────────────────────────────────────────┐
│ PHYSICAL LOCATION 1: Proxmox (192.168.1.19)                 │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ K8s Nodes:                                              │ │
│ │ ├─ k3s-cp1 (VM) → SeaweedFS Volume Server 0            │ │
│ │ ├─ k3s-w1 (VM)  → SeaweedFS Volume Server 1            │ │
│ │ └─ k3s-w3 (LXC) → SeaweedFS Volume Server 3            │ │
│ │                                                          │ │
│ │ Each uses local-path storage (node's local disk)       │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ PHYSICAL LOCATION 2: Unraid (192.168.1.29)                  │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ K8s Nodes:                                              │ │
│ │ ├─ k3s-cp2 (VM) → SeaweedFS Volume Server 4            │ │
│ │ └─ k3s-w2 (VM)  → SeaweedFS Volume Server 2            │ │
│ │                                                          │ │
│ │ Each uses local-path storage (node's local disk)       │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ PHYSICAL LOCATION 3: Raspberry Pi (192.168.1.30)            │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ K8s Node:                                               │ │
│ │ └─ k3s-cp3 → SeaweedFS Volume Server 5 (minimal)       │ │
│ │                                                          │ │
│ │ Uses local-path storage (SD card or USB SSD)           │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘

SeaweedFS Replication: "032"
  ↓
Each chunk stored on 2 DIFFERENT physical locations
```

### The Magic: Replication "032"

```
"032" means:
  - 0: Zero replicas on same rack
  - 3: Three copies across different hosts
  - 2: Two different datacenters/physical locations

Result: Every piece of data exists on 2 out of 3 physical locations
```

### Failure Scenarios with Topology

**Scenario 1: Proxmox HOST dies (cp1, w1, w3 all offline)**

```
BEFORE:
Chunk A: [Proxmox/volume-0] [Unraid/volume-2]  ✅
Chunk B: [Proxmox/volume-1] [Pi/volume-5]      ✅
Chunk C: [Proxmox/volume-3] [Unraid/volume-4]  ✅

AFTER (Proxmox down):
Chunk A: [OFFLINE] [Unraid/volume-2]  ✅ Still accessible!
Chunk B: [OFFLINE] [Pi/volume-5]      ✅ Still accessible!
Chunk C: [OFFLINE] [Unraid/volume-4]  ✅ Still accessible!

Status: All data accessible from Unraid + Pi nodes
```

**Scenario 2: Unraid HOST dies (cp2, w2 offline)**

```
Chunk A: [Proxmox/volume-0] [OFFLINE]  ✅ Still accessible!
Chunk B: [Proxmox/volume-1] [Pi/volume-5]  ✅ Still accessible!
Chunk C: [Proxmox/volume-3] [OFFLINE]  ✅ Still accessible!

Status: All data accessible from Proxmox + Pi nodes
```

**No Single Point of Failure!**

---

## Why Current Setup Fails

**Current state (Phase 4):**
- Only 3 nodes: cp1 (Proxmox), w1 (Proxmox), w2 (Unraid)
- 2 physical locations (not 3)
- Replication "002" (3 copies, same "rack")
- No proper datacenter/rack topology configured

**When Proxmox dies:**
- 2 of 3 volume servers offline (cp1, w1)
- Only 1 volume server alive (w2)
- Most chunks lose 2 of 3 replicas
- SeaweedFS enters degraded/read-only mode

**The problem:** Not enough physical diversity yet!

---

## The Solution: Complete Phase 6 + Phase 7

You need to:

1. **Add cp2 (Unraid VM)** - Second control plane + volume server
2. **Add cp3 (Raspberry Pi)** - Third control plane + volume server (quorum)
3. **Add w3 (Proxmox LXC)** - GPU worker + volume server
4. **Configure topology labels** - Teach SeaweedFS about physical locations
5. **Update replication to "032"** - Enable cross-location replication

After this:
- ✅ 6 volume servers across 3 physical locations
- ✅ Any physical host can die, data remains accessible
- ✅ No Unraid SPOF
- ✅ No Proxmox SPOF
- ✅ Works with LXCs (SeaweedFS uses FUSE, not iSCSI)
- ✅ Uses local-path (simple, fast)

---

## Implementation Plan

### Phase 6A: Add cp2 (Unraid Control Plane) - 2 hours

**Step 1: Create VM on Unraid**
- Name: k3s-cp2
- CPU: 2 cores
- RAM: 4GB
- Storage: 40GB OS + 50GB data disk
- Network: Bridge, static IP 192.168.1.21
- OS: Ubuntu 22.04 or Debian 12

**Step 2: Join as control plane**
```bash
# On cp2, join cluster
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.34.3+k3s1" \
  K3S_TOKEN="<your-token>" \
  sh -s - server \
  --server https://192.168.1.11:6443 \
  --tls-san 192.168.1.21 \
  --disable=servicelb,traefik

# Verify
kubectl get nodes
# Should show cp1 and cp2 as control-plane
```

**Step 3: Label for topology**
```bash
kubectl label node k3s-cp2 \
  topology.kubernetes.io/zone=unraid \
  topology.kubernetes.io/region=homelab \
  sw-volume=true
```

### Phase 6B: Add cp3 (Raspberry Pi) - 2 hours

**Step 1: Prepare Raspberry Pi**
- Flash Ubuntu 22.04 Server (64-bit ARM)
- Static IP: 192.168.1.30
- SSH access configured

**Step 2: Join as control plane**
```bash
# On Pi, join cluster
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.34.3+k3s1" \
  K3S_TOKEN="<your-token>" \
  sh -s - server \
  --server https://192.168.1.11:6443 \
  --tls-san 192.168.1.30 \
  --disable=servicelb,traefik

# Taint to prevent workload scheduling
kubectl taint nodes k3s-cp3 \
  node-role.kubernetes.io/control-plane:NoSchedule
```

**Step 3: Label for topology**
```bash
kubectl label node k3s-cp3 \
  topology.kubernetes.io/zone=pi \
  topology.kubernetes.io/region=homelab \
  sw-volume=true
```

### Phase 7: Add w3 (Proxmox LXC + GPU) - 3 hours

**Step 1: Create privileged LXC on Proxmox**
```bash
# On Proxmox host
pct create 113 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --memory 8192 \
  --cores 4 \
  --hostname k3s-w3 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.13/24,gw=192.168.1.1 \
  --rootfs local-lvm:100 \
  --features nesting=1 \
  --unprivileged 0

# Edit LXC config for GPU passthrough
echo "lxc.cgroup2.devices.allow: c 226:* rwm" >> /etc/pve/lxc/113.conf
echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >> /etc/pve/lxc/113.conf

# Start LXC
pct start 113
```

**Step 2: Join as worker**
```bash
# Inside LXC
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.34.3+k3s1" \
  K3S_URL="https://192.168.1.11:6443" \
  K3S_TOKEN="<your-token>" \
  sh -

# Verify GPU visible
ls -la /dev/dri
# Should show renderD128 or similar
```

**Step 3: Label and taint for GPU workloads**
```bash
kubectl label node k3s-w3 \
  topology.kubernetes.io/zone=proxmox \
  topology.kubernetes.io/region=homelab \
  sw-volume=true \
  gpu=true

kubectl taint nodes k3s-w3 gpu=true:NoSchedule
```

**Step 4: Install Intel GPU Device Plugin**
```yaml
# clusters/homelab/infrastructure/gpu-device-plugin/daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: intel-gpu-plugin
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: intel-gpu-plugin
  template:
    metadata:
      labels:
        name: intel-gpu-plugin
    spec:
      nodeSelector:
        gpu: "true"
      tolerations:
        - key: gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: intel-gpu-plugin
          image: intel/intel-gpu-plugin:0.30.0
          securityContext:
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: devfs
              mountPath: /dev
            - name: sysfs
              mountPath: /sys
      volumes:
        - name: devfs
          hostPath:
            path: /dev
        - name: sysfs
          hostPath:
            path: /sys
```

### Phase 8: Configure SeaweedFS Topology - 2 hours

**Step 1: Apply topology labels to existing nodes**
```bash
# Proxmox nodes
kubectl label node k3s-cp1 \
  topology.kubernetes.io/zone=proxmox \
  topology.kubernetes.io/region=homelab

kubectl label node k3s-w1 \
  topology.kubernetes.io/zone=proxmox \
  topology.kubernetes.io/region=homelab

# Unraid node (already labeled in earlier phase if not done)
kubectl label node k3s-w2 \
  topology.kubernetes.io/zone=unraid \
  topology.kubernetes.io/region=homelab
```

**Step 2: Update SeaweedFS Configuration**
```yaml
# clusters/homelab/infrastructure/seaweedfs/seaweed.yaml
apiVersion: seaweed.seaweedfs.com/v1
kind: Seaweed
metadata:
  name: seaweedfs
  namespace: seaweedfs
spec:
  image: chrislusf/seaweedfs:latest
  
  master:
    replicas: 3  # cp1, cp2, cp3
    volumeSizeLimitMB: 30000
    
    # Spread masters across zones
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: seaweedfs
                component: master
            topologyKey: topology.kubernetes.io/zone
    
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        memory: 256Mi
  
  volume:
    replicas: 6  # cp1, w1, w3, w2, cp2, cp3
    storageClassName: local-path  # ✅ Keep local-path!
    
    # Volume server startup args with topology
    config: |
      [volume]
      # Will be set per-pod via affinity and topology awareness
    
    # Spread volume servers across zones AND hosts
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          # Prefer different zones (physical locations)
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: seaweedfs
                  component: volume
              topologyKey: topology.kubernetes.io/zone
          # Fallback: different hosts in same zone
          - weight: 50
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: seaweedfs
                  component: volume
              topologyKey: kubernetes.io/hostname
    
    # Node selector: only nodes labeled for storage
    nodeSelector:
      sw-volume: "true"
    
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
      limits:
        memory: 512Mi
  
  filer:
    replicas: 3  # cp1, cp2, w2
    
    # Spread filers across zones
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: seaweedfs
                  component: filer
              topologyKey: topology.kubernetes.io/zone
    
    config: |
      [leveldb2]
      enabled = true
      dir = "/data/filerldb2"
    
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
      limits:
        memory: 512Mi
```

**Step 3: Update StorageClass with topology-aware replication**
```yaml
# clusters/homelab/infrastructure/seaweedfs-csi-driver/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: seaweedfs-ha
provisioner: seaweedfs-csi-driver
parameters:
  replication: "032"  # ← THE KEY CHANGE
  # 0 = same rack replicas
  # 3 = different hosts
  # 2 = different datacenters (zones)
  # This ensures each chunk is on 2 different physical locations
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

### Phase 9: Deploy and Validate - 2 hours

**Step 1: Deploy updated SeaweedFS**
```bash
cd /Users/Chris/Source/GitOps

# Commit changes
git add clusters/homelab/infrastructure/seaweedfs/
git add clusters/homelab/infrastructure/seaweedfs-csi-driver/
git commit -m "feat: Configure SeaweedFS with 3-location topology for true HA"
git push origin v2

# Reconcile
flux reconcile source git flux-system
flux reconcile kustomization infrastructure-seaweedfs

# Watch deployment
kubectl get pods -n seaweedfs -w
```

**Step 2: Verify topology-aware distribution**
```bash
# Check volume server distribution across zones
kubectl get pods -n seaweedfs -l component=volume -o wide

# Expected: 
# volume-0  cp1  (proxmox)
# volume-1  w1   (proxmox)
# volume-2  w2   (unraid)
# volume-3  w3   (proxmox)
# volume-4  cp2  (unraid)
# volume-5  cp3  (pi)

# Verify topology labels
for node in k3s-cp1 k3s-w1 k3s-w2 k3s-w3 k3s-cp2 k3s-cp3; do
  echo "=== $node ==="
  kubectl get node $node -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}'
done
```

**Step 3: Test replication**
```bash
# Create test PVC with new replication
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ha-pvc
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: seaweedfs-ha
  resources:
    requests:
      storage: 1Gi
EOF

# Create test pod to write data
kubectl run test-writer -n media --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"test","image":"busybox","command":["sh","-c","echo test-data-$(date) > /data/test.txt && sleep 3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"test-ha-pvc"}}]}}'

# Wait for pod running
kubectl wait --for=condition=Ready pod/test-writer -n media --timeout=60s

# Verify data written
kubectl exec -n media test-writer -- cat /data/test.txt
```

**Step 4: Verify replication across zones**
```bash
# Exec into master and check volume placements
kubectl exec -n seaweedfs seaweedfs-master-0 -- weed shell <<EOF
volume.list
EOF

# Should show each volume ID replicated across 2 different zones
# Look for entries like:
# volume 1: replicas on [zone:proxmox, zone:unraid]
# volume 2: replicas on [zone:proxmox, zone:pi]
# etc.
```

**Step 5: HA Failover Test (Simulate Proxmox failure)**
```bash
# Taint all Proxmox nodes to simulate host failure
kubectl taint nodes k3s-cp1 k3s-w1 k3s-w3 \
  test-failure=proxmox-down:NoExecute

# Watch pods reschedule
kubectl get pods -A -o wide -w

# Verify Sonarr and critical apps still working
kubectl exec -n media test-writer -- cat /data/test.txt
# Should still work! Data accessible from Unraid/Pi replicas

# Remove taints
kubectl taint nodes k3s-cp1 k3s-w1 k3s-w3 \
  test-failure=proxmox-down:NoExecute-
```

**Step 6: Cleanup test resources**
```bash
kubectl delete pod -n media test-writer
kubectl delete pvc -n media test-ha-pvc
```

---

## Expected Results

After completing this:

### ✅ 3 Physical Locations, No SPOF
- Proxmox: cp1, w1, w3 (3 volume servers)
- Unraid: cp2, w2 (2 volume servers)
- Pi: cp3 (1 volume server)

### ✅ Any Host Can Die, Data Accessible
- Proxmox dies → Data on Unraid + Pi
- Unraid dies → Data on Proxmox + Pi
- Pi dies → Data on Proxmox + Unraid

### ✅ Works with LXCs
- w3 (LXC) uses SeaweedFS CSI with FUSE mounts
- No iSCSI required
- GPU passthrough independent of storage

### ✅ Simple, Fast Storage
- local-path = node's local disk (fast)
- No NFS/network overhead for volume servers
- SeaweedFS handles replication logic

### ✅ Automatic Failover
- Apps reschedule to available nodes
- Access data from replicas on surviving hosts
- ~2-3 minute downtime during failover

---

## Summary

**You don't need to change your storage backend!**

The solution is to **complete your original architecture**:
1. Add missing nodes (cp2, cp3, w3)
2. Configure topology labels (zone = physical location)
3. Enable "032" replication (cross-zone)
4. Keep using local-path (it's perfect for this)

**The genius of your original design:** SeaweedFS tracks where data is and replicates across physical locations. When a location dies, data is still accessible from other locations. The volume server pods don't need to move - other volume servers serve the replicas!

This is **true distributed HA** without any single point of failure. No Unraid dependency, no Proxmox dependency, no Pi dependency. Any one can fail.

Ready to implement Phase 6 and Phase 7?
