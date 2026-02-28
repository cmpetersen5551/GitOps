# FUSE Propagation Test — Deployment Ready (2026-02-28)

**Status**: ✅ **READY FOR DEPLOYMENT**  
**Method**: Flux/GitOps (recommended) or manual kubectl  
**Test Node**: w2 (non-production, secondary storage node)  
**Duration**: ~30 minutes  
**Safety**: Isolated namespace, zero production impact  

---

## Executive Summary

The FUSE propagation test is **fully prepared and integrated** into the GitOps/Flux workflow. All manifests, scripts, and documentation are in place. The test is currently **disabled by default** (safe for production). 

**To start the test**: Edit one line in Git, commit, and push. Flux handles the rest automatically.

---

## What's Ready

### ✅ Test Manifests (Integrated into Flux)

```
clusters/homelab/testing/fuse-propagation-test/
├── namespace.yaml           ✓ Creates fuse-test namespace
├── producer.yaml            ✓ FUSE producer pod (privileged)
├── consumer.yaml            ✓ Consumer pod (verifies propagation)
└── kustomization.yaml       ✓ Bundles all 3 manifests
```

### ✅ Flux Integration (Ready)

```
clusters/homelab/
├── kustomization.yaml       ✓ Includes "testing" directory
└── testing/
    ├── kustomization.yaml   ✓ Test parent (disabled by default)
    └── fuse-propagation-test/
```

### ✅ Test Script (Alternative)

```
scripts/test-fuse-propagation.sh   ✓ Manual test runner (optional)
```

### ✅ Documentation (Complete)

| Document | Purpose | Status |
|----------|---------|--------|
| [FUSE_TEST_DOCUMENTATION_MAP.md](FUSE_TEST_DOCUMENTATION_MAP.md) | Navigation guide | ✓ Complete |
| [FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md) | Full test design | ✓ Complete |
| [FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md) | Step-by-step plan | ✓ Complete |
| [FUSE_TEST_QUICK_START.md](FUSE_TEST_QUICK_START.md) | Quick reference | ✓ Complete |
| [FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md) | Flux deployment guide | ✓ Complete |
| [FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md) | Status & next steps | ✓ Complete |
| [FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md) | Command reference | ✓ Complete |

---

## Current State

### Test Status
- **Enabled**: No (disabled by default, safe for production)
- **Deployment Method**: Flux/GitOps (recommended)
- **Flux Status**: Connected and ready
- **Test Namespace**: Defined but not created yet
- **Test Pods**: Defined but not deployed yet

### Cluster Prerequisites
- ✅ k3s cluster (v2 branch)
- ✅ Flux managing cluster (GitOps enabled)
- ✅ w2 node available and healthy
- ✅ Git repo accessible and pushable
- ✅ kubectl configured

---

## How to Enable (Quick Start)

### Step 1: Edit Git

```bash
cd /Users/Chris/Source/GitOps
nano clusters/homelab/testing/kustomization.yaml
```

Change this line:
```yaml
# - fuse-propagation-test
```

To this:
```yaml
- fuse-propagation-test
```

### Step 2: Commit & Push

```bash
git add clusters/homelab/testing/kustomization.yaml
git commit -m "test: enable FUSE propagation test"
git push origin v2
```

### Step 3: Watch Deployment

Flux will detect the change within 5-10 seconds and deploy automatically:

```bash
# Terminal 1: Watch pods appear
watch kubectl get pods -n fuse-test -o wide

# Terminal 2: Follow consumer results (look for SUCCESS/FAILURE)
kubectl logs -f -n fuse-test fuse-consumer

# Terminal 3: Follow producer debug info
kubectl logs -f -n fuse-test fuse-producer
```

### Step 4: Review Results

Look for these key outputs in consumer logs:

**SUCCESS**:
```
SUCCESS: Producer marker found at <timestamp>
✓ Direct FUSE propagation can work in k3s
```

**FAILURE**:
```
ERROR: Producer marker never appeared after 30 seconds!
✗ FUSE propagation blocked by namespace isolation
```

---

## Why This Test Matters

### Current Situation (Production)
- Decypharr runs on host (unmanaged, single-node, not HA)
- Uses SMB/CIFS layer to share FUSE mount with k3s
- Adds complexity: LD_PRELOAD nlink workaround, SMB protocol overhead
- Not Kubernetes-native, not HA-capable

### New Hypothesis (Being Tested)
- Decypharr could run in k3s (containerized, HA, GitOps-managed)
- Simplify sharing using direct FUSE propagation via hostPath
- Eliminate SMB/CIFS layer entirely
- Enable modern HA patterns (multiple replicas, failover, etc.)

### Decision Point
- **If SUCCESS**: Validate Decypharr containerization approach, plan migration
- **If FAILURE**: Confirm SMB/CIFS is necessary, continue with current solution

---

