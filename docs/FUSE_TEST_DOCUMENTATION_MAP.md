# FUSE Propagation Test — Documentation Map (2026-02-28)

**Status**: ✅ Complete and Ready for Deployment  
**Entry Point**: This file  
**Quick Start**: [FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md)

---

## Quick Navigation

### 🚀 I Want to Start the Test NOW
→ [FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md) (5 min read)  
→ [FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md) (copy-paste commands)

### 📋 I Want to Understand What the Test Does
→ [FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md) (comprehensive test design)

### 🔧 I Want Step-by-Step Execution Guide
→ [FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md) (detailed methodology)

### 📚 I Want Quick Reference While Running
→ [FUSE_TEST_QUICK_START.md](FUSE_TEST_QUICK_START.md) (one-page cheat sheet)

### 🔗 I Want to Use Flux/GitOps (Recommended)
→ [FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md) (enable/disable via Git)

### 🗺️ I Want to See Everything at Once (This File)
→ Keep reading below

---

## Document Index

### Core Test Documentation

| Document | Purpose | Read Time | When to Use |
|----------|---------|-----------|-------------|
| **[FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md)** | Complete test design: what, why, how, phases, expected results | 15 min | Understanding the full test methodology and decision tree |
| **[FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md)** | Detailed execution plan: setup, monitoring, interpretation | 20 min | Deep dive into each phase and success/failure criteria |
| **[FUSE_TEST_QUICK_START.md](FUSE_TEST_QUICK_START.md)** | One-page quick reference with commands and checklist | 3 min | Quick lookup while executing test |
| **[FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md)** | Deploying/managing test via Flux/Git (recommended method) | 10 min | Learning how to enable/disable test via GitOps |
| **[FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md)** | Complete status update, next steps, file reference | 10 min | Getting oriented before starting |
| **[FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md)** | Copy-paste command reference for all common tasks | 2 min | Quick command lookup during test execution |

### Context & Background

