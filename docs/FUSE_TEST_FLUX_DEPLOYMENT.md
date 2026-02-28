# FUSE Propagation Test — Flux Deployment Guide (2026-02-28)

**Status**: Test manifests integrated into GitOps via Flux  
**Deployment Method**: Git → Flux (automatic reconciliation)  
**Test Location**: `clusters/homelab/testing/fuse-propagation-test/`

---

## Enabling the Test

The test is currently **disabled by default** (safe for production). To enable it:

### Step 1: Uncomment in Git

Edit: `clusters/homelab/testing/kustomization.yaml`

```yaml
# Change from:
resources:
  # - fuse-propagation-test

# To:
resources:
  - fuse-propagation-test
```

### Step 2: Commit & Push

```bash
cd /Users/Chris/Source/GitOps
git add clusters/homelab/testing/kustomization.yaml
git commit -m "test: enable FUSE propagation test via Flux"
git push
```

### Step 3: Flux Reconciles Automatically

Flux will detect the change and deploy within the next reconciliation cycle (~5-10 seconds):

```bash
# Monitor reconciliation (optional)
flux get kustomization testing --watch

# Or check Flux logs
flux logs --all-namespaces --follow | grep fuse
```

### Step 4: Monitor Test Pods

```bash
# Watch test pods start
watch kubectl get pods -n fuse-test -o wide

# Follow producer logs
kubectl logs -f -n fuse-test fuse-producer

# Follow consumer logs
kubectl logs -f -n fuse-test fuse-consumer
```

---

## Disabling the Test

When test is complete, disable it:

### Step 1: Comment Out in Git

Edit: `clusters/homelab/testing/kustomization.yaml`

```yaml
# Change from:
resources:
  - fuse-propagation-test

# To:
resources:
  # - fuse-propagation-test
```

### Step 2: Commit & Push

```bash
git add clusters/homelab/testing/kustomization.yaml
git commit -m "test: disable FUSE propagation test (completed)"
git push
```

### Step 3: Flux Reconciles & Cleans Up

Flux will delete the test namespace and all test pods automatically:

```bash
# Watch cleanup
watch kubectl get namespace fuse-test

# Should disappear within 1 minute
```

---

## Why This Approach?

### Benefits of Flux Deployment

✅ **GitOps Discipline**: All tests in Git, no manual kubectl commands  
✅ **Automatic Cleanup**: Disable in Git, Flux deletes everything  
✅ **Audit Trail**: Git history shows when test was enabled/disabled  
✅ **Team Transparency**: Everyone sees what's running via Git  
✅ **Easy to Re-enable**: Just uncomment and push again  

### Alternative (Manual)

If you prefer manual control without Flux integration:

```bash
# Manual deployment (not recommended, breaks GitOps discipline)
kubectl apply -f clusters/homelab/testing/fuse-propagation-test/

# Manual cleanup
kubectl delete namespace fuse-test
```

---

## Monitoring Test Execution

### Real-Time Dashboard

Open 3 terminal tabs:

**Tab 1 - Pod Status**:
```bash
watch kubectl get pods -n fuse-test -o wide
# Watch for: Running → Success or CrashLoopBackOff
```

**Tab 2 - Producer Logs**:
```bash
kubectl logs -f -n fuse-test fuse-producer
# Look for: "Producer Ready, Keeping Alive"
```

**Tab 3 - Consumer Logs**:
```bash
kubectl logs -f -n fuse-test fuse-consumer
# SUCCESS: "Producer marker found"
# FAILURE: "Producer marker never appeared"
```

### Flux Status

```bash
# Check if Flux is managing the test
flux get kustomization testing

# Expected output:
# NAME     READY   STATUS
# testing  True    Applied revision main@sha1:<hash>

# Check for errors
flux get source git

# If there's an issue:
flux describe kustomization testing --all=true
```

---

## Test Lifecycle via Flux

