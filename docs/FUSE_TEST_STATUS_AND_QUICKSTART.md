# FUSE Propagation Test — Complete Status & Next Steps (2026-02-28)

**Overall Status**: ✅ Test Ready for Deployment via Flux  
**Branch**: v2  
**Test Node**: w2 (non-production)  
**Deployment Method**: Git + Flux (fully GitOps)

---

## What's Been Done

### 1. ✅ Test Documentation (Complete)

| Document | Purpose | Location |
|----------|---------|----------|
| **FUSE_TEST_OVERVIEW.md** | Complete test methodology, phases, decision tree | docs/ |
| **FUSE_PROPAGATION_TEST_PLAN.md** | Detailed step-by-step plan with success/failure criteria | docs/ |
| **FUSE_TEST_QUICK_START.md** | Fast reference for running the test | docs/ |
| **FUSE_TEST_FLUX_DEPLOYMENT.md** | How to enable/disable via Flux/Git (THIS FILE) | docs/ |

### 2. ✅ Test Manifests (Ready)

```
clusters/homelab/testing/fuse-propagation-test/
├── namespace.yaml       # Creates fuse-test namespace
├── producer.yaml        # Decypharr-like producer pod
├── consumer.yaml        # Consumer pod that reads/verifies
└── kustomization.yaml   # Bundles all 3 files
```

### 3. ✅ Test Script (Ready)

```
scripts/test-fuse-propagation.sh   # Runs test manually if needed
```

### 4. ✅ Flux Integration (Ready)

```
clusters/homelab/                    # Root kustomization includes "testing" ✓
└── testing/
    ├── kustomization.yaml           # Disabled by default, enable tests here
    └── fuse-propagation-test/       # Actual test (commented out in parent)
```

---

## How to Enable the Test

### Quick Start (Copy-Paste)

```bash
# 1. Edit the testing kustomization
cd /Users/Chris/Source/GitOps
nano clusters/homelab/testing/kustomization.yaml

# 2. Uncomment the FUSE test line (change # - to -)
# Before: # - fuse-propagation-test
# After:  - fuse-propagation-test

# 3. Save and commit
git add clusters/homelab/testing/kustomization.yaml
git commit -m "test: enable FUSE propagation test via Flux"
git push

# 4. Flux reconciles automatically (5-10 seconds)
# 5. Monitor pods
watch kubectl get pods -n fuse-test -o wide
```

### Detailed Steps

See [FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md) for:
- Step-by-step enable/disable instructions
- Monitoring dashboards
- Troubleshooting Flux integration
- Manual test alternative (not recommended)

---

## What the Test Does

### Phase 1: Producer Setup (5 min)
- Creates FUSE directory on hostPath (simulating Decypharr)
- Mounts FUSE filesystem
- Writes test markers and files

### Phase 2: Propagation Check (Real-time)
- Consumer pod attempts to read producer's markers
- Tests if FUSE mount propagates across pod isolation boundary
- **Expected Result**: SUCCESS or FAILURE (not a race condition)

### Phase 3: Permission Testing (Multi-phase)
- Tests with different pod/container privilege levels
- Verifies `user_allow_other` and `allow_other` behavior
- Checks mount propagation modes

### Phase 4: Detailed Logging (Real-time)
- Both pods log all access attempts
- Captures exact error types
- Provides decision-tree path

### Phase 5: Cleanup (Auto)
- Pods remain alive for ~30 minutes for inspection
- Then exit cleanly
- Namespace persists for kubectl inspection (until Flux deletes it)

### Duration
**~30 minutes total** (can inspect logs while running, no need to wait)

---

## Understanding Test Results

### SUCCESS Scenario

```bash
$ kubectl logs -n fuse-test fuse-consumer
...
[13:45:22] Checking Phase 2 (Propagation)...
[13:45:23] ✓ Producer marker found at /mnt/fuse/producer-ready
[13:45:24] ✓ Test file /mnt/fuse/test-data readable
[13:45:25] SUCCESS: Direct FUSE propagation works!
```

**Implication**: Direct hostPath FUSE propagation is viable. Can eliminate SMB/CIFS layer.

### FAILURE Scenario

