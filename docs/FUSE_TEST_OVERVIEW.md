# Testing Plan Summary: FUSE Direct hostPath Propagation (2026-02-28)

**What You're Testing**: Can we bypass SMB/CIFS entirely by using direct FUSE mount propagation with `user_allow_other` on k3s?

**Why It Matters**: 
- Current solution (SMB/CIFS + LD_PRELOAD) works but has C code shim
- Direct hostPath FUSE (if it works) would be simpler, faster, cleaner
- Worth 90 minutes to determine feasibility

**Test Node**: k3s-w2 (secondary storage, non-production)  
**Risk**: Low (reversible changes, isolated to w2)  
**Decision Impact**: Could eliminate Samba layer if successful

---

## Files Created

### 1. Test Plan Document
**File**: `docs/FUSE_PROPAGATION_TEST_PLAN.md`
- Detailed 5-phase testing methodology
- Exact commands to run
- Expected outputs for each phase
- Troubleshooting guide
- Results recording template

### 2. Quick Start Guide
**File**: `docs/FUSE_TEST_QUICK_START.md`
- Copy-paste commands for manual execution
- Decision tree for interpreting results
- Quick debugging commands
- Timeline summary

### 3. Automated Test Script
**File**: `scripts/test-fuse-propagation.sh`
- Runs all phases automatically
- Logging to timestamped file
- Colored output showing progress
- Integrated troubleshooting checks
- Usage: `./scripts/test-fuse-propagation.sh`

### 4. Test Manifests
**Directory**: `clusters/homelab/testing/fuse-propagation-test/`
- `kustomization.yaml` — Kustomize structure
- `namespace.yaml` — Test namespace (non-production)
- `producer.yaml` — Pod that creates files in Bidirectional volume
- `consumer.yaml` — Pod that reads files via HostToContainer mount

---

## How to Run the Test

### Option A: Automated (Recommended)
```bash
cd /Users/Chris/Source/GitOps
chmod +x scripts/test-fuse-propagation.sh
./scripts/test-fuse-propagation.sh
```

**Advantages**:
- Runs all phases in sequence
- Automatic error detection
- Comprehensive logging
- Less typing, fewer mistakes

**Time**: ~45 min

### Option B: Manual (For Control)
```bash
# Follow steps in docs/FUSE_TEST_QUICK_START.md
# Run each phase independently
# Monitor logs in separate terminals
```

**Advantages**:
- See each step's output immediately
- Can pause between phases
- Better for understanding what's happening

**Time**: ~90 min (with waiting between phases)

---

## What Each Phase Tests

### Phase 1: Host Setup (Enable user_allow_other)
**Tests**: Can we configure the host to allow FUSE sharing across namespaces?

**Success**: `user_allow_other` appears in `/etc/fuse.conf` and test directory exists on w2

**If fails**: Host config issue, not a fundamental limitation

### Phase 2: Producer Pod (Create files in Bidirectional hostPath)
**Tests**: Can a Kubernetes pod write files to a Bidirectional hostPath volume?

**Success**: Producer logs show files created in `/mnt/dfs`, visible on w2 at `/tmp/fuse-test-bridge`

**If fails**: hostPath mount issue, likely Kubernetes misconfiguration

### Phase 3: Consumer Pod (Read files via HostToContainer)
**Tests**: Can another pod access files created by producer via HostToContainer mount?

**Success**: Consumer logs show "SUCCESS: Producer marker found" and can list/read files

**If fails**: This is the key test — FUSE propagation doesn't work (fundamental k8s limitation confirmed)

### Phase 4: Stale Mount Test (Kill producer, watch consumer)
**Tests**: What happens to consumer when producer pod is deleted?

**Success options**:
- Consumer detects mount is stale ("Transport endpoint" error) → can add auto-recovery via liveness probe
- Consumer keeps running fine → mount doesn't fully break (surprising, good)

**If consumer dies immediately**: Stale mount is detected but not gracefully (needs mitigation)

### Phase 5: Recovery Test (Restart producer, check consumer)
**Tests**: Can consumer automatically recover after producer restarts?

**Success**: Consumer automatically reads fresh producer files after pod restart

**If fails**: Requires manual consumer pod restart (acceptable but not ideal, SMB is better)

---

## Success Scenarios & What They Mean

### Scenario A: Full Success (Phases 1-5 All Pass)
```
✓ Producer creates files
✓ Consumer reads files
✓ Stale mount detected gracefully
✓ Consumer or liveness probe detects and recovers
```

**Decision**: FUSE propagation works! Can replace SMB.

**Next steps**:
1. Test on w1 with real Decypharr pod
2. Measure performance vs SMB
3. Implement liveness probe for auto-recovery
4. Plan migration if similar or better performance

**Migration timeline**: 1-2 weeks to roll out

---

