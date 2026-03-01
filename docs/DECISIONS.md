# Architecture Decisions

Permanent record of what we chose, what we rejected, and why.
Format: decision taken, rejected alternatives with one-line reason, date.

---

## Storage Backend

**Chosen**: Longhorn 2-node HA (w1, w2)  
**Rejected**:
- SeaweedFS — requires minimum 3 nodes/racks for true HA; cannot work on 2 nodes. Do not revisit.
- Ceph — too heavy for homelab
- NFS-only — SPOF, acceptable only for Unraid media library (read-only bulk data)

**Key config (non-negotiable for 2-node)**:
```yaml
replicaSoftAntiAffinity: false   # Must be false; true prevents replica scheduling on 2 nodes
defaultReplicaCount: 2
systemManagedComponentsNodeSelector: "node.longhorn.io/storage:enabled"  # Prevents share-manager landing on cp1
taintToleration: "node.longhorn.io/storage=enabled:NoSchedule"
```

---

## HA Strategy

**Chosen**: Active-Passive with automatic failback  
- w1 = primary (labeled `node.longhorn.io/primary=true`, `workload-priority=primary`)
- w2 = backup (labeled `node.longhorn.io/primary=false`, `workload-priority=backup`)

**Failover flow** (w1 dies → w2):
1. w1 goes down → Longhorn force-deletes stuck pod (nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod)
2. Pod reschedules to w2 → Longhorn reattaches volume → ~60s total downtime

**Failback flow** (w1 recovers → back to w1):
1. w1 comes back → Longhorn rebuilds replica on w1
2. Descheduler CronJob (every 5 min) detects pods violating `preferredDuringScheduling` affinity
3. Descheduler evicts pods from w2 → Kubernetes reschedules to preferred w1
4. ~5 min total failback time

**Fencing CronJob** (every 2 min): Safety layer preventing split-brain if a storage node recovers unexpectedly while volumes are still attached elsewhere.

**Pod affinity pattern** (all stateful media pods):
```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node.longhorn.io/storage
              operator: In
              values: [enabled]
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: node.longhorn.io/primary
              operator: In
              values: ["true"]
tolerations:
  - key: node.longhorn.io/storage
    operator: Equal
    value: enabled
    effect: NoSchedule
  - key: node.kubernetes.io/unreachable
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30
```

---

## DFS Sharing (RealDebrid FUSE mount to consumer pods)

**Chosen**: Direct FUSE mount propagation via hostPath Bidirectional (2026-02-28)

**How it works**:
- decypharr-streaming mounts host's `/mnt` via `hostPath: /mnt, Bidirectional`
- decypharr process creates FUSE mount at `/mnt/dfs` inside container
- `Bidirectional` propagates that FUSE mount back to host at `/mnt/dfs`
- sonarr/radarr bind host's `/mnt/dfs` via `hostPath: /mnt/dfs, HostToContainer`
- No separate sharing layer required

**Rejected** (in order tried):
- rclone serve nfs sidecar — mount propagation blocked by k3s `rprivate` root filesystem; stale mounts; complex
- SFTP via rclone — added too much complexity; latency
- SMB/CIFS via Samba sidecar + dfs-mounter DaemonSet — fully implemented then replaced; eliminated because:
  - Samba 4.x `st_nlink=0` bug required LD_PRELOAD shim (FUSE returns nlink=0 for all inodes)
  - Required kernel dfs-mounter DaemonSet on all nodes (extra infra)
  - Direct FUSE propagation is simpler and has no Samba layer
- CSI drivers — over-engineered for a single-tenant homelab use case
- emptyDir medium:Memory for FUSE propagation — works but loses data on pod restart

**SMB/Samba was removed in commit e828583 (2026-02-28). Do not re-add it.**

---

## GitOps Boundaries

**In Git (Flux managed)**:
- All application manifests (StatefulSets, Services, Ingresses, PVCs)
- Longhorn HelmRelease + StorageClasses
- Infrastructure components (MetalLB, Traefik, descheduler, fencing)

**Outside Git (manual runbook below)**:
- Node labels and taints (infrastructure layer; rarely changes)
- Host-level packages (nfs-common, open-iscsi)

### Node Setup Runbook

Run once when adding/rebuilding a storage node (w1 or w2):

