# ClusterPlex HA Implementation Plan

**Version:** 1.0  
**Date:** January 23, 2026  
**Branch:** v2 (branched from seaweedfs)  
**Status:** Planning Phase  

---

## Executive Summary

This plan outlines the implementation of a High Availability Kubernetes cluster with distributed GPU transcoding using ClusterPlex and SeaweedFS distributed storage. The architecture provides true HA for critical workloads while accepting single points of failure for media storage.

**Key Goals:**
- ✅ True HA for control plane (3 masters across 3 physical locations)
- ✅ Distributed storage with SeaweedFS (3x replication, survives any single host failure)
- ✅ GPU transcoding on both Proxmox and Unraid hosts (ClusterPlex)
- ✅ Media storage via Unraid NFS (SPOF acceptable)
- ✅ GitOps management via Flux for all K8s resources
- ✅ Phased rollout with GPU nodes as priority

---

## Architecture Overview

### Physical Infrastructure (3 Locations)

```
┌─────────────────────────────────────────────────────────────┐
│ PROXMOX HOST (Primary Compute)                               │
│ IP: 192.168.1.19                                             │
│                                                              │
│  K8s Nodes:                                                  │
│  ├─ k3s-cp1 (VM) - Control Plane #1                         │
│  │   └─ IP: 192.168.1.11                                    │
│  │   └─ SeaweedFS: Master, Volume (100GB), Filer           │
│  │                                                           │
│  ├─ k3s-w1 (VM) - Primary Worker                            │
│  │   └─ IP: 192.168.1.12                                    │
│  │   └─ SeaweedFS: Volume (150GB), Filer                   │
│  │   └─ Primary workload target                             │
│  │                                                           │
│  └─ k3s-w3 (LXC) - GPU Worker                               │
│      └─ IP: 192.168.1.13                                    │
│      └─ Privileged LXC with /dev/dri passthrough            │
│      └─ SeaweedFS: Volume (100GB)                           │
│      └─ ClusterPlex Worker Pod (GPU transcoding)            │
│      └─ Taint: gpu=true:NoSchedule                          │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ UNRAID HOST (Storage + Backup Compute)                      │
│ IP: 192.168.1.29                                             │
│                                                              │
│  K8s Nodes:                                                  │
│  ├─ k3s-cp2 (VM) - Control Plane #2                         │
│  │   └─ IP: 192.168.1.21                                    │
│  │   └─ SeaweedFS: Master, Volume (50GB), Filer            │
│  │                                                           │
│  └─ k3s-w2 (VM) - Failover Worker                           │
│      └─ IP: 192.168.1.22                                    │
│      └─ SeaweedFS: Volume (100GB), Filer                   │
│      └─ Failover target for workloads                       │
│                                                              │
│  Docker (NOT in K8s):                                        │
│  └─ clusterplex-worker-unraid                               │
│      └─ Direct GPU access (/dev/dri)                        │
│      └─ NFS mount to SeaweedFS Filer                        │
│      └─ Manual deployment via docker-compose                │
│                                                              │
│  NFS Server:                                                 │
│  ├─ /mnt/user/media (media library, read-only)              │
│  └─ /mnt/user/transcode (ephemeral, read-write)             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ RASPBERRY PI (Quorum/Tiebreaker)                            │
│ IP: 192.168.1.30                                             │
│                                                              │
│  K8s Nodes:                                                  │
│  └─ k3s-cp3 (Bare Metal) - Control Plane #3                 │
│      └─ IP: 192.168.1.30                                    │
│      └─ SeaweedFS: Master, Volume (10GB minimal)            │
│      └─ Taint: node-role.kubernetes.io/master:NoSchedule    │
│      └─ No workloads (infrastructure only)                  │
└─────────────────────────────────────────────────────────────┘
```

### High Availability Characteristics

**Control Plane (3-node etcd cluster):**
- Any 1 host down: ✅ 2/3 quorum maintained, cluster operational
- Any 2 hosts down: ❌ No quorum, read-only mode

**SeaweedFS Storage (3x replication):**
- Data replicated across 3 different physical locations
- Any 1 host down: ✅ Data accessible from 2 other replicas
- Any 2 hosts down: ⚠️ Degraded, data may be partially available

