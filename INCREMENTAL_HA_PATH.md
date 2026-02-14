# Incremental Path to HA (Without Raspberry Pi)

**Date:** February 11, 2026  
**Goal:** Eliminate SPOF progressively, Pi comes later

---

## Current State (Phase 4)

```
Proxmox:           Unraid:
├─ cp1 (VM)        └─ w2 (VM)
└─ w1 (VM)

Nodes: 3
Physical locations: 2
Volume servers: 3 (cp1, w1, w2)
Replication: "002" (3 copies, no topology)
Control plane: Single master (cp1)

Problem: When Proxmox dies → 2 of 3 volume servers gone → Degraded
```

---

## Step 1: Add w3 (Proxmox LXC + GPU) - Improves GPU HA

**Time:** 3 hours  
**Benefit:** GPU transcoding survives w1 failure

```
Proxmox:           Unraid:
├─ cp1 (VM)        └─ w2 (VM)
├─ w1 (VM)         
└─ w3 (LXC+GPU) ← NEW

Nodes: 4
Physical locations: 2
Volume servers: 4 (cp1, w1, w3, w2)
Control plane: Still single (cp1)

Improvement:
- ClusterPlex worker on w3 (LXC with GPU)
- More volume servers = better data distribution
- Still vulnerable to Proxmox host failure
```

**Actions:**
1. Create w3 privileged LXC with GPU passthrough
2. Join as k3s worker
3. Label: `gpu=true`, `topology.kubernetes.io/zone=proxmox`
4. Keep replication at "002" for now
5. Deploy ClusterPlex worker pod on w3

---

## Step 2: Add Topology Labels + Replication "010" - TRUE 2-LOCATION HA! ⭐

**Time:** 1 hour  
**Benefit:** Survive Proxmox OR Unraid failure

```
Proxmox (zone):    Unraid (zone):
├─ cp1             └─ w2
├─ w1              
└─ w3              

Replication: "010" ← KEY CHANGE
  0 = same rack
  1 = different rack/datacenter  
  0 = (unused)

Result: Each chunk on 2 zones (Proxmox + Unraid)
```

**How It Works:**

```
Data chunk A:
  Replica 1: Proxmox (any of: cp1, w1, w3)
  Replica 2: Unraid (w2)

Proxmox dies:
  ✅ Chunk A still accessible from Unraid/w2

Unraid dies:
  ✅ Chunk A still accessible from Proxmox (cp1, w1, or w3)
```

**THIS ELIMINATES THE SPOF!** With 2 zones and "010" replication, no single physical host failure takes down your data.

**Actions:**
1. Label nodes by zone:
   ```bash
   kubectl label nodes k3s-cp1 k3s-w1 k3s-w3 topology.kubernetes.io/zone=proxmox
   kubectl label node k3s-w2 topology.kubernetes.io/zone=unraid
   ```

2. Update StorageClass replication:
   ```yaml
   parameters:
     replication: "010"  # Changed from "002"
   ```

3. Update SeaweedFS to use topology-aware scheduling
4. Test failover: Taint Proxmox nodes, verify apps work from w2

---

## Step 3: Add cp2 (Unraid VM) - Control Plane HA

**Time:** 2 hours  
**Benefit:** Survive control plane failure, better workload distribution

```
Proxmox (zone):    Unraid (zone):
├─ cp1 (CP)        ├─ w2
├─ w1              └─ cp2 (CP) ← NEW
└─ w3 (GPU)        

Nodes: 5
Control plane: 2 masters (cp1, cp2)
Volume servers: 5
Replication: Still "010"

Improvement:
- etcd can survive 1 control plane failure (2 of 2 = 50% not ideal, but better)
- More volume servers on Unraid side (w2 + cp2)
- Better workload failover options
```

**Actions:**
1. Create cp2 VM on Unraid
2. Join as k3s server (control plane)
3. Label: `topology.kubernetes.io/zone=unraid`
4. Verify 2-node control plane functional

**Note:** 2-node control plane is not ideal for quorum (needs 50%+1), but it's better than 1. You can still lose cp1 and have cp2 working. When you add cp3 later, you get true 3-node quorum.

---

## Step 4: Add cp3 (Raspberry Pi) - WHEN AVAILABLE - Perfect 3-Location HA

**Time:** 2 hours (when you get the Pi)  
**Benefit:** True 3-location redundancy, ideal quorum

