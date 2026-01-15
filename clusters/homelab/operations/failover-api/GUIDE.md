# Failover API - Complete Guide

## Overview

HTTP-triggered GitOps failover automation for stateful applications with VolSync replication across cluster nodes. Replaces the non-functional monitor pod with a production-ready, HA service.

**Key features:**
- ✅ **Dynamic configuration** - Add services via ConfigMap, no code changes
- ✅ **GitOps-native** - Commits to Git, Flux applies automatically
- ✅ **High availability** - Runs on multiple nodes, survives single failure
- ✅ **Multiple services** - Single API handles 20+ services
- ✅ **Dry-run support** - Test before executing
- ✅ **Audit trail** - All operations in Git with timestamps

---

## Quick Start

### Deploy
```bash
# 1. Build and push image
docker build -t failover-api:latest .
docker push your-registry/failover-api:latest

# 2. Update image in deployment.yaml
# 3. Merge feature/failover-api to main
git checkout main && git merge feature/failover-api && git push

# 4. Verify deployment
kubectl get pods -n operations -l app=failover-api
```

### Use
```bash
# List services
curl http://failover-api.operations.svc.cluster.local/api/services

# Failover to backup (primary → backup)
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote

# Failback to primary (backup → primary)
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote

# Dry-run (test first, no changes)
curl http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote?dry-run=true

# Check status
curl http://failover-api.operations.svc.cluster.local/api/failover/sonarr/status
```

---

## How It Works

### Architecture

```
User / Monitoring System
    │
    └─ curl /api/failover/sonarr/promote
        │
        ▼
    Failover API (HA Deployment)
        │
        ├─ Clone Git repo
        ├─ Update deployment.yaml
        ├─ Git commit + push
        │
        ▼
    GitHub
        │
        └─ Flux watches for changes
            │
            ▼
        Flux applies updated deployment
            │
            ▼
        Pod reschedules to backup node
            │
            ▼
        Service available again
```

### Data Flow