**GPU Transcoding (2 workers):**
- Normal: Both Proxmox (w3) and Unraid (Docker) workers active
- Proxmox down: Unraid worker handles all transcoding
- Unraid down: Proxmox worker handles all transcoding

---

## Node Specifications

### k3s-cp1 (Proxmox VM) - Control Plane
- **Type:** KVM Virtual Machine
- **CPU:** 2 cores
- **RAM:** 4GB
- **Storage:** 40GB (OS) + 100GB (SeaweedFS volume)
- **Network:** Bridge to Proxmox host network
- **OS:** Ubuntu 22.04 LTS
- **Role:** Control plane + SeaweedFS master/volume/filer
- **IP:** 192.168.1.11 (static)

### k3s-w1 (Proxmox VM) - Primary Worker
- **Type:** KVM Virtual Machine
- **CPU:** 4 cores
- **RAM:** 8GB
- **Storage:** 40GB (OS) + 150GB (SeaweedFS volume)
- **Network:** Bridge to Proxmox host network
- **OS:** Ubuntu 22.04 LTS
- **Role:** Primary worker + SeaweedFS volume/filer
- **IP:** 192.168.1.12 (static)
- **Workloads:** Plex PMS, Sonarr, ClusterPlex Orchestrator

### k3s-w3 (Proxmox LXC) - GPU Worker
- **Type:** Privileged LXC Container
- **CPU:** 4 cores
- **RAM:** 8GB
- **Storage:** 40GB (rootfs) + 100GB (SeaweedFS volume)
- **Network:** Bridge to Proxmox host network
- **OS:** Ubuntu 22.04 LTS
- **Role:** GPU worker + SeaweedFS volume
- **IP:** 192.168.1.13 (static)
- **GPU:** /dev/dri passthrough from Proxmox host
- **Taint:** gpu=true:NoSchedule
- **Workloads:** ClusterPlex Worker Pod only

**LXC-Specific Config:**
```
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
```

### k3s-cp2 (Unraid VM) - Control Plane
- **Type:** KVM Virtual Machine
- **CPU:** 2 cores
- **RAM:** 4GB
- **Storage:** 40GB (OS) + 50GB (SeaweedFS volume)
- **Network:** Bridge to Unraid network
- **OS:** Ubuntu 22.04 LTS
- **Role:** Control plane + SeaweedFS master/volume/filer
- **IP:** 192.168.1.21 (static)

### k3s-w2 (Unraid VM) - Failover Worker
- **Type:** KVM Virtual Machine
- **CPU:** 4 cores
- **RAM:** 8GB
- **Storage:** 40GB (OS) + 100GB (SeaweedFS volume)
- **Network:** Bridge to Unraid network
- **OS:** Ubuntu 22.04 LTS
- **Role:** Failover worker + SeaweedFS volume/filer
- **IP:** 192.168.1.22 (static)
- **Workloads:** Failover target (normally idle)

### k3s-cp3 (Raspberry Pi) - Quorum/Tiebreaker
- **Type:** Raspberry Pi 4/5 (4GB+ RAM recommended)
- **CPU:** ARM (native)
- **RAM:** 4GB minimum
- **Storage:** 64GB USB SSD (recommended) or SD card
- **Network:** Gigabit ethernet (required)
- **OS:** Ubuntu 22.04 LTS (64-bit ARM)
- **Role:** Control plane + SeaweedFS master/volume (minimal)
- **IP:** 192.168.1.30 (static)
- **Taint:** node-role.kubernetes.io/master:NoSchedule
- **Note:** No workloads scheduled here

**Pi Requirements:**
- Minimum: Pi 4 (4GB), USB 3.0 SSD strongly recommended
- Optimal: Pi 5 (8GB), NVMe SSD via PCIe adapter

---

## Network Configuration

### IP Address Assignments (Static DHCP Reservations)

| Node | IP | Hostname | Physical Location |
|------|-----|----------|-------------------|
| k3s-cp1 | 192.168.1.11 | k3s-cp1 | Proxmox |
| k3s-w1 | 192.168.1.12 | k3s-w1 | Proxmox |
| k3s-w3 | 192.168.1.13 | k3s-w3 | Proxmox LXC |
| k3s-cp2 | 192.168.1.21 | k3s-cp2 | Unraid VM |
| k3s-w2 | 192.168.1.22 | k3s-w2 | Unraid VM |
| k3s-cp3 | 192.168.1.30 | k3s-cp3 | Raspberry Pi |