```
┌─ User edits clusters/homelab/testing/kustomization.yaml
│  └─ Uncomments: fuse-propagation-test
│
├─ Git commit & push

├─ Flux detects change (5-10s)
│  └─ Downloads new commit from Git
│
├─ Flux applies kustomization
│  ├─ Creates namespace: fuse-test
│  ├─ Creates ConfigMaps/Secrets (none in this test)
│  ├─ Creates Pod: fuse-producer
│  └─ Creates Pod: fuse-consumer
│
├─ Test pods initialize (30-60s)
│  ├─ Producer: Writes files
│  └─ Consumer: Reads and verifies
│
├─ Test runs (30+ minutes)
│  ├─ Phases 1-5 execute
│  └─ Pods report results in logs
│
├─ User examines results
│  └─ kubectl logs fuse-consumer/fuse-producer
│
├─ User disables test (git edit)
│  └─ Uncommit kustomization
│
├─ Flux detects removal
│  └─ Deletes entire fuse-test namespace
│
└─ Cleanup complete (1 minute)
```

---

## Key Differences from Manual Testing

| Aspect | Manual | Flux |
|--------|--------|------|
| **Deployment** | kubectl apply | git push |
| **Cleanup** | kubectl delete | git push |
| **Audit Trail** | None | Full Git history |
| **Discoverability** | Hidden in your files | Visible in clusters/ |
| **Revert** | git revert only | git toggle + Flux auto-cleanup |
| **Documentation** | Separate notes | In Git as config |
| **Repeatability** | Manual steps each time | One edit toggle |

---

## Troubleshooting Flux Integration

### Test manifests not deploying

```bash
# Check if testing/kustomization.yaml is correctly formatted
kubectl kustomize clusters/homelab/testing/
# Should show fuse-propagation-test resources

# Check Flux source repository status
flux get sources git

# Check Flux kustomization status
flux get kustomization testing
flux describe kustomization testing

# Manually trigger reconciliation
flux reconcile kustomization testing --with-source
```

### Pods not starting after enabling

```bash
# Check manifest validation
kubectl apply -f clusters/homelab/testing/fuse-propagation-test/ --dry-run=client -o wide

# Check pod events
kubectl describe pod -n fuse-test fuse-producer
kubectl describe pod -n fuse-test fuse-consumer

# Check namespace creation
kubectl get namespace fuse-test

# Check for scheduling issues
kubectl get pods -n fuse-test --all-namespaces
```

### Test won't disable/delete

```bash
# Force recreate if stuck
git checkout HEAD -- clusters/homelab/testing/kustomization.yaml
# Then edit again properly

# Manual cleanup if needed
kubectl delete namespace fuse-test --ignore-not-found=true

# Verify Flux cleaned up
kubectl get namespace fuse-test 2>&1 || echo "Namespace deleted"
```

---

## Expected Behavior

### When Test Enabled

```bash
$ kubectl get namespace fuse-test
NAME       STATUS   AGE
fuse-test  Active   2m

$ kubectl get pods -n fuse-test
NAME                READY   STATUS    RESTARTS   AGE
fuse-producer       1/1     Running   0          2m
fuse-consumer       1/1     Running   0          1m

$ kubectl logs -n fuse-test fuse-consumer | grep SUCCESS
SUCCESS: Producer marker found at <timestamp>
```

### When Test Disabled

```bash
$ kubectl get namespace fuse-test
Error from server (NotFound): namespaces "fuse-test" not found
# (Flux cleaned it up within 1-2 minutes)
```

---

## Next Steps

1. **Enable test**: Uncomment in `clusters/homelab/testing/kustomization.yaml`
2. **Commit & push**: Let Flux deploy automatically
3. **Monitor**: Watch pod logs for SUCCESS or FAILURE
4. **Analyze**: Review results using decision tree in FUSE_TEST_OVERVIEW.md
5. **Disable test**: Comment out in kustomization.yaml when done
6. **Commit & push**: Flux cleans up automatically

---

## Using Flux for Active Testing

For real-time iteration during testing:

```bash
# Terminal 1: Watch Flux reconciliation
flux get kustomization testing --watch

# Terminal 2: Watch test pods
watch kubectl get pods -n fuse-test -o wide

# Terminal 3: Follow consumer logs
kubectl logs -f -n fuse-test fuse-consumer

# Terminal 4: Make changes to manifests, commit & push
git add clusters/homelab/testing/fuse-propagation-test/producer.yaml
git commit -m "test: tweak producer behavior"
git push
# Flux reconciles and rolls out changes (~10s)
```

This GitOps workflow means you never need to run `kubectl apply` — everything goes through Git and Flux!

---

**Status**: Test ready for Flux deployment  
**Method**: Edit Git, push, Flux handles it  
**Cleanup**: Comment out in Git, Flux auto-deletes  
**Next Action**: Enable test in `clusters/homelab/testing/kustomization.yaml` and push
