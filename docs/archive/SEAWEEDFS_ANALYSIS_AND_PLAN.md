# SeaweedFS Analysis & Implementation Plan

**Date:** January 16, 2026  
**Cluster:** k3s homelab (Proxmox LXC + Unraid Docker)  
**Current State:** VolSync + Syncthing for HA with manual failover

---

## Executive Summary

After deep analysis, **SeaweedFS would significantly simplify storage management** but requires careful consideration of tradeoffs. The current complexity stems from trying to achieve HA with local storage primitives. SeaweedFS solves this natively but introduces its own operational overhead.

**Recommendation:** **Proceed with SeaweedFS** - The benefits outweigh the learning curve and operational changes for a homelab focused on media services.

---

## Part 1: Root Cause Analysis - Current Complexity

### 1.1 The Core Problem

**You're fighting Kubernetes' stateful storage model with local disks.**

Kubernetes assumes:
- Dynamic provisioning (CSI drivers, cloud storage)
- Storage that "follows" pods (networked storage)
- Storage classes that abstract location

Your setup has:
- Static local disks (`/data/pods/` on each node)
- Storage bound to specific nodes (PVs with nodeAffinity)
- Manual PV creation for each app

**This fundamental mismatch creates cascading complexity.**

### 1.2 Complexity Breakdown

#### A. Static PV Management
**Problem:**
```yaml
# infrastructure/storage/pv-sonarr-primary.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-sonarr-primary
spec:
  capacity:
    storage: 10Gi
  hostPath:
    path: /data/pods/sonarr
    type: DirectoryOrCreate
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k3s-w1  # Hardcoded to node
```

**Why This Hurts:**
- Every new app = 2 PV manifests (primary + backup)
- PV names must be unique cluster-wide
- Manual capacity planning per PV
- No dynamic resizing without recreating PV
- Single source of truth violated (PV path repeated in multiple places)

#### B. VolSync Bidirectional Syncthing Complexity
**Problem:**
```yaml
# apps/media/sonarr/volsync.yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: sonarr-primary
spec:
  sourcePVC: pvc-sonarr
  syncthing:
    serviceType: ClusterIP
    peers:
    - ID: BIK4775-O4DG3X7-N7GB7U7-...  # Manual peer ID discovery
      address: tcp://10.43.163.112:22000  # ClusterIP changes on recreate
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: sonarr-backup
spec:
  sourcePVC: pvc-sonarr-backup
  syncthing:
    peers:
    - ID: FRLLMNU-EOC2JSF-PMB5KWD-...  # Reverse peer ID
      address: tcp://10.43.76.239:22000
```

**Why This Hurts:**
- **Manual peer discovery** - Must extract Syncthing IDs from logs/status after first reconcile
- **Hardcoded ClusterIPs** - If VolSync pods restart, services get new IPs → broken replication
- **Bidirectional sync** - Two ReplicationSource CRs per app (primary ↔ backup)
- **Conflict resolution** - "Last write wins" can cause data corruption if both sides modified
- **No failover automation** - Syncing doesn't automatically redirect app to backup PVC

#### C. Permission Capability Workaround
**Problem:**
```yaml
# apps/media/volsync-mover-capabilities-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: volsync-mover-capabilities
spec:
  schedule: "* * * * *"  # Every minute!
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: patcher
            command:
            - /bin/bash
            - -c
            - |
              for deployment in "volsync-prowlarr-primary" "volsync-sonarr-primary" ...; do
                kubectl patch deployment "$deployment" -n media --type='json' -p='[{
                  "op": "replace",
                  "path": "/spec/template/spec/containers/0/securityContext",
                  "value": {
                    "capabilities": {
                      "add": ["CHOWN", "FOWNER", "DAC_OVERRIDE"],
                      "drop": ["NET_RAW"]
                    }
                  }
                }]'
              done
```

**Why This Hurts:**
- **Runs every minute** - Continuous kubectl patching (wasteful)
- **Fighting VolSync controller** - VolSync reconciles → removes capabilities → CronJob re-adds them
- **One CronJob per namespace** - Doesn't scale to multiple apps
- **k3s-specific** - OpenShift has privileged-movers annotation, k3s doesn't
- **Security tradeoff** - Granting file capabilities to satisfy hostPath ownership

**Root Cause:** VolSync Syncthing mover can't `chown` files on hostPath volumes without elevated Linux capabilities.

