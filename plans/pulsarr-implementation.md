# Pulsarr Implementation Plan

**Date**: February 28, 2026  
**Status**: Planning Phase  
**Target Deployment**: k3s + Flux v2, 2-node HA cluster (w1/w2 primary/backup)

---

## Executive Summary

Pulsarr is a **real-time Plex watchlist monitor** that automatically routes content to Sonarr/Radarr. Users add movies/shows to their Plex watchlist → pulsarr detects it → routes to *arr instances based on routing rules → content appears in Plex when downloaded.

**Result**: Complete media management stack without users leaving the Plex app.

---

## Architecture & Design Decisions

### Deployment Model

| Aspect | Decision | Rationale |
|--------|----------|-----------|
| **Platform** | k3s StatefulSet | Native cluster workload, Flux-managed, scalable |
| **Image** | Docker (`lakker/pulsarr:latest`) | Pre-built, maintained, no build overhead |
| **Instances** | Single admin (non-replicated) | Typical homelab use; one pulsarr instance monitors/routes |
| **Database** | SQLite (file-based, PVC) | Zero external dependencies, lightweight, ACID-compliant |
| **Storage Class** | `longhorn-simple` (RWO) | 1Gi, 2-node HA replication via Longhorn |
| **Node Placement** | w1 (primary) / w2 (failover) | Taint-tolerated storage nodes, HA affinity pattern |
| **Service Port** | Internal 3003 → External 80 | Matches pulsarr default port; Traefik routing convention |
| **Ingress** | `pulsarr.homelab` via Traefik | Local DNS resolution, consistent with sonarr/radarr/plex |
| **Notifications** | None initially | Discord/Apprise can be added post-validation |
| **Webhook Callback Address** | `http://pulsarr.media.svc.cluster.local:3003` | Cluster-internal, stable Service ClusterIP ensures HA resilience; survives pod failover |

### Why This Webhook Address?

Three options available:
1. **`http://pulsarr.media.svc.cluster.local:3003`** ← **Chosen** (most reliable for HA)
   - Service ClusterIP is stable across pod failures/failovers
   - Independent of external DNS, ingress, or network topology
   - Both Sonarr/Radarr and pulsarr are cluster-internal, no routing complexity
   - Aligns with your active-passive HA strategy
   - Failover (w1→w2): Service routing is transparent, no webhook URL change needed

2. `http://pulsarr.homelab` (external ingress)
   - Requires homelab DNS to route back into cluster
   - Adds external network hop; less resilient if ingress is unavailable
   - Works but not HA-optimal

3. `http://localhost:3003` (from Sonarr/Radarr pod perspective)
   - Only works if Sonarr and pulsarr are on same node; breaks on failover

---

## Pre-Implementation Checklist

### 1. Sonarr & Radarr Readiness
- [ ] Sonarr reachable; grab **API key** from Settings → General → Auth (bottom)
  - URL from cluster perspective: `http://sonarr.media.svc.cluster.local`
- [ ] Radarr reachable; grab **API key** from Settings → General → Auth
  - URL from cluster perspective: `http://radarr.media.svc.cluster.local`
- [ ] Both have at least one quality profile and root folder configured

### 2. Plex Server
- [ ] Plex server running and reachable (pulsarr pings it on startup)
- [ ] You have your Plex account credentials (email/password)
  - PIN auth will be done in-app during first-time setup, no pre-config needed

### 3. Cluster DNS
- [ ] `pulsarr.homelab` resolves to cluster ingress (should be auto-handled by Traefik)
- [ ] Internal cluster DNS `media.svc.cluster.local` works (verify with `nslookup` from any pod)

### 4. (Optional) TMDB Key
- Removed from requirements. Pre-built Docker image works without it.
- **Can be added later** if metadata enrichment is needed → Settings UI

---

## Manifest Structure

All files live in: `clusters/homelab/apps/media/pulsarr/`

```
pulsarr/
├── kustomization.yaml          # Orchestrates all resources + patches
├── statefulset.yaml            # Main workload
├── service.yaml                # ClusterIP service (port 80 → 3003)
├── service-headless.yaml       # Headless service for StatefulSet DNS
├── ingress.yaml                # Traefik ingress → pulsarr.homelab
└── configmap.yaml              # .env configuration
```

