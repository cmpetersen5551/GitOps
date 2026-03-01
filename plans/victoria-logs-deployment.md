# VictoriaLogs Deployment Plan

**Date**: March 1, 2026  
**Status**: Planning phase  
**Owner**: Chris  
**Phase**: Phase 2 (Observability Foundation)

---

## Overview

Deploy VictoriaLogs as the centralized log aggregation solution for the media stack. This replaces the Loki+Promtail approach with a simpler, more efficient single-binary logging system.

### Why VictoriaLogs (over Loki/ELK/OpenObserve)

- **Simpler setup**: Single binary vs Loki's DaemonSet + sidecar complexity
- **Lower resource overhead**: ~500 MB–1 GB RAM vs Loki's 1–2 GB
- **Better high-cardinality handling**: Efficient with pod-specific logs (IPs, request IDs)
- **Smaller disk footprint**: ~15 GB/month vs Loki's ~20 GB/month
- **Intuitive queries**: Regex/filter-based vs LogQL's DSL learning curve
- **Built-in UI**: Web interface at port 9428 requires no Grafana (add later if desired)

### What You Get

- **Centralized logging**: All pod stdout/stderr from media namespace + infrastructure in one place
- **Web UI**: Search logs by keyword, timestamp, pod name, namespace
- **No Promtail needed**: k8s kubelet forwards logs directly via `/var/log/pods/**` or VL scrapes from API
- **No Grafana dependency**: Built-in VMUI is sufficient for debugging; add Grafana later for dashboards
- **Storage**: ~15 GB/month (7-day default retention on longhorn-simple PVC)

---

## Architecture

### Components

| Component | Type | Storage | Network | Notes |
|-----------|------|---------|---------|-------|
| VictoriaLogs | StatefulSet | 1x 100 GB PVC (longhorn-simple) | ClusterIP + Ingress | Single replica (homelab) |
| Ingress | Ingress | — | HTTP ingress route | `logs.homelab` → `/vmui` |

### Data Flow

```
Kubernetes kubelet
    ↓
logs at /var/log/pods/**
    ↓
VictoriaLogs (scrape or forward)
    ↓
100 GB PVC (longhorn-simple, RWO)
    ↓
Retention: 7 days (auto-cleanup)
    ↓
Web UI at logs.homelab:9428/vmui
    ↓
Query by pod name, namespace, text search, timestep
```

### PVC Sizing Rationale

- **100 GB PVC**: At ~15 GB/month for 10 media pods (sonarr, radarr, plex, decypharr-*, prowlarr, profilarr, pulsarr), gives ~6-month safety buffer
- **Retention policy**: 7 days is reasonable; older logs auto-deleted by VictoriaLogs
- **StorageClass**: `longhorn-simple` (RWO) — single replica, cost-effective for homelab
- Can expand PVC if needed via Longhorn UI without downtime (StatefulSet upgrade)

### Log Collection Method

**Recommended: Mount host `/var/log/pods`** (simplest for homelab)

```yaml
VictoriaLogs Pod mounts hostPath:
  - /var/log/pods → read-only
VictoriaLogs config:
  - filesd_config scrapes /var/log/pods/**/*.log
  - Parses pod labels from path (k8s-native)
  - Ships to local storage
```

Alternative: Configure kubelet to forward logs to VL via syslog/JSON plugin (requires kubelet restart, not Flux-friendly).

---

## Implementation Steps

### Phase 1: Create Infrastructure Files

**Files to create**:

1. `clusters/homelab/infrastructure/victoria-logs/namespace.yaml`
2. `clusters/homelab/infrastructure/victoria-logs/helmrepository.yaml`
3. `clusters/homelab/infrastructure/victoria-logs/helmrelease.yaml`
4. `clusters/homelab/infrastructure/victoria-logs/ingress.yaml`
5. `clusters/homelab/infrastructure/victoria-logs/kustomization.yaml`

**Helm chart source**: `https://github.com/VictoriaMetrics/helm-charts`
- Chart: `victoria-logs-single` (single-binary, not clustered)
- Latest stable version (2.x)

### Phase 2: HelmRelease Configuration

**Key values**:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: victoria-logs
  namespace: victoria-logs
spec:
  chart:
    spec:
      chart: victoria-logs-single
      version: 0.x.x  # Use latest from chart repo
      sourceRef:
        kind: HelmRepository
        name: victoria-logs
        namespace: victoria-logs
  values:
    server:
      persistentVolume:
        enabled: true
        size: 100Gi
        storageClassName: longhorn-simple
        mountPath: /victorialogs-data
      # Log scrape config (filesd-based)
      vmui:
        enabled: true
      extraArgs:
        - "-retentionPeriod=7d"    # 7-day retention
        - "-storageDataPath=/victorialogs-data"
      resources:
        requests:
          memory: 512Mi
          cpu: 250m
        limits:
          memory: 1Gi
          cpu: 500m
    # No rbac needed; simple StatefulSet
    # Pod affinity: prefer w1 (primary storage node)
    affinity:
      nodeAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
                - key: node.longhorn.io/primary
                  operator: In
                  values: ["true"]
```

### Phase 3: Ingress Configuration

**Route**: `http://logs.homelab` → `http://victoria-logs.victoria-logs:9428/vmui`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: victoria-logs
  namespace: victoria-logs