**Physical Hosts:**
- Proxmox: 192.168.1.19
- Unraid: 192.168.1.29

### Control Plane VIP (kube-vip)

**Virtual IP for kube-apiserver:** 192.168.1.100

All nodes join cluster using: `https://192.168.1.100:6443`

**kube-vip configuration:**
- Leader election among cp1, cp2, cp3
- ARP-based IP failover
- Automatically fails over if any control plane node dies

### DNS Resolution

**For Kubernetes Pods:**
- CoreDNS handles in-cluster DNS (*.svc.cluster.local)

**For External Access (Docker Workers, Proxmox/Unraid hosts):**
- **MetalLB** provides LoadBalancer IPs for services
- **BGP Integration** with Ubiquiti Dream Machine (UDM)
- ClusterPlex Orchestrator exposed via LoadBalancer service
- Docker workers connect to LoadBalancer IP directly

**MetalLB Configuration:**
- Address pool: 192.168.1.150-192.168.1.200 (or as configured)
- BGP peering with UDM (already configured)
- **Action Required:** Update UDM BGP config for new node IPs (cp2, cp3, w2, w3)

**CoreDNS Configuration:**
- In-cluster DNS for *.svc.cluster.local
- No additional configuration needed for external workers

---

## Storage Architecture

### Layer 1: Unraid NFS (Media - SPOF Acceptable)

**Purpose:** Media library and ephemeral transcode files  
**Source:** Unraid NFS server  
**Acceptable SPOF:** Yes (media-dependent workloads offline if Unraid down)

**NFS Exports:**
```bash
# /etc/exports on Unraid
/mnt/user/media         *(ro,sync,no_subtree_check,no_root_squash)
/mnt/user/transcode     *(rw,sync,no_subtree_check,no_root_squash)
```

**Consumed by:**
- Plex PMS pods (via PV/PVC)
- Sonarr, Radarr pods (via PV/PVC)
- ClusterPlex workers (Proxmox LXC pod, Unraid Docker container)

**Mount on hosts** (for Docker workers):
```bash
# Proxmox host
mkdir -p /mnt/unraid/{media,transcode}
mount -t nfs 192.168.1.29:/mnt/user/media /mnt/unraid/media
mount -t nfs 192.168.1.29:/mnt/user/transcode /mnt/unraid/transcode

# Unraid host (local bind mount)
# Already available at /mnt/user/media and /mnt/user/transcode
```

### Layer 2: SeaweedFS (Distributed - True HA)

**Purpose:** HA storage for critical workloads (ChannelsDVR, future services)  
**Source:** SeaweedFS distributed across all K8s nodes  
**Replication:** 3x (data stored on 3 different physical locations)  
**Total Capacity:** ~500GB usable (after 3x replication)

**Storage Allocation:**

| Node | Volume Size | Physical Location | Purpose |
|------|-------------|-------------------|---------|
| cp1 | 100GB | Proxmox | Master + Volume + Filer |
| w1 | 150GB | Proxmox | Volume + Filer (primary) |
| w3 | 100GB | Proxmox LXC | Volume |
| cp2 | 50GB | Unraid | Master + Volume + Filer |
| w2 | 100GB | Unraid | Volume + Filer |
| cp3 | 10GB | Pi | Master + Volume (minimal) |

**Total Raw:** 510GB → **Usable:** ~170GB (with 3x replication)

**SeaweedFS Configuration:**
```yaml
replication: "032"  # 0 same-rack, 3 different-hosts, 2 different-racks
# Ensures replicas spread across physical locations

# INTERIM NOTE (Phase 2 - Current Status):
# Currently using replication "002" (3 copies in same rack) as an interim solution
# while awaiting full topology setup. This provides 3x data redundancy across 3 nodes
# (cp1, w1, w2) but all in same "logical rack" until Phase 6 when we:
#  - Add cp2 (Unraid) and cp3 (Raspberry Pi)  
#  - Configure proper rack topology with volume server -rack flags
#  - Migrate to replication "032" for true geographic redundancy
# Current topology: cp1,w1 on Proxmox | w2 on Unraid (all seen as single rack by SeaweedFS)
```

