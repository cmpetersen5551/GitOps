# Copilot Instructions for GitOps Cluster

## Cluster Overview

**Type**: k3s homelab with Proxmox/Unraid backend  
**Nodes**: 4 — cp1 (control plane), w1/w2 (storage), w3 (edge/GPU)  
**GitOps**: Flux v2 — manifests in `clusters/homelab/`  
**Repository**: cmpetersen5551/GitOps, branch: **main**  
**Status**: ✅ Operational — Longhorn 2-node HA, full media stack deployed

---

## Non-Negotiable Rules

1. **Always use Flux** — never `kubectl apply` directly for Flux-managed resources.
   - Make changes in git, commit, push → Flux reconciles automatically
   - Force immediate sync: `flux reconcile kustomization apps --with-source`
   - Direct `kubectl apply` will be overwritten on next Flux reconcile

2. **Never put credentials, usernames, IPs, or node access info in this repo** — those are stored in personal AI memory only.

---

## HA Architecture (Active-Passive with Automatic Failback)

**Goal**: w1 is always the primary workload node. w2 is the standby. When w1 fails, pods move to w2 automatically. When w1 recovers, pods return automatically.

### Node Roles
- **k3s-w1**: Primary — `node.longhorn.io/primary=true`, `workload-priority=primary`
- **k3s-w2**: Backup — `node.longhorn.io/primary=false`, `workload-priority=backup`
- **k3s-w3**: Edge/GPU only — `gpu=true`, NOT a storage node
- **k3s-cp1**: Control plane only — no workloads, no storage

### Failover (w1 → w2, ~60s)
Longhorn `nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod` force-deletes stuck pods when w1 is unreachable → Kubernetes reschedules to w2 → Longhorn reattaches volume.

### Failback (w2 → w1, ~5min)
Descheduler CronJob runs every 5 minutes with `RemovePodsViolatingNodeAffinity`. When w1 recovers, it evicts pods from w2 → Kubernetes reschedules to preferred w1.

### Fencing CronJob
Runs every 2 minutes. Prevents split-brain if a storage node recovers unexpectedly while volumes are still attached elsewhere. Keep this running always.

### Required Pod Pattern (all stateful media pods must follow this)
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

### Node Infrastructure (Manual Outside GitOps)
Labels/taints are applied manually; documented in `docs/LONGHORN_NODE_SETUP.md`. Never put SSH credentials or usernames in this repo.

---

## Storage Architecture

### Longhorn 2-Node HA (primary — configs and stateful workloads)
- StorageClass `longhorn-simple` (RWO): app configs
- StorageClass `longhorn-rwx` (RWX): shared volumes (e.g., streaming-media symlink library)
- 2 replicas per volume — one on w1, one on w2
- **Critical Longhorn settings** (non-negotiable):
  - `replicaSoftAntiAffinity: false` — must be false for 2-node (default true breaks it)
  - `systemManagedComponentsNodeSelector: "node.longhorn.io/storage:enabled"` — prevents share-manager landing on cp1
  - `taintToleration: "node.longhorn.io/storage=enabled:NoSchedule"`

### NFS on Unraid (secondary — bulk media, acceptable SPOF)
- `pvc-media-nfs` (1Ti RWX) — read-only Unraid media library
- `pvc-transcode-nfs` (200Gi RWX) — transcode cache

---

## DFS Architecture (RealDebrid → Pod Access)

**Current approach (working, 2026-02-28)**: Direct FUSE mount propagation

1. `decypharr-streaming` pod mounts host's `/mnt` via `hostPath: /mnt, Bidirectional`
2. decypharr process creates FUSE filesystem at `/mnt/dfs` inside container
3. `Bidirectional` propagation pushes that mount back to host's `/mnt/dfs`
4. `sonarr`/`radarr` bind host's `/mnt/dfs` via `hostPath: /mnt/dfs, HostToContainer`

**No SMB/Samba/dfs-mounter DaemonSet** — that entire stack was tried and replaced. Do not re-add it.

---

## Applications (media namespace)

| App | Status | Node | Image | Purpose |
|-----|--------|------|-------|---------|
| sonarr-0 | ✅ Running | w1 | linuxserver/sonarr:4.0.16 | TV automation |
| radarr-0 | ✅ Running | w1 | linuxserver/radarr:latest | Movie automation |
| prowlarr-0 | ✅ Running | w1 | — | Indexer management |
| profilarr-0 | ✅ Running | w1 | — | Quality profile sync |
| decypharr-streaming-0 | ✅ Running | w1 | cy01/blackhole:beta | RealDebrid DFS |
| decypharr-download-0 | ✅ Running | w1 | cy01/blackhole:latest | Usenet/Torrent |

**Pending**: Plex + ClusterPlex (Phase 7), Pulsarr (Phase 8)

---

## File Structure

```
clusters/homelab/
├── apps/media/          # Media applications
│   ├── sonarr/
│   ├── radarr/
│   ├── prowlarr/
│   ├── profilarr/
│   ├── decypharr-streaming/
│   └── decypharr-download/
├── infrastructure/
│   ├── longhorn/        # HelmRelease + StorageClasses
│   ├── metallb/         # BGP load balancer
│   ├── traefik/         # Reverse proxy
│   ├── descheduler/     # Failback automation
│   └── fencing/         # Split-brain protection
└── flux-system/         # Auto-generated, don't touch

docs/
├── STATE.md             # Current cluster state snapshot
├── DECISIONS.md         # What was chosen + rejected + why
├── GOTCHAS.md           # Indexed symptom→fix pairs
├── LONGHORN_HA_MIGRATION.md      # Longhorn setup deep-dive
├── LONGHORN_NODE_SETUP.md        # Node labels/taints runbook
├── LONGHORN_SYSTEM_COMPONENTS_SCHEDULING.md  # RWX share-manager fix
└── NFS_STORAGE.md       # Unraid NFS configuration
```

---

## Essential Commands

```bash
# Cluster health
kubectl get nodes -L node.longhorn.io/storage,node.longhorn.io/primary
kubectl get pods -n media -o wide
flux get all

# Force Flux sync
flux reconcile kustomization apps --with-source

# Storage
kubectl get pvc -n media
kubectl get volumes.longhorn.io -n longhorn-system

# Debugging
kubectl logs -n media sonarr-0
kubectl describe pod sonarr-0 -n media
kubectl logs -n longhorn-system -l app=longhorn-manager --tail=100 | grep -i error
```

---

## Adding New Workloads

1. Use `longhorn-simple` StorageClass for app config PVCs
2. Add the required HA pod affinity pattern (see above)
3. Reference `clusters/homelab/apps/media/sonarr/` as the canonical template
4. Commit to git → let Flux deploy; never `kubectl apply`

---

## Key Don't-Repeats

- ❌ SeaweedFS — cannot do 2-node HA (needs 3+ nodes). Tried, abandoned.
- ❌ SMB/Samba/dfs-mounter for FUSE sharing — tried, replaced by direct FUSE propagation
- ❌ `noreparse` CIFS mount option — requires kernel 6.15+; nodes are on 6.12/6.8
- ❌ `replicaSoftAntiAffinity: true` — breaks 2-node Longhorn
- ❌ `preferredDuringScheduling` only (without `required`) — pods drift to cp1
- ❌ `enableServiceLinks: true` on Decypharr pods — injects bad `DECYPHARR_PORT` env var
- ❌ Health probes on Decypharr — all endpoints return 401 until auth setup via UI

---

**Last Updated**: 2026-02-28
