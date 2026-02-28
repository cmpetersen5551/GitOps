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

## Traefik / Ingress

**Service port convention**: All app Services expose port `80` externally, map to app's native port via targetPort.  
Reason: Traefik routes to port 80 by default; inconsistent port numbers cause 404s.

**Annotation that does NOT work**: `traefik.ingress.kubernetes.io/router.entrypoints: web,websecure`  
Correct values are `http` and `https` matching Traefik's internal entrypoint names.
