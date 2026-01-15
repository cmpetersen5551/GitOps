# Failover API Architecture & Design Decisions

## Overview

This document explains the failover-api implementation, design decisions, and how it integrates with your HA architecture.

## Problem Statement

When a primary worker node (k3s-w1) becomes unavailable:
1. VolSync replication keeps the backup PVC synchronized
2. Kubernetes naturally evicts pods from the failed node
3. But pods get stuck Pending because they have:
   - `nodeSelector: role=primary` (no alternative matching node)
   - PVC bound to primary node's storage

**Current situation (without failover-api):**
- Downtime: 5-10 minutes (eviction delay + manual fix)
- Manual intervention required: Edit deployment, commit, push

**With failover-api:**
- Downtime: 1-2 minutes (trigger failover + Flux reconcile)
- Single API call: `curl -X POST http://failover-api.../api/failover/sonarr/promote`

## Architecture

### Components

```
failover-api (Deployment, 2 replicas)
  ├─ Python Flask application
  ├─ Runs on both k3s-w1 and k3s-w2 (HA)
  ├─ Uses Flux's SSH key for Git operations
  └─ HTTP service (ClusterIP, internal only)

Git Repository
  ├─ Source of truth (Flux watches this)
  └─ Updated by failover-api when triggered

Flux Kustomization Controller
  ├─ Watches Git repository
  ├─ Applies changed manifests within 1 minute
  └─ Triggers pod rescheduling

Kubernetes Scheduler
  ├─ Evicts pod from failed node
  ├─ Places new pod on available node with matching selectors
  └─ Binds to backup PVC
```

### Data Flow: Failover Scenario

```
1. k3s-w1 fails
   └─ Pod stuck Pending (can't match nodeSelector)

2. User triggers failover
   └─ curl /api/failover/sonarr/promote

3. failover-api:
   ├─ Clones Git repo
   ├─ Finds deployment.yaml in clusters/homelab/apps/media/sonarr/
   ├─ Updates:
   │   └─ nodeSelector.role: backup
   │   └─ volume[sonarr-data].claimName: pvc-sonarr-backup
   ├─ Commits: "Automated failover: sonarr to backup node"
   └─ Pushes to GitHub

4. Flux (within 1 minute):
   ├─ Detects Git change
   ├─ Applies updated kustomization
   └─ Updates deployment with new PVC + node selector

5. Kubernetes Scheduler:
   ├─ Pod can now match nodeSelector (role=backup)
   ├─ Pod can mount PVC (pvc-sonarr-backup available on k3s-w2)
   └─ New pod scheduled on k3s-w2

6. Pod starts:
   └─ Mounts VolSync-replicated storage
   └─ Starts normally
```

## Design Decisions

### 1. Dynamic Configuration (No Hardcoding)

**Decision:** Services configured in ConfigMap, not in code

**Why:**
- Add 20 services without touching Python code
- Single deployment for all services
- Easy for team members to maintain
- Self-documenting (ConfigMap shows all failover-enabled services)

**ConfigMap structure:**
```yaml
services:
  sonarr:
    namespace: media
    deployment: sonarr
    volume_name: sonarr-data  # Must match pod spec exactly
    primary_pvc: pvc-sonarr
    backup_pvc: pvc-sonarr-backup
    primary_node_label: primary
    backup_node_label: backup
```

**Adding a new service:**
1. Create deployment with VolSync replication (same pattern as Sonarr)
2. Add entry to ConfigMap
3. No code deployment needed

### 2. High Availability for Failover API Itself

**Decision:** Deploy on multiple nodes with pod anti-affinity

```yaml
replicas: 2  # One on each worker node
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - failover-api
          topologyKey: kubernetes.io/hostname
```

**Why:**
- If one pod crashes, other is still available
- Survives single node failure (failover-api continues running on surviving pod)
- No single point of failure

**PodDisruptionBudget:**
```yaml
minAvailable: 1  # Always keep at least 1 pod running
```

**Practical scenario:**
- k3s-w1 fails while failover-api pod running there
- failover-api pod on k3s-w1 evicts
- failover-api pod on k3s-w2 continues serving requests
- Users can still trigger failover for other services

### 3. Using Flux's Existing SSH Key

**Decision:** Reuse flux-system secret instead of creating new credentials

