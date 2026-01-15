# Failover API - Implementation Checklist

**Branch:** `feature/failover-api`
**Status:** Ready for review and merge

## Pre-Merge Review Checklist

Before merging to main, verify:

### Code Review
- [ ] Read `clusters/homelab/operations/failover-api/app.py`
- [ ] Understand the failover logic
- [ ] Check error handling
- [ ] Verify security practices
- [ ] Review Git operations

### Architecture Review  
- [ ] Review `clusters/homelab/operations/failover-api/ARCHITECTURE.md`
- [ ] Understand why each design decision was made
- [ ] Confirm HA design makes sense
- [ ] Validate MetalLB/Traefik integration explanation
- [ ] Check if multi-service scaling approach works for you

### Kubernetes Resources
- [ ] Review deployment.yaml (2 replicas, pod anti-affinity)
- [ ] Check rbac.yaml (minimal permissions)
- [ ] Verify pdb.yaml (minAvailable: 1)
- [ ] Confirm service.yaml (ClusterIP, internal only)

### Configuration
- [ ] Check configmap.yaml (service definitions)
- [ ] Confirm sonarr entry is correct
- [ ] Plan how you'll add radarr, prowlarr, etc.

### Documentation
- [ ] Read README.md (usage guide)
- [ ] Review MIGRATION.md (step-by-step process)
- [ ] Check examples match your cluster names

---

## Post-Merge Implementation (You'll Do These)

### Phase 1: Build & Deploy (1-2 hours)

**1. Build Docker Image**
```bash
cd clusters/homelab/operations/failover-api
docker build -t failover-api:latest .
docker tag failover-api:latest your-registry/failover-api:latest
docker push your-registry/failover-api:latest
```

**2. Update deployment.yaml**
```yaml
# clusters/homelab/operations/failover-api/deployment.yaml
spec:
  template:
    spec:
      containers:
      - name: failover-api
        image: your-registry/failover-api:latest  # Update this
```

**3. Merge to main**
```bash
git checkout main
git pull
git merge feature/failover-api
git push
```

**4. Verify Flux applies it**
```bash
flux get kustomizations -n flux-system operations
kubectl get pods -n operations -l app=failover-api
```

### Phase 2: Testing (30-60 minutes)

**1. Verify Pods Running**
```bash
kubectl get pods -n operations -l app=failover-api
# Should show 2 pods (one on each worker)
```

**2. Test Dry-Run**
```bash
kubectl exec -it -n operations deployment/failover-api -- bash
curl http://localhost:8080/api/services
curl http://localhost:8080/api/failover/sonarr/status
curl http://localhost:8080/api/failover/sonarr/promote?dry-run=true
```

**3. Check Logs**
```bash
kubectl logs -n operations -l app=failover-api --all-containers=true -f
```

**4. Test Real Failover** (causes 1-2 min downtime)
```bash
# Check Sonarr location
kubectl get pods -n media -o wide | grep sonarr

# Trigger failover
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote

# Watch it reschedule
kubectl get pods -n media -o wide --watch

# After it's running on k3s-w2, trigger failback
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote

# Watch it go back to k3s-w1
kubectl get pods -n media -o wide --watch
```

**5. Verify Git Changes**
```bash
# Check commits
git log --oneline clusters/homelab/apps/media/sonarr/deployment.yaml | head -5

# Should see failover-api commits like:
# abc1234 Automated failover: sonarr to backup node
# def5678 Automated failback: sonarr to primary node
```

### Phase 3: Decommission Old Monitor (30 minutes)

**1. Create cleanup branch**
```bash
git checkout -b cleanup/remove-monitor
```

**2. Delete old monitor**
```bash
rm -rf clusters/homelab/operations/volsync-failover/
```

**3. Update kustomization.yaml**
```yaml
# clusters/homelab/operations/kustomization.yaml
# Remove:  - ./volsync-failover
# Keep:    - ./failover-api
```

**4. Commit and merge**
```bash
git add clusters/homelab/operations/
git commit -m "Remove old monitor pod, use failover-api instead"
git push -u origin cleanup/remove-monitor
# Create PR, review, merge
```