**Storage Classes:**
- `seaweedfs-ha` (RWO): For app configs, databases
- `seaweedfs-ha-rwx` (RWX): For shared data (via SeaweedFS Filer NFS)

**Consumed by:**
- ChannelsDVR recordings/config
- Future HA services
- Any workload requiring distributed storage

**Access Methods:**
- K8s pods: SeaweedFS CSI driver (volume mounts)
- Docker workers: NFS mount from SeaweedFS Filer

---

## Application Architecture

### ClusterPlex Components

**1. Plex Media Server (K8s Pod)**
- Deployment in `media` namespace
- Image: `ghcr.io/linuxserver/plex:latest`
- Docker Mod: `ghcr.io/pabloromeo/clusterplex_dockermod:latest`
- Node affinity: `role=primary` (prefers w1)
- Storage:
  - Config: SeaweedFS PVC (RWO)
  - Media: Unraid NFS PV (RO)
  - Transcode: Unraid NFS PV (RW)
- No GPU in pod (transcoding delegated to workers)

**2. ClusterPlex Orchestrator (K8s Pod)**
- Deployment in `media` namespace
- Image: `ghcr.io/pabloromeo/clusterplex_orchestrator:latest`
- Service: LoadBalancer or NodePort (3500)
- Node affinity: `role=primary` (prefers w1)
- Manages all transcode workers (K8s pods + Docker containers)

**3. ClusterPlex Worker - K8s (Proxmox w3 LXC)**
- Deployment in `media` namespace
- Image: `ghcr.io/linuxserver/plex:latest`
- Docker Mod: `ghcr.io/pabloromeo/clusterplex_worker_dockermod:latest`
- Node selector: `gpu=true` (only runs on w3)
- Tolerations: `gpu=true:NoSchedule`
- Resources: `intel.com/gpu: 1` (via Intel GPU Device Plugin)
- Storage:
  - Media: Unraid NFS PV (RO)
  - Transcode: Unraid NFS PV (RW)
  - Codecs: EmptyDir or local PV

**4. ClusterPlex Worker - Docker (Unraid Host)**
- Docker container on Unraid host (NOT in K8s)
- Managed: Manual deployment via docker-compose
- GPU: Direct /dev/dri access
- Storage:
  - Media: /mnt/user/media (local Unraid)
  - Transcode: /mnt/user/transcode (local Unraid)
  - Codecs: /mnt/user/appdata/clusterplex-worker/codecs
- Connects to Orchestrator via NodePort or LoadBalancer

### Sonarr (Test Workload for HA Validation)

- Deployment in `media` namespace
- Image: `ghcr.io/linuxserver/sonarr:latest`
- Node affinity: `role=primary` (prefers w1, fails to w2)
- Storage:
  - Config: SeaweedFS PVC (RWO, 5GB)
  - Media: Unraid NFS PV (RW)
- Purpose: Validate HA failover, test storage, prove architecture

---

## Implementation Phases

### Phase 0: Prerequisites (Pre-Implementation)
- [ ] Set up static DHCP reservations for all node IPs
- [ ] Prepare Raspberry Pi (Ubuntu 22.04 ARM, SSH access)
- [ ] Create v2 branch from seaweedfs branch
- [ ] Set up static DHCP reservations for w1, w2 node IPs
- [ ] Verify current cluster state (cp1 on seaweedfs/v2 branch)
- [ ] Ensure GitHub PAT for Flux is still valid
- [ ] Verify MetalLB + CoreDNS configuration

### Phase 1: Worker Node Infrastructure (w1 and w2 VMs)
**Goal:** Establish primary worker (w1) and failover worker (w2)

**Nodes:** w1 (new/verify on Proxmox), w2 (new on Unraid)

**Steps:**
1. Verify/create k3s-w1 VM on Proxmox
   - 4 cores, 8GB RAM, 40GB OS + 150GB data
   - Join to existing cluster (cp1 as control plane)
   - Label: `kubectl label nodes k3s-w1 role=primary`