#### D. Manual Failover Scripts
**Problem:**
```bash
# scripts/failover/failover promote
# Manually edits deployment YAML in Git:
#   - Changes PVC from pvc-sonarr → pvc-sonarr-backup
#   - Changes nodeAffinity from k3s-w1 → k3s-w2
# Then commits and waits for Flux to reconcile
```

**Why This Hurts:**
- **Not automatic** - Node failure doesn't trigger failover
- **Manual intervention** - Must run script or edit Git
- **Flux reconcile delay** - 1-minute lag before pod reschedules
- **Data sync dependency** - Must wait for VolSync to finish syncing before failover
- **Failback complexity** - Same manual process in reverse

### 1.3 Operational Burden Summary

| Aspect | Current Complexity | Time Cost |
|--------|-------------------|-----------|
| **Add new stateful app** | Create 2 PVs + 2 PVCs + 2 ReplicationSources + update CronJob | ~30 min |
| **Failover** | Run script + wait for sync + verify data + commit + Flux reconcile | ~5-10 min |
| **Debug replication issues** | Check 2 Syncthing pods + logs + peer IDs + ClusterIPs | ~15 min |
| **Scale storage** | Recreate PV + migrate data + update PVC | ~1 hour |
| **Monitor sync status** | Manual kubectl checks, no centralized visibility | Ongoing |

**Annual time cost (10 apps):** ~60-80 hours of maintenance overhead.

---

## Part 2: SeaweedFS Deep Dive

### 2.1 Architecture Overview

SeaweedFS is a **distributed blob store + POSIX filer** designed for billions of small files.

**Core Components:**
```
┌─────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                   │
├─────────────────────────────────────────────────────────┤
│  ┌────────────┐  ┌────────────┐  ┌────────────┐        │
│  │  Master    │  │  Master    │  │  Master    │        │
│  │  (Raft)    │◄─┤  (Raft)    │◄─┤  (Raft)    │        │
│  └────────────┘  └────────────┘  └────────────┘        │
│       │                                                  │
│       │ (Volume ID → Server mapping)                    │
│       ▼                                                  │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐        │
│  │  Volume    │  │  Volume    │  │  Volume    │        │
│  │  Server    │  │  Server    │  │  Server    │        │
│  │  (Storage) │  │  (Storage) │  │  (Storage) │        │
│  └────────────┘  └────────────┘  └────────────┘        │
│       │              │              │                    │
│       └──────────────┼──────────────┘                    │
│                      ▼                                   │
│  ┌────────────────────────────────────────────┐         │
│  │            Filer (POSIX Layer)             │         │
│  │  - Directories & files                     │         │
│  │  - Metadata store (MySQL/Postgres/etc)     │         │
│  │  - S3 API gateway                          │         │
│  └────────────────────────────────────────────┘         │
│                      │                                   │
│                      ▼                                   │
│  ┌────────────────────────────────────────────┐         │
│  │         CSI Driver (PVC provisioner)       │         │
│  └────────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────┘
```

### 2.2 How It Solves Your Problems

#### A. Eliminates Static PVs
**Before (Current):**
```yaml
# Manual PV creation per app
pv-sonarr-primary.yaml
pv-sonarr-backup.yaml
pvc-sonarr.yaml
pvc-sonarr-backup.yaml
```

**After (SeaweedFS):**
```yaml
# One StorageClass, dynamic provisioning
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sonarr-data
spec:
  accessModes:
  - ReadWriteMany  # Multiple nodes can mount!
  resources:
    requests:
      storage: 10Gi
  storageClassName: seaweedfs
```

**How:**
- SeaweedFS CSI driver dynamically creates PVs
- Storage is distributed across volume servers
- No nodeAffinity needed (storage is networked)
- One PVC per app (no primary/backup split)

#### B. Native HA Without Replication CRs
**Before (Current):**
```yaml
# 2 ReplicationSource CRs + manual peer configuration
sonarr-primary ReplicationSource
sonarr-backup ReplicationSource
volsync-mover-capabilities CronJob
```

**After (SeaweedFS):**
```yaml
# Just set replication in StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: seaweedfs
provisioner: seaweedfs-csi-driver
parameters:
  replication: "001"  # Same rack, 1 replica
  # OR
  replication: "010"  # Different rack (k3s-w1 vs k3s-w2)
```

**How:**
- SeaweedFS handles replication at volume level
- Master server tracks which volume servers have copies
- If one volume server fails, master redirects to replica
- No external tools (VolSync, Syncthing, CronJobs)

**Replication Options:**
```
000 - No replication
001 - 1 replica on same rack
010 - 1 replica on different rack (your use case)
100 - 1 replica on different datacenter
```