**Why:**
- Single source of truth for Git credentials
- Less secrets to manage
- Flux already has write access (image automation uses it)
- Follows principle of least privilege (each pod gets what it needs)

**RBAC:**
```yaml
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["flux-system"]  # Can only read this secret
  verbs: ["get"]
```

**SSH key handling:**
- Mounted read-only: `/run/secrets/ssh-identity`
- Permissions: 0400 (read-only for user)
- Used by GitPython for authentication

### 4. Git as Deployment Trigger

**Decision:** Failover-api commits to Git, Flux handles deployment

**Why:**
- Respects GitOps principle (Git is source of truth)
- Audit trail (every failover is a git commit)
- Safer than in-cluster patching (reverts on Flux reconcile)
- Flux reconciliation guarantees consistency

**Alternative considered:** In-cluster patching (what old monitor did)
- ❌ Changes get reverted by Flux
- ❌ No audit trail
- ❌ Conflicting with GitOps model
- ❌ Unpredictable state

### 5. Dry-Run Support

**Decision:** Default is dry-run; require flag to execute

```bash
# Dry run (safe)
curl /api/failover/sonarr/promote?dry-run=true
# Response: [DRY RUN] Would perform failover (no changes made)

# Execute
curl /api/failover/sonarr/promote
# Actually commits and pushes
```

**Why:**
- Test logic before committing
- Catch configuration errors early
- Operator confidence before triggering on real failure
- Safe for CI/CD integration

## MetalLB & Traefik Integration

### How MetalLB Handles Failover

**MetalLB's role:**
```
External traffic
    │
    ├─ Service IP (announced by MetalLB)
    │  └─ Stays same during failover
    │
    ├─ Endpoint IP (changes on failover)
    │  └─ Updated by Kubernetes endpoint controller
    │
    └─ Pod runs on backup node
```

**Why it "just works":**
1. Service IP doesn't change (MetalLB still announces it)
2. Endpoint controller updates Service endpoints
3. Traffic automatically follows new endpoint
4. No MetalLB configuration changes needed

**Example:**
```bash
# Before failover
kubectl get endpoints sonarr -n media
NAME     ENDPOINTS        AGE
sonarr   10.42.1.150:8989   5m

# Trigger failover
curl /api/failover/sonarr/promote

# After failover (few seconds later)
kubectl get endpoints sonarr -n media
NAME     ENDPOINTS        AGE
sonarr   10.42.0.201:8989   5m
# IP changed (different node CIDR), MetalLB unchanged
```

### How Traefik Handles Failover

**Traefik's role:**
```
External traffic
    │
    ├─ Ingress resource (static)
    │  └─ Points to service name: sonarr
    │
    ├─ Service IP (announced by MetalLB)
    │
    └─ Pod endpoints (updated by Kubernetes)
```

**Why it "just works":**
1. Traefik watches Ingress resources (cluster-wide)
2. Ingress points to Service by name (service.namespace.svc.cluster.local)
3. Service endpoints are managed by Kubernetes endpoint controller
4. Traefik auto-updates routing when endpoints change
5. DNS is cached but Service IP doesn't change

**What happens during failover:**
1. You trigger failover via API
2. failover-api commits updated deployment
3. Flux applies deployment (nodeSelector + PVC change)
4. Old pod evicts from k3s-w1
5. New pod starts on k3s-w2
6. Endpoint controller updates Service with new pod IP
7. Traefik detects endpoint change via watch
8. Traefik routes new traffic to new pod
9. **No manual Traefik configuration needed**

**Testing connectivity during failover:**
```bash
# Before failover
curl http://sonarr.yourdomain.com/api/system/status

# Trigger failover
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote

# Wait ~10 seconds for pod to start
sleep 10

# After failover - traffic works automatically
curl http://sonarr.yourdomain.com/api/system/status
# Response: Same as before, no errors
```

### Potential Issues & Mitigations

**Issue 1: DNS cache in client**
- Client caches sonarr.yourdomain.com → IP
- During failover, Service IP doesn't change (MetalLB BGP stabilizes)
- **No issue:** Service IP stable, endpoints update behind it

**Issue 2: BGP convergence time**
- MetalLB BGP may take 30-60s to converge on node change
- Traffic may briefly go to k3s-w1 (old BGP path)
- **Mitigation:** Pod is gone anyway, kernel resets connection
- **Better:** Use shorter BGP timers in UNIFI-BGP-CONFIG

