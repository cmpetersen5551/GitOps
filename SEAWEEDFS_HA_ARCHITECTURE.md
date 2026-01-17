# SeaweedFS Storage Architecture & HA Design

## Directory Structure & Purpose

### `/data/seaweed_master` - Master (Raft consensus)
- **What:** Raft log files storing cluster state
- **Pods:** Master-0, Master-1, Master-2 (3 pods)
- **Purpose:** Consensus on volume-to-server mappings
- **Size:** Small (metadata only), 2Gi allocated
- **HA:** 3 masters = tolerates 1 failure (Raft quorum)
- **Data format:** Binary Raft logs

```
/data/seaweed_master/
├── raft.log       # Raft consensus state
├── raft.snapshot  # Checkpoints for fast recovery
└── meta.db        # Volume assignment table
```

### `/data/seaweed_filer` - Filer (filesystem metadata)
- **What:** LevelDB embedded database with directory tree & file attributes
- **Pods:** Filer-0 (currently 1 pod)
- **Purpose:** POSIX filesystem metadata (directories, file names, permissions)
- **Size:** 2Gi allocated
- **HA:** ⚠️ **SINGLE POD = SPOF** (can't failover with LevelDB)
- **Data format:** LevelDB key-value store

```
/data/seaweed_filer/
├── 000001.log     # LevelDB write-ahead logs
├── CURRENT        # Current manifest
├── MANIFEST-*     # Version manifests
└── *.ldb          # Sorted tables
```

### `/data/seaweed` - Volume Servers (blob storage)
- **What:** 32GB volume files + indices storing actual file blobs
- **Pods:** Volume-0 (k3s-w1), Volume-1 (k3s-w2)
- **Purpose:** Distributed blob storage for file data
- **Size:** Grows with data, 100 max volumes per server
- **HA:** `010` replication = 1 replica on different rack
- **Data format:** SeaweedFS volumes (volume_NNN.dat + volume_NNN.idx)

```
/data/seaweed/
├── volume_001.dat    # 32GB blob file
├── volume_001.idx    # Index (file_id → offset)
├── volume_002.dat
├── volume_002.idx
└── ...
```

---

## HA Topology: Current vs Ideal

### Current (Homelab - SINGLE FILER):
```
┌─────────────────────────────────────────┐
│           k3s-cp1                       │
│  ┌──────────────────────────────────┐   │
│  │  Master-0 (Raft)                │   │
│  │  /data/seaweed_master           │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│           k3s-w1                        │
│  ┌──────────────────────────────────┐   │
│  │  Master-1 (Raft)                │   │
│  │  /data/seaweed_master           │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │  Volume-0 (data)                │   │
│  │  /data/seaweed (016GB limit)    │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │  Filer-0 (metadata) ⚠️ SPOF     │   │
│  │  /data/seaweed_filer (LevelDB)  │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│           k3s-w2                        │
│  ┌──────────────────────────────────┐   │
│  │  Master-2 (Raft)                │   │
│  │  /data/seaweed_master           │   │
│  └──────────────────────────────────┘   │
│  ┌──────────────────────────────────┐   │
│  │  Volume-1 (data replica)        │   │
│  │  /data/seaweed (016GB limit)    │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘

Master HA:    ✅ Raft quorum (3/3 = tolerates 1 failure)
Volume HA:    ✅ 010 replication (1 replica on different rack)
Filer HA:     ❌ SINGLE POD = all file I/O blocked if down
```

---

### Ideal (After Upgrade to MySQL):
```
Filer-0 ──┐
          ├──→ MySQL Cluster (InnoDB)
Filer-1 ──┘    ├─ k3s-w1
               └─ k3s-w2 (backup)

Master HA:    ✅ 3 masters (Raft quorum)
Volume HA:    ✅ 010 replication
Filer HA:     ✅ 2 filers + MySQL cluster = no SPOF
```

---

## What Fails When?

### Master Down (1 of 3):
```
Masters: 2/3 running
Result:  ✅ Cluster operational (Raft: 2/3 = no quorum but read-only)
Impact:  No new volumes can be created
         Existing volumes: readable/writable
Recovery: Auto-restart pod → ~10s recovery
```

### Volume Server Down (1 of 2):
```
Volumes: 1/2 running
Result:  ✅ Cluster operational
Impact:  Can't create new volumes on failed server
         Existing volumes: auto-redirect to replica
Recovery: Auto-restart pod → ~15-30s recovery
```

### Filer Down (1 of 1) ⚠️:
```
Filers: 0/1 running
Result:  ❌ NO FILE I/O POSSIBLE
Impact:  Apps hang on any file operation
         Masters/Volumes still healthy (but inaccessible)
Recovery: Auto-restart pod → 1-2 minutes
          All I/O requests blocked until filer back online
```

---

## Upgrade Path to Reduce SPOF

### Step 1: Add MySQL (can be 1 pod or HA)
```bash
# Deploy MySQL StatefulSet
kubectl apply -f infrastructure/mysql/mysql.yaml
```

### Step 2: Update Filer to MySQL
```yaml
filer:
  replicas: 2  # Or more
  extraEnvironmentVars:
    WEED_MYSQL_ENABLED: "true"
    WEED_MYSQL_HOSTNAME: "mysql.seaweedfs.svc"
```

### Step 3: Add MySQL HA (future)
- MySQL replication (master-slave)
- Or RDS/Cloud SQL
- Or Galera/Percona XtraDB cluster

---

## Current Node Preparation

After you committed, run on **each node** (k3s-cp1, k3s-w1, k3s-w2):

```bash
# SSH to node
ssh k3s-w1

# Create directories
sudo mkdir -p /data/seaweed_master
sudo mkdir -p /data/seaweed_filer
sudo mkdir -p /data/seaweed

# Set permissions (pod UID is 1000)
sudo chown 1000:1000 /data/seaweed_master
sudo chown 1000:1000 /data/seaweed_filer
sudo chown 1000:1000 /data/seaweed

# Verify
ls -lah /data/seaweed*
```

---

## Summary

| Component | Replicas | Backend | HA Status | Risk |
|-----------|----------|---------|-----------|------|
| Master | 3 | Raft logs | ✅ Quorum | Low |
| Volume | 2 | hostPath | ✅ `010` replication | Low |
| Filer | 1 | LevelDB | ❌ **SPOF** | **HIGH** |

**Recommendation:** Accept filer SPOF for now (brief metadata unavailability acceptable for media workload). Upgrade to MySQL + 2 filers when metadata I/O becomes critical.

---

**Updated:** January 17, 2026  
**Status:** Paths separated, validation passed ✅