#### C. Automatic Failover
**Before (Current):**
```bash
# Manual script execution
./scripts/failover/failover promote
```

**After (SeaweedFS):**
```
# Automatic!
1. Volume server on k3s-w1 goes down
2. Master detects failure (heartbeat)
3. Master marks volumes as unavailable on k3s-w1
4. Filer redirects reads/writes to k3s-w2 replica
5. Application continues working (might see brief I/O pause)
```

**How:**
- Master server does health checks (heartbeat every few seconds)
- Master maintains volume → server mapping in memory
- When server fails, master updates routing
- Filer queries master for volume locations on each I/O
- No pod rescheduling needed (storage is network-accessible)

### 2.3 SeaweedFS vs Current Setup

| Feature | Current (VolSync) | SeaweedFS |
|---------|-------------------|-----------|
| **PV Management** | Manual static PVs | Dynamic provisioning |
| **Replication** | VolSync + Syncthing | Built-in (Master-coordinated) |
| **Failover** | Manual script | Automatic (seconds) |
| **Permissions** | CronJob capability patching | CSI driver handles mounting |
| **Multi-mount** | No (RWO) | Yes (RWX) |
| **Storage limit** | Per-PV capacity | Cluster-wide pool |
| **Add new app** | 4 manifests | 1 PVC manifest |
| **Data locality** | Node-pinned hostPath | Distributed + optional locality |
| **Monitoring** | Manual kubectl | Prometheus metrics + Admin UI |
| **Backup** | PV snapshots (manual) | S3 tiering / external backup |

### 2.4 SeaweedFS Architecture Deep Dive

#### Volume Server Storage Model
**How data is stored:**
```
/data/seaweedfs/volume1/
  volume_001.dat  (32GB max, stores many files)
  volume_001.idx  (index: file_id → offset in .dat)
  volume_002.dat
  volume_002.idx
  ...
```

**Key concepts:**
- **Volume** = 32GB blob of data containing many files
- **File ID** = `<volume_id>,<file_key>,<cookie>`
  - Example: `3,01637037d6` means volume 3, file key 01637037d6
- **Master** tracks: "Volume 3 is on k3s-w1 and k3s-w2"
- **O(1) disk access** - Index lookup + single disk read

**Replication:**
- Set at volume creation time (e.g., `010` = different rack)
- Master assigns volumes to servers based on:
  - Free space
  - Rack/datacenter labels
  - Replication requirement
- Volumes are immutable replicas (not synced continuously like Syncthing)

#### Filer Metadata Store
**Filer maintains POSIX filesystem metadata:**
```
/buckets/sonarr/config/
  ├── config.xml  (filer stores: path, size, mod_time, file_id)
  ├── logs/
  │   └── sonarr.txt
```

**Metadata backends (choose one):**
- **LevelDB** - Embedded, simple, good for single/dual filer setup (RECOMMENDED for initial deployment)
- **MySQL/Postgres** - Production-grade, supports HA via database cluster (upgrade option)
- **Redis** - Fast, requires Redis HA setup
- **CockroachDB, TiDB** - Distributed SQL (overkill for homelab)

**For your use case (initial):** LevelDB - no external database needed, simpler to validate SeaweedFS first. Can migrate to MySQL later if concurrent filer access becomes an issue.

#### CSI Driver Operation
**When you create a PVC:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sonarr-data
spec:
  accessModes:
  - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
  storageClassName: seaweedfs