```bash
# 1. Host-level packages (required for RWX volumes — CSI uses host mount.nfs binary)
apt-get update && apt-get install -y nfs-common open-iscsi

# 2. Node labels
kubectl label node k3s-w1 node.longhorn.io/storage=enabled
kubectl label node k3s-w1 node.longhorn.io/create-default-disk=true   # triggers disk creation at /var/lib/longhorn
kubectl label node k3s-w1 node.longhorn.io/primary=true               # w2: set to false
kubectl label node k3s-w1 workload-priority=primary                   # w2: set to backup

# 3. Node taints
kubectl taint node k3s-w1 node.longhorn.io/storage=enabled:NoSchedule --overwrite

# Repeat for k3s-w2 (swap primary→false, workload-priority→backup)

# 4. Verify
kubectl get nodes k3s-w1 k3s-w2 --show-labels | grep longhorn
kubectl get nodes.longhorn.io -n longhorn-system
```

**Two different labels — different purposes**:
- `node.longhorn.io/storage=enabled` — controls where Longhorn manager/system pods schedule
- `node.longhorn.io/create-default-disk=true` — triggers disk creation (requires `createDefaultDiskLabeledNodes: true` in HelmRelease)

**Never in Git**:
- SSH credentials, API keys, passwords
- Usernames for node access

---

## Decypharr Architecture

**Chosen**: Two separate StatefulSets (streaming + download)  
- `decypharr-streaming`: RealDebrid/Alldebrid provider → DFS FUSE → propagated to consumers
- `decypharr-download`: Usenet/Torrent provider → Unraid NFS read-only

**Rejected**: Single monolithic Decypharr pod — splitting allows independent scaling and failure isolation

**Image**: `cy01/blackhole:beta` (streaming), `cy01/blackhole:latest` (download)  
Official image. `ghcr.io/cowboy/decypharr` and `sirrobot01/decypharr` are wrong/private.

**Health probes**: Removed from all Decypharr pods — all endpoints return 401 until auth setup via UI.

**enableServiceLinks: false** required on decypharr pods — k3s injects `DECYPHARR_PORT=tcp://IP:PORT` env var which the blackhole image misparses.

---

## Pulsarr (Plex Watchlist Automation)

**Chosen**: Single StatefulSet, SQLite, longhorn-simple RWO PVC, cluster-internal service URLs (2026-03-01)