2. Create k3s-w2 VM on Unraid
   - 4 cores, 8GB RAM, 40GB OS + 100GB data
   - Join to existing cluster (cp1 as control plane)
   - Label: `kubectl label nodes k3s-w2 role=backup`
3. Verify both workers Ready and can schedule pods

**Validation:**
- w1 and w2 show Ready in `kubectl get nodes`
- Labels applied correctly (role=primary/backup)
- Test pod can schedule on both nodes

**Deliverables:**
- w1/w2 VM creation notes (if new)
- Node labels documentation

### Phase 2: SeaweedFS Distributed Storage (Basic 2-Node)
**Goal:** Deploy SeaweedFS with basic HA across cp1, w1, w2

**Nodes:** cp1 (existing), w1, w2

**Steps:**
1. Deploy SeaweedFS Operator (HelmRelease via Flux)
2. Create Seaweed CRD with volume allocations:
   - cp1: 100GB (master + volume + filer)
   - w1: 150GB (volume + filer)
   - w2: 100GB (volume + filer)
3. Configure 3x replication across 3 nodes
4. Deploy SeaweedFS CSI Driver (DaemonSet on w1, w2)
5. Create StorageClasses: seaweedfs-ha (RWO), seaweedfs-ha-rwx (RWX)
6. Test PVC creation and mounting

**Validation:**
- SeaweedFS master/volume/filer pods Running on cp1, w1, w2
- CSI driver registered on w1, w2
- Test PVC binds successfully
- Test pod can write/read from PVC
- Data replicated across all 3 nodes
- Survive single node stop (stop w1, verify data accessible)

**Deliverables:**
- SeaweedFS manifests (operator, CRD, CSI driver)
- StorageClass definitions
- Storage validation tests

### Phase 3: Unraid NFS Integration
**Goal:** Set up Unraid NFS for media library

**Steps:**
1. Configure NFS exports on Unraid:
   - /mnt/user/media (read-only)
   - /mnt/user/transcode (read-write)
2. Create NFS PV/PVC for media (RO)
3. Create NFS PV/PVC for transcode (RW)
4. Test pod can access media NFS PVC

**Validation:**
- NFS exports accessible from all nodes
- Media PVC binds successfully
- Test pod can read media files

**Deliverables:**
- Unraid NFS export configuration
- NFS PV/PVC manifests

### Phase 4: Sonarr Deployment
**Goal:** Deploy Sonarr as test workload with HA storage

**Steps:**
1. Create `media` namespace
2. Deploy Sonarr to w1 (primary)
   - Config: SeaweedFS PVC (RWO, 5GB)
   - Media: Unraid NFS PVC (RW)
   - Node affinity: `role=primary` (prefers w1)
3. Configure Sonarr via UI, add test series
4. Verify data persisted in SeaweedFS

**Validation:**
- Sonarr pod Running on w1
- Config stored in SeaweedFS PVC
- Media accessible via Unraid NFS
- Sonarr functional (can browse media)

**Deliverables:**
- Sonarr deployment manifest
- Sonarr service/ingress (via Traefik)

### Phase 5: HA Validation (Failover/Failback Testing)
**Goal:** Validate automatic failover and failback

**Tests:**

**Test 1: w1 Node Failure (Planned)**
1. Drain w1: `kubectl drain k3s-w1 --ignore-daemonsets`
2. Verify Sonarr reschedules to w2
3. Access Sonarr UI, verify config intact
4. Check SeaweedFS still accessible (cp1, w2)
5. Uncordon w1: `kubectl uncordon k3s-w1`
6. Delete Sonarr pod to force reschedule back to w1
7. Verify Sonarr returns to w1 with config intact

**Test 2: SeaweedFS Node Failure**
1. Stop SeaweedFS volume pod on w1
2. Verify data still accessible from cp1, w2 replicas
3. Restart volume pod on w1
4. Verify replication resumes

**Test 3: Unraid NFS Failure Simulation**
1. Unmount NFS on w1 temporarily
2. Verify Sonarr shows media as unavailable (expected)
3. Remount NFS
4. Verify Sonarr can access media again

**Validation Criteria:**
- ✅ Sonarr survives w1 failure (moves to w2)
- ✅ Sonarr config persisted (SeaweedFS)
- ✅ Sonarr returns to w1 after recovery
- ✅ No data loss throughout failover/failback
- ✅ SeaweedFS survives single node failure