**Issue 3: Session persistence (if needed)**
- HTTP sessions lost when pod moves
- **Mitigation:** Configure Redis for session store (app-specific)

## Scaling to 20+ Services

### How This Works

**Current:**
- 1 failover-api deployment
- Handles Sonarr today
- Can handle unlimited services

**Adding Radarr:**
1. Edit ConfigMap (add radarr entry)
2. Push to Git
3. Flux applies ConfigMap update
4. failover-api detects new service in next request
5. Call works immediately: `curl /api/failover/radarr/promote`

**No redeployment needed.** Configuration-driven design means:
- New service = add ConfigMap entry
- Same binary handles everything
- No code changes, no rebuild, no redeploy

### ConfigMap Structure

```yaml
services:
  sonarr:     # First app
    ...
  radarr:     # Second app
    ...
  prowlarr:   # Third app
    ...
  # ... add as many as you want
  service-20:
    ...
```

**Each service entry:**
```yaml
namespace: media              # Pod runs here
deployment: sonarr            # Deployment name
volume_name: sonarr-data      # Pod volume name (exact match)
primary_pvc: pvc-sonarr       # Primary PVC
backup_pvc: pvc-sonarr-backup # Backup PVC
primary_node_label: primary   # Node selector for primary
backup_node_label: backup     # Node selector for backup
```

**Deployment pattern requirements:**
- Must use VolSync for replication
- Must have primary + backup PVCs
- Must use nodeSelector with role labels
- Must have volume matching the config

## Testing & Validation

### Pre-Deployment Checklist

- [ ] ConfigMap has correct service entries
- [ ] Deployment file location matches paths in code
- [ ] SSH key in flux-system secret has write access
- [ ] GitHub deploy key shows "Allow write access" enabled
- [ ] Flux reconciliation succeeds
- [ ] failover-api deployment is ready

### Testing Failover (Dry-Run)

```bash
# Get into pod
kubectl exec -it -n operations deployment/failover-api -- bash

# Test dry-run from inside
curl http://localhost:8080/api/failover/sonarr/promote?dry-run=true

# Check logs
kubectl logs -n operations -l app=failover-api --tail=50
```

### Testing Failover (Real)

**WARNING: This will cause brief downtime**

```bash
# 1. Verify Sonarr is running on k3s-w1
kubectl get pods -n media -o wide | grep sonarr

# 2. Check current Git state
git log --oneline clusters/homelab/apps/media/sonarr/deployment.yaml | head -1

# 3. Trigger failover
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote

# 4. Watch Git changes
git pull  # Get latest
git diff HEAD~1 clusters/homelab/apps/media/sonarr/deployment.yaml

# 5. Watch pod reschedule
kubectl get pods -n media -o wide --watch

# 6. Once running, failback
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote

# 7. Verify pod back on primary
kubectl get pods -n media -o wide | grep sonarr
```

## Monitoring & Observability

### Logs

```bash
# Follow failover-api logs
kubectl logs -n operations -l app=failover-api -f

# Look for failover operations
kubectl logs -n operations -l app=failover-api | grep -i "promote\|demote"
```

### Git Audit Trail

```bash
# See all failover operations
git log --grep="failover" --oneline clusters/homelab/apps/

# See commits from failover-api
git log --author="failover-api" --oneline

# View details of specific failover
git show <commit-hash>
```

### Service Availability

```bash
# Check if failover-api pods are healthy
kubectl get pods -n operations -l app=failover-api

# Check if service is reachable
kubectl get svc -n operations failover-api

# Test health check
curl http://failover-api.operations.svc.cluster.local/api/health
```

## Future Enhancements

### Near-term
- [ ] Automatic monitoring (watch node status, trigger on failure)
- [ ] Prometheus metrics (failover count, Git operation duration)
- [ ] Slack/email notifications

### Medium-term
- [ ] Web UI for manual controls
- [ ] Automatic failback on primary recovery
- [ ] Rate limiting for failover requests
- [ ] Service dependency ordering (e.g., fail back services in order)

### Long-term
- [ ] Cross-cluster failover (homeLab → remote cluster)
- [ ] Multi-cluster orchestration
- [ ] AI-based failure prediction
- [ ] Automatic tuning of failover thresholds