## Test Architecture

```
┌─── k3s-w2 (Test Node) ────────────────────────────────┐
│                                                        │
│  ┌─ Pod: fuse-producer ──────────────────────────┐   │
│  │ - Privileged: true                            │   │
│  │ - Volume: /tmp/fuse-test-bridge (hostPath)   │   │
│  │ - Mount: /mnt/dfs (Bidirectional)            │   │
│  │ - Action: Create FUSE mount + test files     │   │
│  └────────────────────────────────────────────────┘   │
│           ↓ writes marker: .producer-ready            │
│  ┌────────────────────────────────────────────────┐   │
│  │ Host Node: /tmp/fuse-test-bridge              │   │
│  │ - Contains: marker files + test data          │   │
│  │ - Mounted by: producer AND consumer pods     │   │
│  └────────────────────────────────────────────────┘   │
│           ↑ reads marker: .producer-ready             │
│  ┌─ Pod: fuse-consumer ──────────────────────────┐   │
│  │ - Privileged: false                           │   │
│  │ - Volume: /tmp/fuse-test-bridge (hostPath)   │   │
│  │ - Mount: /mnt/dfs (HostToContainer)          │   │
│  │ - Action: Read FUSE mount, verify propagation│   │
│  │ - Output: SUCCESS or FAILURE                  │   │
│  └────────────────────────────────────────────────┘   │
│                                                        │
└────────────────────────────────────────────────────────┘
```

---

## Safety Guarantees

### Production Isolation

✅ **Node**: Test runs **only on w2** (secondary storage node)  
✅ **Namespace**: Dedicated `fuse-test` namespace (zero impact on other namespaces)  
✅ **Resources**: Small request/limits (100m CPU, 256Mi RAM max)  
✅ **Storage**: Temp hostPath `/tmp/fuse-test-bridge` (isolated from production data)  
✅ **Duration**: 30 minute test, fully contained  

### Easy Rollback

✅ **Enable**: Edit one line in Git, commit, push  
✅ **Disable**: Edit one line in Git, commit, push  
✅ **Cleanup**: Flux auto-deletes test namespace in 1-2 minutes  
✅ **Audit**: Full Git history of test lifecycle  

### No Production Changes

✅ No changes to Longhorn, NFS, or production storage  
✅ No changes to app namespaces (media, etc.)  
✅ No changes to infrastructure (traefik, metallb, etc.)  
✅ No changes to production pods or configs  

---

## Files Reference

### Documentation (Start Here)

1. **[FUSE_TEST_DOCUMENTATION_MAP.md](FUSE_TEST_DOCUMENTATION_MAP.md)** ← Navigation guide
2. **[FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md)** ← You are here (status summary)
3. **[FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md)** ← Full test methodology
4. **[FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md)** ← Detailed steps
5. **[FUSE_TEST_QUICK_START.md](FUSE_TEST_QUICK_START.md)** ← One-page cheat sheet
6. **[FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md)** ← How to use Flux
7. **[FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md)** ← Command reference

### Manifests (in Git, Flux-managed)

- `clusters/homelab/testing/kustomization.yaml` ← **Edit this to enable**
- `clusters/homelab/testing/fuse-propagation-test/kustomization.yaml`
- `clusters/homelab/testing/fuse-propagation-test/namespace.yaml`
- `clusters/homelab/testing/fuse-propagation-test/producer.yaml`
- `clusters/homelab/testing/fuse-propagation-test/consumer.yaml`

### Script (Manual Alternative)

- `scripts/test-fuse-propagation.sh` ← Optional, use Flux instead

---

## Expected Behavior

### When Test Enabled

```bash
# Flux detects Git change (5-10s)
$ flux get kustomization testing --watch
NAME     READY   STATUS
testing  True    Applied revision main@...

# Pods appear (30-60s)
$ kubectl get pods -n fuse-test
NAME                READY   STATUS    AGE
fuse-producer       1/1     Running   30s
fuse-consumer       1/1     Running   15s

# Result appears in logs (10-15 min)
$ kubectl logs -f -n fuse-test fuse-consumer | grep SUCCESS
SUCCESS: Producer marker found at <timestamp>
```

### When Test Disabled

```bash
# Flux detects Git change
# Deletes test resources automatically (1-2 min)
$ kubectl get namespace fuse-test
Error from server (NotFound): namespaces "fuse-test" not found
```

---

## Recommended Reading Order

1. **This file** (5 min) ← Executive summary
2. **[FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md)** (5 min) ← How to run it
3. **[FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md)** (2 min) ← Commands you'll need
4. **[FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md)** (15 min, optional) ← Full context

Then enable the test and monitor!

---

## Decision Checklist

### Before Starting Test