**Deliverables:**
- HA validation runbook
- Failover test procedure
- Test results documentation

### Phase 6: Control Plane HA (Add cp2 and cp3)
**Goal:** Expand to 3-node control plane for true HA

**Nodes:** cp2 (new on Unraid), cp3 (new on Pi)

**Steps:**
1. Deploy kube-vip on cp1 (establish VIP 192.168.1.100)
2. Create k3s-cp2 VM on Unraid
   - 2 cores, 4GB RAM, 40GB OS + 50GB data
   - Join as control plane node (using VIP)
3. Prepare Raspberry Pi (Ubuntu 22.04 ARM)
4. Create k3s-cp3 on Pi
   - Join as control plane node (using VIP)
   - Taint: `node-role.kubernetes.io/master:NoSchedule`
5. Verify 3-node etcd quorum
6. Update SeaweedFS to include cp2, cp3 volumes

**Validation:**
- 3 control planes show Ready
- etcd has 3 members
- API accessible via VIP
- SeaweedFS masters on cp1, cp2, cp3

**Deliverables:**
- kube-vip manifest
- cp2/cp3 join documentation
- Updated SeaweedFS configuration
- Control plane validation checklist

**UDM BGP Update:**
- Add routes for cp2 (192.168.1.21), cp3 (192.168.1.30)
- Verify BGP peering with new nodes

### Phase 7: GPU Worker Nodes (w3 LXC + Unraid Docker)
**Goal:** Add GPU-enabled transcode workers

**Nodes:** w3 (new Proxmox LXC), clusterplex-worker-unraid (Docker)

**Steps:**
1. Create k3s-w3 privileged LXC on Proxmox
   - 4 cores, 8GB RAM, 40GB rootfs + 100GB data
   - GPU passthrough: /dev/dri
   - Join to cluster (using VIP)
   - Label: `gpu=true role=gpu-worker`
   - Taint: `gpu=true:NoSchedule`
2. Deploy Intel GPU Device Plugin (DaemonSet on w3)
3. Verify GPU available: `kubectl describe node k3s-w3`
4. Update SeaweedFS to include w3 volume
5. Prepare clusterplex-worker-unraid (Docker on Unraid host)
   - Create docker-compose.yml in external/ directory
   - Mount Unraid NFS for media/transcode

**Validation:**
- w3 shows Ready with gpu=true label
- Intel GPU plugin reports available GPU
- Test pod can request `intel.com/gpu: 1`
- SeaweedFS includes w3 volume

**Deliverables:**
- LXC creation guide (config snippet)
- Intel GPU Device Plugin manifest
- GPU validation test pod
- clusterplex-worker-unraid docker-compose.yml
- Unraid Docker template XML

**UDM BGP Update:**
- Add route for w3 (192.168.1.13)

### Phase 8: ClusterPlex Deployment
**Goal:** Deploy Plex + ClusterPlex with GPU transcoding

**Components:** Orchestrator, PMS, Workers (K8s pod + Docker)

**Steps:**
1. Deploy ClusterPlex Orchestrator
   - Service: LoadBalancer (MetalLB assigns IP)
   - Note LoadBalancer IP for workers
2. Deploy Plex PMS with ClusterPlex dockermod
   - Config: SeaweedFS PVC (RWO)
   - Media: Unraid NFS PVC (RO)
   - Transcode: Unraid NFS PVC (RW)
   - Node affinity: `role=primary` (w1)
3. Deploy ClusterPlex Worker pod on w3
   - Node selector: `gpu=true`
   - Resources: `intel.com/gpu: 1`
   - Media: Unraid NFS PVC (RO)
   - Transcode: Unraid NFS PVC (RW)
4. Start clusterplex-worker-unraid Docker container
   - ORCHESTRATOR_URL: http://<loadbalancer-ip>:3500
   - GPU: /dev/dri
   - Media: /mnt/user/media (local)
   - Transcode: /mnt/user/transcode (local)
5. Verify both workers register with Orchestrator
6. Test transcode: Start playback, verify GPU usage