**Patches** (auto-applied from parent `media/kustomization.yaml`):
- `patches/ha-affinity.yaml` — Node affinity (require storage=enabled, prefer primary=true)
- `patches/statefulset-strategy.yaml` — OnDelete updates + OrderedReady pod mgmt
- `patches/disable-service-links.yaml` — `enableServiceLinks: false`

---

## Manifest Templates

### 1. `pulsarr/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: media

resources:
  - statefulset.yaml
  - service.yaml
  - service-headless.yaml
  - ingress.yaml
  - configmap.yaml

# Inherit HA patches from parent directory
patches:
  - path: ../patches/ha-affinity.yaml
    target:
      kind: StatefulSet
      name: pulsarr
  - path: ../patches/statefulset-strategy.yaml
    target:
      kind: StatefulSet
      name: pulsarr
  - path: ../patches/disable-service-links.yaml
    target:
      kind: StatefulSet
      name: pulsarr
```

### 2. `pulsarr/statefulset.yaml`

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pulsarr
  namespace: media
  labels:
    app: pulsarr
spec:
  serviceName: pulsarr-headless  # Links to headless service for stable DNS
  replicas: 1
  selector:
    matchLabels:
      app: pulsarr
  template:
    metadata:
      labels:
        app: pulsarr
        streaming-stack: "true"   # For pod affinity grouping with other media apps
    spec:
      securityContext:
        fsGroup: 1000
        runAsNonRoot: false
        runAsUser: 0
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: config-pulsarr-0  # Created by volumeClaimTemplate
        - name: config
          configMap:
            name: pulsarr-config
            items:
              - key: .env
                path: .env
      containers:
        - name: pulsarr
          image: lakker/pulsarr:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3003
              name: http
          env:
            # Load .env from ConfigMap
            - name: dataDir
              value: "/app/data"
          envFrom:
            - configMapRef:
                name: pulsarr-config
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          volumeMounts:
            - name: data
              mountPath: /app/data
            - name: config
              mountPath: /app/.env
              subPath: .env
          # Health probes: Omit until auth is configured
          # All endpoints return 401 until Plex account is linked via UI
      # Do NOT add affinity here — patches will inject it
  updateStrategy:
    type: OnDelete  # Prevents accidental restarts during deployments
  podManagementPolicy: OrderedReady
  volumeClaimTemplates:
    - metadata:
        name: config
        labels:
          app: pulsarr
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: longhorn-simple
        resources:
          requests:
            storage: 1Gi
```

### 3. `pulsarr/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pulsarr
  namespace: media
  labels:
    app: pulsarr
spec:
  selector:
    app: pulsarr
  ports:
    - port: 80
      targetPort: 3003
      protocol: TCP
      name: http
  type: ClusterIP
```

### 4. `pulsarr/service-headless.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: pulsarr-headless
  namespace: media
  labels:
    app: pulsarr
spec:
  selector:
    app: pulsarr
  ports:
    - port: 3003
      targetPort: 3003
      protocol: TCP
      name: http
  clusterIP: None  # Headless for StatefulSet DNS (pulsarr-0.pulsarr-headless.media.svc.cluster.local)
  type: ClusterIP
```

### 5. `pulsarr/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: pulsarr
  namespace: media
spec:
  ingressClassName: traefik
  rules:
    - host: pulsarr.homelab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: pulsarr
                port:
                  number: 80
```

### 6. `pulsarr/configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pulsarr-config
  namespace: media
  labels:
    app: pulsarr
data:
  .env: |
    # Core Configuration
    port=3003
    listenPort=3003
    baseUrl=http://pulsarr.media.svc.cluster.local:3003
    TZ=America/Chicago
    logLevel=info
    enableConsoleOutput=true
    enableRequestLogging=false
    
    # Authentication
    # Options: required (default), requiredExceptLocal, disabled
    authenticationMethod=requiredExceptLocal
    
    # Database (SQLite by default, lives in /app/data)
    # No extra config needed
    
    # Apprise (optional, add later if enabled)
    # appriseUrl=http://apprise:8000
    
    # Cookie Security (set true only if serving over HTTPS)
    cookieSecured=false
```

---

## Deployment Workflow

### Phase 1: Create Manifests
1. Create `clusters/homelab/apps/media/pulsarr/` directory
2. Write the 5 files above (kustomization.yaml, statefulset.yaml, service.yaml, service-headless.yaml, ingress.yaml, configmap.yaml)

### Phase 2: Integrate with Parent Kustomization
Update `clusters/homelab/apps/media/kustomization.yaml`:

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
  - ./plex
  - ./pulsarr  # ← Add this line
```