**When primary node fails:**
1. Pod on primary becomes Pending (can't match nodeSelector)
2. User triggers failover: `curl /api/failover/sonarr/promote`
3. failover-api clones Git repo and finds deployment.yaml
4. Updates: nodeSelector → backup, PVC → backup PVC
5. Commits and pushes to GitHub
6. Flux detects change within 1 minute
7. Flux applies updated deployment
8. Pod reschedules to backup node and starts normally

**To failback (when primary recovers):**
1. User triggers failback: `curl /api/failover/sonarr/demote`
2. failover-api reverses the changes (nodeSelector → primary, PVC → primary)
3. Commits, pushes, Flux applies
4. Pod reschedules back to primary node

---

## Configuration

### Adding Services

Edit `configmap.yaml`:

```yaml
services:
  sonarr:
    namespace: media
    deployment: sonarr
    volume_name: sonarr-data          # Must match pod spec exactly
    primary_pvc: pvc-sonarr
    backup_pvc: pvc-sonarr-backup
    primary_node_label: primary
    backup_node_label: backup

  radarr:  # Add new services here
    namespace: media
    deployment: radarr
    volume_name: radarr-data
    primary_pvc: pvc-radarr
    backup_pvc: pvc-radarr-backup
    primary_node_label: primary
    backup_node_label: backup
```

**Required fields:**
- `namespace` - Kubernetes namespace
- `deployment` - Deployment name  
- `volume_name` - Pod volume name (exact match from deployment spec)
- `primary_pvc` / `backup_pvc` - PVC names to swap
- `primary_node_label` / `backup_node_label` - Node selector labels

**To add a service:**
1. Ensure service has HA setup (VolSync, primary/backup PVCs, nodeSelector)
2. Add entry to ConfigMap
3. No code changes, no rebuild, no redeploy
4. API immediately works

---

## Scaling & High Availability

### For Failover API Itself

Current setup (2 worker nodes):
```yaml
replicas: 2              # One pod per node
affinity:               # Pod anti-affinity spreads across nodes
  podAntiAffinity: ...
pdb:
  minAvailable: 1       # Always keep 1 pod running
```

If k3s-w1 fails:
- failover-api pod on w1 evicts
- failover-api pod on w2 continues serving
- Can still trigger failover for other services

For 3+ worker nodes:
1. Update `replicas` in deployment.yaml
2. Adjust `minAvailable` in pdb.yaml (typically replicas - 1)

### Scaling to 20+ Services

One API handles unlimited services. Just add to ConfigMap:

```yaml
services:
  sonarr: ...
  radarr: ...
  prowlarr: ...
  lidarr: ...
  # ... add more
```

No code changes, no redeploy. Configuration-driven design.

---

## MetalLB & Traefik Integration

### Good News: It "Just Works"

**MetalLB:**
- Service IP stays same (doesn't change during failover)
- Endpoint IPs update automatically
- Traffic routes to new endpoint

**Traefik:**
- Watches Ingress resources cluster-wide
- Ingress points to Service by name
- Service endpoints managed by Kubernetes
- Traefik auto-updates routing on endpoint change

**Result:** No special configuration needed. External traffic automatically follows pod to backup node.

### Testing

```bash
# Before failover
curl http://sonarr.yourdomain.com/api/system/status

# Trigger failover
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote

# Wait ~10 seconds for pod to start
# After failover - works automatically
curl http://sonarr.yourdomain.com/api/system/status
```

---

## Design Decisions

### Why GitOps (Git commits, not in-cluster patches)?

- Old monitor patched deployments directly (conflicted with Flux)
- Flux reconciliation reverted patches immediately
- New approach commits to Git (single source of truth)
- Flux sees Git change and applies it
- Full audit trail in git history
- Reversible and predictable

### Why Dynamic Configuration?

- Add 20 services without touching code
- Single deployment for all services
- Easy team maintenance
- Self-documenting (ConfigMap lists all services)

### Why HA for Failover API?

- If failover-api crashed, couldn't trigger failover
- 2 replicas with pod anti-affinity
- Pod Disruption Budget ensures 1 always available
- Survives single node failure

### Why Use Flux's SSH Key?

- Flux already has write access to GitHub
- Less secrets to manage
- Principle of least privilege
- No need for separate credentials

---

## Usage Examples

### Port-Forward for External Access

```bash
# From your laptop
kubectl -n operations port-forward svc/failover-api 8080:8080

# Then use
curl http://localhost:8080/api/services
curl -X POST http://localhost:8080/api/failover/sonarr/promote
```

### From Home Assistant

```yaml
rest_command:
  failover_sonarr:
    url: "http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote"
    method: POST
    timeout: 30

automation:
  - alias: Failover Sonarr on Node Failure
    trigger:
      platform: state
      entity_id: binary_sensor.k3s_w1
      to: "off"
    action:
      - service: rest_command.failover_sonarr
```

### Monitoring Integration

```bash
# Check if API is healthy
curl http://failover-api.operations.svc.cluster.local/api/health

# Response: { "status": "ok" }
```

---

## Troubleshooting

### Pods not starting
```bash
# Check events
kubectl describe pod -n operations -l app=failover-api

# Check if SSH secret exists
kubectl get secret flux-system -n flux-system

# Check logs
kubectl logs -n operations -l app=failover-api
```

### Git operations fail
```bash
# Verify SSH key has write access
# GitHub Settings → Deploy Keys → Check "Allow write access"

# Test connection
kubectl run -it --rm ssh-test --image=alpine -- sh
  apk add openssh-client
  ssh -i /path/to/key git@github.com
```

### Failover triggered but deployment didn't update
```bash
# Check logs for file paths
kubectl logs -n operations -l app=failover-api --tail=50 | grep -i path

# Verify ConfigMap path matches actual deployment location
# e.g., clusters/homelab/apps/media/sonarr/deployment.yaml
```

### Service not found errors
```bash
# Verify ConfigMap entry exists
kubectl get configmap failover-api-config -n operations -o yaml | grep -A 5 sonarr

# Verify deployment file exists
git ls-tree -r main -- clusters/homelab/apps/media/sonarr/deployment.yaml
```

---

## Workflow Example: Node Failure Recovery

### Scenario: k3s-w1 goes down

**T+0m:** k3s-w1 becomes unreachable  
**T+1m:** Kubernetes marks node as NotReady  
**T+5m:** You notice issue, decide to failover

```bash
# Trigger failover
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote
```

**T+5m:** failover-api commits to Git  
**T+6m:** Flux detects and applies change  
**T+6m:** Pod starts on k3s-w2  
**T+7m:** Service available again  

**Downtime: ~6-7 minutes** (detection + failover)

**Later, when k3s-w1 recovers:**

```bash
# Trigger failback
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote
```

**T+12m:** Pod reschedules back to k3s-w1

---

## Migration from Old Monitor

### Old vs New

| Aspect | Old Monitor | New Failover API |
|--------|-----------|------------------|
| Approach | Direct cluster patching | Git commits + Flux |
| Scope | Hardcoded for Sonarr | Configuration-driven |
| Services | One only | Unlimited |
| Failover | Auto (broken) | Manual HTTP trigger |
| HA | Single pod | 2 replicas + PDB |
| Git tracking | No | Full audit trail |
| Conflicts | Yes (Flux overwrites) | No (git source of truth) |

### Migration Steps

1. **Verify failover-api works:**
   ```bash
   kubectl get pods -n operations -l app=failover-api
   # Should see 2 pods (one per node)
   
   curl http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote?dry-run=true
   # Should return dry-run response
   ```

2. **Test real failover (brief downtime):**
   ```bash
   curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote
   # Watch pod reschedule
   kubectl get pods -n media -o wide --watch
   ```

3. **Test failback:**
   ```bash
   curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote
   # Watch pod reschedule back
   ```

4. **Delete old monitor:**
   ```bash
   rm -rf clusters/homelab/operations/volsync-failover/
   # Update kustomization.yaml to remove reference
   git add clusters/homelab/operations/
   git commit -m "Remove old monitor, use failover-api"
   git push
   ```

---

## Implementation Checklist

- [ ] Docker image built and pushed
- [ ] deployment.yaml image field updated
- [ ] Branch merged to main
- [ ] Flux reconciles (check `flux get kustomizations`)
- [ ] 2 failover-api pods running (`kubectl get pods -n operations`)
- [ ] Dry-run works (`curl .../api/failover/sonarr/promote?dry-run=true`)
- [ ] Real failover works (brief downtime acceptable)
- [ ] Failback works
- [ ] Git commits appear in history
- [ ] Old monitor deleted
- [ ] Validation passes (`./validate.sh`)

---

## Security Notes

**SSH Key Handling:**
- Mounted read-only from flux-system secret
- Permissions: 0400 (read-only)
- Never shared or exposed

**RBAC:**
- Only reads flux-system secret (specific key)
- No cluster API permissions
- Service account limited to operations namespace

**Pod Security:**
- Non-root user (UID 1000)
- Read-only root filesystem
- Dropped capabilities
- Memory-backed /tmp (no disk writes)

---

## Future Enhancements

- [ ] Automatic failover on node unhealthiness
- [ ] Slack/email notifications
- [ ] Web UI for manual controls
- [ ] Prometheus metrics
- [ ] Automatic failback on primary recovery
- [ ] Cross-cluster failover support

---

## Support

For issues, check:
1. Pod logs: `kubectl logs -n operations -l app=failover-api`
2. ConfigMap: `kubectl get configmap failover-api-config -n operations -o yaml`
3. Git status: `git log --grep="failover" --oneline`
4. Flux status: `flux get kustomizations -n flux-system operations`