```
Proxmox:           Unraid:            Pi:
├─ cp1 (CP)        ├─ w2              └─ cp3 (CP) ← FUTURE
├─ w1              └─ cp2 (CP)        
└─ w3 (GPU)        

Nodes: 6
Physical locations: 3 ⭐
Control plane: 3 masters (perfect quorum)
Volume servers: 6
Replication: "032" ← UPGRADE

  0 = same rack
  3 = 3 total copies
  2 = across 2 different datacenters

Result: Each chunk on 2 of 3 locations
```

**Why 3 Locations > 2 Locations:**

With 2 locations ("010"):
- Proxmox dies → Unraid has data ✅
- Unraid dies → Proxmox has data ✅
- Both together die → ALL data gone ❌

With 3 locations ("032"):
- Proxmox dies → Unraid + Pi have data ✅
- Unraid dies → Proxmox + Pi have data ✅
- Pi dies → Proxmox + Unraid have data ✅
- Any 2 together die → 1 location still has data ✅

**Actions (when Pi arrives):**
1. Flash Pi with Ubuntu 22.04 ARM
2. Join as k3s server (control plane)
3. Label: `topology.kubernetes.io/zone=pi`
4. Update replication to "032"
5. Taint to prevent workload scheduling

---

## Recommended Immediate Path

### Phase 1: Add w3 (This Week)

**Why first:** You need GPU transcoding for ClusterPlex. This is your primary use case.

**What it gives you:**
- GPU worker in LXC ✅
- More volume servers (better distribution)
- Foundation for topology configuration

**Implementation:** See detailed steps below

### Phase 2: Configure Topology + "010" Replication (Immediately After)

**Why next:** This is THE critical step that eliminates SPOF with what you have now.

**What it gives you:**
- TRUE 2-location HA ✅
- Survive Proxmox OR Unraid failure ✅
- No new hardware needed ✅

**Implementation:** Just labels + config changes

### Phase 3: Add cp2 (Next Month?)

**Why later:** Nice to have, but not blocking. You already have HA storage after Phase 2.

**What it adds:**
- Control plane redundancy
- More volume servers on Unraid side

### Phase 4: Add cp3 (When Pi Arrives)

**Why last:** Final piece for perfect 3-location HA and ideal quorum.

---

## Detailed Implementation: Add w3 (LXC + GPU)

### Prerequisites