### Phase 3: Deploy via Flux
```bash
cd /Users/Chris/Source/GitOps
git add clusters/homelab/apps/media/pulsarr/
git add clusters/homelab/apps/media/kustomization.yaml
git commit -m "Add pulsarr Plex watchlist automation"
git push origin main

# Force immediate reconciliation
flux reconcile kustomization apps --with-source
```

### Phase 4: Verify Pod Startup
```bash
# Watch pod spin up (should take ~30s)
kubectl get pod -n media pulsarr-0 -w

# Monitor logs
kubectl logs -f -n media pulsarr-0

# Expected log output on first start:
#   [INFO] Pulsarr v0.x.x starting...
#   [INFO] Database initialized (SQLite)
#   [INFO] Server listening on port 3003
```

### Phase 5: Access Web UI
- **URL**: `http://pulsarr.homelab` (or `http://pulsarr.media.svc.cluster.local:3003` from inside cluster)
- **First-time setup wizard** will appear if database is empty

---

## Configuration & First-Time Setup

### Step 1: Authenticate with Plex
1. Web UI shows "Link Plex Account"
2. Click "Generate PIN"
3. Go to `https://plex.tv/link`
4. Enter the 4-character PIN
5. Scan QR code or click link
6. Grant pulsarr access
7. Confirm in pulsarr UI

### Step 2: Configure Sonarr Connection
1. Settings → Sonarr
2. Add instance:
   - **URL**: `http://sonarr.media.svc.cluster.local`
   - **Port**: `8989`
   - **API Key**: [paste from Sonarr Settings → General → Auth]
   - **Base Path**: Leave empty (or `/sonarr` if you have a reverse proxy path)
3. Click "Test" → should show green checkmark
4. **Webhook Configuration**:
   - If pulsarr shows "⚠️ Webhook Not Working", click "Fix"
   - pulsarr will auto-configure the webhook in Sonarr
   - This allows instant notifications when content is acquired

### Step 3: Configure Radarr Connection
- Same process as Sonarr
- Radarr URL: `http://radarr.media.svc.cluster.local`
- Radarr port: `7878`

### Step 4: (Optional) Set Up Routing Rules
- Default behavior: any content watched → sent to Sonarr (TV) or Radarr (movies)
- Advanced routing:
  - Route by **user** (different users → different instances)
  - Route by **genre** (e.g., anime → separate Sonarr)
  - Route by **rating** (kids → specific instance)
  - Require **approval** before acquiring
  - Set **quotas** (max 3 TV shows/week per user)

---

## HA & Failover Behavior

### Normal Operation
- Pod runs on **w1 (primary)**
- Service ClusterIP `pulsarr.media.svc.cluster.local` stable
- Sonarr/Radarr webhooks point to stable Service URL

### If w1 Fails
1. Longhorn detects w1 offline
2. k3s evicts pulsarr pod from w1 (after 30s toleration)
3. Pod reschedules to **w2 (backup)**
4. Longhorn reattaches 1Gi PVC to w2
5. Pod restarts with same PVC state (config, Plex auth, routing rules intact)
6. Service ClusterIP unchanged → Sonarr/Radarr webhooks continue working
7. **Downtime**: ~60-90 seconds

### If w1 Recovers
1. **Descheduler CronJob** (every 5 min) detects pulsarr is back on w2 (violates preferred affinity)
2. Evicts pod from w2
3. Pod reschedules to **w1 (preferred)**
4. Longhorn rebuilds replica on w1
5. **Failback time**: ~5 minutes (automatic, no manual action)

---

## Storage & Data Persistence

### PVC: config-pulsarr-0 (1Gi)
| Path | Content | Size | Persistence |
|------|---------|------|-------------|
| `/app/data/db/` | SQLite database | ~50-100MB | PVC (Longhorn RWO, 2-rep) |
| `/app/data/logs/` | Application logs | ~10-50MB | PVC (auto-rotated) |
| `/app/data/.env` | Sensitive secrets (injected) | <1KB | ConfigMap (not persisted in DB) |

### Data Flow
- **Plex token**: Stored in SQLite after first login (in PVC)
- **Sonarr/Radarr API keys**: Configured via UI, stored in SQLite
- **Routing rules**: Configured via UI, stored in SQLite
- **Logs**: `/app/data/logs/pulsarr.log` (rotated)

