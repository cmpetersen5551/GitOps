# Media Automation Stack Implementation Plan

**TL;DR**: Deploy a cloud-based media automation stack (Sonarr, Radarr, Prowlarr, Profilarr, Decypharr, Plex with ClusterPlex, Pulsarr) on your existing k3s homelab with Longhorn 2-node HA. Apps use Longhorn for config storage, Decypharr DFS for streamed downloads via RealDebrid/UsenetExpress, Profilarr for manual quality profile management, and ClusterPlex for distributed GPU transcoding. Implement SOPS with age for GitOps secrets management.

**Estimated Total Time**: 12-16 hours over multiple days

---

## Deployment Order & Phases

### Phase 1: Foundation (Secrets & Infrastructure)
**Estimated Time**: 2-3 hours

#### 1. SOPS Setup (*must be first*)
- Generate age keypair: `age-keygen -o age.key`
- Backup in 3 locations: 1Password (Secure Note), encrypted USB drive, printed QR code
- Create `.sops.yaml` in repo root with public key
- Create Kubernetes Secret: `kubectl create secret generic sops-age --namespace=flux-system --from-file=age.agekey=./age.key`
- Update all Flux Kustomizations with decryption config:
  ```yaml
  spec:
    decryption:
      provider: sops
      secretRef:
        name: sops-age
  ```
- Test with dummy secret: `kubectl create secret generic test-secret --from-literal=key=value --dry-run=client -o yaml | sops --encrypt /dev/stdin` → verify it encrypts

#### 2. Base Media Namespace & Storage PVCs (*parallel with step 1*)
- Namespace `media` already exists, verify: `kubectl get namespace media`
- Add NFS PVC for Unraid media library (read-only for permanent imports):
  ```yaml
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: media-library
    namespace: media
  spec:
    accessModes:
      - ReadOnlyMany
    storageClassName: nfs-unraid
    resources:
      requests:
        storage: 100Gi  # Size of your media library
  ```
- Add NFS PVC for transcode temp directory (read-write, shared for ClusterPlex):
  ```yaml
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: transcode-cache
    namespace: media
  spec:
    accessModes:
      - ReadWriteMany
    storageClassName: nfs-unraid
    resources:
      requests:
        storage: 500Gi  # Temporary transcode space
  ```
- Add Longhorn PVC for symlink library (read-write, shared by Decypharr/Sonarr/Radarr/Plex):
  ```yaml
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: symlink-library
    namespace: media
  spec:
    accessModes:
      - ReadWriteMany  # Longhorn RWX via NFSv4
    storageClassName: longhorn-rwx
    resources:
      requests:
        storage: 100Mi  # Symlinks only (~KB per symlink, even 10k shows is <50MB)
  ```

**Note on Longhorn RWX**: This creates a dedicated NFSv4 share-manager pod in `longhorn-system` namespace that exposes the volume via NFS. Adds ~10-30% overhead vs direct block storage, but provides HA failover for the symlink library.

