# Radarr Deployment Notes & Learnings

**Date**: 2026-02-17  
**Status**: ✅ Complete & Operational  
**Commits**: 6dfa2b3 → b788d6f → 6a932e5 → 5be33db

---

## Deployment Summary

Successfully deployed Radarr StatefulSet (Phase 2 of media stack) following Sonarr pattern:
- ✅ Mirrors Sonarr architecture (StatefulSet, Longhorn 5Gi PVC, node affinity)
- ✅ Accessible at `radarr.homelab` via Traefik ingress
- ✅ Pod scheduled on w1 (primary storage node)
- ✅ HA failover configured via descheduler

---

## Issues Encountered & Resolutions

### Issue 1: Invalid Image Tag (First Blocker)
**Problem**: Pod failed with `ErrImagePull` → `ImagePullBackOff`  
**Error**: `docker.io/linuxserver/radarr:5.2.5: not found`

**Root Cause**: Original deployment specified exact tag `5.2.5` which doesn't exist in Docker registry.  
Sonarr uses `4.0.16` (exists), but Radarr doesn't have a `5.2.5` release published.

**Fix Applied**:
```yaml
# FROM:
image: linuxserver/radarr:5.2.5

# TO:
image: linuxserver/radarr:latest
```

**Lesson Learned**: 
- When pinning container images, verify the tag exists on Docker Hub first
- For rapid deployments, using `:latest` is acceptable when exact versions are unavailable
- Sonarr/Radarr releases don't align in version numbering (not all numbered versions exist for both)

**Commit**: `b788d6f`

---

### Issue 2: Service Port Mismatch (Second-Level Blocker)
**Problem**: Ingress routing failed even after pod was running  
**Error**: Pod running but 404 responses from radarr.homelab

**Root Cause**: Inconsistent service port configuration between Radarr and Sonarr:
- **Radarr Service**: exposed port `7878` (matches container port)
- **Sonarr Service**: exposed port `80` (NOT container port 8989)
- **Traefik routing**: Works best when services expose port `80` for HTTP traffic