### Scenario B: Partial Success (Phases 1-3 Pass, 4-5 Problematic)
```
✓ Producer creates files
✓ Consumer reads files
⚠ Stale mount behavior unclear
✗ Consumer can't auto-recover
```

**Decision**: FUSE propagation works, but stale mounts need manual recovery.

**Next steps**:
1. Add livenessProbe to consumer pods that detects stale mount
2. Pod auto-restarts when mount fails
3. Acceptable for homelab: brief interruption, automatic recovery

**Migration timeline**: 1 week (just add probes to existing pods)

---

### Scenario C: Fundamental Failure (Phase 3 Fails)
```
✓ Producer creates files
✗ Consumer can't read files
```

**Decision**: FUSE propagation doesn't work in this k3s setup.

**Why**: Kubernetes container mount namespace isolation prevents FUSE from propagating across peer groups. The `user_allow_other` fix helps with permissions, but not with mount namespace boundaries.

**Next steps**:
1. Confirm findings in test doc
2. Keep current SMB/CIFS solution (proven working)
3. Pursue Option D (fix go-fuse upstream long-term)
4. Accept LD_PRELOAD shim as reasonable workaround

**Migration timeline**: No change needed, maintain SMB

---

## How to Interpret Results

### Look for These Log Outputs

**Consumer SUCCESS**:
```
SUCCESS: Producer marker found at <timestamp>
=== Full /mnt/dfs Contents ===
-rw-r--r-- ... producer-marker.txt
=== Reading Producer Files ===
producer-started-<timestamp>
[Consumer Ready]
```

**Consumer FAILURE**:
```
ERROR: Producer marker never appeared after 30 seconds!
Final /mnt/dfs contents:
total 8
```

**Stale Mount Detection**:
```
[<timestamp>] Mount is accessible
[<timestamp>] Mount is accessible
[<timestamp>] ERROR: Mount became inaccessible!
```

---

## Risk Mitigation

### Phase 1 (Host Setup)
- **Risk**: Modifying `/etc/fuse.conf` could affect system FUSE mounts
- **Mitigation**: w2 is secondary, reversible change, Linux kernels are robust to config changes

### Phase 2-3 (Pod Deployment)
- **Risk**: Test pods eat cluster resources
- **Mitigation**: Small resource requests (50-100m CPU), easy to delete namespace, w2 is not production load

### Phase 4-5 (Fault Testing)
- **Risk**: Killing pods might affect Longhorn or other systems
- **Mitigation**: Test is isolated to `fuse-test` namespace, no persistent volumes, normal pod restart

### Stale Mount (General)
- **Risk**: If stale mount handling is inadequate, consumer pods could hang
- **Mitigation**: CIFS soft mount timeout + HostToContainer propagation both have timeouts, plus liveness probes

---

## Cleanup

If test fails or you want to revert:

```bash
# Remove test namespace (cleans pods, pvcs, etc.)
kubectl delete namespace fuse-test

# Clean up host files
ssh root@k3s-w2 "sudo rm -rf /tmp/fuse-test-bridge"

# Revert host config (optional - user_allow_other is safe)
ssh root@k3s-w2 "sudo sed -i '/user_allow_other/d' /etc/fuse.conf"

# Check cleanup
kubectl get namespace fuse-test 2>&1 || echo "Namespace deleted"
ssh root@k3s-w2 "ls -la /tmp | grep fuse" || echo "Host files removed"
```

---

## Expected Outcomes & Next Actions

| Outcome | Action | Timeline |
|---------|--------|----------|
| **Phase 3 Succeeds** | Test on w1 with real Decypharr, measure perf | 1 week |
| **Phase 4-5 Fail Gracefully** | Add liveness probes, plan migration | 1 week |
| **Phase 3 Fails** | Accept SMB, pursue Option D (go-fuse fix) | Long-term |

---

## Timeline

- **Preparation**: 5 min (read this doc)
- **Automated test**: 45 min
- **Analysis**: 10 min
- **Cleanup**: 5 min

**Total**: ~90 minutes

---

## Contact & Questions

If test results are surprising or unclear:

1. **Check test logs**: `fuse-test-*.log` file created by autorescue script
2. **Review test plan**: `FUSE_PROPAGATION_TEST_PLAN.md` has troubleshooting section
3. **Re-read quick start**: `FUSE_TEST_QUICK_START.md` has decision tree

---

## Summary

You have everything you need to test FUSE propagation on w2:
- **Automated script** that runs all phases
- **Detailed test plan** with expected outputs
- **Quick reference** with copy-paste commands
- **Test manifests** ready to deploy
- **Decision tree** to interpret results

**Next step**: Run the test and report results. 

**If successful**: Could be a cleaner alternative to SMB.  
**If unsuccessful**: Confirms decision to stick with SMB/CIFS + Option D (go-fuse fix).

Either way, you'll have data instead of assumptions. 🚀

---

**Created**: 2026-02-28  
**Status**: Ready to execute  
**Risk Level**: Low (w2 only, reversible)