spec:
  ingressClassName: traefik
  rules:
    - host: logs.homelab
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: victoria-logs
                port:
                  number: 9428
```

### Phase 4: Deployment & Verification

**Flux Sync**:
```bash
git add clusters/homelab/infrastructure/victoria-logs/
git commit -m "feat: add victoria-logs observability stack"
git push
flux reconcile kustomization infrastructure --with-source
```

**Verification**:
```bash
# Wait for StatefulSet ready (may take 2–3 min for PVC bind)
kubectl get sts -n victoria-logs

# Check PVC bound
kubectl get pvc -n victoria-logs

# Port-forward to test (if DNS not yet available)
kubectl port-forward -n victoria-logs svc/victoria-logs 9428:9428
# Visit http://localhost:9428/vmui

# Confirm logs are flowing (check via UI or API)
curl http://logs.homelab/api/v1/labels
```

**Expected output**: JSON list of available log labels (`pod`, `namespace`, `container`, etc.)

---

## Storage & Retention

| Metric | Value | Rationale |
|--------|-------|-----------|
| PVC Size | 100 Gi | 6-month buffer at ~15 GB/month |
| Retention | 7 days (default) | Recent errors stay accessible; older logs auto-purged |
| Compression | Built-in | VictoriaLogs auto-compresses; no extra tune needed |
| Backups | ✅ Included in `backup-all-volumes` | PVC labeled for automatic nightly snapshot |

---

## Integration with Existing Cluster

### Namespace & RBAC

- New namespace: `victoria-logs` (isolated from apps)
- No RBAC-heavy ServiceAccount needed (logs are read-only for most apps)
- Kubelet has implicit permission to write logs

### Labeling for Backups

Add label to PVC so it's included in nightly backup:
```yaml
metadata:
  labels:
    recurring-job-group.longhorn.io/default: enabled
```

### Node Affinity

- **Preferred** (not required): Run on k3s-w1 (primary storage node)
- Rationale: Collocates with Longhorn replicas for better I/O locality
- Falls back to w2 if w1 overloaded (no impact to functionality)

---

## Querying Logs (VMUI)

### Simple Examples

**UI Path**: `http://logs.homelab/vmui`

**Query syntax** (LogQL-compatible but simpler):

```
# All Sonarr logs from last 1h
{pod=~"sonarr.*"}

# All error-level messages
{level="error"}

# Decypharr + Radarr combined
{pod=~"(decypharr|radarr).*"}

# Text search: find all "disk full" messages
{pod=~".*"} | "disk full"
```

### Recommended Saved Queries (add later as bookmarks)

- `{namespace="media"} | "error"` — All media app errors
- `{pod="plex*"}` — Plex logs only
- `{pod=~"decypharr.*"}` — Both decypharr instances
- `{pod=~"(sonarr|radarr).*"} | "failed"` — Import failures

---

## Future Extensions (Not Part of This Plan)

These are deferred but documented for reference:

### Add Grafana Later
- Install Grafana HelmRelease
- Add VictoriaLogs datasource (plugin: victoria-logs)
- Build dashboards for error trends, search queries

### Add Prometheus (Metrics)
- Deploy kube-prometheus-stack
- Will not interfere with VL setup
- Allows unified Grafana dashboards: logs + metrics

### Structured Logging (Optional)
- If C# apps (Phase 3) need JSON logging, configure Serilog sinks
- VL parses JSON fields automatically (pod, level, message, custom fields)

---

## Effort Estimate

| Task | Duration |
|------|----------|
| Create manifests (HelmRelease + Ingress + kustomization) | 15 min |
| Deploy and wait for PVC bind | 5 min |
| Verify logs flowing + VMUI accessible | 10 min |
| **Total** | **~30 min** |

---

## Success Criteria

- [ ] VictoriaLogs StatefulSet running (1 replica, Ready)
- [ ] PVC bound and mounted (`100 Gi` from longhorn-simple)
- [ ] Ingress active: `http://logs.homelab/vmui` loads without errors
- [ ] VMUI shows available labels (pod, namespace, container)
- [ ] Can query `{namespace="media"}` and see logs from sonarr, radarr, plex, decypharr, etc.
- [ ] Logs are recent (< 5 min old for active pods)
- [ ] PVC included in nightly Longhorn backup and labeled correctly

---

## Rollback Plan

**If issues occur after deploy**:

```bash
# Remove from Flux
kubectl delete helmrelease victoria-logs -n victoria-logs

# Keep data on PVC (not deleted)
# Redeploy with fixed config and Flux will pick it up

# If you need to wipe data (full reset):
kubectl delete pvc victoria-logs-data -n victoria-logs
# (This deletes the 100 GB disk; Longhorn will snapshot first)
```

---

## Next Steps (After Deployment)

1. **Monitor PVC usage** — Check Longhorn UI monthly to ensure 15 GB/month assumption holds
2. **Test queries** — Build saved queries for common debugging scenarios (error spikes, pod restarts)
3. **(Optional Phase 3)** — Add Grafana + Prometheus if dashboards become needed
4. **(Optional Phase 4)** — Wire up C# apps (sonarr-utils, etc.) with structured JSON logging