**StorageClass for Longhorn RWX** (create if doesn't exist):
```yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: longhorn-rwx
provisioner: driver.longhorn.io
parameters:
  numberOfReplicas: "2"
  migratable: "false"
  nfsOptions: "soft,timeo=600,retrans=5"
```

**Verification**: 
- `sops -d test-secret.yaml` works (outputs plaintext)
- `kubectl get pvc -n media | grep -E "nfs|streaming"` shows all three PVCs bound

---

### Phase 2: Core *Arr Apps (Foundation for Automation)
**Estimated Time**: 1-2 hours deployment + 15-30min manual config

#### 3. Sonarr (*first for API key generation*)
- StatefulSet with:
  - Image: `linuxserver/sonarr:latest`
  - Longhorn PVC: `config-sonarr` (10Gi)
  - Node affinity: `preferredDuringScheduling` for w1 (active-passive with descheduler failback)
  - Taint toleration: `node.longhorn.io/storage=enabled:NoSchedule`
  - Init container: Wait for Longhorn PVC to bind (standard practice)
  - Environment: `PUID=1000 PGID=1000 TZ=UTC` (matches container user)
  - Resource requests: 100m CPU, 512Mi RAM
  - Resource limits: 500m CPU, 2Gi RAM
  - Liveness probe: HTTP GET to `http://localhost:8989/health` (port 8989)
  - Readiness probe: Same, with initialDelaySeconds=30
- ClusterIP Service on port 8989
- Ingress: `sonarr.homelab` (via Traefik)
- **Manual post-deploy**:
  1. Access via ingress, wait 2-3 min for DB initialization
  2. Settings → General → Security → Copy API Key
  3. Save in 1Password: `Sonarr API Key`
  4. Encrypt and commit to repo: `clusters/homelab/apps/media/sonarr/secrets.yaml`

#### 4. Radarr (*parallel with Sonarr*)
- Same architecture as Sonarr, but:
  - Longhorn PVC: `config-radarr` (10Gi, can be larger if many movies)
  - Ingress: `radarr.homelab`
  - **Manual post-deploy**: Extract API key, save to 1Password

**Verification**: 
- Both pods running on w1: `kubectl get pods -n media -o wide | grep -E "sonarr|radarr"`
- Both ingresses accessible: `curl http://sonarr.homelab` returns Sonarr UI
- API keys accessible from Settings UI

---

### Phase 3: Indexer Management
**Estimated Time**: 1 hour deployment + 20min configuration

#### 5. Prowlarr
- StatefulSet with:
  - Image: `linuxserver/prowlarr:latest`
  - Longhorn PVC: `config-prowlarr` (5Gi)
  - Same HA pattern as Sonarr/Radarr
  - Ingress: `prowlarr.homelab`
  - Port: 9696
  - Resource requests: 100m CPU, 256Mi RAM
  - Readiness probe: HTTP GET to `http://localhost:9696/ping`
- ClusterIP Service port 9696
- **Manual post-deploy**:
  1. Access Prowlarr UI
  2. Settings → Apps → Add Applications:
     - Application: Sonarr
     - Sync URL: `http://sonarr:8989` (Kubernetes service DNS)
     - API Key: paste from 1Password
     - Sync profiles/categories
     - Test & Save
     - Repeat for Radarr with `http://radarr:8989`
  3. Add indexers (15-20 common ones, manually or via existing configs)
  4. **CRITICAL**: Wait 10-15 minutes for initial sync
  5. Verify indexers appear in Sonarr/Radarr Settings → Indexers
  6. In Sonarr/Radarr, manually disable any non-Prowlarr versions of existing indexers
  7. Extract Prowlarr API Key, save to 1Password
  8. Encrypt and commit: `clusters/homelab/apps/media/prowlarr/secrets.yaml`

**Why manual indexer setup?**
- No standard format for bulk indexer import (vary by source/format)
- TRaSH Guides provide curated indexer recommendations (better than automation)
- First-time setup is one-time cost

#### 6. Profilarr
- StatefulSet with:
  - Image: `ghcr.io/sirrobot01/profilarr:latest` (long-running service, not Job)
  - Longhorn PVC: `config-profilarr` (2Gi)
  - Port: 6868
  - Resource requests: 50m CPU, 256Mi RAM
  - Environment (via encrypted secrets):
    - `SONARR_URL=http://sonarr:8989`
    - `SONARR_API_KEY=<encrypted>`
    - `RADARR_URL=http://radarr:8989`
    - `RADARR_API_KEY=<encrypted>`
- ClusterIP Service port 6868
- Ingress: `profilarr.homelab`
- **Manual post-deploy**:
  1. Access Profilarr UI
  2. Verify API connections to Sonarr/Radarr
  3. Import TRaSH Guides quality profiles (manual process via Profilarr UI)
  4. Click "Sync" to push profiles to Sonarr/Radarr
  5. Quarterly: Repeat when TRaSH Guides update

**Verification**: 
- Prowlarr indexers synced to Sonarr/Radarr: `kubectl logs prowlarr-0 | grep "Sync.*completed"`
- Profilarr can connect to APIs: Check UI for green checkmarks

---

### Phase 4: Download Client (Decypharr with DFS)
**Estimated Time**: 2-3 hours (includes mount troubleshooting)

#### 7. Decypharr (*separate pod with FUSE hostPath mount*)

**Critical Architecture Decision**: Decypharr runs as separate StatefulSet (not sidecar) because:
- ✅ Single RealDebrid connection = efficient resource usage
- ✅ Shared DFS mount for Sonarr/Radarr = can see each other's downloads
- ✅ **Creates symlinks in shared Longhorn PVC** = Plex reads streaming content without duplicating storage
- ✅ Independent restart/lifecycle management

**Standardized Mount Path Strategy**: All pods mount the DFS cache at the **same path `/mnt/dfs`**:
- Decypharr: Direct FUSE mount at `/mnt/dfs`
- Sonarr/Radarr/Plex/Workers: NFS mount (via rclone-nfs-server sidecar) at `/mnt/dfs`

This unified path means symlinks work identically across all pods, regardless of mount type. Co-location is now **optional** (simplicity/performance preference rather than requirement).

**StatefulSet Configuration**:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: decypharr
  namespace: media
spec:
  serviceName: decypharr
  replicas: 1
  selector:
    matchLabels:
      app: decypharr
  template:
    metadata:
      labels:
        app: decypharr
        streaming-stack: "true"  # SHARED with Sonarr, Radarr, Plex
    spec:
      # CRITICAL: All four (Decypharr, Sonarr, Radarr, Plex) prefer same node
      affinity:
        podAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: streaming-stack
                      operator: In
                      values: [streaming-stack]
                topologyKey: kubernetes.io/hostname
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
                    values: ["true"]  # Prefer w1
      containers:
        - name: decypharr
          image: sirrobot01/decypharr:latest
          ports:
            - containerPort: 8080
              name: api
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: TZ
              value: "UTC"
            - name: REAL_DEBRID_API_KEY
              valueFrom:
                secretKeyRef:
                  name: decypharr-secrets
                  key: realdebrid-api-key
            - name: USENET_NNTP_HOST
              valueFrom:
                secretKeyRef:
                  name: decypharr-secrets
                  key: usenet-host
            - name: USENET_NNTP_USER
              valueFrom:
                secretKeyRef:
                  name: decypharr-secrets
                  key: usenet-user
            - name: USENET_NNTP_PASS
              valueFrom:
                secretKeyRef:
                  name: decypharr-secrets
                  key: usenet-pass
          volumeMounts:
            - name: config
              mountPath: /config
            - name: dfs-mount
              mountPath: /mnt/dfs
              mountPropagation: Bidirectional  # CRITICAL for FUSE sharing
            - name: streaming-media
              mountPath: /mnt/streaming-media    # Where symlinks are created
          securityContext:
            privileged: true  # REQUIRED for FUSE mount creation
            capabilities:
              add:
                - SYS_ADMIN
                - MKNOD
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 1Gi
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 5
          lifecycle:
            # Signal readiness to waiting pods
            postStart:
              exec:
                command: ["/bin/sh", "-c", "touch /mnt/dfs/.decypharr-ready || true"]
        # CRITICAL SIDECAR: Exposes DFS via NFS for remote ClusterPlex workers
        - name: rclone-nfs-server
          image: rclone/rclone:latest
          command:
            - rclone
            - serve
            - nfs
            - /mnt/dfs
            - --addr
            - :2049
            - --read-only
            - --vfs-cache-mode
            - full
            - --vfs-cache-max-age
            - 24h
            - --nfs-cache-handle-limit
            - "0"  # No handle caching (better for streaming)
          ports:
            - containerPort: 2049
              name: nfs
              protocol: TCP
          volumeMounts:
            - name: dfs-mount
              mountPath: /mnt/dfs
              mountPropagation: HostToContainer  # Receives FUSE mount from Decypharr
          securityContext:
            privileged: false  # No special perms needed for NFS server
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 1Gi
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: config-decypharr
        - name: dfs-mount
          hostPath:
            path: /mnt/k8s/decypharr-dfs
            type: DirectoryOrCreate
        - name: symlink-library
          persistentVolumeClaim:
            claimName: symlink-library
```

**Services & Ingress**:
- ClusterIP Service on port 8080 named `decypharr` (API)
- ClusterIP Service on port 2049 named `decypharr-nfs` (NFS export for remote transcoding)
  ```yaml
  apiVersion: v1
  kind: Service
  metadata:
    name: decypharr-nfs
    namespace: media
  spec:
    selector:
      app: decypharr
    ports:
      - port: 2049
        targetPort: 2049
        protocol: TCP
        name: nfs
  ```
- Ingress: `decypharr.homelab`

**Secrets**:
Create encrypted secret with Debrid/Usenet credentials:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: decypharr-secrets
  namespace: media
type: Opaque
stringData:
  realdebrid-api-key: "YOUR_REALDEBRID_API_KEY"
  usenet-host: "YOUR_USENET_HOST"
  usenet-user: "YOUR_USENET_USER"
  usenet-pass: "YOUR_USENET_PASS"
```

Then encrypt with SOPS: `sops --encrypt --in-place decypharr/secrets.yaml`

**Decypharr Configuration** (Manual Setup):
- Configure Decypharr to **create symlinks** in `/mnt/streaming-media` instead of copying files
  - RealDebrid provider: Set import mode to "symlink" (if available) or ensure post-processing creates symlinks
  - Usenet provider: Same symlink strategy
- Ensure symlink folder structure matches what Sonarr/Radarr will create (e.g., `/mnt/streaming-media/TV Shows/Show Name/`)

**Manual post-deploy**:
1. Wait 10-15s for pod to start (FUSE mount init takes time)
2. Access Decypharr UI at `decypharr.homelab`
3. Configure RealDebrid providers (Add credentials, test)
4. Configure Usenet provider (NNTP host, user, pass, test)
5. Verify DFS mount: `kubectl exec decypharr-0 -n media -- ls -la /mnt/dfs`
   - Should show `drwxr-xr-x`
   - May be empty initially (populates on demand)
6. Verify streaming media library mount: `kubectl exec decypharr-0 -n media -- ls -la /mnt/streaming-media`
   - Should be writable by Decypharr
7. Check mount from Sonarr/Radarr: `kubectl exec sonarr-0 -n media -- ls -la /mnt/dfs`
   - Must be accessible (init containers below ensure this)

**Verification**:
- Decypharr pod running on w1 with 2 containers: `kubectl get pods -n media decypharr-0 -o jsonpath='{.status.containerStatuses[*].name}'` → should show "decypharr rclone-nfs-server"
- DFS mount visible: `kubectl exec decypharr-0 -c decypharr -n media -- mount | grep fuse`
- Streaming media library accessible: `kubectl exec decypharr-0 -c decypharr -n media -- ls -la /mnt/streaming-media`
- Test file access: `kubectl exec decypharr-0 -c decypharr -n media -- test -w /mnt/streaming-media && echo "writable"`
- **NFS export accessible**: `kubectl exec decypharr-0 -c rclone-nfs-server -n media -- rclone ls /mnt/dfs | head -5` (should show DFS files)
- **NFS service reachable**: `kubectl get svc decypharr-nfs -n media` → should show ClusterIP

---

### Phase 5: Sonarr/Radarr ↔ Decypharr Integration
**Estimated Time**: 1-2 hours

#### 8. Update Sonarr StatefulSet with Decypharr Integration

**Add init container** (ensures Decypharr mounts BEFORE Sonarr starts):
```yaml
initContainers:
  - name: wait-for-decypharr-dfs
    image: busybox:latest
    command:
      - sh
      - -c
      - |
        echo "Waiting for Decypharr DFS mount..."
        until [ -f /mnt/dfs/.decypharr-ready ]; do
          sleep 2
        done
        echo "Decypharr DFS ready, starting Sonarr"
    volumeMounts:
      - name: dfs-mount
        mountPath: /mnt/dfs
```

**Add volume**:
```yaml
volumes:
  - name: dfs-mount
    hostPath:
      path: /mnt/k8s/decypharr-dfs
      type: DirectoryOrCreate
```

**Add volume mounts to Sonarr container** for all media paths:
```yaml
volumeMounts:
  - name: dfs-mount
    mountPath: /mnt/dfs
  - name: streaming-media
    mountPath: /mnt/streaming-media
  - name: media
    mountPath: /mnt/media
    readOnly: true
```

**Add pod affinity label and streaming-stack group**:
```yaml
metadata:
  labels:
    app: sonarr
    streaming-stack: "true"
spec:
  template:
    metadata:
      labels:
        app: sonarr
        streaming-stack: "true"
    spec:
      affinity:
        podAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: streaming-stack
                      operator: In
                      values: [streaming-stack]
                topologyKey: kubernetes.io/hostname
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
                    values: ["true"]  # Prefer w1
```

**Add volume mounts to Sonarr container**:
```yaml
volumeMounts:
  - name: dfs-mount
    mountPath: /mnt/dfs
  - name: streaming-media
    mountPath: /mnt/streaming-media
  - name: media
    mountPath: /mnt/media
    readOnly: true
```

**Add volumes**:
```yaml
volumes:
  - name: dfs-mount
    hostPath:
      path: /mnt/k8s/decypharr-dfs
      type: DirectoryOrCreate
  - name: symlink-library
    persistentVolumeClaim:
      claimName: symlink-library
```

#### 9. Update Radarr StatefulSet (*same pattern as Sonarr, with streaming-stack affinity*)

#### 10. Configure Download Clients in Sonarr/Radarr

**CRITICAL ARCHITECTURE FINDING**: Sonarr/Radarr do NOT support root folder → download client association. Instead, they use **indexer-based download client assignment** with tags for routing.

**Workflow**:
1. Each download client is configured globally
2. Each indexer can be assigned a specific download client (advanced setting)
3. Tags control which shows search which indexers
4. Shows tagged "streaming" search only Decypharr indexer → use Decypharr client
5. Shows tagged "downloads" search only SABnzbd indexer → use SABnzbd client

**In Sonarr UI** (Settings → Download Clients):
- Add "qBittorrent" (Decypharr mimics qBittorrent API):
  - Name: `Decypharr`
  - Host: `decypharr` (Kubernetes service DNS)
  - Port: `8080`
  - Category: `sonarr`
  - Username/Password: Leave blank (Decypharr doesn't require auth by default)
  - Client Priority: `1` (highest priority)
  - **CRITICAL**: Disable "Use Hardlinks instead of Copy"
    - Cloud downloads don't support hardlinks
    - Expect 2x storage temporarily during import
  - Test connection: Button should turn green

- Add second client (if using SABnzbd for fallback - optional for your setup):
  - Name: `SABnzbd`
  - Host: `sabnzbd` (or external Usenet provider)
  - Port: `8080`
  - Category: `sonarr`
  - Client Priority: `2` (fallback only)

**In Radarr UI** (*repeat same configuration, categories: `radarr`*)

**In Prowlarr UI** (Settings → Indexers - Configure per-indexer download client):
For each indexer, set which download client it uses:
- Decypharr torrent indexers → Download Client: `Decypharr` (Sonarr/Radarr)
- SABnzbd Usenet indexers → Download Client: `SABnzbd` (if available)
- This is an **advanced setting** per Prowlarr indexer configuration

**Use tags to control indexer/download client routing**:
```yaml
Sonarr Settings → Tags:
  - Create tag: "streaming"
  - Create tag: "downloads"

Prowlarr Settings → Indexers:
  - Decypharr torrent indexers: Tag "streaming"
  - SABnzbd Usenet indexers: Tag "downloads"

Shows:
  - Tag with "streaming": Only searches Decypharr indexers → Decypharr client used
  - Tag with "downloads": Only searches SABnzbd indexers → SABnzbd client used
  - Untagged: Searches all (Decypharr priority 1 used first)
```

**Verification**:
- Successful test download: Search obscure episode → Download → appears in DFS mount → imports without errors
- Check Sonarr/Radarr Activity queue: No "Waiting for import" errors

#### 11. Configure Root Folders & Import Paths

**Root Folders are for file organization only** (do NOT affect download client selection):

**In Sonarr UI** (Settings → Media Management):
- Add Root Folder: `/mnt/streaming-media/sonarr` (streaming downloads)
  - Optional: Add second root folder `/mnt/streaming-media/permanent` (for shows to keep permanently)
- Default folder: Choose primary folder

**In Radarr UI** (*same, folder: `/mnt/streaming-media/radarr`*)

**Note**: Root folder choice has NO impact on which download client is used. Download client is determined by indexer tagging (see section 10 above).

**Verification**:
- Successful test download: Search obscure episode → Download → appears in DFS mount → imports without errors
- Check Sonarr/Radarr Activity queue: No "Waiting for import" errors

---

### Phase 6: Quality Profile Management via Profilarr
**Estimated Time**: 30min setup + ongoing manual sync

#### 12. Manual Quality Profile Setup via Profilarr

**Workflow**:
1. Access Profilarr UI at `profilarr.homelab`
2. Browse available TRaSH Guides quality profile templates
3. Select profiles suitable for your setup:
   - TV: HD/4K quality options
   - Movies: HD/4K quality options
4. Import profiles (Profilarr handles config generation)
5. Click "Sync" to push to Sonarr/Radarr
6. Verify in Sonarr/Radarr Settings → Profiles
7. **Repeat quarterly** when TRaSH Guides update their recommendations

**Why manual instead of automated?**
- Profilarr is long-running (UI-driven), not event-driven
- Quality preferences are personal (4K vs HD, streaming bitrate, audio codecs)
- TRaSH Guides update irregularly, not on a fixed schedule
- Better manual control over when profiles change

**Verification**:
- Profiles visible in Sonarr/Radarr: Settings → Profiles shows imported profiles
- Profiles match TRaSH Guides recommendations

---

### Phase 7: Media Server (Plex + ClusterPlex)
**Estimated Time**: 3-4 hours (GPU passthrough + testing)

#### 13. Intel GPU Device Plugin (*prerequisite for w3 GPU support*)

**Deployment**:
- DaemonSet with `nodeSelector: gpu=true` (only runs on w3)
- Image: `intel/intel-gpu-plugin:0.30.0`
- Namespace: `kube-system` or `media` (your choice)

**Post-deploy verification**:
```bash
kubectl describe node k3s-w3 | grep -A 5 "Allocated resources"
# Should show: intel.com/gpu: 1
```

**Troubleshooting GPU access**:
```bash
# Check if GPU device plugin sees GPU
kubectl logs -n kube-system -l app=intel-gpu-plugin --tail=20

# Verify /dev/dri exists on w3
kubectl debug node/k3s-w3 -it --image=ubuntu:latest
# Inside node debug pod: ls -la /dev/dri
```

#### 14. Plex Media Server (*co-located on storage nodes w1/w2*)

**Architecture**: Plex runs on **same node as Decypharr/Sonarr/Radarr** (w1 primary, failover to w2) for consistency and HA symmetry:
- Prefers w1 (via node affinity) for primary streaming stack co-location
- Fails over to w2 with other storage apps
- All mounts are NFS-based, so node movement works transparently

**Mounts**:
- `/mnt/dfs` → NFS mount to `decypharr-nfs.media.svc:` (read-only, RealDebrid cache)
- `/mnt/streaming-media` → Longhorn RWX mount (symlink library)
- `/mnt/media` → Unraid NFS mount (permanent library)
- `/mnt/transcode` → Unraid NFS mount (transcode cache for ClusterPlex)

All mount paths are standardized, so node movement and failover work seamlessly via NFS backend.

**Workflow**:
1. Decypharr creates symlinks in `/mnt/streaming-media` (e.g., `/mnt/streaming-media/TV Shows/Breaking Bad/S01E01.mkv` → `/mnt/dfs/breaking-bad-s01e01.mkv`)
2. Sonarr/Radarr organize/rename those symlinks into proper folder structure
3. Plex reads from ONE library with multiple roots (/mnt/streaming-media + /mnt/media) via NFS → all symbolic links resolve correctly
4. Plex serves streaming content (via symlink chain) and permanent content side-by-side

**StatefulSet Configuration**:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: plex
  namespace: media
spec:
  serviceName: plex
  replicas: 1
  selector:
    matchLabels:
      app: plex
  template:
    metadata:
      labels:
        app: plex
        streaming-stack: "true"  # SAME as Decypharr/Sonarr/Radarr
    spec:
      affinity:
        podAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: streaming-stack
                      operator: In
                      values: [streaming-stack]
                topologyKey: kubernetes.io/hostname
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
                    values: ["true"]  # Prefer w1
      containers:
        - name: plex
          image: linuxserver/plex:latest
          ports:
            - containerPort: 32400
              name: plex
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: TZ
              value: "UTC"
            - name: DOCKER_MODS
              value: "ghcr.io/pabloromeo/clusterplex_dockermod:latest"
            - name: PLEX_CLAIM
              valueFrom:
                secretKeyRef:
                  name: plex-secrets
                  key: plex-claim
          volumeMounts:
            - name: config
              mountPath: /config
            - name: media
              mountPath: /mnt/media
              readOnly: true
            - name: dfs-mount
              mountPath: /mnt/dfs
              readOnly: true
              mountPropagation: Bidirectional
            - name: streaming-media
              mountPath: /mnt/streaming-media
            - name: transcode
              mountPath: /transcode
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi
          livenessProbe:
            httpGet:
              path: /identity
              port: 32400
            initialDelaySeconds: 60
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /identity
              port: 32400
            initialDelaySeconds: 60
            periodSeconds: 10
      volumes:
        - name: config
          persistentVolumeClaim:
            claimName: config-plex
        - name: media
          persistentVolumeClaim:
            claimName: media-library
        - name: dfs-mount
          hostPath:
            path: /mnt/k8s/decypharr-dfs
            type: DirectoryOrCreate
        - name: symlink-library
          persistentVolumeClaim:
            claimName: symlink-library
        - name: transcode
          persistentVolumeClaim:
            claimName: transcode-cache
```

**Longhorn PVC for config** (create separately):
- Name: `config-plex`
- Size: 50Gi (Plex metadata is large for large libraries)
- StorageClass: `longhorn-simple`

**Service & Ingress**:
- LoadBalancer Service (via MetalLB BGP) on port 32400 for external clients
- Ingress: `plex.homelab` (for web UI access via internal network)

**Secrets**:
Generate Plex claim token at `https://www.plex.tv/claim` (valid 4 minutes):
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: plex-secrets
  namespace: media
type: Opaque
stringData:
  plex-claim: "claim-YOUR_CLAIM_TOKEN"
```

Then encrypt: `sops --encrypt --in-place plex/secrets.yaml`

**Manual post-deploy**:
1. Wait 5-10 min for initial startup
2. Access Plex UI via `plex.homelab:32400` or LoadBalancer IP
3. Complete setup wizard (name server, enable remote access)
4. Add media library with THREE root folders (unified view):
   - Library Name: "TV Shows" (or "Movies")
   - **Root Folder 1**: `/mnt/streaming-media` (streaming content, symlinks to DFS)
   - **Root Folder 2**: `/mnt/media` (permanent content, NFS from Unraid)
   - Plex will treat all as one library, showing all content together
5. Refresh library
6. Generate Plex token for other apps:
   - Settings → Account → Look for "X-Plex-Token" in auth cookie or API
   - Save to 1Password as `Plex Auth Token`
7. Verify symlink resolution:
   - Play a streamed show (from `/mnt/streaming-media`)
   - Should resolve through symlink to DFS cache
   - File info should show path under `/mnt/streaming-media`

**Streaming → Permanent Workflow (Manual Upgrade)**:
When you decide to keep a show permanently:
1. In Sonarr: Change show's root folder from streaming → permanent root
2. Trigger "Move Files" in Sonarr → copies from DFS to NFS
3. **CRITICAL**: Delete streaming symlinks after copy completes:
   ```bash
   kubectl exec sonarr-0 -n media -- rm -rf /mnt/streaming-media/TV\ Shows/<ShowName>
   ```
4. Plex scans and updates metadata → now points to `/mnt/media` path
5. Original DFS files expire from cache (no action needed)

**Why cleanup matters**: Without deleting streaming symlinks, Plex sees duplicate entries (one from `/mnt/streaming-media`, one from `/mnt/media`). Manual cleanup ensures only one copy visible.

**Verification**:
- Plex accessible from web browser
- One library with three root folders visible in Settings → Libraries → Edit
- Remote access enabled (test from external network if possible)
- Streaming media readable: `kubectl exec plex-0 -n media -- ls -la /mnt/streaming-media`
- Permanent media readable: `kubectl exec plex-0 -n media -- ls -la /mnt/media`
- No duplicate shows after upgrade workflow

---

#### 15. ClusterPlex Orchestrator

**Deployment**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clusterplex-orchestrator
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: clusterplex-orchestrator
  template:
    metadata:
      labels:
        app: clusterplex-orchestrator
    spec:
      containers:
        - name: orchestrator
          image: ghcr.io/pabloromeo/clusterplex_orchestrator:latest
          ports:
            - containerPort: 3500
              name: orchestrator
          env:
            - name: PLEX_TOKEN
              valueFrom:
                secretKeyRef:
                  name: plex-secrets
                  key: plex-auth-token
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 512Mi
```

**LoadBalancer Service** (port 3500):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: clusterplex-orchestrator
  namespace: media
spec:
  type: LoadBalancer
  selector:
    app: clusterplex-orchestrator
  ports:
    - port: 3500
      targetPort: 3500
      protocol: TCP
```

**Post-deploy**:
1. Wait for LoadBalancer IP assignment: `kubectl get svc clusterplex-orchestrator -n media` → Note IP/hostname
2. This IP (`ORCHESTRATOR_URL`) is needed for workers (step 16)

---

#### 16. ClusterPlex Worker (Kubernetes pod on w3)

**CRITICAL ARCHITECTURE NOTE**: ClusterPlex workers on w3 (GPU node) need access to streaming content stored in Decypharr's DFS. Since FUSE mounts cannot be accessed across nodes, we expose the DFS via **rclone NFS server** (sidecar in Decypharr pod). Workers mount this NFS export to transcode streaming content.

**Deployment**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clusterplex-worker
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: clusterplex-worker
  template:
    metadata:
      labels:
        app: clusterplex-worker
    spec:
      # STRICT requirement: Must run on GPU node only
      nodeSelector:
        gpu: "true"
      tolerations:
        - key: gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values: [k3s-w3]
      containers:
        - name: worker
          image: linuxserver/plex:latest
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: TZ
              value: "UTC"
            - name: DOCKER_MODS
              value: "ghcr.io/pabloromeo/clusterplex_worker_dockermod:latest"
            - name: ORCHESTRATOR_URL
              value: "http://192.168.100.101:3500"  # Replace with actual LoadBalancer IP
            - name: PLEX_TOKEN
              valueFrom:
                secretKeyRef:
                  name: plex-secrets
                  key: plex-auth-token
          volumeMounts:
            - name: streaming-media
              mountPath: /mnt/streaming-media
              readOnly: true
            - name: media
              mountPath: /mnt/media
              readOnly: true
            - name: dfs-nfs
              mountPath: /mnt/dfs
              readOnly: true
            - name: transcode
              mountPath: /mnt/transcode
            - name: codec-cache
              mountPath: /codecs
          securityContext:
            privileged: false  # GPU device pass only
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
              intel.com/gpu: 1  # Request GPU resource
            limits:
              cpu: 2000m
              memory: 2Gi
              intel.com/gpu: 1  # Limit GPU (no overcommit)
          livenessProbe:
            exec:
              command: ["/bin/sh", "-c", "curl -f http://localhost:32400/identity || exit 1"]
            initialDelaySeconds: 30
            periodSeconds: 30
      volumes:
        - name: media
          persistentVolumeClaim:
            claimName: media-library
        - name: dfs-nfs
          nfs:
            server: decypharr-nfs.media.svc.cluster.local
            path: /
            readOnly: true
        - name: transcode
          persistentVolumeClaim:
            claimName: transcode-cache
        - name: codec-cache
          emptyDir: {}  # Per-pod codec cache (ephemeral)
```

**Post-deploy**:
1. Verify worker registration: `kubectl logs -f deployment/clusterplex-worker -n media`
   - Look for: "Connected to Orchestrator" or similar message
2. Check Orchestrator logs for worker connection: `kubectl logs -f deployment/clusterplex-orchestrator -n media`
3. Verify GPU resource allocated: `kubectl describe pod <worker-pod-name> -n media | grep gpu`
4. **Verify NFS mount accessible**: `kubectl exec deployment/clusterplex-worker -n media -- ls -la /mnt/dfs` (should show DFS files from Decypharr)
5. **Test streaming file access**: `kubectl exec deployment/clusterplex-worker -n media -- test -f /mnt/streaming-media/<test-file> && echo "Mount OK"`

**Testing**:
1. Play 4K/high-bitrate **streaming content** (from `/mnt/streaming-media` library) from Plex client
2. Check ClusterPlex Orchestrator logs for transcode job dispatch to w3 worker
3. Verify GPU utilization on w3: `kubectl exec deployment/clusterplex-worker -n media -- cat /sys/class/drm/card0/engine/rcs0/busy` (Intel GPU, or use `intel_gpu_top`)
4. Monitor transcode progress in Plex dashboard
5. **Verify worker can read streaming files**: Check worker logs for successful file open (no "file not found" errors)
6. Play **permanent content** (from `/mnt/media` library) → should also transcode on w3 via NFS

**Why this works**: 
- Decypharr's rclone-nfs-server sidecar exposes DFS cache as read-only NFS on port 2049
- ClusterPlex workers mount `decypharr-nfs.media.svc.cluster.local:/` at `/mnt/dfs`
- Workers also mount `/mnt/streaming-media` (Longhorn RWX) and `/mnt/media` (Unraid NFS) for reading input files
- Workers mount `/mnt/transcode` (Unraid NFS) for writing transcoded output
- When Plex requests transcode, FFmpeg arguments include the path (e.g., `/mnt/streaming-media/...`), worker reads from that mount → transcodes with GPU → writes to `/mnt/transcode`
- No FUSE mount crossing nodes

**Optional: External Docker Worker on Unraid**
- Documented separately in `docs/CLUSTERPLEX_EXTERNAL_WORKER.md`
- Deploy outside Kubernetes for GPU redundancy
- Not GitOps-managed, but provides failover if w3 fails

---

### Phase 8: Plex Watchlist Integration
**Estimated Time**: 30min

#### 17. Pulsarr

**Deployment**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pulsarr
  namespace: media
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pulsarr
  template:
    metadata:
      labels:
        app: pulsarr
    spec:
      containers:
        - name: pulsarr
          image: pulsarr/pulsarr:latest
          ports:
            - containerPort: 3000
              name: web
          env:
            - name: PLEX_TOKEN
              valueFrom:
                secretKeyRef:
                  name: plex-secrets
                  key: plex-auth-token
            - name: PLEX_URL
              value: "http://plex:32400"
            - name: SONARR_URL
              value: "http://sonarr:8989"
            - name: SONARR_API_KEY
              valueFrom:
                secretKeyRef:
                  name: arr-api-keys
                  key: sonarr-api-key
            - name: RADARR_URL
              value: "http://radarr:8989"
            - name: RADARR_API_KEY
              valueFrom:
                secretKeyRef:
                  name: arr-api-keys
                  key: radarr-api-key
            - name: POLL_INTERVAL
              value: "900"  # 15 minutes in seconds
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 512Mi
```

**Service & Ingress**:
- ClusterIP Service (optional, mainly for logging/monitoring)
- Ingress: `pulsarr.homelab`

**Secrets**:
Create encrypted secret with API keys:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: arr-api-keys
  namespace: media
type: Opaque
stringData:
  sonarr-api-key: "YOUR_SONARR_API_KEY"
  radarr-api-key: "YOUR_RADARR_API_KEY"
  plex-auth-token: "YOUR_PLEX_AUTH_TOKEN"
```

Then encrypt: `sops --encrypt --in-place pulsarr/secrets.yaml`

**Manual post-deploy**:
1. Add items to Plex watchlist
2. Wait up to 15 minutes for Pulsarr to poll watchlist
3. Check Sonarr/Radarr for new requests

**Verification**: 
- Add TV show to Plex watchlist → appears in Sonarr within 15 min
- Check Pulsarr logs: `kubectl logs deployment/pulsarr -n media`

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                   Kubernetes Cluster (k3s)                      │
│ ┌──────────────────────────────────────────────────────────────┐│
│ │ Media Namespace                                              ││
│ │                                                              ││
│ │ ┌─────────────────────────────────────────────────────────┐ ││
│ │ │ Storage Nodes (w1/w2) - Active-Passive HA              │ ││
│ │ │  ┌────────────┐  ┌────────────┐  ┌───────────────┐    │ ││
│ │ │  │ Sonarr *   │  │ Radarr *   │  │ Decypharr *   │    │ ││
│ │ │  │ (Longhorn) │  │ (Longhorn) │  │ (Longhorn +   │    │ ││
│ │ │  │            │  │            │  │  hostPath FUSE│    │ ││
│ │ │  └────────────┘  └────────────┘  │ + rclone-nfs) │    │ ││
│ │ │  Pod affinity: co-located +      └───────────────┘    │ ││
│ │ │   node affinity to w1 (primary)   ↓ NFS export        │ ││
│ │ │                                    Service: decypharr  │ ││
│ │ │  ┌────────────┐  ┌─────────────┐ -nfs (port 2049)    │ ││
│ │ │  │ Prowlarr * │  │ Profilarr * │  ┌──────────────┐   │ ││
│ │ │  │ (Longhorn) │  │ (Longhorn)  │  │ Plex *       │   │ ││
│ │ │  │            │  │             │  │ (Longhorn +  │   │ ││
│ │ │  └────────────┘  └─────────────┘  │  NFS media)  │   │ ││
│ │ │  * = StatefulSet (HA via descheduler failback)        │ ││
│ │ │  Plex: Co-located w/ storage stack (w1 primary, w2 failover)││
│ │ └─────────────────────────────────────────────────────────┘ ││
│ │                                                              ││
│ │ ┌─────────────────────────────────────────────────────────┐ ││
│ │ │ GPU Node (w3) - Transcoding Only                        │ ││
│ │ │  ┌──────────────────────────────────────────────────┐  │ ││
│ │ │  │ ClusterPlex Worker (w3 GPU)                     │  │ ││
│ │ │  │ - intel.com/gpu: 1                             │  │ ││
│ │ │  │ - Mounts:                                      │  │ ││
│ │ │  │   • /mnt/dfs (NFS) → decypharr-nfs (RO)       │  │ ││
│ │ │  │   • /mnt/streaming-media (Longhorn RWX, RO)   │  │ ││
│ │ │  │   • /mnt/media (Unraid NFS, RO)               │  │ ││
│ │ │  │   • /mnt/transcode (Unraid NFS, RW)           │  │ ││
│ │ │  │ ✅ Can transcode streaming + permanent        │  │ ││
│ │ │  └──────────────────────────────────────────────────┘  │ ││
│ │ └─────────────────────────────────────────────────────────┘ ││
│ │                                                              ││
│ │ ┌─────────────────────────────────────────────────────────┐ ││
│ │ │ Stateless Services                                      │ ││
│ │ │  ┌────────────────────┐  ┌──────────────────────┐      │ ││
│ │ │  │Pulsarr (Deployment)│  │ClusterPlex          │      │ ││
│ │ │  │- No PVC            │  │Orchestrator         │      │ ││
│ │ │  │- Syncs watchlists  │  │LoadBalancer svc     │      │ ││
│ │ │  └────────────────────┘  │port 3500            │      │ ││
│ │ │                           └──────────────────────┘      │ ││
│ │ └─────────────────────────────────────────────────────────┘ ││
│ └──────────────────────────────────────────────────────────────┘│
│                                                                  │
│ ┌──────────────────────────────────────────────────────────────┐│
│ │ External Storage (Not in K8s)                                ││
│ │  ┌─────────────────────┐    ┌──────────────────────────┐    ││
│ │  │ Unraid NFS Server   │    │ RealDebrid / Usenet      │    ││
│ │  │ /mnt/media (RO)     │◄───┤ (via Decypharr)          │    ││
│ │  │ /mnt/transcode (RW) │    │                          │    ││
│ │  └─────────────────────┘    └──────────────────────────┘    ││
│ │                                                              ││
│ │  Optional: Docker Worker on Unraid (external ClusterPlex)   ││
│ └──────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘

## Mount Path Strategy (Key to Flexibility)

All pods standardize on `/mnt/dfs` mount point:
- **Decypharr**: Direct FUSE mount at `/mnt/dfs` (pod creates symlinks here)
- **Sonarr/Radarr**: NFS mount to `decypharr-nfs.media.svc:` at `/mnt/dfs` 
- **Plex**: NFS mount to `decypharr-nfs.media.svc:` at `/mnt/dfs`
- **ClusterPlex Worker**: NFS mount to `decypharr-nfs.media.svc:` at `/mnt/dfs`

**Result**: Symlinks created by Decypharr resolve identically across all nodes:
```
Symlink: /mnt/streaming-media/TV/Show/S01E01.mkv → /mnt/dfs/file.mkv
         ↓ works from w1 (FUSE), w2 (NFS), w3 (NFS)
```

This unified approach eliminates the need for strict pod co-location while maintaining HA failover capability.

## Data Flows
1. User adds show to Plex watchlist → Pulsarr detects → requests in Sonarr (tagged "streaming")
2. Sonarr searches Prowlarr → finds torrent → sends to Decypharr
3. Decypharr downloads from RealDebrid → stores in /mnt/dfs (FUSE mount)
4. **Decypharr's rclone-nfs-server sidecar exposes /mnt/dfs as NFS** (read-only on port 2049)
5. Decypharr creates symlinks → /mnt/streaming-media/TV Shows/Show/S01E01.mkv → /mnt/dfs/file.mkv
6. Sonarr/Radarr rename/organize those symlinks in /mnt/streaming-media
7. Plex reads from ONE library with multiple roots (/mnt/streaming-media + /mnt/media) → resolves symlinks → serves from cloud cache
8. **When transcoding needed**: ClusterPlex Orchestrator dispatches job to w3 worker → worker reads file from /mnt/streaming-media or /mnt/media → transcodes with Intel GPU → writes output to /mnt/transcode (Unraid NFS)
9. User watches content, decides if worth keeping permanently

Data Flow (Manual Upgrade: Streaming → Permanent):
1. User changes show's root folder in Sonarr (streaming → permanent)
2. Sonarr triggers "Move Files" → copies from /mnt/dfs to /mnt/media (NFS)
3. **Manual cleanup**: Delete streaming symlinks (`rm -rf /mnt/streaming-media/TV Shows/<ShowName>`)
4. Plex rescans library → updates to /mnt/media path, removes duplicate entry
5. Original DFS cache expires naturally (no action needed, symlink now broken)
6. Show now served from permanent NFS storage

Data Flow (Cache Expiration without Upgrade):
1. DFS cache expires (Decypharr/RealDebrid cleanup after X days)
2. Symlink becomes broken (target file missing)
3. Plex shows "unavailable" for that content
4. Options: Re-download (Sonarr re-search), or manually upgrade to permanent
```

---

## Critical Gotchas & Mitigations

### Gotcha 0: Standardized Mount Path Strategy Solves Symlink Resolution Across Nodes

**Key Insight**: 
By mounting the DFS cache at the **same path `/mnt/dfs`** across all pods (whether direct FUSE or NFS), symlinks resolve identically regardless of node placement:

```
Decypharr (pod on w1):              Plex (pod on w3):              Sonarr (pod on w1):
/mnt/dfs/file.mkv                   /mnt/dfs/file.mkv             /mnt/dfs/file.mkv
  ↓ FUSE mount                        ↓ NFS mount                   ↓ FUSE mount
  Direct access                      Via rclone-nfs-server        Direct access
  Same symlink target: /mnt/dfs/file.mkv ✅ Works!
```

**Why This Works**:
- Decypharr: Creates symlinks pointing to `/mnt/dfs/file.mkv`
- All other pods: Mount NFS service at same path `/mnt/dfs` → symlink targets resolve
- Mount backend (FUSE vs NFS) is transparent to applications

**Implication for Deployment Architecture**:
- ✅ **Plex runs on w1/w2 storage nodes**: Co-located with Decypharr/Sonarr/Radarr for HA symmetry
- ✅ **All mounts via NFS**: Even though Plex is co-located, all mounts are NFS-based (not FUSE)
- ✅ **w3 reserved for GPU**: ClusterPlex Worker on w3 handles all GPU transcoding requests
- ✅ **Flexibility at architecture level**: Mount standardization allows easy redesign if needed (e.g., co-location is optional, not required)

**Verification**:
- Test symlink resolution from different nodes:
  ```bash
  # From Plex pod (any node)
  kubectl exec plex-0 -n media -- readlink -f /mnt/streaming-media/TV/Show/S01E01.mkv
  # Should show: /mnt/dfs/file.mkv ✅
  
  # From Sonarr pod (any node)
  kubectl exec sonarr-0 -n media -- readlink -f /mnt/streaming-media/TV/Show/S01E01.mkv
  # Should show: /mnt/dfs/file.mkv ✅
  ```

**HA Failover Testing**:
```bash
# Drain w1 → pods on w1 move to w2
kubectl drain k3s-w1 --ignore-daemonsets --delete-emptydir-data

# Verify Decypharr moved to w2
kubectl get pods -n media decypharr-0 -o wide
# Should show NODE: k3s-w2

# Verify NFS service still reachable from any pod
kubectl exec plex-0 -n media -- ls -la /mnt/dfs | head
# Should show DFS files (NFS service IP updated automatically) ✅

# Restore w1
kubectl uncordon k3s-w1

# Pods can migrate back (descheduler) but NOT required for functionality
kubectl get pods -n media -o wide
# Plex remains on w2 or wherever it is—symlinks still resolve via NFS ✅
```

### Gotcha 1: Sonarr/Radarr Do NOT Support Root Folder → Download Client Binding

**Problem**: 
- You cannot configure: "All shows in root folder A → always use download client X"
- Download client selection is GLOBAL, not per-root-folder or per-show
- Root folders are purely for **file organization**, not content routing

**Important Finding**: 
- Sonarr/Radarr use **indexer-based download client assignment** (not root folder-based)
- Each indexer can be assigned a specific download client (advanced setting per indexer)
- Use **tags** to control which shows search which indexers

**Solution**: Indexer + Tag Routing
```yaml
Prowlarr Indexers:
  - Decypharr Torrents → Download Client: Decypharr → Tag: "streaming"
  - SABnzbd Usenet → Download Client: SABnzbd → Tag: "downloads"

Sonarr Shows:
  - Tag "streaming" → Only searches Decypharr indexer → Decypharr client used
  - Tag "downloads" → Only searches SABnzbd indexer → SABnzbd client used
```

**Why this matters**:
- Single Decypharr instance can handle BOTH streaming (fast access) and download (archive) workloads
- Routing happens at **indexer level**, not download folder level
- Root folders remain for file organization (e.g., `/TV Shows` vs `/Movies`)
- Shows in same root folder can use different download clients (via tags)

**Verification**:
- Tag a show "streaming" → search produces results from Decypharr indexers only
- Untag and search → might find results from other indexers (based on priority)
- Download should route to Decypharr (priority 1) for streams, SABnzbd (priority 2) for fallback

---

### Gotcha 1: rclone NFS Sidecar is the Primary Mitigation for Cross-Node Access

**Problem Solved**: 
- FUSE mounts are process-specific and per-node (can't cross nodes)
- Direct FUSE access to Decypharr DFS from remote pods fails
- ClusterPlex workers on w3 (GPU node) need DFS access for streaming transcodes
- Sonarr/Radarr/Plex need consistent `/mnt/dfs` mount path across nodes

**Mitigation: rclone NFS Server Sidecar**:
- **Decypharr StatefulSet includes `rclone-nfs-server` sidecar** (port 2049)
- Sidecar exposes Decypharr's FUSE mount as read-only NFS share
- All pods mount `decypharr-nfs.media.svc.cluster.local:/` at `/mnt/dfs` (Kubernetes Service DNS automatically routes to current Decypharr pod)
- Effect: **All pods see identical `/mnt/dfs` path** regardless of node or mount backend
- Benefit: Symlinks work identically across w1, w2, w3 (NFS mount vs direct FUSE is transparent)

**Optional Optimizations** (not required for correctness):
1. **Pod Affinity** (Decypharr/Sonarr/Radarr only): Co-locate on w1 for direct FUSE access
   - Effect: Frequent file operations avoid NFS overhead during imports
   - Performance benefit only, not correctness requirement
2. **Init Container Ordering** (Sonarr/Radarr): Wait for Decypharr readiness probe
   - Effect: Guarantees rclone-nfs-server is serving before other pods mount
   - Best practice for startup reliability

**Test failover** (Storage stack failover with HA symmetry):
```bash
# Simulate w1 failure → all storage pods move together to w2
kubectl drain k3s-w1 --ignore-daemonsets --delete-emptydir-data

# Verify all storage apps migrated to w2
kubectl get pods -n media -o wide | grep -E "decypharr|sonarr|radarr|plex"
# All should show NODE: k3s-w2

# Verify NFS service reachable (auto-redirected to w2 Decypharr pod)
kubectl exec plex-0 -n media -- ls /mnt/dfs | head
# Should show DFS files (Service DNS updated) ✅

# Verify imports still work from w2
kubectl exec sonarr-0 -n media -- ls /mnt/streaming-media | head
# Should show streaming library (all mounts work on w2) ✅

# Restore w1
kubectl uncordon k3s-w1

# Wait 5min for descheduler to migrate pods back to w1 (preferred node)
kubectl get pods -n media -o wide -w

# Verify all storage apps back on w1
kubectl get pods -n media -o wide | grep -E "decypharr|sonarr|radarr|plex"
# All should show NODE: k3s-w1 ✅
# Symlinks continue working throughout migration (NFS transparent) ✅
```

### Gotcha 2: Prowlarr API Chicken-Egg Problem

**Problem**: 
- Prowlarr needs Sonarr/Radarr API keys to configure app sync
- But API keys are generated at first Sonarr/Radarr startup
- Can't automate without having keys first

**Mitigation**:
1. Deploy Sonarr/Radarr FIRST (Phase 2)
2. Extract API keys manually (Settings UI or Kubernetes secret)
3. Store in 1Password + encrypted secret in Git
4. Deploy Prowlarr SECOND (Phase 3) with keys in environment
5. Configure app sync via Prowlarr UI or init Job

**Automation Option (Future)**: Two-phase init Job could automate this, but not worth complexity for one-time setup.

### Gotcha 3: Hardlinks Don't Work with Cloud Storage

**Problem**: 
- Sonarr defaults to "Use Hardlinks" for copy-on-import
- Hardlinks require same filesystem
- Cloud mounts (FUSE via Decypharr) are separate filesystem
- Result: Import fails silently or takes impossibly long

**Mitigation**:
- **Disable hardlinks** in Sonarr/Radarr:
  - Settings → Media Management → untick "Use Hard Links instead of Copy"
- Trade-off: Copy mode uses 2x storage temporarily but is reliable
- Remember: NFS from Unraid might also not support hardlinks (verify with `df -T`)

### Gotcha 4: ClusterPlex LoadBalancer IP Unknown at Deploy Time

**Problem**: 
- Workers need `ORCHESTRATOR_URL=http://<IP>:3500`
- MetalLB assigns LoadBalancer IP only AFTER deployment
- Pod environment vars set at deploy time → workers missing orchestrator URL

**Solution**:
1. Deploy Orchestrator first → wait for LoadBalancer IP
2. Write IP to ConfigMap or note it
3. Deploy workers with correct `ORCHESTRATOR_URL`

**Example**:
```bash
# After deploying Orchestrator
kubectl get svc clusterplex-orchestrator -n media -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Note IP (e.g., 192.168.100.101)

# Update worker Deployment with IP
# Then deploy or update workers
```

### Gotcha 5: GPU Passthrough Requires Privileged LXC

**Problem**: 
- w3 runs in Proxmox LXC (not VM)
- Unprivileged LXC can't access `/dev/dri`
- GPU Device Plugin sees no GPU → workers can't allocate GPU resource

**Mitigation**:
- Verify LXC is **privileged**: `lxc.restricted = 0` in Proxmox config
- Add GPU cgroup: `lxc.cgroup2.devices.allow: c 226:* rwm`
- Mount GPU device: `lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir`
- Verify: `kubectl describe node k3s-w3 | grep intel.com/gpu`
  - Should show resource available

### Gotcha 6: SOPS Age Key Loss = Unrecoverable Secrets

**Problem**: 
- If age private key lost, all encrypted secrets permanently unrecoverable
- No way to decrypt without key
- Must regenerate ALL API keys, credentials

**Mitigation - Backup Strategy**:
1. **Auto-backup to 1Password** (encrypted, cloud-synced):
   - Copy `age.key` content
   - Create 1Password Secure Note: "Age Encryption Key Backup"
   - Add to both personal vault + team vault if shared

2. **Offline backup to encrypted USB**:
   - Store encrypted USB in physical location
   - Verify annually

3. **Printed QR code in safe** (extreme, but useful):
   - QR encodes `age.key` text
   - Survives all-digital failures

4. **Plaintext fallback** (separate from age key):
   - Store plaintext copy of critical secrets in 1Password
   - Different vault/note from age key
   - If key lost, can manually recreate without re-authenticating everywhere

**Test recovery quarterly**:
```bash
# Simulate key loss
rm age.key

# Try to decrypt → should fail
sops -d sonarr/secrets.yaml
# Error: can't find key

# Restore from 1Password backup
# Retry decrypt → should succeed
```

**Recovery document** (`docs/SECRETS_RECOVERY.md`):
```markdown
## Age Key Loss Recovery

### If age.key lost:
1. Retrieve from 1Password Secure Note "Age Encryption Key Backup"
2. Save locally: `cp age-backup.txt age.key`
3. Verify: `sops -d clusters/homelab/apps/media/sonarr/secrets.yaml`

### If all backups lost:
1. Regenerate all API keys (Sonarr, Radarr, Prowlarr, Plex, Debrid, Usenet)
2. Generate new age key: `age-keygen -o age-new.key`
3. Update `.sops.yaml` with new public key
4. Re-encrypt all secrets: `find . -name '*secrets.yaml' -exec sops updatekeys {} \;`
5. Commit and push to Git

### Prevents future loss:
- Commit `age-new.key` to 1Password, encrypted USB immediately
```

### Gotcha 7: Prowlarr Initial Sync Takes 10-15 Minutes

**Problem**: 
- After configuring Prowlarr app sync to Sonarr/Radarr
- Indexers don't immediately appear in Sonarr/Radarr
- May appear to not work

**Mitigation**:
- **Wait 10-15 minutes** for initial sync (Prowlarr queries each indexer)
- **Force sync** via Prowlarr UI: Settings → Apps → (app name) → Test & Save
- **Check logs**: `kubectl logs prowlarr-0 -n media | grep -E "Sync|completed"`
  - `Sync.*completed` message indicates sync finished
- **Verify**: Sonarr/Radarr Settings → Indexers should list Prowlarr-backed indexers

### Gotcha 8: Descheduler Auto-Failback May Disrupt During Maintenance

**Problem**: 
- When w1 recovers from maintenance, descheduler automatically evicts pods from w2
- If pods mid-import, eviction interrupts the job
- Results in failed imports or stuck downloads

**Mitigation**:
- Document procedure for scheduled maintenance:
  1. Check import queue: `kubectl logs sonarr-0 -n media | grep -i import`
  2. Wait for active imports to complete
  3. Scale descheduler: `kubectl scale deploy descheduler -n kube-system --replicas=0`
  4. Perform maintenance on w1
  5. Restore descheduler: `kubectl scale deploy descheduler -n kube-system --replicas=1`
- Alternative: Let failback happen (pods restart, resume downloads fresh)

### Gotcha 9: NFS Timeout During Failover

**Problem**: 
- Unraid NFS is single point of failure
- If Unraid NFS unreachable during w1→w2 failover
- Sonarr/Radarr hang on NFS unmount/remount

**Mitigation**:
- NFS mount options: `nfsvers=4,soft,timeo=10,retrans=2`
  - `soft`: Don't hang forever on timeout
  - `timeo=10,retrans=2`: Faster failure detection
- Monitor NFS: `df -h /mnt/media` on each pod
- If NFS fails: Pods remain runnable but can't import
  - Acceptable for homelab (Unraid SPOF is acceptable per your design)

### Gotcha 10: Profilarr Manual Sync Means Settings Drift

**Problem**: 
- Profilarr doesn't auto-sync like Recyclarr would
- If TRaSH Guides update and you forget to sync
- Sonarr/Radarr profiles get stale

**Mitigation**:
- Set calendar reminder: Monthly check of Profilarr
- Document in personal notes/wiki
- Verify: Check Profilarr for "Updates Available" banner
- Quarterly: Expect major TRaSH Guides updates

---

## Verification Checklist

### Per-Tier Validation

**Tier 1: Foundation**
- [ ] SOPS age key backed up in 3 locations (1Password, USB, printed QR)
- [ ] `.sops.yaml` in repo root with public key
- [ ] Flux kustomizations configured for SOPS decryption
- [ ] NFS PVCs bound: `kubectl get pvc -n media | grep nfs`
- [ ] Symlink library PVC bound: `kubectl get pvc -n media symlink-library`

**Tier 2: *Arr Apps**
- [ ] Sonarr pod running on w1: `kubectl get pod sonarr-0 -n media -o wide`
- [ ] Sonarr PVC bound: `kubectl get pvc config-sonarr -n media`
- [ ] Sonarr ingress working: `curl http://sonarr.homelab/health` → 200
- [ ] Sonarr API key extracted and encrypted in Secret
- [ ] Radarr pod running, API key extracted (repeat verification)
- [ ] Prowlarr pod running, indexers synced to Sonarr/Radarr:
  - [ ] `kubectl logs prowlarr-0 -n media | grep "Sync.*completed"`
  - [ ] Sonarr: Settings → Indexers shows "Prowlarr" indexers
  - [ ] Radarr: Settings → Indexers shows "Prowlarr" indexers
- [ ] Profilarr pod running, connected to Sonarr/Radarr APIs

**Tier 3: Decypharr & Symlink Library**
- [ ] Decypharr pod running on w1 with 2 containers: `kubectl get pod decypharr-0 -n media -o jsonpath='{.status.containerStatuses[*].name}'` → should show "decypharr rclone-nfs-server"
- [ ] Decypharr pod affinity label: `kubectl get pod decypharr-0 -n media -o jsonpath='{.metadata.labels.streaming-stack}'` → should show "true"
- [ ] Decypharr FUSE mount visible: `kubectl exec decypharr-0 -c decypharr -n media -- mount | grep fuse`
- [ ] Streaming media library writable from Decypharr: `kubectl exec decypharr-0 -c decypharr -n media -- test -w /mnt/streaming-media && echo "OK"`
- [ ] **rclone-nfs-server sidecar running**: `kubectl logs decypharr-0 -c rclone-nfs-server -n media --tail=10` → should show "Serving nfs://"
- [ ] **NFS service reachable**: `kubectl get svc decypharr-nfs -n media` → should show ClusterIP
- [ ] **NFS export accessible from worker**: `kubectl exec deployment/clusterplex-worker -n media -- ls /mnt/dfs | head` → should show DFS files
- [ ] Sonarr init container waiting for DFS:
  - [ ] `kubectl logs sonarr-0 -n media -c wait-for-decypharr-dfs` shows "ready"
- [ ] DFS accessible from Sonarr: `kubectl exec sonarr-0 -n media -- ls -la /mnt/dfs`
- [ ] Streaming media readable from Sonarr: `kubectl exec sonarr-0 -n media -- ls -la /mnt/streaming-media`
- [ ] Sonarr download client configured for Decypharr (Settings → Download Clients)
- [ ] Hardlinks disabled: `kubectl exec sonarr-0 -n media -- grep -i hardlink /config/config.xml` → should not find "true"

**Tier 4: Plex & ClusterPlex**
- [ ] Plex pod running on w1 (same as Decypharr/Sonarr/Radarr): `kubectl get pod plex-0 -n media -o wide`
- [ ] Plex pod affinity label: `kubectl get pod plex-0 -n media -o jsonpath='{.metadata.labels.streaming-stack}'` → should show "true"
- [ ] Plex ingress accessible: `curl http://plex.homelab/identity` → 200
- [ ] Plex can read permanent media: `kubectl exec plex-0 -n media -- ls /mnt/media | head -1` → should show media folders
- [ ] Plex can read streaming media: `kubectl exec plex-0 -n media -- ls /mnt/streaming-media | head -1` → should show folders or be empty (OK if empty initially)
- [ ] Plex can read DFS: `kubectl exec plex-0 -n media -- test -d /mnt/dfs && echo "DFS accessible"` (for testing symlink targets)
- [ ] Intel GPU Device Plugin running: `kubectl get daemonset -n kube-system intel-gpu-plugin`
- [ ] GPU resource visible on w3: `kubectl describe node k3s-w3 | grep intel.com/gpu`
- [ ] ClusterPlex Orchestrator LoadBalancer has IP: `kubectl get svc clusterplex-orchestrator -n media`
- [ ] ClusterPlex worker running on w3: `kubectl get pod clusterplex-worker-0 -n media -o wide`
- [ ] Worker registered: `kubectl logs deployment/clusterplex-worker -n media | grep -i "orchestrator\|worker"`

**Tier 5: Streaming Integration**
- [ ] Search test in Sonarr → finds results (via Prowlarr indexers)
- [ ] Download test: Search → Download → Appears in DFS mount (/mnt/dfs)
- [ ] Symlink test: Decypharr creates symlinks in `/mnt/streaming-media`
  - [ ] `kubectl exec sonarr-0 -n media -- find /mnt/streaming-media -type l | head -1` → should show symlink paths
- [ ] Import test: Sonarr/Radarr organize symlinks without errors
- [ ] Plex streaming test: Play show from `/mnt/streaming-media` library → should stream from cloud cache
- [ ] Plex permanent test: Play show from `/media` library → plays from NFS
- [ ] **Transcode test (streaming content)**: Play 4K video from `/mnt/streaming-media` library → ClusterPlex worker transcodes (GPU utilized)
  - [ ] Verify worker reads from NFS: `kubectl logs deployment/clusterplex-worker -n media | grep -i "file.*open"`
  - [ ] Verify GPU usage on w3: `kubectl exec deployment/clusterplex-worker -n media -- cat /sys/class/drm/card0/engine/rcs0/busy` (should show >0)
- [ ] **Transcode test (permanent content)**: Play 4K video from `/media` library → also transcodes on w3
- [ ] Pulsarr test: Add show to Plex watchlist → appears in Sonarr within 15 min

### HA Failover Testing (Streaming-Stack Co-Location)

- [ ] **w1 Failure Scenario**:
  - All four pods (Decypharr, Sonarr, Radarr, Plex) evicted → reschedule to w2 within 60s
  - Verify all four co-located on w2: `kubectl get pods -n media -o wide | grep -E "sonarr|radarr|decypharr|plex"` (all showing "k3s-w2")
  - FUSE mount re-established on w2: `kubectl exec decypharr-0 -n media -- mount | grep fuse`
  - Symlinks resolve from Plex on w2: `kubectl exec plex-0 -n media -- ls -la /mnt/streaming-media/`
  - Streaming continues to work
  
- [ ] **w1 Recovery Scenario**:
  - w1 comes online
  - Descheduler detects streaming-stack pods violating affinity (prefer w1)
  - Evicts all four pods from w2 → reschedule to w1 within 5min
  - Verify migration: `kubectl get pods -n media -o wide -w` (watch all pods transition to w1)
  - FUSE mount moves back to w1
  - Symlinks resolve again
  
- [ ] **w3 Failure Scenario**:
  - ClusterPlex worker stops (GPU node)
  - Streaming continues (Plex still serves from cloud cache)
  - Transcode unavailable (expected, no GPU failover)
  - Plex serves with software transcode (slow, but functional)
  
- [ ] **Unraid Failure Scenario**:
  - NFS unmount with timeout (5-10s per `soft` option)
  - Streaming continues (Plex serves from `/mnt/streaming-media`)
  - Permanent library unavailable (Plex can't read `/media`)
  - (This is acceptable per architecture - Unraid is SPOF)

---

## File Structure

```
clusters/homelab/apps/media/
├── kustomization.yaml                    (UPDATE - add new apps)
├── namespace.yaml                        (✅ exists)
├── sonarr/
│   ├── statefulset.yaml                  (UPDATE - add Decypharr init container, pod affinity)
│   ├── service.yaml                      (✅ exists)
│   ├── service-headless.yaml             (✅ exists)
│   ├── ingress.yaml                      (✅ exists)
│   ├── pvc-config.yaml                   (NEW - Longhorn 10Gi)
│   ├── kustomization.yaml                (UPDATE)
│   └── secrets.yaml                      (NEW - SOPS-encrypted API key)
├── radarr/
│   ├── statefulset.yaml                  (NEW - same as sonarr with Decypharr init)
│   ├── service.yaml                      (NEW)
│   ├── service-headless.yaml             (NEW)
│   ├── ingress.yaml                      (NEW)
│   ├── pvc-config.yaml                   (NEW - Longhorn 10Gi)
│   ├── kustomization.yaml                (NEW)
│   └── secrets.yaml                      (NEW - SOPS-encrypted API key)
├── prowlarr/
│   ├── statefulset.yaml                  (✅ exists, UPDATE - add pod affinity/init for ordering)
│   ├── service.yaml                      (✅ exists)
│   ├── service-headless.yaml             (✅ exists)
│   ├── ingress.yaml                      (✅ exists)
│   ├── pvc-config.yaml                   (NEW - Longhorn 5Gi)
│   ├── kustomization.yaml                (UPDATE)
│   └── secrets.yaml                      (NEW - if using API automation)
├── profilarr/
│   ├── statefulset.yaml                  (NEW)
│   ├── service.yaml                      (NEW)
│   ├── ingress.yaml                      (NEW)
│   ├── pvc-config.yaml                   (NEW - Longhorn 2Gi)
│   ├── kustomization.yaml                (NEW)
│   └── secrets.yaml                      (NEW - SOPS-encrypted Sonarr/Radarr API keys)
├── decypharr/
│   ├── statefulset.yaml                  (NEW - with FUSE/hostPath, pod affinity, init container signals)
│   ├── service.yaml                      (NEW - ClusterIP port 8080)
│   ├── ingress.yaml                      (NEW)
│   ├── pvc-config.yaml                   (NEW - Longhorn 5Gi)
│   ├── kustomization.yaml                (NEW)
│   └── secrets.yaml                      (NEW - SOPS-encrypted RealDebrid + Usenet creds)
├── plex/
│   ├── statefulset.yaml                  (NEW - with ClusterPlex dockermod)
│   ├── service.yaml                      (NEW - LoadBalancer via MetalLB)
│   ├── ingress.yaml                      (NEW)
│   ├── pvc-config.yaml                   (NEW - Longhorn 50Gi)
│   ├── kustomization.yaml                (NEW)
│   └── secrets.yaml                      (NEW - SOPS-encrypted Plex claim token)
├── clusterplex/
│   ├── orchestrator-deployment.yaml      (NEW)
│   ├── orchestrator-service.yaml         (NEW - LoadBalancer port 3500)
│   ├── worker-deployment.yaml            (NEW - GPU node, w3 only)
│   ├── kustomization.yaml                (NEW)
│   └── README.md                         (NEW - ClusterPlex architecture notes)
├── pulsarr/
│   ├── deployment.yaml                   (NEW - stateless)
│   ├── service.yaml                      (NEW - ClusterIP optional)
│   ├── ingress.yaml                      (NEW - optional, mainly for health monitoring)
│   ├── kustomization.yaml                (NEW)
│   └── secrets.yaml                      (NEW - SOPS-encrypted API keys)
├── nfs/
│   ├── pvc-media.yaml                    (✅ exists, verify RO setup)
│   ├── pvc-transcode.yaml                (NEW - RW transcode cache for ClusterPlex)
│   └── kustomization.yaml                (UPDATE)
├── storage/
│   ├── pvc-symlink-library.yaml          (NEW - Longhorn 100Mi, RW for symlinks)
│   └── kustomization.yaml                (UPDATE)
└── README.md                             (NEW - Media stack deployment overview)

clusters/homelab/infrastructure/
├── gpu-device-plugin/
│   ├── daemonset.yaml                    (NEW - Intel GPU plugin)
│   ├── kustomization.yaml                (NEW)
│   └── README.md                         (NEW - GPU troubleshooting)
└── kustomization.yaml                    (UPDATE - add gpu-device-plugin)

docs/
├── MEDIA_STACK_IMPLEMENTATION_PLAN.md    (THIS FILE - saved as reference)
├── SECRETS_MANAGEMENT.md                 (NEW - SOPS setup + recovery procedure)
├── DECYPHARR_DFS_SETUP.md               (NEW - FUSE mount troubleshooting guide)
├── CLUSTERPLEX_ARCHITECTURE.md          (NEW - GPU transcoding reference)
├── SECRETS_RECOVERY.md                   (NEW - age key loss recovery playbook)
└── PROFILARR_QUALITY_PROFILES.md        (NEW - TRaSH Guides integration reference)

.sops.yaml                                (NEW - repo root SOPS configuration)
```

---

## Implementation Order (Recommended)

1. **Before any pods**: SOPS setup (Phase 1), test with dummy secret
2. **Parallel streams**:
   - Sonarr/Radarr StatefulSets + PVCs (Phase 2)
   - Prowlarr StatefulSet + PVCs (Phase 3)
3. **After *arr apps running**: Extract API keys, configure Prowlarr sync
4. **Then**: Decypharr StatefulSet (Phase 4)
5. **After Decypharr mounts**: Update Sonarr/Radarr init containers, configure download clients
6. **Once downloads working**: Deploy Plex + ClusterPlex (Phase 7)
7. **Finally**: Profilarr setup (manual process) + Pulsarr deployment (Phase 6 & 8)

---

## Key Design Decisions

| Decision | Rationale | Trade-off |
|----------|-----------|-----------|
| **Decypharr as separate pod** (not sidecar) | Single DFS mount shared by Sonarr/Radarr; efficient; can restart independently | More complex pod affinity & init container logic |
| **Pod affinity for co-location** | Ensures all three move together on failover → DFS mount doesn't get stuck on wrong node | Reduced flexibility; pods restricted to same node |
| **Init container ordering** | Guarantees Decypharr mounts before Sonarr/Radarr start → avoids import-path-not-found errors | Added pod startup complexity |
| **SOPS with age** | Flux-native, lightweight, no external deps | Manual key backup required; no UI for key rotation |
| **Profilarr (manual) not Recyclarr (auto)** | User preference; UI-based control; flexible | Requires quarterly manual sync; potential profile drift |
| **ClusterPlex on w3 + optional Unraid worker** | Distributed GPU transcoding; keeps main PMS on storage node; redundancy option | GPU node isolation; more infrastructure to manage |
| **NFS for media (Unraid SPOF)** | Existing setup; proven; acceptable for homelab | No media redundancy; Unraid failure = no playback |

---

## Future Enhancements (Out of Scope)

1. **Longhorn backup to Unraid**: Scheduled sync of config PVCs for long-term storage
2. **External Docker worker on Unraid**: GPU redundancy if w3 fails (documented separately)
3. **Prometheus/Grafana**: Metrics exporters for *arr apps + transcoding visualization
4. **Notification webhooks**: Discord/Slack alerts for downloads/imports/transcoding errors
5. **Additional *Arr apps**: Lidarr (music), Readarr (books), Bazarr (subtitles)
6. **Automated Prowlarr indexer setup**: Init Job to configure indexers via API (complex chicken-egg problem)
7. **Custom operator for *Arr stack**: GitOps-native controller for config management (out of scope for homelab)

---

## Success Criteria

**Phase 2 Complete**: Sonarr/Radarr running, API keys extracted ✓  
**Phase 3 Complete**: Prowlarr synced to Sonarr/Radarr, indexers visible ✓  
**Phase 4 Complete**: Decypharr DFS mount accessible to all three pods ✓  
**Phase 5 Complete**: End-to-end download+import test successful ✓  
**Phase 6 Complete**: Profilarr quality profiles synced to Sonarr/Radarr ✓  
**Phase 7 Complete**: Plex library visible, ClusterPlex worker transcoding ✓  
**Phase 8 Complete**: Pulsarr watchlist sync working ✓  
**HA Testing Complete**: w1 failover/failback tested, all pods move together ✓  

---

## Support & Troubleshooting References

**Serarr Ecosystem**: https://wiki.servarr.com/  
**TRaSH Guides**: https://trash-guides.info/  
**Decypharr Docs**: https://sirrobot01.github.io/decypharr/beta/  
**ClusterPlex**: https://github.com/pabloromeo/clusterplex  
**Longhorn HA**: See [LONGHORN_HA_MIGRATION.md](LONGHORN_HA_MIGRATION.md)  
**Flux Secrets**: https://fluxcd.io/flux/security/  

---

**Document Version**: 1.0  
**Last Updated**: February 15, 2026  
**Status**: Ready for implementation  

Start with Phase 1 (SOPS setup). One phase per day is sustainable for homelab work. Good luck!
