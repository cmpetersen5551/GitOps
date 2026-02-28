# FUSE Test — Command Reference Card

Quick copy-paste commands for test management and monitoring.

---

## Enable Test via Flux

```bash
# 1. Open editor
nano /Users/Chris/Source/GitOps/clusters/homelab/testing/kustomization.yaml

# 2. Uncomment this line (remove leading # and space):
# - fuse-propagation-test
# Should become:
- fuse-propagation-test

# 3. Save (Ctrl+O, Enter, Ctrl+X in nano) then commit
cd /Users/Chris/Source/GitOps
git add clusters/homelab/testing/kustomization.yaml
git commit -m "test: enable FUSE propagation test"
git push origin v2
```

---

## Monitor Test in Real Time

```bash
# Watch pod status (in tab 1)
watch kubectl get pods -n fuse-test -o wide

# Follow consumer results (in tab 2) — look for SUCCESS/FAILURE here
kubectl logs -f -n fuse-test fuse-consumer

# Follow producer debug info (in tab 3)
kubectl logs -f -n fuse-test fuse-producer
```

---

## Check Test Status (Flux)

```bash
# Is Flux managing it?
flux get kustomization testing

# See Flux sync status
flux get all

# Force Flux to reconcile (if needed)
flux reconcile kustomization testing --with-source
```

---

## Disable Test (Stop Early)

```bash
# 1. Open editor
nano /Users/Chris/Source/GitOps/clusters/homelab/testing/kustomization.yaml

# 2. Re-comment the line (add # and space):
- fuse-propagation-test
# Should become:
# - fuse-propagation-test

# 3. Save and commit
cd /Users/Chris/Source/GitOps
git add clusters/homelab/testing/kustomization.yaml
git commit -m "test: disable FUSE propagation test"
git push origin v2

# Wait 1-2 minutes for Flux to clean up namespace
```

---

## Capture Test Results

```bash
# Save consumer results (SUCCESS/FAILURE is here)
kubectl logs -n fuse-test fuse-consumer > ~/fuse-consumer-results.log

# Save producer debug logs
kubectl logs -n fuse-test fuse-producer > ~/fuse-producer-debug.log

# View on disk
cat ~/fuse-consumer-results.log
cat ~/fuse-producer-debug.log
```

---

## Inspect Test Pods

```bash
# List all test pods
kubectl get pods -n fuse-test

# Detailed pod info
kubectl describe pod -n fuse-test fuse-producer
kubectl describe pod -n fuse-test fuse-consumer

# Check pod events
kubectl describe pod -n fuse-test fuse-consumer | tail -20
```

---

## Kubernetes Context (Verify Cluster)

```bash
# Confirm you're on right cluster
kubectl cluster-info
kubectl get nodes

# Verify w2 is available (test runs there)
kubectl get nodes | grep w2
```

---

## Git Commands (For Reference)

```bash
# Check current branch
git branch

# View uncommitted changes
git status

# View changes before committing
git diff clusters/homelab/testing/kustomization.yaml

# View commit history for this file
git log -p clusters/homelab/testing/kustomization.yaml
```

---

## Common Issues & Quick Fixes

**Pods not starting**
```bash
# Check events
kubectl describe pod -n fuse-test fuse-producer
kubectl describe pod -n fuse-test fuse-consumer

# Check if namespace exists
kubectl get namespace fuse-test

# Manually check pod definitions
kubectl get pod -n fuse-test fuse-producer -o yaml
```

**Flux not reconciling**
```bash
# Check Flux status
flux get all

# Manual reconcile
flux reconcile kustomization testing --with-source

# Check Flux logs
flux logs --all-namespaces --follow
```

**Want to restart test**
```bash
# Disable, wait for cleanup
# Then enable again — simpler than manual restart

# Or manually restart pods if needed
kubectl delete pod -n fuse-test fuse-producer
kubectl delete pod -n fuse-test fuse-consumer
# Flux will restart them
```

---

## Documentation References

| Task | Document |
|------|----------|
| **Full Test Design** | [FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md) |
| **Step-by-Step Plan** | [FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md) |
| **Quick Reference** | [FUSE_TEST_QUICK_START.md](FUSE_TEST_QUICK_START.md) |
| **Flux Integration** | [FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md) |
| **Status & Next Steps** | [FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md) |
| **This Reference** | [FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md) |

---

## Test Results Summary Template

When test completes, answer these questions:

```
Test Date: [YYYY-MM-DD]
Test Duration: [started at... ended at...]
Result: [SUCCESS / FAILURE / ERROR]

Key Observations:
- Producer FUSE mount created? [YES/NO]
- Consumer could read mount? [YES/NO]  
- Specific errors seen: [paste from logs]

Recommendation:
- Can proceed with direct FUSE? [YES/NO]
- Next steps: [...]
```

---

## Gotchas

⚠️ **Don't forget to push to Git** — uncommenting locally won't trigger Flux  
⚠️ **Test runs on w2 only** — verify w2 is healthy before starting  
⚠️ **Test namespace is not auto-deleted immediately** — leave it for inspection (Flux removes after some time)  
⚠️ **Don't mix git and kubectl** — use Flux for all deployments, not manual `kubectl apply`

---

**Last Updated**: 2026-02-28
