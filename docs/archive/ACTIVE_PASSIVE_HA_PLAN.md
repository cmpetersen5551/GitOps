# Active-Passive HA Implementation Plan with Automatic Failback

**Date:** February 14, 2026  
**Branch:** v2  
**Goal:** Configure workload scheduling so w1 is the primary active node, w2 is passive failover, and pods automatically return to w1 when it recovers  

---

## Problem Statement

Current situation (observed during w1 shutdown test):
- **w1 (k3s-w1)**: `role=primary` label - intended as active worker node
- **w2 (k3s-w2)**: `role=backup` label - intended as passive failover node
- **w3 (k3s-w3)**: No role label, `gpu=true` - dedicated for ClusterPlex only
- **Sonarr deployment**: Uses `nodeSelector: role: primary` (strict constraint)

**Issue:** When w1 goes down:
1. Sonarr pod is evicted (after ~5 min default toleration)
2. Scheduler tries to find node with `role=primary` label
3. **No suitable node found** (w2 has `role=backup`, not `role=primary`)
4. Pod stays **Pending indefinitely**

**Desired behavior:**
1. **Normal operation**: All workloads run on w1 (active)
2. **w1 failure**: Workloads immediately failover to w2 (passive becomes active)
3. **w1 recovery**: Workloads automatically failback to w1 (w2 returns to passive)
4. **w3 isolation**: Only ClusterPlex GPU workloads run on w3

---

## Research Summary

### Kubernetes Scheduling Concepts

**1. nodeSelector (Strict Constraint)**
- Hard requirement: Pod MUST run on nodes matching ALL specified labels
- No fallback: If no matching node, pod stays Pending forever
- Current approach: `nodeSelector: role: primary` → BLOCKS failover to w2

**2. Node Affinity (Flexible Constraints)**
Two types:
- `requiredDuringSchedulingIgnoredDuringExecution`: Hard constraint (like nodeSelector but more expressive)
- `preferredDuringSchedulingIgnoredDuringExecution`: Soft constraint (preference, not requirement)