**Backup considerations** (post-deployment):
- Longhorn backup the `config-pulsarr-0` PVC to Unraid NFS (optional)
- Frequency: Daily at 3 AM (align with plex/config backup)
- Retention: 7 days

---

## Gotchas & Safety Checks

### 1. Webhook Callback Address
- ✅ Use `http://pulsarr.media.svc.cluster.local:3003` (not `localhost` or external ingress)
- ❌ Do NOT use `http://pulsarr.homelab` for webhooks (external loop-back issues)
- Test: After configuring Sonarr, pulsarr will show webhook status; green = good

### 2. Health Probes
- ⚠️ **Do NOT enable health probes initially**
  - All pulsarr endpoints return 401 until Plex auth is configured
  - Pod will appear "unhealthy" → liveness probe will kill it → restart loop
  - Add probes only after successful first-time setup; see docs for exact endpoints

### 3. Service Links Patch
- `enableServiceLinks: false` is applied by patch
- This prevents Kubernetes from injecting env vars like `PULSARR_PORT=tcp://...`
- Harmless for pulsarr but prevents potential env var conflicts

### 4. Node Affinity
- HA patches enforce `node.longhorn.io/storage=enabled` (required)
- Pod WILL NOT schedule on cp1 (control plane) or w3 (GPU node)
- This is intentional — pulsarr needs Longhorn storage access

### 5. PVC Size
- 1Gi allocated; SQLite is lightweight
- Monitor PVC usage: `kubectl exec -n media pulsarr-0 -- du -sh /app/data`
- If exceeds 800Mi, expand PVC in StatefulSet volumeClaimTemplate → reapply manifest

### 6. Sonarr/Radarr Connectivity
- If webhook testing fails, pulsarr will show "⚠️ Webhook Failed"
- Common issues:
  - Sonarr/Radarr URLs are external IPs instead of cluster DNS
  - API keys wrong or missing
  - Firewall/network policies blocking traffic
- Pulsarr has built-in fix suggestions in UI

### 7. Plex Server Unreachable
- On startup, pulsarr pings your Plex server
- If unreachable, pod will still start but log warnings
- Fix: Verify Plex server reachable from cluster (test with curl from another pod)

### 8. Multiple Instances Anti-Pattern
- Do NOT create multiple pulsarr StatefulSets
- Only one admin instance should manage watchlist sync per Plex account
- If you need multi-instance isolation for different users, that's a future expansion (not in scope)

---

## Performance & Monitoring

### Expected Resource Utilization
| Metric | Typical | Peak |
|--------|---------|------|
| CPU | 50-150m | 300-500m (on route calculation) |
| Memory | 200-300Mi | 400-500Mi |
| Disk (PVC) | 100-200Mi | <800Mi (logs) |
| Network | Polling: ~1-2KB/min | Webhook: ~10KB per event |

### Monitoring
**Prometheus/Grafana** (optional, future):
- Pod resource consumption
- Sonarr/Radarr webhook latency
- Watchlist update frequency

**Manual checks**:
```bash
# Pod health
kubectl get pod -n media pulsarr-0

# Recent logs
kubectl logs -n media pulsarr-0 --tail=50

# PVC usage
kubectl exec -n media pulsarr-0 -- du -sh /app/data

# Service connectivity
kubectl exec -n media sonarr-0 -- curl -s http://pulsarr.media.svc.cluster.local:3003/health
```

---

## Post-Deployment Next Steps

### Immediate (after first-time setup)
1. ✅ Plex linked
2. ✅ Sonarr/Radarr configured + webhooks green
3. ✅ Add a test item to your Plex watchlist → verify it appears in Sonarr/Radarr within 30 seconds

### Short-term (week 1)
1. ✅ Monitor logs for errors
2. ✅ Test failover: SSH to w1, `sudo shutdown -h now` → watch pod move to w2
3. ✅ Set up basic routing rules (e.g., TV → Sonarr, Movies → Radarr)
4. ✅ Configure approval workflow if desired (Settings → Rules)

### Medium-term (week 2+)
1. Add Discord notifications (optional)
2. Set up Apprise for multi-channel notifications (email, Telegram, etc.)
3. Create advanced routing rules (genre-based, user-based, rating-based)
4. Configure quotas (e.g., max 3 TV episodes/week per user)
5. Enable Plex label sync (experimental; syncs user ratings back to Plex)

### Long-term (month 1+)
1. Monitor Longhorn backup of pulsarr PVC (if enabled)
2. Tune resource requests/limits based on actual usage
3. Archive logs if desired
4. Document any custom routing rules in `docs/STATE.md`