**5. Verify cleanup**
```bash
kubectl get pods -n operations
# Should only see failover-api pods (no monitor pod)
```

### Phase 4: Scale to More Services (Optional, can do later)

**For each new service (Radarr, Prowlarr, etc.):**

1. Ensure service has HA setup (primary/backup PVCs, VolSync replication)
2. Add entry to ConfigMap:
```yaml
configmap:
  services.yaml: |
    services:
      sonarr: ...
      radarr:  # Add this
        namespace: media
        deployment: radarr
        volume_name: radarr-data
        primary_pvc: pvc-radarr
        backup_pvc: pvc-radarr-backup
        primary_node_label: primary
        backup_node_label: backup
```

3. Push to Git (Flux updates ConfigMap automatically)
4. API immediately works: `curl /api/failover/radarr/promote`

---

## Key Files You'll Interact With

### During Implementation
```
clusters/homelab/operations/failover-api/
├── Dockerfile          # Build this
├── deployment.yaml     # Update image: field
├── configmap.yaml      # Add services here later
├── app.py             # Reference only
├── README.md          # Reference for usage
├── ARCHITECTURE.md    # Reference for design decisions
└── MIGRATION.md       # Reference for step-by-step process
```

### Command Cheat Sheet

```bash
# List services
curl http://failover-api.operations.svc.cluster.local/api/services

# Failover to backup
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote

# Failback to primary
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote

# Dry run
curl http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote?dry-run=true

# Health check
curl http://failover-api.operations.svc.cluster.local/api/health

# Check logs
kubectl logs -n operations -l app=failover-api -f

# Port-forward for external access
kubectl -n operations port-forward svc/failover-api 8080:8080
# Then from your laptop: curl http://localhost:8080/api/services
```

---

## Troubleshooting Quick Reference

| Issue | Diagnosis | Fix |
|-------|-----------|-----|
| Pods not starting | `kubectl describe pod` | Image doesn't exist or image pull error |
| Git operation fails | Check logs for SSH error | Flux key doesn't have write access |
| Failover didn't happen | Check logs for deployment path | Deployment location doesn't match config |
| Service not reachable | `kubectl get svc -n operations` | Service might not be ready yet |
| Old monitor still running | `kubectl get pods -n operations` | Need to delete volsync-failover |

---

## Risk Assessment

### Low Risk
- ✅ Only reads Flux SSH key (doesn't create new credentials)
- ✅ Only commits to Git (Flux applies, reversible)
- ✅ Runs in operations namespace (isolated)
- ✅ No cluster API modifications
- ✅ Completely optional (can keep old monitor if needed)

### Medium Risk
- ⚠️ Modifies deployment.yaml in Git (but reverts work fine)
- ⚠️ Causes pod restart (service downtime during failover)
- ⚠️ Requires SSH key access (manage carefully)

### Mitigation
- Always test with dry-run first
- Merge old monitor removal last (keep it running initially)
- Monitor Git activity (check for unexpected commits)
- Have failback procedure ready (demote command)

---

## Success Criteria

After all phases, you'll have:

✅ Failover API running on both worker nodes  
✅ Can trigger failover with `curl /api/failover/sonarr/promote`  
✅ Service automatically moves to backup node within 1-2 minutes  
✅ Git commits track every failover operation  
✅ Failback works the same way (service moves back to primary)  
✅ Works for any number of services (just add to ConfigMap)  
✅ HA property: if one node fails, failover-api continues working  

---

## Timeline Estimate

- **Phase 1 (Build & Deploy):** 1-2 hours
- **Phase 2 (Testing):** 30-60 minutes
- **Phase 3 (Decommission):** 30 minutes
- **Phase 4 (Add More Services):** 15 minutes each

**Total:** ~3 hours for full implementation

---

## Questions Before You Start?

Read these in order:
1. `PR_SUMMARY.md` - High-level overview
2. `FAILOVER_API_REVIEW.md` - Implementation details
3. `clusters/homelab/operations/failover-api/README.md` - Usage guide
4. `clusters/homelab/operations/failover-api/ARCHITECTURE.md` - Design deep-dive

If anything's unclear, I can help clarify!

---

**You're all set to review and implement!** 🚀