**Validation:**
- Orchestrator pod Running, LoadBalancer IP assigned
- PMS pod Running, WebUI accessible
- Worker pod on w3 Running with GPU
- Docker worker on Unraid running
- Both workers registered in Orchestrator logs
- Transcode jobs distributed across workers
- GPU usage visible during transcoding

**Deliverables:**
- ClusterPlex Orchestrator manifest
- Plex PMS manifest
- ClusterPlex Worker K8s manifest
- LoadBalancer service definitions
- Worker verification tests
- ClusterPlex architecture diagram

### Phase 9: Flux GitOps Integration
**Goal:** Ensure all K8s resources managed by Flux on v2 branch

**Steps:**
1. Commit all manifests to v2 branch
2. Update Flux Kustomization to point to v2 branch
3. Verify Flux reconciles all resources
4. Test GitOps workflow: Update manifest, push, verify auto-deploy
5. Document external resources (Docker workers, NFS mounts) in external/ directory

**Validation:**
- All K8s resources show in Flux status
- Git push triggers reconciliation
- No manual kubectl apply needed
- External resources documented

**Deliverables:**
- Updated kustomization.yaml files
- Flux source configuration for v2 branch
- external/ directory structure with Docker configs

## Post-Implementation

### Monitoring & Alerting (Future Work)
- Prometheus for metrics collection
- Grafana dashboards for SeaweedFS, ClusterPlex
- Alertmanager for failure notifications
- Uptime monitoring for control plane

### Additional Applications (Future Work)
- ChannelsDVR (live TV, HA storage)
- Radarr, Prowlarr (media management)
- Jellyfin (alternative media server)
- Home Assistant (home automation)
- Frigate (NVR with GPU detection)

### Backup Strategy (Future Work)
- Velero for K8s resource backup
- SeaweedFS snapshot/replication to external storage
- Sonarr/Plex config backups
- Disaster recovery runbook

---

## Failure Scenarios & Recovery

### Scenario 1: Proxmox Host Failure
**Impact:**
- cp1, w1, w3 offline
- etcd: 1/3 nodes down, quorum maintained (cp2, cp3)
- SeaweedFS: 3/6 volumes down, data still accessible
- GPU transcoding: Only Unraid worker available

**Recovery:**
- Automatic: Workloads reschedule to w2 (Unraid)
- Manual: None required, wait for Proxmox host recovery

**Validation:**
- Plex PMS moves to w2
- Sonarr moves to w2
- Orchestrator moves to w2
- Only Unraid GPU worker active
- SeaweedFS data accessible from cp2, w2, cp3

### Scenario 2: Unraid Host Failure
**Impact:**
- cp2, w2 offline
- Unraid NFS offline (media inaccessible)
- etcd: 1/3 nodes down, quorum maintained (cp1, cp3)
- SeaweedFS: 2/6 volumes down, data still accessible
- GPU transcoding: Only Proxmox worker available

**Recovery:**
- Automatic: Workloads stay on w1 (Proxmox)
- Degraded: Media-dependent apps offline (Plex, Sonarr)
- Functional: HA apps (ChannelsDVR future) continue

**Validation:**
- Plex PMS stays on w1 (no media access)
- Sonarr stays on w1 (no media access)
- Only Proxmox GPU worker active
- SeaweedFS data accessible from cp1, w1, w3, cp3

### Scenario 3: Raspberry Pi Failure
**Impact:**
- cp3 offline
- etcd: 1/3 nodes down, quorum maintained (cp1, cp2)
- SeaweedFS: 1/6 volumes down (minimal), data accessible

**Recovery:**
- Automatic: None needed
- Impact: Minimal, only quorum witness lost

**Validation:**
- All workloads continue normally
- No pod rescheduling needed
- GPU transcoding unaffected

---

## Rollback Plan

If critical issues arise during implementation, rollback to current state:

### Rollback Procedure
1. Preserve current k3s-w2 (Docker) if it exists
2. Phase-by-phase rollback:
   - Phase 8: Delete Sonarr deployment
   - Phase 7: Stop ClusterPlex workers
   - Phase 6: Delete Orchestrator and PMS
   - Phase 5: Remove NFS PVCs
   - Phase 4: Delete SeaweedFS (data loss acceptable at this stage)
   - Phase 3: Drain and delete w2 (if new)
   - Phase 2: Drain and delete w3
   - Phase 1: Remove cp2, cp3 from cluster
