# Cluster State

**Last Updated**: 2026-02-28  
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
| pvc-media-nfs | 1Ti | nfs-unraid (RWX) | sonarr, radarr (read-only Unraid media) |
| pvc-transcode-nfs | 200Gi | nfs-unraid (RWX) | transcode cache |

---

## Infrastructure Components

| Component | Namespace | Type | Details |
|-----------|-----------|------|---------|
| Longhorn | longhorn-system | HelmRelease | v1.8.x, 2-node HA, systemManagedComponentsNodeSelector=storage nodes |
| MetalLB | metallb-system | DaemonSet | BGP speaker, 1 node |
| Traefik | kube-system | Deployment | Reverse proxy, ingress |
| Descheduler | kube-system | CronJob | Every 5 min, RemovePodsViolatingNodeAffinity (enables failback to w1) |
| Volume-Fencing | kube-system | CronJob | Every 2 min, prevents split-brain on storage node recovery |

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

---

## Pending (Not Yet Deployed)

- Phase 6: Quality profiles via Profilarr/TRaSH Guides sync
- Phase 7: Plex + ClusterPlex (Plex on StatefulSet, Intel GPU plugin for w3, workers)
- Phase 8: Pulsarr (Plex watchlist → Sonarr/Radarr auto-request)
