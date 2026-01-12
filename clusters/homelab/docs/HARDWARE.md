# Hardware & Topology

This document provides detailed hardware inventory and HA patterns.

- **Type:** k3s (lightweight Kubernetes)
- **Hypervisors:** Proxmox (primary), Unraid (secondary)
- **Status:** 1 control-plane + 2 workers (HA planned with 3 control-planes)
- **Storage:** Local node storage + NFS from Unraid
- **HA Strategy:** VolSync replication for stateful apps

## Nodes

### Control Plane
- **k3s-cp1** (Proxmox VM)
  - Role: API server, scheduler, controller-manager
  - Storage: No `/data` mount
  - ⚠️ Single control-plane (HA improvement planned)

### Workers
- **k3s-w1** (Proxmox LXC)
  - Labels: `role=primary`, GPU node
  - GPU: Yes (primary workload target)
  - Storage: `/data/media` (NFS bind-mount), `/data/pods` (local)
  - VolSync: Primary replication node

- **k3s-w2** (Unraid Docker container)
  - Labels: `role=backup`
  - GPU: Yes (failover target)
  - Storage: `/data/media` (direct NFS mount), `/data/pods` (local)
  - VolSync: Backup replication node

## Storage Topology

### Media Storage (`/data/media`)
**Purpose:** Shared read-only media library

**Path:**
```
Unraid NFS export (/mnt/user/media)
  ↓ (network)
Proxmox host
  ↓ (bind mount)
k3s-w1 LXC (/data/media)

Unraid NFS export (/mnt/user/media)
  ↓ (network)
k3s-w2 Docker (/data/media)
```

**Used by:** All media apps (Sonarr, Radarr, Plex, etc.) — read-only access

### Pod Storage (`/data/pods`)
**Purpose:** Application persistent data with high availability

**Characteristics:**
- Local to each node (not NFS)
- Synchronized between nodes via VolSync + Syncthing
- Holds application configs, databases, temporary files
- Enables failover without manual intervention

**Path on k3s-w1:** `/data/pods/<app-name>/`
**Path on k3s-w2:** `/data/pods/<app-name>/` (replicated)

## Stateful Application Storage Pattern

**For each HA-enabled app (e.g., Sonarr, Radarr, etc.):**

**PVs:**
- **Primary PV:** `pv-<app>-primary` → `/data/pods/<app>` on k3s-w1
- **Backup PV:** `pv-<app>-backup` → `/data/pods/<app>` on k3s-w2
- Examples: `pv-sonarr-primary`, `pv-radarr-primary`, etc.

**VolSync Replication:**
- Keeps `/data/pods/<app>` synchronized between nodes
- Enables failover automation if primary node becomes unavailable

**Failover Logic:**
1. App normally runs on k3s-w1 (primary) against primary PV
2. VolSync continuously replicates state to k3s-w2
3. On node failure, monitoring detects issue and triggers failover
4. Deployment switches to backup PV on k3s-w2
5. On recovery, can failback to k3s-w1

**Why Static PVs with nodeAffinity?**
- Each node gets its own dedicated storage path
- Prevents dual-mount conflicts
- Enables reliable failover with minimal data loss
- Works with any stateful application following this pattern

**Current Implementation:**
- Sonarr is configured with this pattern (see `infrastructure/storage/` and `apps/media/sonarr/`)
- This pattern can be extended for other stateful apps (Radarr, Plex, databases, etc.)

## Node Affinity & Labels

Node labels control workload placement:

```bash
# View labels
kubectl get nodes --show-labels

# Applied labels
k3s-w1: role=primary,node.kubernetes.io/instance-type=lxc
k3s-w2: role=backup,node.kubernetes.io/instance-type=docker
```

**Usage in manifests:**
```yaml
nodeAffinity:
  required:
    nodeSelectorTerms:
      - matchExpressions:
          - key: role
            operator: In
            values:
              - primary    # Matches k3s-w1
```

## Cluster Topology (ASCII)

```
┌─ Unraid (NFS Server) ──────────────────────────┐
│  /mnt/user/media (media library)               │
│  Syncthing daemon (external, optional)         │
└────────┬───────────────────────────────────┬───┘
         │ (NFS mount)                       │ (Docker)
    ┌────▼──────────────┐              ┌────▼──────────────┐
    │   Proxmox Host    │              │  Unraid Docker    │
    │ /mnt/media        │              │  Container        │
    ├───────────────────┤              │                   │
    │ k3s-w1 (LXC)      │              │ k3s-w2            │
    │ /data/media       │──────────────│ /data/media       │
    │ /data/pods/sonarr │              │ /data/pods/sonarr │
    │ role=primary      │              │ role=backup       │
    │ GPU enabled       │              │ GPU enabled       │
    └─────────┬─────────┘              └─────────┬─────────┘
              │                                  │
              │ (VolSync Replication)           │
              └──────────────┬───────────────────┘
                             │
                   VolSync Syncthing Pods
                   (managed by Flux)
```

## Network & Connectivity

- **Intra-cluster:** Direct via Kubernetes CNI
- **External ingress:** Traefik (k3s built-in reverse proxy)
- **Media access:** NFS on same local network
- **Failover communication:** Direct pod-to-pod via Syncthing

## Resource Constraints

**k3s-w1 (Proxmox LXC):**
- CPU: 4 cores
- Memory: 8 GB
- Storage: `/data/pods` = 100GB (local)

**k3s-w2 (Unraid Docker):**
- CPU: 4 cores
- Memory: 8 GB  
- Storage: `/data/pods` = 100GB (local)

## Future Considerations

- **HA Control Plane:** Add 2 more control-plane nodes
- **Load Balancing:** Implement metallb for multiple ingress IPs
- **Monitoring:** Add Prometheus/Grafana stack
- **Backup:** Velero or similar for cluster backup
- **Storage:** Consider persistent storage provisioner for dynamic PVs

## Important Notes

- `/data/pods` replication is managed by VolSync (Flux-controlled)
- Sonarr failover is automated via monitoring pod in `operations/volsync-failover/`
- Static PVs are intentional for failover support (see [ARCHITECTURE.md](ARCHITECTURE.md#storage-architecture))
- All infrastructure managed by Flux GitOps (see [ARCHITECTURE.md](ARCHITECTURE.md))
- No sensitive data (IPs, credentials) stored in documentation