---

## Validation Checklist

After pod is running and accessible:

- [ ] Web UI loads at `http://pulsarr.homelab`
- [ ] Plex account successfully linked (PIN auth)
- [ ] Sonarr connection test passes (green checkmark)
- [ ] Radarr connection test passes (green checkmark)
- [ ] Sonarr webhook shows "OK" (auto-configured)
- [ ] Radarr webhook shows "OK" (auto-configured)
- [ ] Add test item to Plex watchlist
- [ ] Item appears in Sonarr/Radarr within 30 seconds
- [ ] Pod logs show no errors (tail last 50)
- [ ] PVC mounted and accessible (`kubectl exec ... du -sh /app/data`)
- [ ] Service reachable from Sonarr pod: `curl http://pulsarr.media.svc.cluster.local:3003` → returns HTML

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─── w1 (Primary) ───────────────────────────────────────┐   │
│  │  ┌──────────────────────────────────────────────────┐   │   │
│  │  │ Pulsarr StatefulSet (pulsarr-0)                │   │   │
│  │  │ ├─ Port 3003 (HTTP)                            │   │   │
│  │  │ ├─ PVC: config-pulsarr-0 (1Gi, Longhorn RWO)  │   │   │
│  │  │ |   - Plex tokens                               │   │   │
│  │  │ |   - Sonarr/Radarr API keys                     │   │   │
│  │  │ |   - SQLite DB + routing rules                 │   │   │
│  │  │ └─ Labels: app=pulsarr, streaming-stack=true    │   │   │
│  │  └──────────────────────────────────────────────────┘   │   │
│  │                                                           │   │
│  │  Longhorn Replica (active)                              │   │
│  └───────────────────────────────────────────────────────┬──┘   │
│                                                            │      │
│  ┌─── w2 (Failover) ──────────────────────────────────────┤──┐   │
│  │                                                            │  │   │
│  │  Longhorn Replica (standby, RO)                          │  │   │
│  │  [Pulsarr pod evacuates here if w1 fails]               │  │   │
│  │                                                            │  │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Service: pulsarr.media.svc.cluster.local:3003          │   │
│  │ ├─ ClusterIP: stable (survives pod failover)           │   │
│  │ └─ Routed via kube-proxy to current pod IP             │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Traefik Ingress: pulsarr.homelab → Service:80          │   │
│  │ (External access for web UI)                            │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Sonarr Pod                                              │   │
│  │ └─ Webhook callback: POST http://pulsarr:3003/webhook  │   │
│  │    [Receives content acquired notifications]           │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Radarr Pod                                              │   │
│  │ └─ Webhook callback: POST http://pulsarr:3003/webhook  │   │
│  │    [Receives content acquired notifications]           │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
         │
         │ (external)
         ▼
    ┌────────────────┐
    │ Plex Server    │
    │ + User Library │
    │ + Watchlists   │
    └────────────────┘
         │
         │ (RSS feeds / polling every 5 min)
         │
    ┌────────────────────────────────────┐
    │ Pulsarr Workflow:                 │
    │ 1. Monitor Plex watchlists (RSS)  │
    │ 2. Analyze content metadata       │
    │ 3. Apply routing rules            │
    │ 4. POST to Sonarr/Radarr APIs    │
    │ 5. Handle approvals/quotas        │
    │ 6. Notify users (Discord later)   │
    └────────────────────────────────────┘
```

---

## References & Links

- [Pulsarr GitHub](https://github.com/jamcalli/Pulsarr)
- [Pulsarr Documentation](https://jamcalli.github.io/Pulsarr/)
- [Cluster DECISIONS.md](../../docs/DECISIONS.md) — Storage, HA strategy, DFS architecture
- [Cluster STATE.md](../../docs/STATE.md) — Current nodes, pods, PVCs
- [Cluster GOTCHAS.md](../../docs/GOTCHAS.md) — Troubleshooting index

---

## Status

**Current Phase**: Planning (this document)  
**Next Phase**: Create manifests + implement (pending approval)  
**Estimated Implementation Time**: ~20-30 minutes (all 5 files, copy-paste from templates above)  
**Estimated First-Time Setup**: ~15 minutes (Plex PIN, Sonarr/Radarr pairing)  

**Ready to proceed?** → Create manifests in `clusters/homelab/apps/media/pulsarr/` and commit to git.