**Architecture**:
- StatefulSet on w1/w2 (HA affinity, same pattern as sonarr/radarr)
- `data-pulsarr-0` PVC (1Gi, longhorn-simple RWO) — stores SQLite DB with Plex tokens, API keys, routing rules
- Service exposes port 80 → targetPort 3003 (app's native port)
- **Key config**: `port=80` (external/webhook port via Service), `listenPort=3003` (internal bind), `baseUrl=http://pulsarr.media.svc.cluster.local` (no port suffix)
- Sonarr/Radarr URLs in pulsarr UI: use port 80 service (`http://sonarr.media.svc.cluster.local`, `http://radarr.media.svc.cluster.local`)
- Webhook callback is cluster-internal → survives pod failover (ClusterIP stable)

**Rejected**:
- `port=3003` as external port — Kubernetes Service only exposes 80; Sonarr/Radarr webhook callbacks time out on 3003
- `baseUrl` with `:3003` suffix — same problem; webhook URLs must match what the Service exposes
- Health probes — all endpoints return 401 until Plex auth is set up via UI; omit probes entirely

---

## Traefik / Ingress

**Service port convention**: All app Services expose port `80` externally, map to app's native port via targetPort.  
Reason: Traefik routes to port 80 by default; inconsistent port numbers cause 404s.

**Annotation that does NOT work**: `traefik.ingress.kubernetes.io/router.entrypoints: web,websecure`  
Correct values are `http` and `https` matching Traefik's internal entrypoint names.

---

## Plex Media Server (Single-Pod GPU Acceleration)

**Chosen**: Standard linuxserver/plex on w3 GPU node with Longhorn RWX config (2026-02-28)

**Architecture**:
- **Plex Pod**: StatefulSet on w3 (GPU node affinity required), 1 replica
  - Image: `lscr.io/linuxserver/plex:latest` — standard, actively maintained
  - Mounts:
    - `/config` — Longhorn RWX PVC → wrapped via static NFS PV (share-manager export) for GPU node access
    - `/mnt/media` — Unraid NFS (permanent media library)
    - `/mnt/streaming-media` — Longhorn RWX → wrapped via static NFS PV (share-manager export)
    - `/mnt/dfs` — NFS server pod re-export of host `/mnt/dfs` FUSE
    - `/dev/dri` — hostPath to Intel QSV GPU device
  - **No transcode volume** — Plex writes transcode buffers to container overlay FS (ephemeral, correct pattern)
  - Hardware acceleration: Intel QSV via `/dev/dri`, configured in Preferences.xml post-deploy
  - Security context: `runAsUser: 0`, `supplementalGroups: [992]` for render group GPU access

- **Config Holder Deployment**: Dummy pod on w1/w2 (storage node affinity)
  - Maintains a CSI mount to `pvc-plex-config` (dynamic Longhorn RWX PVC)
  - Purpose: Keeps Longhorn share-manager alive; Plex on w3 accesses config via NFS, not CSI
  - Without holder: share-manager shuts down → NFS export unavailable → Plex pod loses `/config`

- **NFS Server Pod**: `erichough/nfs-server` Deployment on w1/w2 (storage affinity + prefer primary)
  - Mounts host's `/mnt/dfs` (FUSE) with `mountPropagation: HostToContainer`
  - Re-exports as read-only NFS to allow GPU nodes to access FUSE content
  - Service ClusterIP stable across pod restarts; HA failover handled by descheduler

**Rejected (ClusterPlex — removed 2026-02-28)**:
- ClusterPlex (orchestrator Deployment + stateless GPU worker StatefulSet) — GPU path was architecturally broken: PMS ran on w1/w2 and generated libx264 transcode arguments, defeating vaapi GPU offload on w3. Added unnecessary complexity: separate orchestrator, worker StatefulSet, per-worker codec PVCs, DOCKER_MOD layer. Normal Plex with direct DRI device access on w3 is simpler and actually works.

**Longhorn config backup**: Target `nfs://192.168.1.29:/mnt/cache/longhorn_backup` (Unraid NFS). RecurringJob `plex-config-daily-backup` runs nightly at 3 AM, retains 7 daily backups. Block-level incremental after first full backup. Restore via Longhorn UI: Volumes → Backups → Restore to new PVC.

**Why This Works for LXC w3**:
- w3 is Proxmox VE LXC, cannot use Longhorn iSCSI CSI driver (block device cgroups forbidden)
- Config PVC is Longhorn RWX (replicated on w1/w2) → share-manager exports over NFSv4
- Static NFS PV wraps the share-manager export → accessible from w3 without CSI
- Same pattern used for streaming-media and DFS access, proven reliable

**GPU Acceleration Details**:
- linuxserver/plex entrypoint automatically fixes `/dev/dri` permissions for the `abc` internal user (via Docker's `--device` flag)
- In Kubernetes with hostPath mount, explicit `supplementalGroups: [992]` is required (cluster-specific GID for render group)
- Verify GID before deploy: `stat /dev/dri/renderD128 | grep Gid` on w3 host

**Single-Pod HA Trade-off**:
- w3 pod failure → Plex unavailable until w3 recovers (minutes to hours)
- Config volume safe (Longhorn RWX on w1/w2) and backed up nightly to Unraid
- Acceptable for homelab; GPU transcoding only available when w3 is up anyway
- ClusterPlex complexity (orchestrator + stateless workers on w3) was unnecessary — standard Plex handles GPU fine

**Rejected Alternatives**:
- ClusterPlex (orchestrator + workers) — added complexity without GPU benefit (GPU device not shareable across pods)
- Plex on w1/w2 (storage nodes) — no GPU, software transcode only, same single-pod failure scenario
- Multiple GPU nodes with pod affinity spreading — works, but single node (w3) sufficient for homelab

**Configuration Notes**:
- NFS mount options (`soft`, `timeo=10`, `retrans=2`) prevent stale handle errors
- SQLite over NFS acceptable for single-writer homelab; Longhorn nightly backup (~7-day retention) is safety net
- Plex will auto-initialize `/config` on first boot, then sign in via UI to claim server and add libraries