```

**CSI driver flow:**
1. **CreateVolume RPC** - CSI driver calls Filer to create `/buckets/<pvc-name>/`
2. **Filer creates directory** in metadata store
3. **Mount RPC** - Kubelet requests mount on node
4. **FUSE mount** - CSI driver creates FUSE mount at `/var/lib/kubelet/pods/.../sonarr-data`
5. **Pod starts** - Pod sees regular directory, writes files
6. **Filer handles I/O**:
   - Write: Filer asks Master for writable volume → writes to Volume Server → updates metadata
   - Read: Filer queries metadata → gets file_id → asks Master for volume location → reads from Volume Server

**Result:** Application sees normal filesystem, but data is distributed and replicated.

---

## Part 3: Implementation Plan

### 3.1 Deployment Architecture

**Recommended topology for your 2-node cluster:**
```
┌─────────────────────────────────────────────────────────┐
│  k3s-cp1 (Control Plane - Proxmox LXC)                  │
│  ┌────────────┐                                         │
│  │  Master 1  │  (Raft leader election)                 │
│  └────────────┘                                         │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  k3s-w1 (Worker 1 - Proxmox LXC)                        │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐        │
│  │  Master 2  │  │  Volume    │  │  Filer 1   │        │
│  │  (Raft)    │  │  Server 1  │  │            │        │
│  └────────────┘  └────────────┘  └────────────┘        │
│                   /data/seaweedfs/                      │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  k3s-w2 (Worker 2 - Unraid Docker)                      │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐        │
│  │  Master 3  │  │  Volume    │  │  Filer 2   │        │
│  │  (Raft)    │  │  Server 2  │  │            │        │
│  └────────────┘  └────────────┘  └────────────┘        │
│                   /data/seaweedfs/                      │
└─────────────────────────────────────────────────────────┘
```

**Component placement rationale:**
- **3 Masters** - Raft requires odd number for quorum (tolerates 1 failure)
- **2 Volume Servers** - Minimum for `010` replication (different racks)
- **2 Filers** - HA for filer service (MySQL backend shared)
- **CSI Driver** - DaemonSet on all nodes

### 3.2 Node Preparation

#### A. On ALL Nodes (k3s-cp1, k3s-w1, k3s-w2)

**1. Create SeaweedFS data directory:**
```bash
sudo mkdir -p /data/seaweedfs
sudo chown 1000:1000 /data/seaweedfs  # Match pod UID if needed
```

**2. Label nodes for scheduling:**
```bash
# Label k3s-w1 as rack-1
kubectl label node k3s-w1 topology.kubernetes.io/rack=rack-1

# Label k3s-w2 as rack-2
kubectl label node k3s-w2 topology.kubernetes.io/rack=rack-2

# Verify
kubectl get nodes --show-labels | grep rack
```

**Why:** SeaweedFS uses these labels for `010` replication (different racks).

#### B. Unraid-Specific (k3s-w2)

**1. Ensure Docker volume mount persists:**
```bash
# Unraid: Add to Docker container config for k3s
-v /mnt/user/appdata/seaweedfs:/data/seaweedfs
```

**2. Set proper permissions:**
```bash
chown -R 1000:1000 /mnt/user/appdata/seaweedfs
```

### 3.3 Filer Metadata Backend Setup

**Option 1: LevelDB (Recommended for Initial Deployment)**
Use embedded LevelDB with a single filer:
```yaml
# No external database setup needed
filer:
  enabled: true
  replicas: 1  # Start with 1 filer for simplicity
  # LevelDB is default, no config needed
```
**Pros:**
- Zero external dependencies
- Simple to deploy and validate
- Good enough for media workloads (low concurrent metadata access)

**Cons:**
- Single filer only (no HA filer)
- Limited to ~1000 files/sec metadata operations

**When to upgrade:** If you add more services with high concurrent file operations (databases, caching layers), upgrade to MySQL.

**Option 2: Deploy MySQL in Kubernetes (Future Upgrade)**
If performance becomes an issue, deploy MySQL:

```yaml
# infrastructure/mysql/mysql-statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: seaweedfs
spec:
  serviceName: mysql
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: root-password
        - name: MYSQL_DATABASE
          value: seaweedfs_filer
        ports:
        - containerPort: 3306
        volumeMounts:
        - name: mysql-data
          mountPath: /var/lib/mysql
  volumeClaimTemplates:
  - metadata:
      name: mysql-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 20Gi
```

**Create database:**
```sql
CREATE DATABASE IF NOT EXISTS seaweedfs_filer;
CREATE USER 'seaweedfs'@'%' IDENTIFIED BY 'your-password';
GRANT ALL PRIVILEGES ON seaweedfs_filer.* TO 'seaweedfs'@'%';
FLUSH PRIVILEGES;
```

**Enable in SeaweedFS Helm values** (see below).

### 3.4 Helm Chart Deployment

**1. Add Helm repository:**
```bash
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm
helm repo update
```

**2. Create `values.yaml`:**
```yaml
# clusters/homelab/infrastructure/seaweedfs/values.yaml
# NOTE: Start with LevelDB (default). Upgrade to MySQL later if needed.

global:
  replicationPlacment: "010"  # Different rack replication

master:
  enabled: true
  replicas: 3  # HA with Raft
  persistence:
    enabled: true
    size: 10Gi
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: seaweedfs-master
        topologyKey: kubernetes.io/hostname