```bash
$ kubectl logs -n fuse-test fuse-consumer
...
[13:45:22] Checking Phase 2 (Propagation)...
[13:45:23] ✗ Producer marker NOT found at /mnt/fuse/producer-ready
[13:45:24] ✗ Directory exists but appears empty
[13:45:25] FAILURE: FUSE mount did not propagate into consumer pod
```

**Implication**: Direct FUSE won't work via hostPath. Keep SMB/CIFS + LD_PRELOAD.

### Decision Tree

See [FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md) for full decision tree with failure mode diagnosis.

---

## After Test Results

### If SUCCESS: FUSE Propagation Works

**Next Steps**:
1. Document findings in test results summary
2. Investigate whether Decypharr itself can be containerized similarly
3. Design new architecture using direct FUSE instead of SMB wrapper
4. Create Proof-of-Concept deployment of simplified Decypharr

**Benefit**: Eliminate SMB/CIFS complexity, LD_PRELOAD workaround, and FUSE-to-FUSE translation layer.  
**Cost**: Decypharr must run as privileged pod, requires `user_allow_other` on cluster nodes.

### If FAILURE: FUSE Propagation Doesn't Work

**Next Steps**:
1. Document failure mode and logs
2. Continue with SMB/CIFS + LD_PRELOAD (current proven approach)
3. Consider upstream fixes to go-fuse or kernel FUSE driver
4. Evaluate if Decypharr maintainers have suggestions

**Benefit**: Confirms current solution is the best practical approach.  
**Cost**: Continue maintaining SELinux policy, FUSE nlink workaround, and SMB/CIFS layers.

---

## Test Isolation & Safety

### Why This Won't Break Production

✅ **Node Isolation**: Test runs only on **w2** (explicitly selected in producer pod affinity)  
✅ **Namespace Isolation**: All test pods in dedicated `fuse-test` namespace  
✅ **No Cluster Impact**: Test manifests don't touch production apps, infrastructure, or configs  
✅ **Easy Rollback**: Disable test, Flux auto-deletes it, cluster returns to prior state  
✅ **No Storage Conflicts**: Test uses temp hostPath on w2, doesn't interfere with Longhorn/NFS  

### How to Disable Test

If you need to stop the test before 30 minutes are up:

```bash
# Edit the file
nano clusters/homelab/testing/kustomization.yaml

# Re-comment the line: # - fuse-propagation-test

# Commit and push
git add clusters/homelab/testing/kustomization.yaml
git commit -m "test: disable FUSE propagation test"
git push

# Flux deletes test namespace within 1-2 minutes
```

---

## Monitoring the Test

### Real-Time Dashboard (3 tabs recommended)

**Tab 1 — Quick Status**:
```bash
watch kubectl get pods -n fuse-test -o wide
```

**Tab 2 — Consumer Results** (where SUCCESS/FAILURE printed):
```bash
kubectl logs -f -n fuse-test fuse-consumer
```

**Tab 3 — Producer Debug Info** (what producer wrote):
```bash
kubectl logs -f -n fuse-test fuse-producer
```

### Flux Status (Optional, Technical)

```bash
# Confirm test deployed via Flux
flux get kustomization testing

# Expected:
# NAME     READY   STATUS
# testing  True    Applied revision main@sha1:...
```

---

## File Reference

### Documentation
- **[FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md)** — Complete test design, phases, decision tree
- **[FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md)** — Detailed step-by-step walkthrough
- **[FUSE_TEST_QUICK_START.md](FUSE_TEST_QUICK_START.md)** — Fast reference
- **[FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md)** — Flux integration guide (THIS FILE)

### Manifests (in Git)
- **[clusters/homelab/testing/kustomization.yaml](../../clusters/homelab/testing/kustomization.yaml)** — Enable/disable tests here
- **[clusters/homelab/testing/fuse-propagation-test/kustomization.yaml](../../clusters/homelab/testing/fuse-propagation-test/kustomization.yaml)** — Test bundle config
- **[clusters/homelab/testing/fuse-propagation-test/namespace.yaml](../../clusters/homelab/testing/fuse-propagation-test/namespace.yaml)** — fuse-test namespace
- **[clusters/homelab/testing/fuse-propagation-test/producer.yaml](../../clusters/homelab/testing/fuse-propagation-test/producer.yaml)** — FUSE producer pod
- **[clusters/homelab/testing/fuse-propagation-test/consumer.yaml](../../clusters/homelab/testing/fuse-propagation-test/consumer.yaml)** — Verification pod

