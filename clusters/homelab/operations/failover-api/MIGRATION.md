# Migration Guide: From Monitor Pod to Failover API

This guide walks through replacing the old `volsync-failover` monitor pod with the new failover-api service.

## Summary of Changes

**Old approach (monitor pod):**
- ❌ Patches deployments directly in-cluster
- ❌ Conflicts with Flux reconciliation
- ❌ AUTO_FAILOVER disabled (monitoring but no action)
- ❌ Hardcoded for Sonarr
- ❌ Single point of failure

**New approach (failover-api):**
- ✅ Commits changes to Git (Flux applies them)
- ✅ Respects GitOps model
- ✅ Manual HTTP trigger (deterministic)
- ✅ Dynamic configuration (works for 20+ services)
- ✅ HA deployment (runs on multiple nodes)

## Migration Steps

### Phase 1: Deploy Failover API

**Branch:** `feature/failover-api`

1. **Review the code:**
   ```bash
   git diff main -- clusters/homelab/operations/failover-api/
   ```
   - Check app.py logic
   - Review deployment HA setup
   - Verify RBAC is minimal
   - Confirm ConfigMap has correct services

2. **Build and push Docker image:**
   ```bash
   # If using local registry or Docker Hub
   cd clusters/homelab/operations/failover-api
   docker build -t failover-api:latest .
   docker tag failover-api:latest <your-registry>/failover-api:latest
   docker push <your-registry>/failover-api:latest
   
   # Update image in deployment.yaml
   # image: <your-registry>/failover-api:latest
   ```
   
   **Or use Flux Image Automation:**
   - Push to registry with tag
   - Flux will update image reference automatically

3. **Merge to main:**
   ```bash
   git checkout main
   git pull
   git merge feature/failover-api
   git push
   ```

4. **Verify deployment:**
   ```bash
   # Flux reconciles within 1 minute
   flux get kustomizations -n flux-system operations
   
   # Check failover-api pods
   kubectl get pods -n operations -l app=failover-api
   
   # Verify service is accessible
   kubectl get svc -n operations failover-api
   ```

### Phase 2: Test Failover API

**Before decommissioning monitor pod:**

1. **Test dry-run (safe):**
   ```bash
   curl http://failover-api.operations.svc.cluster.local/api/services
   
   curl http://failover-api.operations.svc.cluster.local/api/failover/sonarr/status
   
   curl http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote?dry-run=true
   ```

2. **Test real failover (causes brief downtime):**
   ```bash
   # 1. Check where Sonarr is running
   kubectl get pods -n media -o wide | grep sonarr
   
   # 2. Trigger failover
   curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote
   
   # 3. Watch pod reschedule
   kubectl get pods -n media -o wide --watch
   
   # 4. Verify failback works
   curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote
   
   # 5. Verify pod is back on primary
   kubectl get pods -n media -o wide | grep sonarr
   ```

### Phase 3: Decommission Old Monitor

**Only after confirming failover-api works:**

1. **Delete the old monitor pod:**
   ```bash
   # Create cleanup branch
   git checkout -b cleanup/remove-monitor
   
   # Delete old monitor
   rm -rf clusters/homelab/operations/volsync-failover/
   ```

2. **Update kustomization:**
   ```yaml
   # clusters/homelab/operations/kustomization.yaml
   # Remove:
   # - ./volsync-failover
   
   # Keep:
   # - ./failover-api
   ```

3. **Commit and merge:**
   ```bash
   git add clusters/homelab/operations/
   git commit -m "Remove old monitor pod, use failover-api instead"
   git push -u origin cleanup/remove-monitor
   # Create PR, review, merge
   ```

4. **Verify cleanup:**
   ```bash
   # Flux reconciles
   flux get kustomizations -n flux-system operations
   
   # Old monitor pod should be deleted
   kubectl get pods -n operations
   # Should only show failover-api pods
   ```

## Comparison

### Old Monitor Pod

```yaml
# Watched node status
# If node NotReady for 120+ seconds, attempted failover
# But AUTO_FAILOVER=false, so didn't actually do anything
# Just logged and exited

# What happened when you shut down w1:
1. Monitor detected w1 NotReady
2. Monitor tried to patch deployment
3. But Flux reconciled and reverted the patch
4. Pod remained Pending
```

### New Failover API

```yaml
# Waits for human decision (HTTP request)
# When triggered, commits to Git
# Flux sees Git change and applies it
# Pod reschedules automatically

# What happens when you shut down w1:
1. w1 becomes NotReady
2. Pod evicted from w1, enters Pending
3. User triggers failover:
   curl /api/failover/sonarr/promote
4. failover-api commits updated deployment to Git
5. Flux detects change within 1 minute
6. Flux applies updated deployment
7. Pod reschedules to w2
8. Pod starts normally on backup PVC
```

## Troubleshooting Migration

### failover-api pods not starting

```bash
# Check for image issues
kubectl describe pod -n operations -l app=failover-api

# Check if SSH secret exists
kubectl get secret flux-system -n flux-system

# Check if ConfigMap is mounted
kubectl exec -it -n operations <pod-name> -- ls -la /etc/failover-api/
```

### Git operations fail

```bash
# Check if SSH key has write access
# GitHub Settings → Deploy Keys → Check "Allow write access"

# Verify secret contents
kubectl get secret flux-system -n flux-system -o jsonpath='{.data.identity}' | base64 -d | head -1
# Should start with: -----BEGIN OPENSSH PRIVATE KEY-----
```

### Failover triggered but no Git commit

```bash
# Check logs
kubectl logs -n operations -l app=failover-api --tail=50

# Look for:
# - "Starting backup failover"
# - "Updated volume" messages
# - "Pushed changes to GitHub"

# If "Git operation failed":
# 1. Verify secret has write access
# 2. Verify path to deployment.yaml is correct in ConfigMap
```

## Rollback Plan

If failover-api causes issues:

```bash
# Revert to old monitor
git revert <merge-commit-hash-of-cleanup>
git push

# Flux will reapply old monitor
kubectl get pods -n operations

# Re-enable if needed (change AUTO_FAILOVER=true in old deployment)
```

## Next Steps

After migration is stable:

1. **Add more services** to ConfigMap (Radarr, etc.)
2. **Set up alerting** to trigger failover automatically
3. **Document procedures** in OPERATIONS.md
4. **Consider Prometheus** metrics integration
5. **Plan automatic failback** for future