volume:
  enabled: true
  replicas: 2  # k3s-w1 and k3s-w2
  dataDirs:
  - name: data
    type: hostPath
    hostPathPrefix: /data/seaweedfs
    maxVolumes: 100  # Adjust based on disk size
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: seaweedfs-volume
        topologyKey: kubernetes.io/hostname
  nodeSelector:
    sw-volume: "true"  # Only schedule on labeled nodes

filer:
  enabled: true
  replicas: 1  # Start with 1 filer (LevelDB default)
  s3:
    enabled: true  # Optional S3 API
    port: 8333
  # For initial deployment: use LevelDB (no config needed)
  # For future MySQL backend, uncomment and update below:
  # extraEnvironmentVars:
  #   WEED_MYSQL_ENABLED: "true"
  #   WEED_MYSQL_HOSTNAME: mysql.seaweedfs.svc.cluster.local
  #   WEED_MYSQL_PORT: "3306"
  #   WEED_MYSQL_DATABASE: seaweedfs_filer
  #   WEED_MYSQL_USERNAME: seaweedfs
  #   WEED_MYSQL_PASSWORD: your-password  # Use Sealed Secret!
  #   WEED_MYSQL_CONNECTION_MAX_IDLE: "5"
  #   WEED_MYSQL_CONNECTION_MAX_OPEN: "75"
  #   WEED_MYSQL_CONNECTION_MAX_LIFETIME_SECONDS: "0"
  
  # LevelDB metadata persistence
  persistence:
    enabled: true
    size: 10Gi  # LevelDB metadata store
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app: seaweedfs-filer
          topologyKey: kubernetes.io/hostname

# CSI Driver
csi:
  driver:
    enabled: true
  controller:
    replicas: 1
  node:
    enabled: true  # DaemonSet on all nodes

# Node labels (ensure these exist)
global:
  nodeSelector:
    sw-backend: "true"  # For master/filer
    sw-volume: "true"   # For volume servers
```

**3. Install SeaweedFS:**
```bash
kubectl create namespace seaweedfs
helm install seaweedfs seaweedfs/seaweedfs \
  --namespace seaweedfs \
  --values clusters/homelab/infrastructure/seaweedfs/values.yaml
```

**4. Verify deployment:**
```bash
# Check pods
kubectl get pods -n seaweedfs

# Expected output:
# seaweedfs-master-0                1/1     Running
# seaweedfs-master-1                1/1     Running
# seaweedfs-master-2                1/1     Running
# seaweedfs-volume-0                1/1     Running
# seaweedfs-volume-1                1/1     Running
# seaweedfs-filer-0                 1/1     Running
# seaweedfs-filer-1                 1/1     Running
# seaweedfs-csi-controller-...      2/2     Running
# seaweedfs-csi-node-...            2/2     Running (on each node)

# Check master UI
kubectl port-forward -n seaweedfs svc/seaweedfs-master 9333:9333
# Open http://localhost:9333

# Check CSI driver
kubectl get csidrivers
# Should show: seaweedfs-csi-driver
```

### 3.5 Create StorageClass

```yaml
# clusters/homelab/infrastructure/seaweedfs/storageclass.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: seaweedfs
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: seaweedfs-csi-driver
parameters:
  replication: "010"  # 1 replica on different rack
  collection: ""      # Optional: group volumes
  diskType: "hdd"     # or "ssd"
  path: /buckets      # Base path in filer
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
```

### 3.6 Migrate Existing Applications

**Strategy:** Blue-green deployment (run old and new in parallel).

**Example: Sonarr Migration**

**1. Create new PVC with SeaweedFS:**
```yaml
# apps/media/sonarr/pvc-new.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sonarr-data-seaweedfs
  namespace: media
spec:
  accessModes:
  - ReadWriteMany  # Can mount on multiple nodes!
  resources:
    requests:
      storage: 10Gi
  storageClassName: seaweedfs
```

**2. Deploy data migration job:**
```yaml
# apps/media/sonarr/migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: sonarr-migrate
  namespace: media
spec:
  template:
    spec:
      containers:
      - name: rsync
        image: instrumentisto/rsync-ssh
        command:
        - sh
        - -c
        - |
          rsync -av --progress /old-data/ /new-data/
          echo "Migration complete"
        volumeMounts:
        - name: old-data
          mountPath: /old-data
          readOnly: true
        - name: new-data
          mountPath: /new-data
      volumes:
      - name: old-data
        persistentVolumeClaim:
          claimName: pvc-sonarr  # Old VolSync PVC
      - name: new-data
        persistentVolumeClaim:
          claimName: sonarr-data-seaweedfs
      restartPolicy: Never