- Proxmox host: 192.168.1.19
- Available LXC ID: 113 (or whatever's free)
- Intel GPU on Proxmox host

### Step 1: Create Privileged LXC (30 min)

```bash
# SSH to Proxmox host
ssh root@192.168.1.19

# Download Debian 12 template (if not already)
pveam update
pveam available | grep debian-12
pveam download local debian-12-standard_12.7-1_amd64.tar.zst

# Create LXC (privileged, unprivileged=0)
pct create 113 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname k3s-w3 \
  --memory 8192 \
  --cores 4 \
  --rootfs local-lvm:100 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.1.13/24,gw=192.168.1.1 \
  --nameserver 192.168.1.1 \
  --features nesting=1 \
  --unprivileged 0 \
  --start 0

# Configure GPU passthrough
cat >> /etc/pve/lxc/113.conf <<EOF
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
EOF

# Start LXC
pct start 113

# Enter LXC console
pct enter 113
```

### Step 2: Configure LXC (15 min)

```bash
# Inside LXC
apt update && apt upgrade -y

# Set static hostname
hostnamectl set-hostname k3s-w3

# Verify GPU visible
ls -la /dev/dri
# Should show: renderD128 or card0

# Install required packages
apt install -y curl sudo intel-gpu-tools

# Test GPU
intel_gpu_top
# Should show GPU stats (Ctrl+C to exit)

# Create SSH user (optional, for easier access)
useradd -m -s /bin/bash -G sudo admin
passwd admin
# Set password

# Configure SSH (if needed)
apt install -y openssh-server
systemctl enable --now ssh

# Exit LXC
exit
```

### Step 3: Install k3s Agent (15 min)

```bash
# SSH into w3 (or use pct enter)
ssh root@192.168.1.13

# Get k3s token from control plane
# (run this on your local machine or cp1)
# TOKEN=$(kubectl get secret -n kube-system k3s-token -o jsonpath='{.data.node-password}' | base64 -d)
# Or retrieve from cp1: cat /var/lib/rancher/k3s/server/node-token

# Install k3s agent
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.34.3+k3s1" \
  K3S_URL="https://192.168.1.11:6443" \
  K3S_TOKEN="<paste-token-here>" \
  sh -

# Verify k3s running
systemctl status k3s-agent

# Verify node joined
kubectl get nodes
# (run from local machine or cp1)
```

### Step 4: Label and Taint Node (5 min)

```bash
# From local machine or cp1
kubectl label node k3s-w3 \
  topology.kubernetes.io/zone=proxmox \
  topology.kubernetes.io/region=homelab \
  sw-volume=true \
  gpu=true

# Taint so only GPU workloads schedule here
kubectl taint node k3s-w3 gpu=true:NoSchedule

# Verify labels
kubectl get node k3s-w3 --show-labels
```

### Step 5: Install Intel GPU Device Plugin (30 min)

```bash
cd /Users/Chris/Source/GitOps

# Create directory
mkdir -p clusters/homelab/infrastructure/gpu-device-plugin
```

Create files:

```yaml
# clusters/homelab/infrastructure/gpu-device-plugin/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gpu-device-plugin
```

```yaml
# clusters/homelab/infrastructure/gpu-device-plugin/daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: intel-gpu-plugin
  namespace: gpu-device-plugin
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
          imagePullPolicy: IfNotPresent
          securityContext:
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: devfs
              mountPath: /dev
              readOnly: true
            - name: sysfs
              mountPath: /sys
              readOnly: true
            - name: kubeletsockets
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: devfs
          hostPath:
            path: /dev
        - name: sysfs
          hostPath:
            path: /sys
        - name: kubeletsockets
          hostPath:
            path: /var/lib/kubelet/device-plugins
```

```yaml
# clusters/homelab/infrastructure/gpu-device-plugin/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - daemonset.yaml
```

```yaml
# clusters/homelab/cluster/infrastructure-gpu-device-plugin-kustomization.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-gpu-device-plugin
  namespace: flux-system
spec:
  interval: 5m
  path: ./clusters/homelab/infrastructure/gpu-device-plugin
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

Apply:

```bash
# Add to root kustomization
# Edit clusters/homelab/kustomization.yaml, add:
# - cluster/infrastructure-gpu-device-plugin-kustomization.yaml

# Commit
git add clusters/homelab/infrastructure/gpu-device-plugin/
git add clusters/homelab/cluster/infrastructure-gpu-device-plugin-kustomization.yaml
git commit -m "feat: Add Intel GPU device plugin for w3 LXC"
git push origin v2

# Reconcile
flux reconcile source git flux-system
flux reconcile kustomization infrastructure-gpu-device-plugin

# Verify
kubectl get pods -n gpu-device-plugin
kubectl describe node k3s-w3 | grep gpu.intel.com
# Should show: gpu.intel.com/i915: 1
```

### Step 6: Test GPU Allocation (15 min)

```yaml
# Create test pod requesting GPU
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
  namespace: default
spec:
  nodeSelector:
    gpu: "true"
  tolerations:
    - key: gpu
      operator: Equal
      value: "true"
      effect: NoSchedule
  containers:
    - name: ubuntu
      image: ubuntu:22.04
      command: ["sleep", "3600"]
      resources:
        limits:
          gpu.intel.com/i915: 1
      volumeMounts:
        - name: dri
          mountPath: /dev/dri
  volumes:
    - name: dri
      hostPath:
        path: /dev/dri
```

```bash
# Apply
kubectl apply -f gpu-test-pod.yaml

# Verify scheduled to w3
kubectl get pod gpu-test -o wide

# Verify GPU access inside pod
kubectl exec -it gpu-test -- ls -la /dev/dri
# Should show renderD128

# Cleanup
kubectl delete pod gpu-test
```

---

## Phase 2: Configure Topology + "010" Replication

### Step 1: Label Nodes (5 min)

```bash
# Proxmox zone
kubectl label nodes k3s-cp1 k3s-w1 k3s-w3 \
  topology.kubernetes.io/zone=proxmox

# Unraid zone
kubectl label node k3s-w2 \
  topology.kubernetes.io/zone=unraid

# Verify
kubectl get nodes -L topology.kubernetes.io/zone
```

### Step 2: Update SeaweedFS StorageClass (10 min)

```bash
cd /Users/Chris/Source/GitOps
```

Update all StorageClasses:

```yaml
# clusters/homelab/infrastructure/seaweedfs-csi-driver/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: seaweedfs-ha
provisioner: seaweedfs-csi-driver
parameters:
  replication: "010"  # ← CHANGED from "002"
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: seaweedfs-single
provisioner: seaweedfs-csi-driver
parameters:
  replication: "010"  # ← CHANGED from "002"
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

### Step 3: Update SeaweedFS Volume Server Affinity (10 min)

Edit the Seaweed CRD to spread volume servers across zones:

```yaml
# clusters/homelab/infrastructure/seaweedfs/seaweed.yaml
# In volume section, add/update affinity:
  volume:
    replicas: 4  # cp1, w1, w3, w2
    storageClassName: local-path
    
    # Add this:
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          # Prefer different zones (Proxmox vs Unraid)
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: seaweedfs
                  component: volume
              topologyKey: topology.kubernetes.io/zone
          # Fallback: different nodes in same zone
          - weight: 50
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: seaweedfs
                  component: volume
              topologyKey: kubernetes.io/hostname
```

### Step 4: Apply Changes (10 min)

```bash
git add clusters/homelab/infrastructure/seaweedfs*
git commit -m "feat: Configure SeaweedFS for 2-zone HA with replication 010"
git push origin v2

flux reconcile source git flux-system
flux reconcile kustomization infrastructure-seaweedfs
flux reconcile kustomization infrastructure-seaweedfs-csi-driver

# Watch volume servers redistribute
kubectl get pods -n seaweedfs -l component=volume -w -o wide
```

### Step 5: Test Cross-Zone Replication (20 min)

```bash
# Create new PVC with "010" replication
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-cross-zone-pvc
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: seaweedfs-ha
  resources:
    requests:
      storage: 1Gi
EOF

# Create test pod writing data
kubectl run test-zone-writer -n media --image=busybox --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"test","image":"busybox","command":["sh","-c","for i in $(seq 1 100); do echo test-data-$i >> /data/test-$i.txt; done && sleep 3600"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"test-cross-zone-pvc"}}]}}'

# Wait for completion
kubectl wait --for=condition=Ready pod/test-zone-writer -n media --timeout=60s

# Check which node it's on
kubectl get pod -n media test-zone-writer -o wide

# Exec into SeaweedFS master to check replication
kubectl exec -n seaweedfs seaweedfs-master-0 -- weed shell <<EOF
volume.list
EOF

# Look for the volume ID used by test-cross-zone-pvc
# Verify it has replicas on BOTH zones (Proxmox + Unraid)
```

### Step 6: Simulate Proxmox Failure (20 min)

```bash
# Taint all Proxmox nodes to simulate host failure
kubectl taint nodes k3s-cp1 k3s-w1 k3s-w3 \
  test-failure=proxmox-down:NoExecute

# Watch test pod reschedule to w2 (Unraid)
kubectl get pods -n media -w -o wide

# Verify data still accessible
kubectl wait --for=condition=Ready pod -n media -l run=test-zone-writer --timeout=120s
kubectl exec -n media test-zone-writer -- ls -la /data
kubectl exec -n media test-zone-writer -- wc -l /data/test-*.txt
# Should show all 100 files intact!

# Remove taints
kubectl taint nodes k3s-cp1 k3s-w1 k3s-w3 \
  test-failure=proxmox-down:NoExecute-

# Cleanup
kubectl delete pod -n media test-zone-writer
kubectl delete pvc -n media test-cross-zone-pvc
```

---

## Summary: What This Gets You

### After Phase 1 (w3 + GPU):
- ✅ GPU transcoding working
- ✅ w3 LXC operational
- ✅ 4 volume servers (better distribution)
- ⚠️ Still vulnerable to Proxmox host failure

### After Phase 2 (Topology + "010"):
- ✅ **ELIMINATE SPOF!** ⭐
- ✅ Survive Proxmox OR Unraid failure
- ✅ Automatic failover/failback
- ✅ All data accessible from surviving location
- ⚠️ Control plane still single node (cp1)

### After Phase 3 (cp2):
- ✅ Control plane redundancy (2 nodes)
- ✅ Better workload distribution

### After Phase 4 (cp3 when Pi arrives):
- ✅ Perfect 3-location HA
- ✅ Ideal 3-node quorum
- ✅ Replication "032" (any 2 of 3 locations survive)

**Bottom line:** Phases 1 + 2 (achievable this week) give you TRUE HA with no SPOF using only what you have now!

Ready to start with Phase 1 (w3 LXC)?