**3. Taints and Tolerations**
- **Taint** on node: Repels pods that don't tolerate it
- **Toleration** on pod: Allows (but doesn't require) scheduling on tainted node
- Three effects:
  - `NoSchedule`: Hard block for new pods
  - `PreferNoSchedule`: Soft preference to avoid
  - `NoExecute`: Evicts existing pods that don't tolerate

**4. Pod Priority and Preemption**
- Higher priority pods can evict lower priority pods to get resources
- System-critical pods use `priorityClassName: system-cluster-critical`

**5. Descheduler (Automatic Rebalancing)**
- Separate controller that evicts pods based on policies
- Can enforce node affinity preferences by moving pods to preferred nodes
- Enables automatic failback when preferred nodes recover

---

## Solution: Multi-Layered Approach

### Strategy Overview

**Layer 1: Node Affinity (Preference for w1)**
- Use `preferredDuringSchedulingIgnoredDuringExecution` to express preference for w1
- Allows pods to run on w2 when w1 unavailable
- No automatic failback (pods stay on w2 even after w1 recovers)

**Layer 2: Taints (Repel from w2)**
- Taint w2 with `role=backup:PreferNoSchedule`
- Scheduler avoids w2 unless w1 unavailable
- Pods tolerate the taint (so they CAN run on w2 if needed)

**Layer 3: Descheduler (Automatic Failback)**
- Descheduler observes pods running on non-preferred nodes
- Evicts pods from w2 when w1 becomes available again
- Scheduler then re-places pods on w1 (preferred node)

**Layer 4: w3 Isolation (GPU Only)**
- Keep existing strict taint: `gpu=true:NoSchedule`
- Only ClusterPlex worker pods tolerate this taint
- No general workloads can schedule on w3

---

## Implementation Plan

### Phase 1: Label Strategy

**Goal:** Establish clear node roles

**Actions:**
```bash
# Verify current labels
kubectl get nodes --show-labels

# Current state:
# k3s-w1: role=primary
# k3s-w2: role=backup
# k3s-w3: gpu=true, sw-volume=true

# Add weight labels for affinity preferences
kubectl label node k3s-w1 workload-priority=primary --overwrite
kubectl label node k3s-w2 workload-priority=backup --overwrite

# Keep existing labels (don't remove role=primary/backup yet)
```

**Rationale:**
- Keep `role=primary/backup` for reference/documentation
- Add `workload-priority` labels for affinity rules
- Clear distinction between active (primary) and passive (backup) nodes

---

### Phase 2: Taint w2 to Repel Workloads

**Goal:** Make scheduler avoid w2 unless w1 unavailable

**Actions:**
```bash
# Taint w2 with PreferNoSchedule (soft repel)
kubectl taint nodes k3s-w2 role=backup:PreferNoSchedule

# Verify taint applied
kubectl describe node k3s-w2 | grep -A 5 Taints
```

**Effect:**
- Scheduler **prefers** not to schedule on w2
- Can still schedule on w2 if:
  - Pod tolerates the taint
  - No other suitable nodes available (w1 down)

**Rationale:**
- `PreferNoSchedule` (not `NoSchedule`) allows failover
- Soft constraint: w2 is available but deprioritized
- Works without changing pod specs (yet)

---

### Phase 3: Update Deployment Manifests

**Goal:** Replace strict nodeSelector with flexible affinity + tolerations

#### Update Pattern for All Workloads

**Before (sonarr example):**
```yaml
spec:
  template:
    spec:
      nodeSelector:
        role: primary  # STRICT - blocks failover
```

**After (sonarr example):**
```yaml
spec:
  template:
    spec:
      # REMOVED: nodeSelector
      
      # ADD: Node affinity (preference for w1)
      affinity:
        nodeAffinity:
          # Soft preference: prefer w1 (primary)
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100  # Highest weight for primary
              preference:
                matchExpressions:
                  - key: workload-priority
                    operator: In
                    values:
                      - primary
            - weight: 10   # Low weight for backup (only if primary unavailable)
              preference:
                matchExpressions:
                  - key: workload-priority
                    operator: In
                    values:
                      - backup
      
      # ADD: Toleration for w2 taint (allow failover)
      tolerations:
        - key: role
          operator: Equal
          value: backup
          effect: PreferNoSchedule
          # No tolerationSeconds: tolerate indefinitely
```

**Workloads to Update:**
1. **Sonarr** ([clusters/homelab/apps/media/sonarr/deployment.yaml](clusters/homelab/apps/media/sonarr/deployment.yaml))
2. **Prowlarr** ([clusters/homelab/apps/media/prowlarr/deployment.yaml](clusters/homelab/apps/media/prowlarr/deployment.yaml))
3. Any other apps with `nodeSelector: role: primary`

**Testing Strategy:**
- Start with sonarr (already being tested)
- Apply changes, verify pod reschedules
- Roll out to other apps incrementally

---

### Phase 4: Deploy Descheduler

**Goal:** Enable automatic failback when w1 recovers

#### Descheduler Overview
- **What**: Kubernetes controller that evicts pods based on policies
- **Why**: Default scheduler doesn't move running pods to better nodes
- **How**: Observes cluster, evicts pods not meeting preferred placement
- **Effect**: Evicted pods get rescheduled by scheduler to preferred nodes

#### Installation

**Option A: Helm (Recommended)**
```bash
# Add descheduler Helm repo
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/
helm repo update

# Install descheduler
helm install descheduler descheduler/descheduler \
  --namespace kube-system \
  --create-namespace \
  --set cronJobSchedule="*/5 * * * *" \
  --set deschedulerPolicy.strategies.RemovePodsViolatingNodeAffinity.enabled=true \
  --set deschedulerPolicy.strategies.RemovePodsViolatingNodeAffinity.params.nodeAffinityType[0]=preferredDuringSchedulingIgnoredDuringExecution

# Verify deployment
kubectl get pods -n kube-system -l app.kubernetes.io/name=descheduler
```

**Option B: Manual YAML (GitOps)**
Create `clusters/homelab/infrastructure/descheduler/` directory:

**descheduler-policy.yaml:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: descheduler-policy
  namespace: kube-system
data:
  policy.yaml: |
    apiVersion: "descheduler/v1alpha2"
    kind: "DeschedulerPolicy"
    profiles:
      - name: default
        pluginConfig:
          - name: "RemovePodsViolatingNodeAffinity"
            args:
              nodeAffinityType:
                - "preferredDuringSchedulingIgnoredDuringExecution"
          - name: "DefaultEvictor"
            args:
              evictFailedBarePods: false
              evictLocalStoragePods: false
              evictSystemCriticalPods: false
              nodeFit: true
        plugins:
          balance:
            enabled:
              - "RemovePodsViolatingNodeAffinity"
```

**descheduler-cronjob.yaml:**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: descheduler
  namespace: kube-system
spec:
  schedule: "*/5 * * * *"  # Run every 5 minutes
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app: descheduler
        spec:
          serviceAccountName: descheduler
          restartPolicy: Never
          containers:
            - name: descheduler
              image: registry.k8s.io/descheduler/descheduler:v0.30.0
              command:
                - "/bin/descheduler"
              args:
                - "--policy-config-file=/policy/policy.yaml"
                - "--v=3"
              volumeMounts:
                - name: policy
                  mountPath: /policy
              resources:
                requests:
                  cpu: 50m
                  memory: 64Mi
                limits:
                  cpu: 200m
                  memory: 128Mi
          volumes:
            - name: policy
              configMap:
                name: descheduler-policy
```

**descheduler-rbac.yaml:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: descheduler
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: descheduler
rules:
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch", "delete"]
  - apiGroups: [""]
    resources: ["pods/eviction"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: descheduler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: descheduler
subjects:
  - kind: ServiceAccount
    name: descheduler
    namespace: kube-system
```

**kustomization.yaml:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - descheduler-policy.yaml
  - descheduler-rbac.yaml
  - descheduler-cronjob.yaml
```

**Flux Kustomization:**
```yaml
# clusters/homelab/cluster/infrastructure-descheduler-kustomization.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure-descheduler
  namespace: flux-system
spec:
  interval: 5m
  path: ./clusters/homelab/infrastructure/descheduler
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```

#### Descheduler Behavior

**Normal Operation (w1 healthy):**
- Pods run on w1 (preferred node)
- Descheduler: "Pods on preferred nodes, no action"

**Failover (w1 down):**
1. Pods evicted from w1 (unreachable node)
2. Scheduler places pods on w2 (only available node)
3. Descheduler: "w1 unavailable, pods correctly on w2, no action"

**Failback (w1 recovers):**
1. w1 becomes Ready again
2. Descheduler runs (every 5 min): "Pods on w2, but w1 (preferred) available"
3. Descheduler evicts pods from w2
4. Scheduler reschedules pods to w1 (preferred node)
5. **Automatic return to w1 complete!**

#### Failback Timing
- **Detection**: Up to 5 minutes (CronJob schedule)
- **Eviction**: ~30 seconds (graceful shutdown)
- **Rescheduling**: ~10-60 seconds (pod startup)
- **Total**: ~6-7 minutes maximum

**Tuning:**
- Faster failback: Reduce CronJob schedule to `*/2 * * * *` (every 2 min)
- Gentler evictions: Add `--evict-max-pods-per-node=1` to limit disruption

---

### Phase 5: Testing & Validation

#### Test Scenario 1: Normal Operation

**Expected:**
- sonarr runs on w1
- prowlarr runs on w1
- All other workloads on w1

**Validation:**
```bash
kubectl get pods -n media -o wide
# Should show: NODE=k3s-w1 for all pods
```

---

#### Test Scenario 2: Failover (w1 Shutdown)

**Steps:**
1. Shutdown w1: `ssh k3s-w1 'sudo shutdown -h now'`
2. Watch pods: `kubectl get pods -n media -o wide -w`
3. Monitor node: `kubectl get nodes -w`

**Expected Timeline:**
- **T+0s**: w1 stops responding
- **T+40s**: Node marked NotReady
- **T+5m00s**: Pods evicted from w1 (default toleration)
- **T+5m10s**: Pods Pending (scheduler looking for nodes)
- **T+5m15s**: Pods scheduled to w2 (via affinity + toleration)
- **T+6m00s**: Pods Running on w2

**Validation:**
```bash
# After failover complete
kubectl get pods -n media -o wide
# Should show: NODE=k3s-w2 for sonarr, prowlarr

# Verify app functionality
curl http://<sonarr-ingress-url>
# Should return 200 OK (config intact via SeaweedFS)
```

---

#### Test Scenario 3: Failback (w1 Recovery)

**Steps:**
1. Power on/start w1
2. Wait for w1 to become Ready: `kubectl get nodes -w`
3. Wait for descheduler cycle (~5 min)
4. Watch pods: `kubectl get pods -n media -o wide -w`

**Expected Timeline:**
- **T+0s**: w1 powered on
- **T+1m**: w1 node Ready
- **T+5m**: Descheduler runs, detects affinity violation
- **T+5m10s**: Pods evicted from w2
- **T+5m20s**: Pods Pending (scheduler looking)
- **T+5m25s**: Pods scheduled to w1 (preferred node)
- **T+6m30s**: Pods Running on w1

**Validation:**
```bash
# After failback complete
kubectl get pods -n media -o wide
# Should show: NODE=k3s-w1 for sonarr, prowlarr

# Verify app functionality
curl http://<sonarr-ingress-url>
# Should return 200 OK (config persisted through failover/failback)
```

---

#### Test Scenario 4: Pod Restart on w1 (No Migration)

**Steps:**
1. Delete pod while w1 is healthy: `kubectl delete pod -n media sonarr-xxx`
2. Watch rescheduling: `kubectl get pods -n media -o wide -w`

**Expected:**
- Pod immediately recreated on w1 (preferred node)
- No detour to w2

**Validation:**
```bash
kubectl get pods -n media -o wide
# Should show: NODE=k3s-w1 (stayed on w1)
```

---

### Phase 6: Optimization & Tuning

#### Faster Failover

**Problem:** Default 5-minute toleration delay before eviction

**Solution:** Add custom toleration in pod spec:
```yaml
tolerations:
  - key: node.kubernetes.io/unreachable
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30  # Evict after 30 seconds
  - key: node.kubernetes.io/not-ready
    operator: Exists
    effect: NoExecute
    tolerationSeconds: 30  # Evict after 30 seconds
```

**Effect:** Failover in ~1 minute instead of ~6 minutes

---

#### Faster Failback

**Problem:** Descheduler runs every 5 minutes (CronJob schedule)

**Solution:** Increase frequency:
```yaml
spec:
  schedule: "*/2 * * * *"  # Every 2 minutes
```

**Trade-off:** More frequent cluster scans (minimal overhead for homelab)

---

#### PodDisruptionBudget (PDB)

**Problem:** Descheduler may evict pods too aggressively during maintenance

**Solution:** Create PDB to limit disruption:
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: sonarr-pdb
  namespace: media
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: sonarr
```

**Effect:** Ensures at least one replica stays available during evictions

---

## Summary: Behavior Matrix

| Scenario | w1 Status | w2 Status | Pod Location | Mechanism |
|----------|-----------|-----------|--------------|-----------|
| **Normal** | Ready | Ready (tainted) | w1 | Affinity preference + w2 taint |
| **w1 Failure** | NotReady | Ready | w2 | Toleration allows, w1 unreachable |
| **w1 Recovery** | Ready | Ready | w1 (after ~5 min) | Descheduler evicts from w2 |
| **Forced Pod Restart** | Ready | Ready | w1 | Scheduler respects affinity |
| **w1 Maintenance** | Drained | Ready | w2 | Drain evicts, toleration allows w2 |
| **Both Down** | NotReady | NotReady | Pending | No suitable nodes |

---

## Architecture Comparison

### Before (Current - Broken Failover)

```
┌─────────────────────────────────────────┐
│ w1: role=primary                        │
│  ├─ Sonarr (nodeSelector: role=primary)│
│  └─ Prowlarr (nodeSelector: role=primary)
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ w2: role=backup                         │
│  └─ (empty - can't run primary workloads)
└─────────────────────────────────────────┘

Problem: w1 down → Pods Pending forever
```

### After (Proposed - Automatic Failover/Failback)

```
┌─────────────────────────────────────────┐
│ w1: workload-priority=primary           │
│  ├─ Sonarr (affinity: prefer primary)  │
│  └─ Prowlarr (affinity: prefer primary)│
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ w2: workload-priority=backup            │
│     Taint: role=backup:PreferNoSchedule │
│  └─ (pods tolerate taint, can failover) │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ Descheduler (kube-system)               │
│  └─ Moves pods back to preferred nodes  │
└─────────────────────────────────────────┘

Normal: w1 active, w2 passive
Failover: w1 down → w2 active (automatic)
Failback: w1 up → pods return to w1 (automatic via descheduler)
```

---

## Alternative Approaches Considered

### Alternative 1: Manual Failback (No Descheduler)

**Pros:**
- Simpler (no additional controller)
- More control over failback timing

**Cons:**
- Requires manual intervention: `kubectl delete pod` to trigger rescheduling
- Not truly "automatic" HA

**Verdict:** Rejected - defeats purpose of HA automation

---

### Alternative 2: Dual Primary Labels

**Approach:** Label both w1 and w2 with `role=primary`, use pod anti-affinity to prefer w1

**Pros:**
- No tolerations needed
- Simpler pod specs

**Cons:**
- Loses semantic distinction between active/passive
- Anti-affinity doesn't guarantee w1 preference (scoring ties)
- Harder to reason about which node is "primary"

**Verdict:** Rejected - less clear intent

---

### Alternative 3: Custom Scheduler

**Approach:** Write custom scheduler with active/passive logic

**Pros:**
- Complete control over scheduling decisions
- Could implement sophisticated failback strategies

**Cons:**
- Significant development/maintenance burden
- Overkill for homelab
- Reinventing solved problems

**Verdict:** Rejected - too complex

---

## Implementation Checklist

### Preparation
- [ ] Review current node labels and taints
- [ ] Review all deployments with nodeSelector
- [ ] Back up current configs: `kubectl get deploy -n media -o yaml > backup.yaml`
- [ ] Document current pod locations

### Phase 1: Labels
- [ ] Add `workload-priority` labels to w1, w2
- [ ] Verify labels: `kubectl get nodes --show-labels`

### Phase 2: Taints
- [ ] Taint w2: `kubectl taint nodes k3s-w2 role=backup:PreferNoSchedule`
- [ ] Verify taint: `kubectl describe node k3s-w2`

### Phase 3: Deployments
- [ ] Update sonarr deployment (affinity + toleration)
- [ ] Test sonarr failover/failback manually
- [ ] Update prowlarr deployment
- [ ] Update any other workloads with nodeSelector

### Phase 4: Descheduler
- [ ] Create descheduler manifests in Git
- [ ] Deploy descheduler (Helm or Flux)
- [ ] Verify descheduler running: `kubectl get pods -n kube-system`
- [ ] Check descheduler logs: `kubectl logs -n kube-system -l app=descheduler`

### Phase 5: Testing
- [ ] Test scenario 1: Normal operation (pods on w1)
- [ ] Test scenario 2: Failover (shutdown w1, pods → w2)
- [ ] Test scenario 3: Failback (start w1, pods → w1 via descheduler)
- [ ] Test scenario 4: Pod restart (stays on w1)

### Phase 6: Monitoring
- [ ] Set up alerts for node failures
- [ ] Monitor descheduler behavior
- [ ] Document actual failover/failback timings

---

## Rollback Plan

If issues arise:

### Rollback Phase 4 (Descheduler)
```bash
# Delete descheduler
helm uninstall descheduler -n kube-system
# Or via Flux:
kubectl delete kustomization infrastructure-descheduler -n flux-system
```

### Rollback Phase 3 (Deployments)
```bash
# Restore original deployment
kubectl apply -f backup.yaml
```

### Rollback Phase 2 (Taints)
```bash
# Remove taint from w2
kubectl taint nodes k3s-w2 role=backup:PreferNoSchedule-
```

### Rollback Phase 1 (Labels)
```bash
# Remove added labels
kubectl label node k3s-w1 workload-priority-
kubectl label node k3s-w2 workload-priority-
```

---

## Next Steps

**Immediate (for current w1 shutdown test):**
1. Observe current failover behavior (pod going to Pending)
2. Confirm root cause: `nodeSelector: role: primary` blocking w2
3. Let w1 come back up, document observations

**Short-term (after test):**
1. Implement Phases 1-3 (labels, taints, deployment updates)
2. Test failover without descheduler (manual failback)
3. Validate workloads can run on w2

**Medium-term:**
1. Deploy descheduler (Phase 4)
2. Test full automatic failover/failback cycle
3. Tune timings and parameters

**Long-term:**
1. Extend pattern to all workloads
2. Add monitoring/alerting for node failures
3. Document runbooks for maintenance

---

## Questions to Address

1. **Should w2 ever run workloads during normal operation?**
   - Proposed: No (pure active-passive)
   - Alternative: Allow overflow (active-active with preference)

2. **How fast should failback be?**
   - Proposed: ~5-7 minutes (balance stability vs responsiveness)
   - Alternative: Faster (2-3 min) with `*/2 * * * *` descheduler schedule

3. **Should all workloads follow this pattern?**
   - Proposed: Yes, for consistency
   - Alternative: Per-app decision based on criticality

4. **What about w3 (GPU node)?**
   - Proposed: Keep strict isolation (gpu=true:NoSchedule)
   - Status: No changes needed, working as intended

---

**End of Plan**