```

**3. Update deployment to use new PVC:**
```yaml
# apps/media/sonarr/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sonarr
  namespace: media
spec:
  template:
    spec:
      containers:
      - name: sonarr
        volumeMounts:
        - name: config
          mountPath: /config
      volumes:
      - name: config
        persistentVolumeClaim:
          claimName: sonarr-data-seaweedfs  # Changed from pvc-sonarr
      # Remove nodeAffinity - no longer needed!
```

**4. Delete old resources (after verification):**
```bash
# Remove VolSync CRs
kubectl delete replicationsource -n media sonarr-primary sonarr-backup

# Remove old PVCs
kubectl delete pvc -n media pvc-sonarr pvc-sonarr-backup

# Remove old PVs
kubectl delete pv pv-sonarr-primary pv-sonarr-backup

# Remove CronJob
kubectl delete cronjob -n media volsync-mover-capabilities

# Commit changes to Git
git rm infrastructure/storage/pv-sonarr-*.yaml
git rm apps/media/sonarr/volsync.yaml
git rm apps/media/volsync-mover-capabilities-cronjob.yaml
git commit -m "Migrate Sonarr to SeaweedFS, remove VolSync"
git push
```

### 3.7 Cleanup Legacy Infrastructure

**After all apps migrated:**
```bash
# Remove VolSync operator
kubectl delete -f infrastructure/controllers/volsync-operator.yaml

# Remove VolSync CRDs
kubectl delete crd replicationsources.volsync.backube
kubectl delete crd replicationdestinations.volsync.backube