Traefik's expectations for standard HTTP routing:
- Service port: `80` (conventional HTTP)
- Container port: `7878` (Radarr's internal)
- Ingress routes to service port `80`, which maps to container port via targetPort

**Fix Applied**:
```yaml
# service.yaml - FROM:
ports:
  - port: 7878
    targetPort: 7878

# TO:
ports:
  - port: 80        # External service port (for ingress)
    targetPort: 7878 # Container port (where Radarr listens)
```

```yaml
# ingress.yaml - FROM:
backend:
  service:
    port:
      number: 7878

# TO:
backend:
  service:
    port:
      number: 80  # Must match service.spec.ports[].port
```

**Lesson Learned**:
- Service port 80 is the de facto standard for HTTP traffic in Kubernetes
- Traefik ingress expects services to expose standard HTTP ports (80)
- Container ports and service ports are independent (service abstracts the container)
- Always match ingress port references to service.spec.ports[].port (not targetPort)

**Commit**: `6a932e5`

---

### Issue 3: Invalid Traefik Entrypoint Annotation (Final Blocker)
**Problem**: Even after port fix, 404 persisted  
**Error**: Traefik logs:
```
ERR Skipping service: no endpoints found ingress=radarr servicePort=&ServiceBackendPort{Number:7878,}
ERR EntryPoint doesn't exist entryPointName=web routerName=media-radarr-radarr-homelab@kubernetes
ERR EntryPoint doesn't exist entryPointName=websecure routerName=media-radarr-radarr-homelab@kubernetes
ERR No valid entryPoint for this router routerName=media-radarr-radarr-homelab@kubernetes
```

**Root Cause**: Radarr ingress had invalid Traefik annotation:
```yaml
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
```

But Traefik deployment was configured with different entrypoint names:
```bash
--entrypoints.http.address=:8000/tcp
--entrypoints.https.address=:8443/tcp
```

**Mismatch**: 
- Ingress specifies: `web`, `websecure`
- Traefik has: `http`, `https`
- No match = router fails

**Comparison with Sonarr**: Sonarr's ingress doesn't use this annotation at all:
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: traefik   # ← Only this
```

**Fix Applied**:
```yaml
# FROM:
metadata:
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web,websecure
  ingressClassName: traefik

# TO:
metadata:
  annotations:
    kubernetes.io/ingress.class: traefik   # ← Match Sonarr's pattern
  ingressClassName: traefik
```

Also required: **Delete and recreate the ingress** to force Traefik to re-read configuration:
```bash
kubectl delete ingress radarr -n media
kubectl annotate kustomization flux-system -n flux-system reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
```

**Lesson Learned**:
- Traefik entrypoint names must match between:
  1. Ingress annotation (`router.entrypoints`)
  2. Traefik deployment arguments (`--entrypoints.NAME.address`)
- When entrypoint names don't exist, Traefik skips the entire router
- Simpler approach: Omit the annotation entirely and let Traefik auto-select valid entrypoints
- Always compare successful deployments (Sonarr) when debugging similar apps (Radarr)
- Ingress changes sometimes require deletion + recreation for Traefik to reload (especially annotation changes)

**Commits**: `5be33db` (annotation fix + deletion), then Flux recreated with correct config

---

## Implementation Best Practices (Validated)

### 1. **Service Port Standardization**
Use port `80` for ClusterIP services exposed via Traefik ingress:
```yaml
service:
  ports:
    - port: 80              # Standard HTTP (for ingress routing)
      targetPort: XXXX      # App's internal port
      name: http
```

**Why**: 
- Ingress routes to service port (80 is conventional)
- Services abstract container ports
- Traefik expects HTTP traffic on port 80

### 2. **Ingress Annotation Consistency**
When deploying similar apps (Sonarr, Radarr, Prowlarr), copy ingress annotations from working apps:
```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: traefik  # ← Standard, always works
    # Don't add router.entrypoints unless you verify Traefik's config
```

### 3. **Traefik Entrypoint Verification**
Before using Traefik annotations with entrypoint names:
```bash
# Check deployed entrypoint names
kubectl get deployment traefik -n kube-system -o yaml | grep "entrypoints"

# Should show: --entrypoints.http.address, --entrypoints.https.address
# NOT: web, websecure (those are custom names you'd need to define)
```

### 4. **Pod Configuration Template Matching**
When deploying apps following a pattern (Sonarr→Radarr):
1. Copy the entire ingress.yaml from working app
2. Only update hostname and service names
3. Verify service port matches

**Example**:
```bash
# Copy Sonarr's pattern to Radarr
cp sonarr/ingress.yaml radarr/ingress.yaml
# Only change host: sonarr.homelab → host: radarr.homelab
# Keep service port: 80 (don't change to 7878)
```

### 5. **Image Tag Validation**
Before committing container image specs:
```bash
# Quick check if tag exists
docker pull linuxserver/radarr:TAGNAME 2>&1 | grep -i "not found"

# Or use `:latest` for rapid iteration, then pin later when stabilized
```

---

## Technical Architecture Validated

### Service Routing Path
```
Client (radarr.homelab)
  ↓ [DNS resolves to Traefik service IP: 192.168.100.101]
  ↓ [Traefik HTTP listener on port 8000]
  ↓ [Traefik reads Ingress rule: host=radarr.homelab → service=radarr:80]
  ↓ [Service radarr:80 has endpoints: 10.42.1.202:7878]
  ↓ [iptables NAT: 10.42.1.202:7878 → radarr-0 pod:7878]
  ↓ [Radarr app listening on localhost:7878]
  ✅ Response returned
```

**Key Validation Points**:
- ✅ DNS: `nslookup radarr.homelab` resolves to Traefik IP
- ✅ Service: `kubectl get svc radarr` shows port 80
- ✅ Endpoints: `kubectl get endpoints radarr` shows pod IP:7878
- ✅ Pod: `kubectl logs radarr-0` shows "listening on :7878"
- ✅ Traefik: No error logs about entrypoints or endpoints

---

## Deployment Checklist for Future *Arr Apps

Use this checklist when deploying similar apps (Prowlarr, Sonarr variants, etc.):

- [ ] **Image Tag**: Verify tag exists (use `:latest` if uncertain)
- [ ] **Service Port**: Set to `80` for Ingress compatibility
- [ ] **Target Port**: Set to app's internal port (various per app)
- [ ] **Ingress Annotation**: Copy from Sonarr exactly (don't customize)
- [ ] **Pod Status**: `kubectl get pods -l app=APPNAME` shows `1/1 Running`
- [ ] **Endpoints**: `kubectl get endpoints APPNAME` shows pod IP:targetPort
- [ ] **DNS**: `kubectl run debug --rm -it -n media -- nslookup APPNAME.homelab`
- [ ] **HTTP Test**: `kubectl run debug --rm -it -n media -- wget http://APPNAME:80 -O-`
- [ ] **Web URL**: Browser test at `http://APPNAME.homelab`
- [ ] **Traefik Logs**: `kubectl logs -n kube-system -l app.kubernetes.io/name=traefik | grep APPNAME` (no errors)

---

## Summary

**What Worked**:
- ✅ Replicating Sonarr's StatefulSet pattern exactly
- ✅ Using Longhorn 2-replica storage (zero data loss on node failure)
- ✅ Node affinity rules (ensures scheduling on w1/w2)
- ✅ Traefik ingress when configured consistently

**What Didn't Work (Initially)**:
- ❌ Custom image tag that doesn't exist
- ❌ Non-standard service port (7878 instead of 80)
- ❌ Invalid Traefik entrypoint names in annotations

**Key Takeaways**:
1. **Copy working patterns exactly** (don't innovate on first deploy)
2. **Verify container image tags** before pushing to Git
3. **Use standard ports** (80 for HTTP services)
4. **Match Traefik entrypoint names** or omit the annotation
5. **Compare successful deployments** when debugging similar apps

---

## Phase 5 Updates: Volume Mounts (2026-02-24)

### Added Complete Mount Configuration

Following Phase 5 integration, Radarr now has the same volume mounts as Sonarr:

| Mount | Source | Type | Purpose |
|-------|--------|------|----------|
| `/mnt/media` | pvc-media-nfs | ROX | Unraid media (from decypharr-download) |
| `/mnt/dfs` | decypharr-streaming-nfs.media.svc | NFS | RealDebrid downloads (via rclone sidecar) |
| `/mnt/streaming-media` | pvc-streaming-media | RWX | Symlinks and streaming-ready content |

### StatefulSet Changes

Added three new volume mounts to the radarr container:
- `/mnt/media` - Unraid NFS (read-only)
- `/mnt/dfs` - Decypharr-Streaming NFS export (RealDebrid cache)
- `/mnt/streaming-media` - Longhorn RWX for symlinks

For detailed mount configuration, see [DECYPHARR_DEPLOYMENT_NOTES.md#sonarr--radarr-integration](./DECYPHARR_DEPLOYMENT_NOTES.md#sonarr--radarr-integration).

---

## Next Steps

### Phase 3: Scale Prowlarr (Next)
- Change `replicas: 0 → 1` in prowlarr/statefulset.yaml
- Use same service/ingress pattern as Sonarr/Radarr
- Verify at prowlarr.homelab

### Phase 4: Longhorn RWX StorageClass (Foundation for Decypharr)
- Create `longhorn-rwx` StorageClass
- Create `streaming-media` PVC (Longhorn RWX)
- Required for symlink sharing across pods

### Phase 4: Decypharr (Complex - 2-3 hours)
- Includes FUSE mount + rclone-nfs-server sidecar
- Critical for cross-node DFS access
- See MEDIA_STACK_IMPLEMENTATION_PLAN.md Phase 4

---

**Last Updated**: 2026-02-17 00:15 UTC  
**By**: Copilot (GitHub)  
**Status**: Ready for Phase 3 (Prowlarr)