- [ ] Read this file (5 min)
- [ ] Read Quick Start guide (5 min)
- [ ] Verify cluster health: `kubectl get nodes` ✓
- [ ] Verify w2 is up: `kubectl get nodes | grep w2` ✓
- [ ] Verify Flux is working: `flux get all` ✓
- [ ] Git repo clean: `git status` shows nothing uncommitted ✓

### Starting Test

- [ ] Edit: `clusters/homelab/testing/kustomization.yaml`
- [ ] Change: `# - fuse-propagation-test` → `- fuse-propagation-test`
- [ ] Commit & push: `git commit -m "test: enable..." && git push`
- [ ] Watch pods: `watch kubectl get pods -n fuse-test`
- [ ] Follow logs: `kubectl logs -f -n fuse-test fuse-consumer`

### Interpreting Results

- [ ] Look for: "SUCCESS: Producer marker found" or "ERROR: Producer marker never appeared"
- [ ] Note: Result appears within 10-15 minutes
- [ ] Save logs: `kubectl logs -n fuse-test fuse-consumer > results.log`

### Ending Test

- [ ] Re-comment: `- fuse-propagation-test` → `# - fuse-propagation-test`
- [ ] Commit & push: `git commit -m "test: disable..." && git push`
- [ ] Verify cleanup: `kubectl get namespace fuse-test` (should disappear in 1-2 min)

---

## What to Expect Afterwards

### If SUCCESS (Direct FUSE works)
- [ ] Next: Design Decypharr containerization
- [ ] Implication: Can simplify sharing via direct FUSE
- [ ] Opportunity: Enable HA, GitOps management, modern patterns
- [ ] Effort: Significant refactor but cleaner outcome

### If FAILURE (Direct FUSE doesn't work)
- [ ] Next: Continue with proven SMB/CIFS approach
- [ ] Implication: Kernel namespace isolation blocks FUSE propagation
- [ ] Status: Current solution is correct and necessary
- [ ] Effort: Maintain LD_PRELOAD workaround ongoing

---

## Support Resources

### Documentation

- **Full Test Guide**: [FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md)
- **Step-by-Step**: [FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md)
- **Quick Reference**: [FUSE_TEST_QUICK_START.md](FUSE_TEST_QUICK_START.md)
- **Navigation**: [FUSE_TEST_DOCUMENTATION_MAP.md](FUSE_TEST_DOCUMENTATION_MAP.md)

### Common Questions

**Q: Will this break anything?**  
A: No. Test is isolated to w2, namespace fuse-test, no production impact.

**Q: How long does it take?**  
A: ~5 min to enable, ~30 min to run, ~2 min to disable. Total: ~40 min.

**Q: Can I stop early?**  
A: Yes. Edit Git, re-comment the test, commit/push, Flux cleanup is automatic.

**Q: What if pods fail?**  
A: That's data! Check logs to see why. Review decision tree in FUSE_TEST_OVERVIEW.md.

**Q: How do I save results?**  
A: `kubectl logs -n fuse-test fuse-consumer > results.log` while pods exist.

---

## Troubleshooting Quick Links

| Problem | Solution |
|---------|----------|
| Pods not starting | Check: `kubectl describe pod -n fuse-test <pod>` |
| Flux not deploying | Check: `flux get all` and `flux logs --follow` |
| Can't read logs | Wait for pods to be Running, then `kubectl logs -n fuse-test <pod>` |
| Namespace won't delete | Git may not have pushed; check `git status` |
| Test disabled but pods still exist | Flux cleanup takes 1-2 min; just wait |

See [FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md#troubleshooting-flux-integration) for detailed troubleshooting.

---

## Timeline

```
Now
 │
 ├─ Read docs (10 min)
 │
 ├─ Edit & enable test (2 min)
 │
 ├─ Flux detects change (5 sec)
 │
 ├─ Pods start (30-60 sec)
 │
 ├─ Test runs (30 min)
 │   └─ SUCCESS/FAILURE appears in logs (10-15 min)
 │
 ├─ Review results (10 min)
 │
 ├─ Disable test (2 min)
 │
 ├─ Flux cleanup (1-2 min)
 │
 └─ Done! (~45 min total)
```

---

## Next Action

**Ready to start?**

👉 **[Click here](FUSE_TEST_STATUS_AND_QUICKSTART.md)** to go to the Quick Start guide.

Or run these commands directly:

```bash
# Open editor
nano /Users/Chris/Source/GitOps/clusters/homelab/testing/kustomization.yaml

# Change:   # - fuse-propagation-test
# To:      - fuse-propagation-test

# Then:
cd /Users/Chris/Source/GitOps
git add clusters/homelab/testing/kustomization.yaml
git commit -m "test: enable FUSE propagation test"
git push origin v2
```

---

**Repository**: [GitOps](https://github.com/cmpetersen5551/GitOps)  
**Status**: ✅ Ready for deployment  
**Created**: 2026-02-28  
**Last Updated**: 2026-02-28
