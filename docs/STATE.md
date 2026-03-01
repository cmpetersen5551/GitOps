# Cluster State

**Last Updated**: 2026-03-01  
**Branch**: main  
**Status**: ✅ Operational

---

## Nodes

| Node | Role | IP | OS | Kernel | Labels |
|------|------|----|----|--------|--------|
| k3s-cp1 | control-plane | 192.168.1.11 | Debian 13 | 6.12.57 | — |
| k3s-w1 | storage/primary | 192.168.1.12 | Debian 13 | 6.12.57 | storage=enabled, create-default-disk=true, primary=true, workload-priority=primary |
| k3s-w2 | storage/backup | 192.168.1.22 | Debian 13 | 6.12.63 | storage=enabled, create-default-disk=true, primary=false, workload-priority=backup |
| k3s-w3 | edge/GPU | 192.168.1.13 | Proxmox VE | 6.8.12 | gpu=true |

**Taints**: k3s-w1 and k3s-w2 both have `node.longhorn.io/storage=enabled:NoSchedule`

---

## Running Pods (media namespace)

| Pod | Node | Image | PVC |
|-----|------|-------|-----|
| sonarr-0 | k3s-w1 | linuxserver/sonarr:4.0.16 | config-sonarr-0 (5Gi RWO) |
| radarr-0 | k3s-w1 | linuxserver/radarr:latest | config-radarr-0 (5Gi RWO) |
| prowlarr-0 | k3s-w1 | — | config-prowlarr-0 (2Gi RWO) |
| profilarr-0 | k3s-w1 | — | config-profilarr-0 (2Gi RWO) |
| decypharr-streaming-0 | k3s-w1 | cy01/blackhole:beta | config-decypharr-streaming-0 (1Gi RWO) |
| decypharr-download-0 | k3s-w1 | cy01/blackhole:latest | config-decypharr-download-0 (1Gi RWO) |
| plex-0 | k3s-w3 | lscr.io/linuxserver/plex:latest | pvc-nfs-plex-config, pvc-nfs-streaming-media, pvc-nfs-dfs, pvc-media-nfs |
| plex-config-holder | k3s-w1 | busybox:latest | pvc-plex-config (CSI, keeps share-manager alive) |
| plex-nfs-server | k3s-w1 | erichough/nfs-server | — (re-exports /mnt/dfs FUSE for w3) |
| pulsarr-0 | k3s-w1 | lakker/pulsarr:latest | data-pulsarr-0 (1Gi RWO) |

---

## PVC Inventory

| PVC | Capacity | Class | Used By |
|-----|----------|-------|---------|
| config-sonarr-0 | 5Gi | longhorn-simple (RWO) | sonarr |
| config-radarr-0 | 5Gi | longhorn-simple (RWO) | radarr |
| config-prowlarr-0 | 2Gi | longhorn-simple (RWO) | prowlarr |
| config-profilarr-0 | 2Gi | longhorn-simple (RWO) | profilarr |
| config-decypharr-streaming-0 | 1Gi | longhorn-simple (RWO) | decypharr-streaming |
| config-decypharr-download-0 | 1Gi | longhorn-simple (RWO) | decypharr-download |
| pvc-streaming-media | 10Gi | longhorn-rwx (RWX) | sonarr, radarr, decypharr-streaming (symlink library) |
| pvc-media-nfs | 1Ti | nfs-unraid (RWX) | sonarr, radarr, plex-0 (read-only Unraid media) |
| pvc-plex-config | 10Gi | longhorn-rwx (RWX) | plex-config-holder (CSI mount; keeps Longhorn share-manager alive) |
| pvc-nfs-plex-config | 10Gi | static NFS | plex-0 (/config via share-manager NFSv4) |
| pvc-nfs-streaming-media | — | static NFS | plex-0 (/mnt/streaming-media via share-manager NFSv4) |
| pvc-nfs-dfs | — | static NFS | plex-0 (/mnt/dfs via NFS server pod) |
| data-pulsarr-0 | 1Gi | longhorn-simple (RWO) | pulsarr (SQLite DB + config) |

---

## Infrastructure Components

| Component | Namespace | Type | Details |
|-----------|-----------|------|---------|
| Longhorn | longhorn-system | HelmRelease | v1.8.x, 2-node HA, systemManagedComponentsNodeSelector=storage nodes |
| MetalLB | metallb-system | DaemonSet | BGP speaker, 1 node |
| Traefik | kube-system | Deployment | Reverse proxy, ingress |
| Descheduler | kube-system | CronJob | Every 5 min, RemovePodsViolatingNodeAffinity (enables failback to w1) |
| Volume-Fencing | kube-system | CronJob | Every 2 min, prevents split-brain on storage node recovery |
| Longhorn Backup | longhorn-system | RecurringJob | `backup-all-volumes`: backs all 9 cluster volumes (config + data PVCs), nightly 3 AM UTC → `nfs://192.168.1.29:/mnt/cache/longhorn_backup`, 7-day retention |

---

## Ingress Routes

| URL | App | Port |
|-----|-----|------|
| http://sonarr.homelab | sonarr | 8989 |
| http://radarr.homelab | radarr | 7878 |
| http://prowlarr.homelab | prowlarr | — |
| http://profilarr.homelab | profilarr | — |
| http://decypharr-streaming.homelab | decypharr-streaming | 8282 |
| http://decypharr-download.homelab | decypharr-download | 8282 |
| http://plex.homelab | plex | 32400 |
| http://longhorn.homelab | longhorn-ui | — |
| http://pulsarr.homelab | pulsarr | 3003 |

---

## Pending (Not Yet Deployed)

- Nothing currently pending