3. Return to single-node cp1 or current working state

### Rollback Criteria
- Unable to achieve quorum in any phase
- SeaweedFS data corruption or loss
- ClusterPlex workers fail to connect
- Critical bug blocking progress

---

## Success Criteria

### Phase Completion
- All phases completed without rollback
- All nodes show Ready in `kubectl get nodes`
- All core pods Running in respective namespaces
- Flux reconciling successfully

### Functional Validation
- Sonarr running with HA storage (SeaweedFS)
- Sonarr can access media via Unraid NFS
- Plex PMS running, media library accessible
- ClusterPlex workers transcoding with GPU
- Transcode load distributed across both workers

### HA Validation
- Simulate w1 failure: Sonarr migrates to w2, data intact
- Simulate Proxmox failure: Workloads move to Unraid
- Simulate Unraid failure: HA workloads continue on Proxmox
- Simulate Pi failure: No impact to operations

### Performance Validation
- GPU transcoding functional on both workers
- Transcode jobs complete successfully
- Media playback smooth (no stuttering)
- Storage I/O acceptable (no bottlenecks)

---

## Documentation Deliverables

This plan will generate the following documentation:

1. **Architecture diagrams** (ASCII + optional Mermaid)
2. **Node setup guides** (VM/LXC creation, k3s installation notes)
3. **Kubernetes manifests** (all YAMLs for Flux GitOps)
4. **External component configs** (docker-compose, Unraid templates)
5. **Validation checklists** (per-phase testing procedures)
6. **Troubleshooting guide** (common issues and solutions)
7. **Runbooks** (failover procedures, maintenance tasks)

---

## Agent Implementation Notes

This plan is designed for agent-driven implementation:

- **Phased approach:** Each phase is independent, can be executed sequentially
- **Validation steps:** Clear success criteria for each phase
- **Rollback plan:** Defined procedure if issues arise
- **Deliverables:** Concrete artifacts to create (manifests, configs, docs)
- **Dependencies:** Explicit (e.g., Phase 4 requires Phase 3 completion)

**Recommended Agent Workflow:**
1. Read this plan thoroughly
2. Execute phases in order (0 → 9)
3. Validate each phase before proceeding
4. Generate deliverables as you go
5. Commit manifests to Git after each phase
6. Document any deviations or issues encountered

---

## Appendix

### Glossary
- **CP:** Control Plane node (k3s server with --server flag)
- **CSI:** Container Storage Interface (Kubernetes storage plugin)
- **LXC:** Linux Container (Proxmox lightweight VM)
- **PV/PVC:** PersistentVolume / PersistentVolumeClaim
- **RWO:** ReadWriteOnce (single pod mount)
- **RWX:** ReadWriteMany (multiple pod mount)
- **VIP:** Virtual IP (kube-vip floating IP for API server)

### Useful Commands
```bash
# Check cluster status
kubectl get nodes -o wide
kubectl get pods -A

# Check etcd cluster
kubectl -n kube-system exec -it etcd-k3s-cp1 -- etcdctl member list

# Check SeaweedFS status
kubectl -n seaweedfs-system get pods
kubectl -n seaweedfs-system logs -l app=seaweedfs-master

# Test GPU on w3
kubectl run gpu-test --rm -it --restart=Never \
  --image=ubuntu --overrides='{"spec":{"nodeSelector":{"gpu":"true"},"tolerations":[{"key":"gpu","value":"true","effect":"NoSchedule"}],"containers":[{"name":"gpu-test","image":"ubuntu","command":["ls","-la","/dev/dri"],"resources":{"limits":{"intel.com/gpu":"1"}}}]}}'

# Check ClusterPlex workers
kubectl -n media logs -l app=clusterplex-worker
docker logs clusterplex-worker-unraid
```

### Reference Links
- **SeaweedFS:** https://github.com/seaweedfs/seaweedfs
- **ClusterPlex:** https://github.com/pabloromeo/clusterplex
- **kube-vip:** https://kube-vip.io/
- **Intel GPU Plugin:** https://github.com/intel/intel-device-plugins-for-kubernetes

---

**End of Implementation Plan**