| Document | Purpose | Read Time | When to Use |
|----------|---------|-----------|-------------|
| **[FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md#context)** | Why this test exists, hypothesis, technical background | 5 min | Understanding the motivation |
| **[DFS_SHARING_ALTERNATIVES_ANALYSIS.md](DFS_SHARING_ALTERNATIVES_ANALYSIS.md)** | All options considered and why they were chosen/rejected | 25 min | Broader context on storage sharing decisions |
| **[LONGHORN_HA_MIGRATION.md](LONGHORN_HA_MIGRATION.md)** | Current cluster HA architecture | 10 min | Understanding the cluster infrastructure |

---

## How to Use These Docs

### Scenario 1: "I'm ready to start the test"

1. Read: [FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md) (5 min)
2. Use: [FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md) to enable test
3. Monitor: Follow the 3-tab monitoring setup (10-30 min)
4. Interpret: Use decision tree in [FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md) to analyze results

### Scenario 2: "I want to understand what the test is doing"

1. Read: [FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md) (comprehensive)
2. Read: [FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md) (detailed phases)
3. Reference: [FUSE_TEST_QUICK_START.md](FUSE_TEST_QUICK_START.md) for checklist

### Scenario 3: "I want to use Flux (GitOps) to manage the test"

1. Read: [FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md)
2. Reference: [FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md) for enable/disable commands

### Scenario 4: "I need to troubleshoot the test"

1. Check: [FUSE_TEST_OVERVIEW.md](FUSE_TEST_OVERVIEW.md#failure-scenarios) for failure modes
2. Check: [FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md#debugging) for debugging steps
3. Check: [FUSE_TEST_FLUX_DEPLOYMENT.md](FUSE_TEST_FLUX_DEPLOYMENT.md#troubleshooting-flux-integration) for Flux issues

### Scenario 5: "Test is running, I need a quick command"

→ [FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md) (all commands on one page)

---

## Documentation Roadmap

```
docs/
├── README.md                                    [Cluster overview]
├── LONGHORN_HA_MIGRATION.md                    [HA architecture]
│
├── FUSE_PROPAGATION_TEST/
│   ├── FUSE_TEST_DOCUMENTATION_MAP.md          ← YOU ARE HERE
│   ├── FUSE_TEST_OVERVIEW.md                   [Full design]
│   ├── FUSE_PROPAGATION_TEST_PLAN.md           [Step-by-step]
│   ├── FUSE_TEST_QUICK_START.md                [Reference]
│   ├── FUSE_TEST_FLUX_DEPLOYMENT.md            [GitOps]
│   ├── FUSE_TEST_STATUS_AND_QUICKSTART.md      [Status]
│   └── FUSE_TEST_COMMANDS.md                   [Commands]
│
├── DFS_SHARING_ALTERNATIVES_ANALYSIS.md        [Options]
├── DFS_MOUNT_STRATEGY.md                       [Current approach]
│
└── archive/                                     [Historical docs]
    ├── SEAWEEDFS_*.md                          [Old attempts]
    ├── CSI_*.md                                [Old attempts]
    └── ...
```

---

## Key Files & Manifests

### Test Manifests (in Git, enabled via Flux)

```
clusters/homelab/testing/
├── kustomization.yaml              [Enable/disable tests here]
└── fuse-propagation-test/
    ├── namespace.yaml              [Creates fuse-test namespace]
    ├── producer.yaml               [FUSE producer pod]
    ├── consumer.yaml               [Verification pod]
    └── kustomization.yaml          [Bundles all 3]
```

### Test Script (Manual alternative, not recommended)

```
scripts/
└── test-fuse-propagation.sh        [Run manually if needed]
```

---

## Quick Facts

| Aspect | Details |
|--------|---------|
| **What's Being Tested** | Can FUSE mount propagate from one container to another via hostPath? |
| **Test Hypothesis** | With `user_allow_other`, `allow_other`, privileged pods, and bidirectional propagation, yes. |
| **Test Node** | w2 (non-production storage node) |
| **Test Namespace** | fuse-test (isolated) |
| **Test Pods** | fuse-producer (creates FUSE FS), fuse-consumer (reads from it) |
| **Deployment Method** | Flux/GitOps (recommended) or manual kubectl |
| **Duration** | 30 minutes total (results appear after ~10-15 min) |
| **Cleanup** | Disable in Git → Flux auto-deletes after 1-2 minutes |
| **Success Indicator** | "SUCCESS: Producer marker found" in fuse-consumer logs |
| **Failure Indicator** | "FAILURE: Producer marker never appeared" in fuse-consumer logs |

---

## Before You Start

### Prerequisites

- [ ] Access to `/Users/Chris/Source/GitOps` workspace
- [ ] Git configured and able to push (ssh/https)
- [ ] `kubectl` configured for k3s cluster
- [ ] Flux installed and managing the cluster
- [ ] w2 node is healthy and available

### Safety Checks

- [ ] Test runs on w2 only (production-safe)
- [ ] Test uses isolated namespace (fuse-test)
- [ ] No production pods affected
- [ ] Easy to disable (git edit → Flux cleanup)

### Cluster Health Check

```bash
# Is cluster up?
kubectl cluster-info

# Is w2 healthy?
kubectl get nodes | grep w2

# Is Flux working?
flux get all
```

---

## Decision Tree Summary

After test completes, use this tree to decide next steps:

```
┌─ Test runs to completion
│
├─ SUCCESS: Producer marker found
│  └─ Direct FUSE propagation works
│     ├─ Can containerize Decypharr in k3s
│     ├─ Simplify sharing (no SMB/CIFS layer needed)
│     ├─ Enable HA (multiple replicas possible)
│     └─ Next: Design Decypharr-in-k3s PoC
│
├─ FAILURE: Producer marker never appeared
│  └─ Direct FUSE propagation doesn't work in k3s
│     ├─ Kernel namespace isolation blocks it
│     ├─ Or permission model incompatible
│     ├─ Must use SMB/CIFS layer (current approach)
│     └─ Next: Continue with proven SMB solution
│
└─ ERROR: Pods fail to start
   └─ Check logs for specific error
      ├─ Affinity? → w2 node issue
      ├─ Permissions? → Pod privilege level
      ├─ Mount? → Propagation mode issue
      └─ Other? → Review [FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md#debugging)
```

---

## After Test Results

### If SUCCESS
- [ ] Document findings
- [ ] Review implications for Decypharr containerization
- [ ] Design simplified architecture (no SMB layer)
- [ ] Create PoC deployment manifest
- [ ] Plan migration path away from host-based Decypharr

### If FAILURE
- [ ] Document findings and failure mode
- [ ] Confirm current SMB/CIFS approach is optimal
- [ ] Close the FUSE propagation hypothesis
- [ ] Continue with LD_PRELOAD maintenance
- [ ] Explore other improvements (e.g., upstream fixes to go-fuse)

---

## Contact & Escalation

**If you get stuck**:
1. Check the troubleshooting section in [FUSE_PROPAGATION_TEST_PLAN.md](FUSE_PROPAGATION_TEST_PLAN.md)
2. Review [FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md) for quick fixes
3. Check Flux status: `flux get all`
4. Check pod logs: `kubectl logs -n fuse-test <pod>`
5. Check pod events: `kubectl describe pod -n fuse-test <pod>`

---

## Timeline

- **Now**: You are here (reading docs)
- **+5 min**: Read [FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md)
- **+10 min**: Enable test in Git via [FUSE_TEST_COMMANDS.md](FUSE_TEST_COMMANDS.md)
- **+15 min**: Flux deploys, pods start
- **+25-30 min**: Test completes, results in logs
- **+35 min**: Disable test if done
- **+40 min**: Cluster clean, analysis begins

---

## File Sizes

| Document | Size | Format |
|----------|------|--------|
| FUSE_TEST_OVERVIEW.md | ~15 KB | Markdown |
| FUSE_PROPAGATION_TEST_PLAN.md | ~20 KB | Markdown |
| FUSE_TEST_QUICK_START.md | ~5 KB | Markdown |
| FUSE_TEST_FLUX_DEPLOYMENT.md | ~12 KB | Markdown |
| FUSE_TEST_STATUS_AND_QUICKSTART.md | ~18 KB | Markdown |
| FUSE_TEST_COMMANDS.md | ~4 KB | Markdown |
| **Total** | **~74 KB** | Documentation |

---

## Next Action

**You probably want to do this next:**

```
1. Click → [FUSE_TEST_STATUS_AND_QUICKSTART.md](FUSE_TEST_STATUS_AND_QUICKSTART.md)
2. Read (5 min)
3. Follow the "Ready to Start?" section
4. Enable test via Git
5. Monitor pods
6. Watch for SUCCESS/FAILURE in logs
```

---

**Repository**: [GitOps](https://github.com/cmpetersen5551/GitOps)  
**Branch**: v2  
**Status**: Ready for deployment  
**Last Updated**: 2026-02-28  
**Created**: 2026-02-28
