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

## Running Pods (live namespace)

| Pod | Node | Image | PVC |
|-----|------|-------|-----|
| channels-dvr-0 | k3s-w1 | fancybits/channels-dvr:latest | config-channels-dvr-0 (5Gi RWO), pvc-media-nfs (NFS recordings) |
| dispatcharr-0 | k3s-w1 | ghcr.io/dispatcharr/dispatcharr:v0.20.1 | config-dispatcharr-0 (2Gi RWO) |
| eplustv-0 | k3s-w1 | tonywagner/eplustv:v4.15.0 | config-eplustv-0 (1Gi RWO) |
| pluto-for-channels | k3s-w1 | jonmaddox/pluto-for-channels:2.0.2 | — (stateless) |
| teamarr-0 | k3s-w1 | ghcr.io/pharaoh-labs/teamarr:v2.2.2 | config-teamarr-0 (2Gi RWO) |

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
| config-channels-dvr-0 | 5Gi | longhorn-simple (RWO) | channels-dvr (config + recordings DB) |
| config-dispatcharr-0 | 2Gi | longhorn-simple (RWO) | dispatcharr |
| config-eplustv-0 | 1Gi | longhorn-simple (RWO) | eplustv |
| config-teamarr-0 | 2Gi | longhorn-simple (RWO) | teamarr |
| pvc-media-nfs (live) | 1Ti | nfs-unraid (RWX) | channels-dvr (Unraid media — recordings) |

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
| **Renovate** | **—** | **Mend-hosted** | **Detects Helm + container updates, posts PRs for review. Dashboard: Issue #11. Config: renovate.json** |
| **VictoriaLogs** | **victoria-logs** | **HelmRelease** | **`victoria-logs-single` chart; Vector DaemonSet collects all cluster logs; 10Gi PVC on longhorn-simple; retention 4d; pod on k3s-w1** |

---

## NFS Configuration (Unraid)

**Server**: 192.168.1.29  
**Exports** (add to Unraid `/etc/exports` or via GUI):
```
/mnt/user/media       *(rw,sync,no_subtree_check,no_root_squash)
/mnt/user/transcode   *(rw,sync,no_subtree_check,no_root_squash)
```

**PVs in cluster**:
- `pv-nfs-media` → claimed by `pvc-media-nfs` (media namespace) → sonarr, radarr, plex
- `pv-nfs-media-live` → claimed by `pvc-media-nfs` (live namespace) → channels-dvr recordings

**Note**: Each namespace that needs Unraid NFS access requires its own PV (with `claimRef` locking it to the namespace) and its own PVC. PVCs cannot cross namespaces.

**Mount examples** (Proxmox / other hosts):
```bash
mkdir -p /mnt/unraid/media /mnt/unraid/transcode
mount -t nfs 192.168.1.29:/mnt/user/media /mnt/unraid/media
mount -t nfs 192.168.1.29:/mnt/user/transcode /mnt/unraid/transcode
```

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
| http://pulsarr.homelab | pulsarr | 3003 || http://logs.homelab | victoria-logs (VMUI + API) | 9428 |
| http://channels.homelab | channels-dvr | 8089 |
| http://dispatcharr.homelab | dispatcharr | 9191 |
| http://eplustv.homelab | eplustv | 8080 |
| http://pluto.homelab | pluto-for-channels | 8080 |
| http://teamarr.homelab | teamarr | 9195 |

---

## Tooling

| Script | Purpose | Usage |
|--------|---------|-------|
| `docs/vlogs-troubleshoot.sh` | Query Victoria Logs from macOS | `./docs/vlogs-troubleshoot.sh help` |

**vlogs-troubleshoot.sh quick reference**:
```bash
chmod +x docs/vlogs-troubleshoot.sh
./docs/vlogs-troubleshoot.sh fields          # Discover indexed field names (run first)
./docs/vlogs-troubleshoot.sh streams         # List active log streams with hit counts
./docs/vlogs-troubleshoot.sh errors 2h       # Find errors last 2 hours
./docs/vlogs-troubleshoot.sh top 1h 10       # Top 10 noisiest streams
./docs/vlogs-troubleshoot.sh tail '*'        # Live log stream
./docs/vlogs-troubleshoot.sh query '_time:15m i(error) | sort by (_time)'
```
Default URL: `http://logs.homelab` (auto-falls back to `kubectl port-forward -n victoria-logs svc/victoria-logs 9428:9428` if unreachable).
---

## Pending (Not Yet Deployed)

- Nothing currently pending

---

## Recently Completed (2026-03-01)

- Phase 1.1: Longhorn recurring backups — `backup-all-volumes` RecurringJob
- Phase 1.2: Renovate — automated Helm + container update PRs
- Phase 2.1: VictoriaLogs — centralized logging, Vector DaemonSet, `http://logs.homelab`
- Live TV namespace (`live`) — channels-dvr, dispatcharr, eplustv, pluto-for-channels, teamarr. All images pinned to stable versions; all manifests externally verified (ports, health probes, env vars, volume mounts). NFS access added for channels-dvr recordings via `pv-nfs-media-live` + `pvc-media-nfs` in `live` namespace.
- NFS PV pattern hardened — both `pv-nfs-media` and `pv-nfs-media-live` now use `claimRef` to prevent accidental binding to the wrong namespace PVC.