# Update Flux Kustomization
git rm infrastructure/controllers/volsync-operator.yaml
git rm infrastructure/storage/pv-*.yaml
git commit -m "Remove VolSync infrastructure"
git push
```

---

## Part 4: Operational Comparison

### 4.1 Day-to-Day Operations

| Task | Current (VolSync) | SeaweedFS |
|------|-------------------|-----------|
| **Add new stateful app** | 1. Create 2 PVs in `infrastructure/storage/`<br>2. Create 2 PVCs in `apps/<category>/<app>/`<br>3. Create 2 ReplicationSources<br>4. Update CronJob with new app<br>5. Wait for Syncthing peer discovery<br>6. Update ReplicationSources with peer IDs | 1. Create 1 PVC<br>2. Done. |
| **Failover to backup node** | 1. Run `./failover promote`<br>2. Script edits deployment (PVC + nodeAffinity)<br>3. Git commit<br>4. Wait for Flux reconcile<br>5. Verify pod rescheduled<br>6. Check data integrity | Automatic.<br>Master detects failure → redirects I/O.<br>No manual action. |
| **Failback to primary** | 1. Wait for VolSync to sync backup → primary<br>2. Run `./failover demote`<br>3. Git commit<br>4. Wait for Flux reconcile | Automatic when node returns.<br>Data already synced. |
| **Scale storage for app** | 1. Recreate PV with larger capacity<br>2. Delete PVC<br>3. Recreate PVC<br>4. Trigger data migration<br>5. Update both primary and backup PVs | 1. Edit PVC:<br>   `kubectl edit pvc sonarr-data`<br>2. Increase `spec.resources.requests.storage`<br>3. Done. SeaweedFS expands automatically. |
| **Monitor replication** | `kubectl get replicationsource -n media`<br>`kubectl logs -n media -l volsync.backube/mover=syncthing` | Check Master UI at `:9333`<br>Prometheus metrics<br>`kubectl exec seaweedfs-master-0 -- weed shell` |
| **Debug I/O issues** | Check 2 Syncthing pods + logs + peer connectivity + ClusterIPs | Check filer logs:<br>`kubectl logs -n seaweedfs seaweedfs-filer-0` |

### 4.2 Failure Scenarios

| Scenario | Current (VolSync) | SeaweedFS |
|----------|-------------------|-----------|
| **k3s-w1 node down** | 1. Sonarr pod stuck (can't mount PVC on k3s-w1)<br>2. Manual failover script<br>3. Wait for Flux<br>4. Pod reschedules to k3s-w2<br>5. Data may be stale if VolSync lagged | 1. Master detects failure (10s)<br>2. Redirects I/O to k3s-w2 volume replica<br>3. Sonarr continues (brief I/O pause)<br>4. No pod reschedule needed |
| **VolSync Syncthing pod crash** | 1. Replication stops<br>2. Data diverges between primary/backup<br>3. CronJob keeps trying to patch capabilities<br>4. Manual restart needed | N/A - No replication pods. |
| **Both nodes down** | **Total data loss** if VolSync didn't finish syncing. | **Data loss** - Need 3rd node or external backup for true HA. |
| **MySQL down (filer metadata)** | N/A | Filer can't serve files (reads/writes fail).<br>Solution: MySQL HA (master-slave). |
| **Master quorum lost** | N/A | Cluster read-only until quorum restored.<br>Solution: 3+ masters (tolerates 1 failure). |

### 4.3 Backup Strategy

**Current:**
- VolSync replicates to backup node (not a real backup)
- No external backup system

**With SeaweedFS:**
1. **VolSync still works!** Can replicate SeaweedFS PVCs to external storage
2. **S3 Tiering** - Auto-move old data to S3 (AWS, Backblaze, MinIO)
3. **Snapshots** - Use Kubernetes VolumeSnapshot (if CSI supports)
4. **Direct backup** - Mount filer via FUSE, rsync to NAS

**Recommended:** VolSync + Backblaze B2 for offsite backup.

---

## Part 5: Drawbacks & Tradeoffs

### 5.1 Disadvantages of SeaweedFS

| Concern | Impact | Mitigation |
|---------|--------|------------|
| **Learning curve** | New system to learn (Master, Filer, Volume Server concepts) | Well-documented, active community |
| **Additional components** | More moving parts (3 masters, 2 filers, 2 volume servers) vs current (just VolSync operator) | Helm chart simplifies deployment |
| **Metadata backend** | Filer metadata can be local (LevelDB) or external (MySQL/Postgres) | LevelDB is simpler for initial deploy; upgrade to MySQL if you need HA across multiple filers |
| **Master is SPOF** | If all masters down, cluster is read-only | Deploy 3+ masters (tolerates 1 failure) |
| **Network overhead** | All I/O is networked (vs local hostPath) | Acceptable for homelab; optimize with data locality |
| **Resource usage** | ~2GB RAM for masters + filers + volume servers | Verify nodes have capacity |
| **No ZFS/BTRFS** | SeaweedFS uses its own blob format, not filesystem snapshots | Trade snapshot features for HA |
| **Erasure coding complexity** | Advanced feature, not needed for 2-node setup | Skip erasure coding for now |

### 5.2 When NOT to Use SeaweedFS

**Don't use SeaweedFS if:**
- You have only 1 node (no HA benefit)
- You need < 1ms latency (local disk is faster)
- You require POSIX compliance at kernel level (FUSE has limitations)
- You need massive single-file performance (Ceph/Lustre better)
- You want zero operational overhead (current static PVs simpler, but not HA)

**Your use case DOES benefit** because:
- 2+ nodes (HA is primary goal)
- Media workloads (large files, sequential I/O, not latency-sensitive)
- Want to eliminate manual failover scripts
- Willing to trade complexity type (VolSync + CronJobs → SeaweedFS cluster management)

---

## Part 6: Recommended Approach

### 6.1 Phased Rollout

**Phase 1: Deploy SeaweedFS (Week 1)**
- [ ] Deploy SeaweedFS Helm chart (3 masters, 2 volume servers, filer(s) using LevelDB, CSI)
- [ ] Create StorageClass with `010` replication
- [ ] Create `/data/seaweed` and `/data/seaweed_master` on nodes and verify permissions
- [ ] Deploy test pod with PVC to verify CSI driver works
- [ ] Test failover: stop volume server on k3s-w1, verify I/O continues

**Phase 2: Migrate 1 App (Week 2)**
- [ ] Choose low-risk app (not Sonarr/Radarr initially)
- [ ] Create new PVC with SeaweedFS
- [ ] Run migration job (rsync old PVC → new PVC)
- [ ] Update deployment to use new PVC
- [ ] Monitor for 3-7 days
- [ ] Delete old PVCs/PVs if successful

**Phase 3: Migrate Remaining Apps (Week 3-4)**
- [ ] Migrate Sonarr, Prowlarr, Radarr, etc.
- [ ] Use same migration pattern
- [ ] Parallelize where possible (non-dependent apps)

**Phase 4: Cleanup (Week 5)**
- [ ] Remove VolSync operator
- [ ] Remove VolSync CRDs
- [ ] Remove volsync-mover-capabilities CronJob
- [ ] Remove all static PVs from `infrastructure/storage/`
- [ ] Update GitOps documentation

**Phase 5: Optimize (Ongoing)**
- [ ] Add Prometheus monitoring
- [ ] Set up S3 tiering for old data
- [ ] Configure external backups (VolSync to Backblaze)
- [ ] Tune performance (adjust volume sizes, replica count)

### 6.2 Rollback Plan

**If SeaweedFS doesn't work out:**
1. Keep old PVs/PVCs during Phase 2-3 (don't delete immediately)
2. Rsync data back from SeaweedFS PVC → old PVC
3. Revert deployment to use old PVC
4. Uninstall SeaweedFS Helm chart
5. Re-enable VolSync operator

**Decision Point:** After Phase 2 (1 app migrated). If successful for 1 week, proceed. If issues, rollback.

---

## Part 7: Final Recommendation

### ✅ **GO with SeaweedFS**

**Why:**
1. **Eliminates 90% of current complexity** - No more static PVs, VolSync CRs, CronJobs, failover scripts
2. **True HA** - Automatic failover without manual intervention
3. **Scales easily** - Adding stateful apps is trivial (1 PVC manifest)
4. **Future-proof** - Can add 3rd node later, enable S3 API, add cloud tiering
5. **Well-maintained** - Active project, 29.6k GitHub stars, enterprise backing

**Tradeoffs accepted:**
- More components to manage (masters, filers, volume servers)
- Network overhead vs local disk (acceptable for media workloads)
- Metadata backend: LevelDB by default (local). Optional MySQL/Postgres for multi-filer HA.

### Next Steps

1. **Read SeaweedFS documentation:**
   - https://github.com/seaweedfs/seaweedfs/wiki
   - https://github.com/seaweedfs/seaweedfs-csi-driver

2. **Deploy in test namespace first:**
   ```bash
   kubectl create namespace seaweedfs-test
   helm install seaweedfs-test seaweedfs/seaweedfs \
     --namespace seaweedfs-test \
     --values test-values.yaml
   ```

3. **Test with dummy app:**
   - Deploy nginx with SeaweedFS PVC
   - Write files, read files
   - Stop volume server, verify failover
   - Scale PVC, verify expansion works

4. **Proceed with Phase 1 if tests pass.**

---

## Part 8: Resources & References

**Official Documentation:**
- SeaweedFS GitHub: https://github.com/seaweedfs/seaweedfs
- CSI Driver: https://github.com/seaweedfs/seaweedfs-csi-driver
- Helm Chart: https://github.com/seaweedfs/seaweedfs/tree/master/k8s/charts/seaweedfs
- Wiki: https://github.com/seaweedfs/seaweedfs/wiki

**Architecture:**
- Facebook Haystack Paper: http://www.usenix.org/event/osdi10/tech/full_papers/Beaver.pdf
- Facebook f4 Paper: https://www.usenix.org/system/files/conference/osdi14/osdi14-paper-muralidhar.pdf

**Community:**
- Slack: https://join.slack.com/t/seaweedfs/shared_invite/...
- Reddit: https://www.reddit.com/r/SeaweedFS/
- Discussions: https://github.com/seaweedfs/seaweedfs/discussions

---

## Appendix: Quick Reference

### Useful Commands

**Check cluster status:**
```bash
kubectl exec -n seaweedfs seaweedfs-master-0 -- weed shell <<EOF
volume.list
cluster.status
EOF
```

**Check replication:**
```bash
kubectl exec -n seaweedfs seaweedfs-master-0 -- weed shell <<EOF
volume.list -volumeId=1
EOF
```

**Mount filer locally (for debugging):**
```bash
weed mount -filer=localhost:8888 -dir=/mnt/seaweedfs
```

**Check filer metadata store:**
```bash
kubectl exec -n seaweedfs seaweedfs-filer-0 -- weed filer.meta.cat -dir=/buckets/sonarr-data
```

### Troubleshooting

**PVC stuck in Pending:**
```bash
kubectl describe pvc <pvc-name>
# Check events for errors

kubectl logs -n seaweedfs -l app=seaweedfs-csi-controller
# Check CSI controller logs
```

**I/O errors:**
```bash
kubectl logs -n seaweedfs seaweedfs-filer-0
# Check filer logs

kubectl exec -n seaweedfs seaweedfs-volume-0 -- ls -la /data
# Verify volume data exists
```

**Replication not working:**
```bash
kubectl exec -n seaweedfs seaweedfs-master-0 -- weed shell <<EOF
volume.fix.replication
EOF
```

---

**End of Analysis & Plan**

**Author:** GitHub Copilot  
**Date:** January 16, 2026  
**Version:** 1.0