### Script (Manual Alternative)
- **[scripts/test-fuse-propagation.sh](../../scripts/test-fuse-propagation.sh)** — Run test manually if needed (not recommended, breaks GitOps)

---

## Why This Test Matters

**Current Setup** (Production):
- Decypharr on host machine (unmanaged, single-node)
- Mounts remote shares via Samba/CIFS
- Shares back via FUSE
- k3s pods access via SMB/CIFS + LD_PRELOAD workaround
- **Pros**: Proven, stable, self-contained
- **Cons**: Complex sharing chain, LD_PRELOAD maintenance burden, not HA

**New Hypothesis** (Tested Here):
- Decypharr could run in k3s (containerized, HA-ready)
- Uses FUSE mount inside container
- k3s pods directly read FUSE mount via hostPath propagation
- Requires `user_allow_other`, privileged pod, correct propagation mode
- **Pros**: Simpler, more reliable, enables HA, no LD_PRELOAD needed
- **Cons**: Decypharr requires containerization, untested approach

**This Test Determines**: Is the "New Hypothesis" technically viable?

---

## Timeline

- **Now**: Enable test in Git, commit, push
- **+5-10s**: Flux detects change, reconciles
- **+2-5m**: Pods start, producer initializes FUSE
- **+10-15m**: Consumer reads FUSE mount, SUCCESS/FAILURE appears in logs
- **+15-30m**: Test phases 3-5 continue (for thorough verification)
- **After Review**: Disable test in Git, Flux cleans up
- **+1-2m after disable**: Namespace deleted, cluster back to normal

---

## Access to Test Results

### While Test is Running

```bash
# Live logs (best for monitoring)
kubectl logs -f -n fuse-test fuse-consumer
kubectl logs -f -n fuse-test fuse-producer

# Or watch pod events
kubectl describe pod -n fuse-test fuse-consumer | tail -30
```

### After Test Completes

```bash
# Pods may still exist for 30 minutes after completion
# Their logs are available the whole time

# Fetch complete logs for analysis
kubectl logs -n fuse-test fuse-consumer > consumer-results.log
kubectl logs -n fuse-test fuse-producer > producer-debug.log
```

### After Disable/Cleanup

```bash
# Namespace gone (Flux cleaned up)
# But you have logs saved to review
cat consumer-results.log
```

---

## Questions Before Starting?

**Q: Will this interfere with production?**  
A: No. Test runs only on w2, in isolated namespace, with no cluster impact.

**Q: Can I stop the test early?**  
A: Yes. Comment out in Git, commit, push. Flux deletes it in 1-2 minutes.

**Q: What if the test pods fail?**  
A: Normal! We're testing an unknown scenario. Failures provide data. Review logs for why.

**Q: How do I save test results?**  
A: `kubectl logs -n fuse-test fuse-consumer > results.log` while pods exist.

**Q: Can I re-run the test?**  
A: Yes. Disable (comment), then enable (uncomment) again. Flux handles the rest.

---

## Ready to Start?

**Next Action**: 

```bash
# 1. Edit the file
nano clusters/homelab/testing/kustomization.yaml

# 2. Uncomment: - fuse-propagation-test

# 3. Commit and push
git add clusters/homelab/testing/kustomization.yaml
git commit -m "test: enable FUSE propagation test"
git push

# 4. Watch it deploy
watch kubectl get pods -n fuse-test -o wide

# 5. Review results
kubectl logs -f -n fuse-test fuse-consumer
```

**Estimated Time**:
- Enabling: 2 minutes
- Test Running: 30 minutes
- Review & Analysis: 15-30 minutes
- Disable & Cleanup: 2 minutes

---

**Repository**: [GitOps](https://github.com/cmpetersen5551/GitOps)  
**Branch**: v2  
**Status**: Ready for test deployment  
**Created**: 2026-02-28  
**Last Updated**: 2026-02-28
