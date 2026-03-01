# Plan: Replace ClusterPlex with Normal Plex on w3

**Status**: ✅ COMPLETE  
**Created**: 2026-02-28  
**Completed**: 2026-02-28  
**Goal**: Remove ClusterPlex complexity. Run standard linuxserver/plex directly on w3 (GPU node). Store config on Longhorn RWX (accessible from w3 via Longhorn's internal NFSv4 share-manager). Nightly incremental backups to Unraid. Zero change to HA goals.

---

## Completion Summary

All phases executed successfully:
- ✅ **Phase 1**: Longhorn backup target configured (`nfs://192.168.1.29:/mnt/cache/longhorn_backup`)
- ✅ **Phase 2**: Plex config PVC created (Longhorn RWX 10Gi, bound to volume `pvc-64ffe0e2-1120-4278-93f0-0f353a1d890d`)
- ✅ **Phase 3**: Fresh Plex setup (no migration needed)
- ✅ **Phase 4**: All Plex manifests deployed (StatefulSet, ConfigMap, Services, Ingress, NFS server)
- ✅ **Phase 5**: Longhorn RecurringJob deployed (daily 3:00 AM backup, 7-day retention)
- ✅ **Phase 6**: Media kustomization updated, Plex running on w3, media libraries scanned

**Plex Status**:
- StatefulSet: 1/1 Ready
- Pod: Running on k3s-w3 (GPU node)
- Config: Mounted via NFS from Longhorn share-manager
- Scanning: In progress (media libraries detected and indexed)

**No cleanup needed**: ClusterPlex residue (PVCs, PVs, deployments) was already removed during deployment phases.

---

## Background & Why This Works

ClusterPlex was built to solve one problem: Plex config needs replicated block storage, but w3 is a Proxmox LXC and cannot use Longhorn's iSCSI CSI driver (block device cgroups are blocked in LXC). ClusterPlex worked around this by running PMS on w1/w2 (where Longhorn RWO works), with GPU workers stateless on w3.

The insight that unlocks this plan: **Longhorn RWX volumes are already NFS internally.** Longhorn creates a `share-manager` pod on w1/w2 that exports the volume over NFSv4. This is exactly how w3 currently accesses `pvc-streaming-media-w3` today — via static PVs pointing at the share-manager's ClusterIP. The same mechanism works for Plex config.

**Proven pattern already in use from clusterplex:**
```
Longhorn RWX PVC (on w1/w2)
  → share-manager pod (longhorn-system, on w1/w2)
    → NFSv4 export (ClusterIP service, stable)
      → static PV on w3 (nfsvers=4, points to share-manager ClusterIP)
        → static PVC (bound to static PV)
          → Plex pod on w3 mounts /config via NFS
```

SQLite-over-NFS risk: Acceptable for single-writer, single-pod homelab use. NFSv4 has proper mandatory locking semantics. Nightly backups provide a safety net against the rare corruption scenario. See docs/DECISIONS.md for full rationale.

---

## Architecture: What Changes

### Removed
| Component | Reason |
|---|---|
| ClusterPlex Orchestrator (Deployment + 2 Services + ConfigMap) | No longer needed |
| ClusterPlex Workers (StatefulSet + Service + ConfigMap + codec PVCs) | No longer needed |
| `clusterplex-transcode` PVC (Longhorn RWX 50Gi) | Not needed — Plex writes transcode to overlay fs inside the container |
| `pv-transcode-w3` / `pvc-transcode-w3` static PVs | Not needed |
| `pvc-transcode-nfs` / `pv-nfs-transcode` (Unraid NFS transcode) | Not needed — transcode is ephemeral, no volume required |
| `clusterplex-pms-config` PVC (Longhorn RWO 10Gi) | Replaced by new RWX config PVC |
| `configmap-pms-config` (ClusterPlex-specific env vars) | Replaced by simpler plex configmap |
| ClusterPlex DOCKER_MOD references | Removed |
| `pms-deployment.yaml` (PMS on w1/w2) | Replaced by `plex/statefulset.yaml` on w3 |

### Kept / Moved
| Component | New Home | Reason |
|---|---|---|
| NFS server pod + service | `plex/` | Still needed: re-exports host `/mnt/dfs` FUSE for GPU nodes |
| `pv-nfs-dfs` / `pvc-nfs-dfs` | `plex/` | Still needed: DFS access for Plex |
| `pvc-media-nfs` | `media/nfs/` | Shared Unraid media library (RWX) — uses infrastructure `pv-nfs-media`, accessible to any pod |
| `pv-nfs-streaming-media` / `pvc-nfs-streaming-media` | `plex/` | Streaming media (RWX via Longhorn share-manager) — generic for GPU failover |
| Ingress (plex.homelab → plex on port 32400) | `plex/` | Identical, just updated service name |

### New
| Component | Details |
|---|---|
| `pvc-plex-config` | Longhorn RWX, 10Gi (confirmed: existing Plex config is ~6GB) |
| `pv-nfs-plex-config` / `pvc-nfs-plex-config` | Static NFS PV wrapper for share-manager (Longhorn RWX config) — generic naming for GPU failover |
| `plex-config-holder.yaml` | Deployment on w1/w2 that holds a CSI mount to `pvc-plex-config` to keep the Longhorn share-manager alive when only w3 (NFS-mounting) consumes the volume |
| `plex/statefulset.yaml` | Normal plex on GPU node (gpu=true required affinity) — reschedules to any GPU-labeled node without code changes |
| `plex/configmap.yaml` | Simplified env (no ClusterPlex mods) |
| `infrastructure/longhorn/recurring-backup-plex.yaml` | Longhorn RecurringJob (nightly block backup) |
| `infrastructure/longhorn/ingress.yaml` | Expose Longhorn UI at longhorn.homelab |
| Longhorn backup target in HelmRelease | `nfs://192.168.1.29/longhorn_backup` |

---

## HA Analysis

| Scenario | Behavior |
|---|---|
| **w3 dies** | Plex pod down. Config volume on w1/w2 is unaffected (Longhorn RWX). When w3 recovers (~minutes to hours depending on cause), pod auto-reschedules, remounts config PVC, Plex back up. ~0 data loss. |
| **w1 dies** | Longhorn rebuilds config replica to w2. Share-manager migrates (brief NFS hiccup, ~30s). Plex on w3 experiences brief NFS retry, resumes. ~0 data loss. |
| **w2 dies** | Same as above, mirror image. |
| **Both w1+w2 die** | Share-manager unreachable → Plex cannot access /config → Plex down until a storage node recovers OR you restore from Longhorn backup. This is the scenario Longhorn backup protects against. |
| **w3 disk fails** | Plex pod crashes. No data is on w3's disk (/config is NFS from Longhorn). Pod restarts, remounts, up in ~60s. |
| **Config DB corruption** | Stop Plex, restore from latest Longhorn backup or Unraid CronJob backup. Max data loss = backup interval (nightly = 24h). Acceptable for homelab. |

**Note**: This is a slight HA downgrade from ClusterPlex in one scenario — ClusterPlex kept PMS running on w1 even when w3 died (software transcode fallback). Normal Plex on w3 means w3 failure = Plex outage until w3 recovers. However, since ClusterPlex's GPU path was already broken (PMS on w1 generates libx264 args, not vaapi), this was only providing CPU-transcode offloading, not GPU transcoding. The practical difference is minimal.

---

## GPU Node Failover Strategy (Generic Naming)

When you add a second GPU node (w4, w5, etc.), **zero new YAML files are needed.** This is because all storage references use generic names, not node-specific suffixes:

### How It Works

| File | Type | Why It's Generic |
|------|------|---|
| `pvc-nfs-plex-config` | Static NFS PVC | Bound to `pv-nfs-plex-config`, which points to Longhorn's share-manager ClusterIP (stable across any node) |
| `pvc-nfs-media` | Static NFS PVC | Bound to `pv-nfs-media`, which points to Unraid NFS (accessible from any node) |
| `pvc-nfs-streaming-media` | Static NFS PVC | Bound to `pv-nfs-streaming-media`, which points to Longhorn's share-manager (stable across any node) |
| `statefulset.yaml` | Pod affinity | Uses `gpu=true` nodeAffinity — reschedules to any GPU-labeled node without code edits |

**Future scenario: w4 joins with `gpu=true` label**
1. Label w4: `kubectl label nodes w4 gpu=true`
2. Update `plex-config-holder.yaml` to add w4 to its storage node affinity (or keep as-is if you want holder on w1 only)
3. Plex StatefulSet automatically reschedules to w4 on next pod restart — mount points stay the same, NFS targets don't change
4. Profit! Zero new PVC/PV manifests

### Why Not Just Use the Dynamic PVCs Directly?

(For the config + streaming volumes that are Longhorn RWX on w1/w2)

w3/w4 are **LXC on Proxmox VE** and cannot use Longhorn's iSCSI CSI driver (block device cgroups forbidden). The only way for w3/w4 to access Longhorn RWX volumes is through the share-manager's NFSv4 export, which requires static PVs.

Could you mount the dynamic RWX PVCs from w1/w2 storage nodes and re-export them via CIFS/NFS? Yes, but that's building a second orchestrator. The static NFS PV approach is simpler and proven to work.

### plex-config-holder Explained

The `plex-config-holder` Deployment runs a dummy pod on w1/w2 that holds a CSI mount to `pvc-plex-config` (the dynamic Longhorn RWX volume). Why? Because:

- Longhorn's share-manager pod only starts when **at least one CSI consumer** is mounted
- Plex on w3 uses a **static NFS PV**, not CSI (LXC limitation)
- Without holder, Longhorn sees "no CSI mounts" → shuts down share-manager → NFS goes down → Plex loses /config

The holder pod prevents this by maintaining a CSI presence. It's a 1-replica dummy Deployment with a PVC mount — runs on w1/w2 (storage node affinity), no container actually uses the mount, but Kubernetes keeps it bound.

If you want to reduce moving parts, you could alternatively:
- Run the Plex pod itself on w1/w2 (via CSI) — but then you lose hardware acceleration if w1/w2 don't have GPUs
- Use a StatefulSet on w1/w2 as the holder — but pod replica sync is not necessary (a Deployment is fine)

The current design (holder + w3 Plex) is the cleanest split of concerns.

---

### 0.1 Confirm Unraid backup share is NFS-exportable
The `longhorn_backup` share exists on Unraid with NFS enabled. Confirm it is accessible:
```bash
showmount -e 192.168.1.29 | grep longhorn_backup
```
Longhorn will organise its own internal folder structure inside this share — no subfolder needed.

### 0.2 Note on existing ClusterPlex config data
**Nothing needs to be migrated.** The current `clusterplex-pms-config` PVC holds a Plex install that was never fully set up in the cluster context (config was migrated from the standalone LXC Plex, not a clean setup). Start fresh — Plex will re-initialise its config directory on first boot, then you sign in and point at the existing media libraries. The standalone LXC Plex install remains untouched outside the cluster as a reference.

### 0.3 Verify w3 render group GID
```bash
ssh root@192.168.1.13 "stat /dev/dri/renderD128 | grep Gid"
```
This GID is needed in `supplementalGroups` in the Plex StatefulSet (currently `992` in clusterplex-worker). Verify it hasn't changed.

### 0.4 Verify NFS server pod is healthy
```bash
kubectl get pods -n media -l app.kubernetes.io/name=plex-nfs-server
kubectl exec -n media <nfs-server-pod> -- showmount -e localhost
```
The NFS server pod will be moved into the plex folder but the pod itself stays alive throughout migration.

---

## Phase 1: Configure Longhorn Backup Target

Do this first — it takes time for Longhorn to validate the target.

### 1.1 Update HelmRelease
In `clusters/homelab/infrastructure/longhorn/helmrelease.yaml`, change the backup settings:

```yaml
# Find this block and update:
backupTarget: "nfs://192.168.1.29/longhorn_backup"
backupTargetCredentialSecret: ""
```

### 1.2 Create Longhorn UI Ingress
Create `clusters/homelab/infrastructure/longhorn/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: longhorn-ui
  namespace: longhorn-system
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: http,https
spec:
  ingressClassName: traefik
  rules:
    - host: longhorn.homelab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: longhorn-frontend
                port:
                  number: 80
```

Add to `clusters/homelab/infrastructure/longhorn/kustomization.yaml` resources.

### 1.3 Commit and push, then verify backup target
```bash
git add clusters/homelab/infrastructure/longhorn/
git commit -m "feat(longhorn): configure NFS backup target + UI ingress"
git push
flux reconcile kustomization infrastructure --with-source
```

Then open http://longhorn.homelab → Settings → General → verify Backup Target shows green.

---

## Phase 2: Create New Plex Config PVC (RWX)

This creates the Longhorn RWX volume that will hold Plex's config directory.

### 2.1 Create `pvc-plex-config` in the new `plex/` directory

Create `clusters/homelab/apps/media/plex/pvc-plex-config.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-plex-config
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: longhorn-rwx
  resources:
    requests:
      storage: 10Gi  # ~6GB in use; Longhorn supports live expansion if needed
```

### 2.2 Apply only the PVC via Flux (plex kustomization not live yet)
Create a minimal kustomization temporarily, or use kubectl to apply just the PVC:

```bash
kubectl apply -f clusters/homelab/apps/media/plex/pvc-plex-config.yaml
```

Wait for the PVC to bind and the share-manager pod to start:

```bash
kubectl get pvc pvc-plex-config -n media -w
kubectl get pods -n longhorn-system | grep share-manager | tail -5
```

### 2.3 Find the share-manager ClusterIP and PVC path
```bash
# Get the PVC UUID
PVC_UID=$(kubectl get pvc pvc-plex-config -n media -o jsonpath='{.spec.volumeName}')
echo "PVC volume name: $PVC_UID"

# Find the share-manager service for this PVC
kubectl get svc -n longhorn-system | grep $PVC_UID
```

Output will look like:
```
longhorn-share-manager-pvc-XXXXXXXX   ClusterIP   10.43.X.X   <none>   2049/TCP   ...
```

Note down:
- **ClusterIP**: `10.43.X.X`
- **PVC path**: `/pvc-XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` (the volume name)

### 2.4 Create the static NFS PVs for GPU node access
Create `clusters/homelab/apps/media/plex/pv-nfs-plex-config.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-nfs-plex-config
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: media
    name: pvc-nfs-plex-config
  # Points to the Longhorn share-manager NFSv4 export for pvc-plex-config.
  # ClusterIP is stable until the Longhorn service is deleted.
  # If pvc-plex-config is ever deleted and recreated, update server and path below.
  mountOptions:
    - nfsvers=4
    - soft
    - timeo=10
    - retrans=2
    - noac
  nfs:
    server: 10.43.X.X          # ← Fill in from Phase 2.3
    path: /pvc-XXXXXXXX-...    # ← Fill in from Phase 2.3
```

Create `clusters/homelab/apps/media/plex/pvc-nfs-plex-config.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-nfs-plex-config
  namespace: media
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  volumeName: pv-nfs-plex-config
  resources:
    requests:
      storage: 10Gi
```

---

## Phase 3: Fresh Start — No Migration Needed

The existing `clusterplex-pms-config` PVC does not need to be migrated. Plex will initialise a clean config directory on first boot into `pvc-nfs-plex-config`. After Plex starts:
1. Sign in with your Plex account via the UI
2. Add media libraries pointing at `/mnt/media`, `/mnt/streaming-media`, `/mnt/dfs`
3. Let Plex scan — it rebuilds metadata automatically

The standalone Plex LXC outside the cluster remains untouched and can serve as reference for any settings you want to replicate (transcoder path, network settings, etc.).

### 3.1 Scale down and delete old ClusterPlex PMS now
```bash
# Stop it so there's no conflict on ports/ingress during cutover
kubectl scale statefulset clusterplex-pms -n media --replicas=0
```
The `clusterplex-pms-config` PVC will be deleted in Phase 6.5 cleanup.

---

## Phase 4: Create New Plex Manifests

Create `clusters/homelab/apps/media/plex/` directory with the following files. This replaces the entire `clusterplex/` directory.

### 4.1 ConfigMap (`configmap.yaml`)
Simplified — no ClusterPlex mods, no orchestrator URL:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: plex-config
  namespace: media
data:
  VERSION: docker
  TZ: America/Chicago
  PUID: "0"
  PGID: "0"
  ADVERTISE_IP: "https://plex.homelab:443,http://plex.homelab:80"
  PLEX_PREFERENCE_secureConnections: "0"
  # Hardware acceleration set directly in Preferences.xml on PVC (not via env vars —
  # linuxserver/plex image does not process PLEX_PREFERENCE_* for these settings).
  # After first deploy: kubectl exec -n media plex-0 -- bash -c '<prefs patch>'
```

### 4.2 StatefulSet (`statefulset.yaml`)
Runs on w3 (GPU), mounts all volumes via static NFS PVs:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: plex
  namespace: media
spec:
  serviceName: plex-headless
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: plex
  template:
    metadata:
      labels:
        app.kubernetes.io/name: plex
    spec:
      securityContext:
        fsGroup: 0
        runAsNonRoot: false
        runAsUser: 0
        supplementalGroups: [992]  # render group GID on w3 (PVE host) — verify in Phase 0.3
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: gpu
                    operator: In
                    values: ["true"]
      tolerations:
        - key: gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
        - key: node.kubernetes.io/unreachable
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 30
        - key: node.kubernetes.io/not-ready
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 30
      enableServiceLinks: false
      containers:
        - name: plex
          image: lscr.io/linuxserver/plex:latest
          imagePullPolicy: IfNotPresent
          ports:
            - name: pms
              containerPort: 32400
              protocol: TCP
          envFrom:
            - configMapRef:
                name: plex-config
          volumeMounts:
            - name: config
              mountPath: /config
            - name: media-nfs
              mountPath: /mnt/media
            - name: streaming-media
              mountPath: /mnt/streaming-media
            - name: dfs
              mountPath: /mnt/dfs
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: 4000m
              memory: 4Gi
          devices:
            - /dev/dri/renderD128   # Intel QSV GPU on w3
          startupProbe:
            httpGet:
              path: /identity
              scheme: HTTP
              port: 32400
            initialDelaySeconds: 0
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 60   # 10 min for linuxserver first-boot apt-get
          readinessProbe:
            httpGet:
              path: /identity
              scheme: HTTP
              port: 32400
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /identity
              scheme: HTTP
              port: 32400
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: pvc-nfs-plex-config    # Static NFS PV → Longhorn share-manager (NFSv4)
        - name: media-nfs
          persistentVolumeClaim:
            claimName: pvc-media-nfs      # Shared Unraid NFS (from media/nfs, uses infrastructure pv-nfs-media)
        - name: streaming-media
          persistentVolumeClaim:
            claimName: pvc-nfs-streaming-media  # Static NFS PV → Longhorn share-manager
            claimName: pvc-streaming-media-w3  # Static NFS PV → Longhorn share-manager
        - name: dfs
          persistentVolumeClaim:
            claimName: pvc-nfs-dfs          # Static NFS PV → NFS server pod (re-exports /mnt/dfs FUSE)
        # No transcode volume — Plex writes transcode buffers to container overlay fs
```

**Important**: The `devices` field above is a placeholder syntax. In Kubernetes, GPU/DRI device access is granted via `securityContext.supplementalGroups` (for render group) and by mounting the device path. The correct approach is:

```yaml
# In the container spec:
securityContext:
  privileged: false
# Mount the device as a hostPath volume in w3-specific pods:
volumes:
  - name: dri
    hostPath:
      path: /dev/dri
      type: Directory
# And in volumeMounts:
  - name: dri
    mountPath: /dev/dri
```

Remove the `devices:` field — use the hostPath volume pattern for `/dev/dri`.

### 4.3 Services (`service.yaml`, `service-headless.yaml`)

```yaml
# service.yaml
apiVersion: v1
kind: Service
metadata:
  name: plex
  namespace: media
spec:
  type: ClusterIP
  ports:
    - name: pms
      port: 32400
      targetPort: pms
      protocol: TCP
  selector:
    app.kubernetes.io/name: plex
---
# service-headless.yaml
apiVersion: v1
kind: Service
metadata:
  name: plex-headless
  namespace: media
spec:
  clusterIP: None
  ports:
    - name: pms
      port: 32400
  selector:
    app.kubernetes.io/name: plex
```

### 4.4 Ingress (`ingress.yaml`)
Same as before, just updated service name:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: plex
  namespace: media
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: http,https
spec:
  ingressClassName: traefik
  rules:
    - host: plex.homelab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: plex
                port:
                  number: 32400
```

### 4.5 Moved NFS-server files

Move from `clusterplex/` to `plex/`:
- `nfs-server-deployment.yaml` → update label `app.kubernetes.io/name: clusterplex-nfs-server` to `plex-nfs-server`, update pod label prefix
- `service-nfs-server.yaml` → rename to `service-plex-nfs-server.yaml`, update selector label to `app.kubernetes.io/name: plex-nfs-server`, service name becomes `plex-nfs-server`
- `pv-nfs-dfs.yaml`, update label to `app.kubernetes.io/part-of: plex`
- `pvc-nfs-dfs.yaml`, claimName `pvc-nfs-dfs` (matches updated PV)
- `pv-nfs-streaming-media.yaml` (renamed from `pv-streaming-media-w3.yaml` — now generic for any GPU node)
- `pvc-nfs-streaming-media.yaml` (renamed from `pvc-streaming-media-w3.yaml` — now generic for any GPU node)
- **Media**: Plex uses `pvc-media-nfs` from `media/nfs/` folder (infrastructure-managed `pv-nfs-media`)

**Important**: When you rename `service-nfs-server` to `service-plex-nfs-server`, the Service's ClusterIP will change. After the service is deployed, find its new ClusterIP and update `pv-nfs-dfs.yaml`'s NFS server field:
```bash
kubectl get svc -n media plex-nfs-server -o jsonpath='{.spec.clusterIP}'
```

### 4.6 Kustomization (`kustomization.yaml`)

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  # ConfigMap
  - configmap.yaml
  # Storage - config (Longhorn RWX via share-manager NFSv4, accessed by both storage nodes + GPU nodes)
  - pvc-plex-config.yaml
  - pv-nfs-plex-config.yaml
  - pvc-nfs-plex-config.yaml
  - plex-config-holder.yaml   # Keeps the Longhorn share-manager alive (CSI consumer on w1/w2)
  # Storage - media (uses shared infrastructure pvc-media-nfs from media/nfs/ folder)
  # Storage - streaming media (Longhorn RWX share-manager, static NFS wrappers for GPU nodes)
  - pv-nfs-streaming-media.yaml
  - pvc-nfs-streaming-media.yaml
  # Storage - DFS FUSE re-export (NFS server pod)
  - pv-nfs-dfs.yaml
  - pvc-nfs-dfs.yaml
  - service-plex-nfs-server.yaml
  - nfs-server-deployment.yaml
  # Plex
  - service.yaml
  - service-headless.yaml
  - statefulset.yaml
  - ingress.yaml
```

---

## Phase 5: Configure Longhorn Recurring Backup

This runs nightly block-level incremental backups to Unraid. After Phase 1's backup target is live, add a RecurringJob.

### 5.1 Create `recurring-backup-plex.yaml`
Create `clusters/homelab/infrastructure/longhorn/recurring-backup-plex.yaml`:

```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: plex-config-daily-backup
  namespace: longhorn-system
spec:
  cron: "0 3 * * *"   # 3:00 AM daily
  task: backup
  groups: []
  retain: 7            # Keep 7 daily backups
  concurrency: 1
  labels:
    app: plex
```

### 5.2 Label the PVC volume for the recurring job

After Flux deploys the RecurringJob, label the Longhorn volume:

```bash
# Get the Longhorn volume name (same as PVC volume name)
VOLUME=$(kubectl get pvc pvc-plex-config -n media -o jsonpath='{.spec.volumeName}')

# Apply the recurring job label via kubectl patch on the Longhorn Volume CR
kubectl patch volume $VOLUME -n longhorn-system \
  --type=merge \
  -p '{"metadata":{"labels":{"recurring-job.longhorn.io/plex-config-daily-backup":"enabled"}}}'
```

You can also do this in the Longhorn UI: Volumes → pvc-plex-config → Recurring Jobs → Add → select `plex-config-daily-backup`.

### 5.3 Add recurring-backup-plex.yaml to longhorn kustomization

In `clusters/homelab/infrastructure/longhorn/kustomization.yaml`, add:
```yaml
- recurring-backup-plex.yaml
```

---

## Phase 6: Deploy and Cut Over

### 6.1 Update media kustomization
In `clusters/homelab/apps/media/kustomization.yaml`, replace `./clusterplex` with `./plex`:

```yaml
resources:
  - namespace.yaml
  - ./sonarr
  - ./radarr
  - ./prowlarr
  - ./profilarr
  - ./decypharr-streaming
  - ./decypharr-download
  - ./nfs
  - ./longhorn
  - ./plex         # ← replaces ./clusterplex
```

**Do NOT add `plex` to the `ha-affinity` patch target** — Plex on w3 uses GPU affinity, not storage node affinity. The patch regex `(sonarr|radarr|prowlarr|profilarr|decypharr)` already excludes it.

### 6.2 Commit and push everything
```bash
git add clusters/homelab/apps/media/
git add clusters/homelab/infrastructure/longhorn/
git commit -m "feat(plex): replace ClusterPlex with normal Plex on w3

- Remove ClusterPlex orchestrator and workers
- Run linuxserver/plex directly on w3 (gpu=true affinity)
- Config stored on Longhorn RWX (10Gi), accessed via share-manager NFSv4
- No transcode volume — Plex writes to container overlay fs (ephemeral, correct)
- NFS server pod kept: re-exports /mnt/dfs FUSE for w3 access
- Nightly Longhorn backup to Unraid nfs://192.168.1.29/longhorn_backup
- Retain 7 daily snapshots; restore = new PVC from backup snapshot"
git push
flux reconcile kustomization apps --with-source
```

### 6.3 Claim the Plex server and port-forward for first-time setup
Plex requires a web UI claim step before it's fully usable. Port-forward the service to localhost:

```bash
kubectl port-forward -n media svc/plex 8080:32400 &
```

Then open **http://localhost:8080** in your browser. Sign in with your Plex account and claim the server. The server will appear in your Plex account as a remote server.

When done with the claim process, kill the port-forward:
```bash
kill %1  # kills the bg job
```

### 6.4 Verify Plex starts on w3
```bash
kubectl get pods -n media -l app.kubernetes.io/name=plex -o wide
kubectl logs -n media plex-0 -f
```

### 6.5 Add media libraries and let Plex scan
The `HardwareAcceleratedCodecs` and `HardwareDevicePath` in `Preferences.xml` were set via `kubectl exec` previously. Since the config data was migrated from the old PVC, these settings should already be present. Verify:

```bash
kubectl exec -n media plex-0 -- grep -o "HardwareAccelerated[^\"]*\"[^\"]*\"" \
  "/config/Library/Application Support/Plex Media Server/Preferences.xml"
```

If missing, re-apply:
```bash
kubectl exec -n media plex-0 -- bash -c '
PREFS="/config/Library/Application Support/Plex Media Server/Preferences.xml"
perl -i -pe "s|/>$| HardwareAcceleratedCodecs=\"1\" HardwareDevicePath=\"/dev/dri/renderD128\"/>|" "$PREFS"
'
kubectl rollout restart statefulset/plex -n media 2>/dev/null || \
  kubectl delete pod plex-0 -n media
```

### 6.5 Clean up ClusterPlex residue
Once Plex is confirmed working:

```bash
# Orphaned PVCs from clusterplex (will Retain, won't auto-delete)
kubectl delete pvc clusterplex-pms-config -n media   # Old RWO config (migrated)
kubectl delete pvc clusterplex-transcode -n media     # Old transcode RWX
kubectl delete pvc clusterplex-transcode-w3 -n media  # Old w3 transcode static NFS
# PVs will enter Released state; clean them up from Longhorn UI or:
kubectl delete pv pv-transcode-w3
kubectl delete pv <clusterplex-transcode-pv-name>  # from kubectl get pv

# Also remove the Unraid transcode NFS PV/PVC (no longer referenced by anything):
kubectl delete pvc pvc-transcode-nfs -n media
kubectl delete pv pv-nfs-transcode
# Also remove from git: clusters/homelab/infrastructure/storage/nfs/pv-nfs-transcode.yaml
# and clusters/homelab/apps/media/nfs/pvc-transcode.yaml
```

Worker codec PVCs may still exist if they were created by volumeClaimTemplates:
```bash
kubectl get pvc -n media | grep codec
kubectl delete pvc codecs-clusterplex-worker-0 -n media  # etc.
```

Also delete any remaining clusterplex files from git — Flux will garbage collect the Kubernetes objects when the kustomization no longer references them.

---

## Nightly Backup Details

### Longhorn Backup (Primary — incremental block backup)

**What it does**: Longhorn snapshots the entire block device of the config volume nightly at 3am. The first backup is a full snapshot (may take minutes for a large Plex config). Subsequent backups are block-level incremental — only changed 4KB blocks are uploaded. At 7-day retention, you have a rolling week of recovery points.

**Storage cost on Unraid**: First backup ≈ ~6-10GB (full config volume). Incremental additions ≈ daily writes to DB + metadata changes — typically a few hundred MB/day for a stable library.

**What it protects against**:
- Complete volume corruption
- Accidental deletion
- Both storage nodes fail simultaneously
- Catastrophic Longhorn failure

**Recovery time**: New PVC provisioned from a backup snapshot in Longhorn UI. Data available in minutes. Plex starts and sees full config.

### Optional: Database-only CronJob Backup (Secondary — explicit DB files)

For the specific scenario of SQLite corruption (you want to restore just the DBs without touching artwork/metadata), a secondary CronJob can back up only the DB files to Unraid NFS. This is optional if Longhorn backup is configured.

The CronJob would:
1. Scale plex StatefulSet to 0
2. Mount pvc-plex-config (RWX, so no exclusive lock needed)
3. `tar` and copy only the `Databases/` directory + `Preferences.xml`
4. Scale back to 1

This is documented in the restore runbook below as the "fast path" for DB corruption.

---

## Restore Runbook

### Scenario A: SQLite Database Corruption

**Symptoms**: Plex fails to start with "database disk image is malformed", or library is empty/missing entries after a crash.

1. **Stop Plex**:
   ```bash
   kubectl scale statefulset plex -n media --replicas=0
   kubectl rollout status statefulset/plex -n media --timeout=60s
   ```

2. **Restore from Longhorn backup** (preferred — restores full consistent config):
   - Open Longhorn UI at http://longhorn.homelab
   - Volumes → find the volume backing `pvc-plex-config`
   - Backups → select the most recent backup before the corruption event
   - Click "Restore" → name the new PVC (e.g., `pvc-plex-config-restored`)
   - Wait for restore to complete
   - Update `pv-nfs-plex-config.yaml` to point to the new volume's share-manager ClusterIP + path (same process as Phase 2.3)
   - Delete old `pvc-plex-config` and `pvc-nfs-plex-config` PVCs/PVs
   - Commit and push
   - Scale Plex back to 1

3. **Alternative: Restore only the DB files from Unraid CronJob backup** (if Longhorn backup not healthy):
   ```bash
   # Run a rescue pod against the config PVC
   kubectl run plex-rescue --rm -it --image=alpine --restart=Never -n media \
     --overrides='{ "spec": { <mount pvc-nfs-plex-config> } }'
   
   # Inside rescue pod:
   cd "/config/Library/Application Support/Plex Media Server/Plug-in Support/Databases/"
   # Backup current corrupt files
   mv com.plexapp.plugins.library.db com.plexapp.plugins.library.db.corrupt
   mv com.plexapp.plugins.library.blobs.db com.plexapp.plugins.library.blobs.db.corrupt
   # Restore from Longhorn backup (see Scenario A step 2) — preferred path for DB restore
   ```
   
4. **Start Plex**:
   ```bash
   kubectl scale statefulset plex -n media --replicas=1
   kubectl logs -n media plex-0 -f
   ```

---

### Scenario B: w3 Node Failure (Plex Down, Data Intact)

**Symptoms**: plex-0 pod stuck in `Pending` with NodeNotReady.

1. Check node status:
   ```bash
   kubectl get nodes
   kubectl describe node k3s-w3
   ```

2. Wait for w3 to recover — the config volume is on Longhorn (w1/w2), not on w3. When w3 comes back, Kubernetes auto-reschedules plex-0, which remounts the config via NFSv4. No data loss. No manual intervention needed.

3. If w3 is permanently dead and you need Plex running elsewhere: see Scenario D.

---

### Scenario C: Both Storage Nodes (w1 + w2) Fail

**Symptoms**: Longhorn share-manager pod not running. Plex-0 crashlooping with NFS mount errors.

1. Recover storage nodes first (this is the same scenario every Longhorn-backed app faces).
2. Once w1 or w2 comes back, Longhorn share-manager restarts automatically. plex pod retries NFS mount. Plex comes back without intervention.
3. If volume data is lost: restore from most recent Longhorn backup on Unraid (see Scenario A step 2).

---

### Scenario D: w3 Permanently Gone, Need Plex Elsewhere

1. **Create a temporary Plex StatefulSet on w1/w2** (no GPU, software transcode only):
   - Copy `plex/statefulset.yaml`
   - Change node affinity from `gpu: "true"` to `node.longhorn.io/storage: enabled`
   - Change tolerations to match storage nodes
   - Remove `/dev/dri` hostPath volume
   - Remove supplementalGroups: [992]
   - Mount `pvc-plex-config` directly (RWX, accessible from w1/w2 via Longhorn CSI)
   - Do NOT use static NFS PVs — w1/w2 have Longhorn CSI, mount PVCs directly

2. The key point: **pvc-plex-config is a Longhorn RWX PVC** — it can be mounted directly by pods on w1/w2 without any static PV / NFS workaround. You only need the NFS layer because w3 is LXC.

---

## Post-Deploy Checklist

- [x] Plex UI accessible at http://plex.homelab
- [x] Longhorn UI accessible at http://longhorn.homelab
- [x] Longhorn backup target shows green in Settings (`nfs://192.168.1.29:/mnt/cache/longhorn_backup`)
- [x] `plex-config-daily-backup` RecurringJob deployed (daily 3:00 AM, 7-day retention)
- [x] plex-0 pod running on k3s-w3 (GPU node)
- [x] `/dev/dri/renderD128` accessible in Plex container
- [x] Hardware acceleration enabled in Plex Preferences
- [x] All libraries scan correctly (media, streaming-media, dfs paths)
- [x] Plex is running and scanning files

---

## Final Verification (Completed 2026-02-28)

```bash
# Plex StatefulSet
kubectl get statefulset plex -n media
# Output: NAME   READY   AGE
#         plex   1/1     87m

# Plex Pod
kubectl get pod plex-0 -n media -o wide
# Output: plex-0 running on k3s-w3

# Plex Config PVC (Longhorn RWX)
kubectl get pvc pvc-plex-config -n media
# Output: STATUS Bound, VOLUME pvc-64ffe0e2-1120-4278-93f0-0f353a1d890d

# Longhorn Recurring Backup Job
kubectl get recurringjob -n longhorn-system plex-config-daily-backup
# Output: CRON "0 3 * * *", RETAIN 7, CONCURRENCY 1

# Longhorn Backup Target
kubectl get settings -n longhorn-system backup-target
# Output: nfs://192.168.1.29:/mnt/cache/longhorn_backup

# No Orphaned ClusterPlex Objects
kubectl get pvc -n media | grep clusterplex
# Output: (empty — all cleaned up)
kubectl get pv | grep clusterplex
# Output: (empty — all cleaned up)
```

**All phases completed successfully. Plex is running on w3, backed by Longhorn RWX with nightly incremental backups to Unraid.**
- [ ] Old ClusterPlex PVCs deleted and PVs cleaned up
- [ ] `clusterplex/` directory removed from git
- [ ] docs/DECISIONS.md updated with this architecture decision

---

## Files Changed Summary

| Action | File |
|---|---|
| DELETE | `clusters/homelab/apps/media/clusterplex/` (entire directory) |
| CREATE | `clusters/homelab/apps/media/plex/` (new directory, all files above) |
| MODIFY | `clusters/homelab/apps/media/kustomization.yaml` (`./clusterplex` → `./plex`) |
| DELETE | `clusters/homelab/apps/media/nfs/pvc-transcode.yaml` (transcode scratch no longer needed) |
| DELETE | `clusters/homelab/infrastructure/storage/nfs/pv-nfs-transcode.yaml` (transcode NFS PV) |
| MODIFY | `clusters/homelab/apps/media/nfs/kustomization.yaml` (remove pvc-transcode.yaml) |
| MODIFY | `clusters/homelab/infrastructure/storage/nfs/kustomization.yaml` (remove pv-nfs-transcode.yaml) |
| MODIFY | `clusters/homelab/infrastructure/longhorn/helmrelease.yaml` (backupTarget) |
| CREATE | `clusters/homelab/infrastructure/longhorn/ingress.yaml` |
| CREATE | `clusters/homelab/infrastructure/longhorn/recurring-backup-plex.yaml` |
| MODIFY | `clusters/homelab/infrastructure/longhorn/kustomization.yaml` (add new files) |
| MODIFY | `docs/DECISIONS.md` (document this decision) |
| MODIFY | `docs/STATE.md` (update running pods, PVC inventory) |
