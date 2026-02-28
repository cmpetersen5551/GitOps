# FUSE Propagation Testing Plan: Direct hostPath Approach (2026-02-28)

**Objective**: Validate whether FUSE mounts can propagate from a Kubernetes pod to host via `user_allow_other` + `Bidirectional` propagation, then be accessed by consumer pods.

**Test Node**: k3s-w2 (secondary storage node, acceptable to disrupt)  
**Risk Level**: Low (non-production node, reversible changes)  
**Timeline**: ~2 hours  
**Success Criteria**: Consumer pod can read FUSE mount created by producer pod after `user_allow_other` is enabled

---

## Overview: Why w2?

- w1 is primary with production Sonarr/Radarr running
- w2 is failover/secondary — safe to experiment with
- Tests on w2 won't affect production
- If successful, can then test on w1 with production workload as validation

---

## Phase 1: Host Setup (15 min) — Run on w2 Host

### 1.1 Verify FUSE Module & Current Config

```bash
# SSH to w2 as root
ssh root@k3s-w2

# Check FUSE module is loaded
lsmod | grep fuse
# Expected: fuse module listed

# Check current fuse.conf
sudo cat /etc/fuse.conf 2>/dev/null
# Expected: either empty, commented, or might already have user_allow_other

# Check what user is running k3s/kubelet
ps aux | grep kubelet | head -1
# Usually: root, or _k3s if k3s-specific user
```

### 1.2 Enable `user_allow_other` (If Not Already Enabled)

```bash
# Check if already enabled
grep -q "user_allow_other" /etc/fuse.conf && echo "Already enabled" || echo "Not enabled"

# If not enabled, add it
sudo bash -c 'echo "user_allow_other" >> /etc/fuse.conf'

# Verify
cat /etc/fuse.conf
# Expected: user_allow_other on a line by itself
```

### 1.3 Prepare Test Directory

```bash
# Create bridge directory on host where FUSE will be mounted
sudo mkdir -p /tmp/fuse-test-bridge
sudo chmod 755 /tmp/fuse-test-bridge

# Create a marker file so we can verify propagation
sudo touch /tmp/fuse-test-bridge/.marker-host

# Verify
ls -la /tmp/fuse-test-bridge/
# Expected: .marker-host visible
```

### 1.4 Verify Kubernetes can Access Host Path

```bash
# Check kubelet config on w2
ps aux | grep kubelet
# Look for: --root-dir or --var-lib-kubernetes-dir
# Usually: /var/lib/kubelet or /var/lib/rancher/k3s/...

# Ensure /tmp is accessible from kubelet
ls -la /tmp/ | head -5
# Expected: directory listing works from root
```

---

## Phase 2: Deploy Producer Pod (FUSE Creator) — 20 min

### 2.1 Create Test Namespace

```bash
kubectl create namespace fuse-test
kubectl label namespace fuse-test testing=true
```

### 2.2 Create Simple FUSE Mount Producer Pod

**File**: `test-fuse-producer.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fuse-producer
  namespace: fuse-test
spec:
  nodeName: k3s-w2  # Force to w2
  securityContext:
    runAsUser: 0
    runAsNonRoot: false
  containers:
  - name: fuse-creator
    image: alpine:3.19
    imagePullPolicy: IfNotPresent
    securityContext:
      privileged: true
      capabilities:
        add:
          - SYS_ADMIN
    command: ["/bin/sh", "-c"]
    args:
      - |
        set -x
        apk add --no-cache fuse fuse-dev alpine-sdk
        
        # CRITICAL: Create a simple FUSE filesystem
        # For testing, use bindfs (simple FUSE that just bind-mounts a directory)
        # Or mount a tmpfs and export via FUSE
        
        # Create source data
        mkdir -p /tmp/source-data
        echo "test-content-$(date +%s)" > /tmp/source-data/test-file.txt
        
        # Create FUSE mount point
        mkdir -p /mnt/fuse-output
        
        # Mount with allow_other flag
        # Using bindfs as a simple FUSE example (if available)
        # Fallback: use null-mount or simple tmpfs setup
        
        # For this test, we'll use a simple approach:
        # Create a FUSE mount by using go-fuse or fuser
        # Simplest: just verify the directory propagates with Bidirectional
        
        # Create a marker that proves we ran
        echo "fuse-producer-running-$(date +%s)" > /mnt/dfs/producer-marker.txt
        touch /mnt/dfs/.producer-started
        
        # Keep running so mount stays alive
        while true; do
          sleep 60
          echo "$(date): Producer still running"
        done
    
    volumeMounts:
    - name: fuse-bridge
      mountPath: /mnt/dfs
      mountPropagation: Bidirectional
    
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
  
  volumes:
  - name: fuse-bridge
    hostPath:
      path: /tmp/fuse-test-bridge
      type: DirectoryOrCreate
  
  restartPolicy: OnFailure
  tolerations:
  - key: node.longhorn.io/storage
    operator: Equal
    value: enabled
    effect: NoSchedule
```

### 2.3 Deploy & Verify Producer

```bash
# Deploy
kubectl apply -f test-fuse-producer.yaml

# Wait for pod to start (check logs)
kubectl logs -f -n fuse-test fuse-producer
# Expected: "fuse-producer-running" messages

# Check pod status
kubectl get pod -n fuse-test fuse-producer -o wide
# Expected: Running, on k3s-w2

# Check if markers appeared on host
ssh root@k3s-w2 "ls -la /tmp/fuse-test-bridge/"
# Expected: .marker-host (from step 1.3) + any files created by pod
```

### 2.4 If FUSE Not Available in Alpine

**If the above fails** because Alpine doesn't have a simple FUSE tool, use **bindfs**:

```bash
# Modified args for fuse-producer to install bindfs:
apk add --no-cache bindfs fuse

# Then mount with allow_other:
bindfs --allow-other /tmp/source-data /mnt/dfs
```

**Or** use **https://github.com/hanwen/go-fuse** example (requires building from source, more complex).

**Simpler fallback**: Just create regular files and let Bidirectional propagate them:

```bash
# Modified args:
mkdir -p /mnt/dfs
echo "producer-content-$(date +%s)" > /mnt/dfs/test-file.txt
touch /mnt/dfs/.producer-ready

# Keep running
while true; do
  sleep 60
  echo "$(date): Producer running" >> /mnt/dfs/producer-log.txt
done
```

This tests **propagation without needing actual FUSE**, which proves the namespace/mount mechanism works.

---

## Phase 3: Deploy Consumer Pod — 10 min

**File**: `test-fuse-consumer.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: fuse-consumer
  namespace: fuse-test
spec:
  nodeName: k3s-w2  # Force to w2 (same node for first test)
  containers:
  - name: reader
    image: alpine:3.19
    imagePullPolicy: IfNotPresent
    command: ["/bin/sh", "-c"]
    args:
      - |
        set -x
        echo "Consumer starting..."
        
        # Wait for /mnt/dfs to be accessible
        MAX_WAIT=30
        ELAPSED=0
        while [ ! -f /mnt/dfs/.producer-ready ] && [ $ELAPSED -lt $MAX_WAIT ]; do
          echo "Waiting for producer ($ELAPSED/$MAX_WAIT)..."
          sleep 1
          ELAPSED=$((ELAPSED+1))
        done
        
        if [ ! -f /mnt/dfs/.producer-ready ]; then
          echo "ERROR: Producer marker never appeared!"
          ls -la /mnt/dfs 2>&1
          exit 1
        fi
        
        echo "SUCCESS: Producer marker found!"
        echo "Contents of /mnt/dfs:"
        ls -la /mnt/dfs/
        
        echo "Reading producer file:"
        cat /mnt/dfs/test-file.txt || echo "Could not read file"
        
        # Keep running so we can check logs
        while true; do
          echo "$(date): Consumer healthy, producer data accessible"
          sleep 30
        done
    
    volumeMounts:
    - name: fuse-bridge
      mountPath: /mnt/dfs
      mountPropagation: HostToContainer
    
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
  
  volumes:
  - name: fuse-bridge
    hostPath:
      path: /tmp/fuse-test-bridge
      type: DirectoryOrCreate
  
  restartPolicy: OnFailure
```

### Deploy & Check

```bash
# Deploy consumer
kubectl apply -f test-fuse-consumer.yaml

# Monitor logs real-time
kubectl logs -f -n fuse-test fuse-consumer
# Expected: 
#   - "Waiting for producer (0/30)..."
#   - "SUCCESS: Producer marker found!"
#   - List of /mnt/dfs contents
#   - Consumer health messages

# Check consumer pod status
kubectl get pod -n fuse-test fuse-consumer -o wide
# Expected: Running (if SUCCESS), or CrashLoopBackOff (if FAILURE)

# If CrashLoopBackOff, check detailed logs
kubectl describe pod -n fuse-test fuse-consumer
kubectl logs -n fuse-test fuse-consumer --previous  # Last run's logs
```

---

## Phase 4: Cross-Node Test (If Phase 3 Works) — 15 min

### 4.1 Deploy Same Setup Across Nodes

If Phase 3 succeeds, confirm it works cross-node:

```bash
# Modify test-fuse-consumer.yaml: remove nodeName: k3s-w2
# Let scheduler place consumer pod on any node (could be cp1, w1, w3)
# Producer still on w2

# Deploy modified consumer
kubectl apply -f test-fuse-consumer-no-nodeaffinity.yaml

# Check where it landed
kubectl get pod -n fuse-test fuse-consumer -o wide
# If on a different node, verify it can still access the /tmp/fuse-test-bridge mount
```

**Important**: Cross-node access requires:
- Producer on w2 creates files in `/tmp/fuse-test-bridge`
- Consumer on different node tries to access via NFS or similar (not direct hostPath!)
- Direct hostPath only works within the same node

So **this phase will likely FAIL for cross-node** — which is fine, we're testing if Bidirectional propagation even works same-node.

---

## Phase 5: Stale Mount Test (10 min) — Critical HA Validation

### 5.1 Kill Producer Pod, Watch Consumer

```bash
# Delete producer pod
kubectl delete pod -n fuse-test fuse-producer --grace-period=0 --force

# Immediately watch consumer logs
kubectl logs -f -n fuse-test fuse-consumer

# Expected behavior:
# - Consumer keeps running (or fails immediately)
# - If it fails: "Transport endpoint is not connected" error
# - If it keeps running: Can it still read /mnt/dfs?
#   (Likely: files are no longer accessible, stat() fails)
```

### 5.2 Recreate Producer Pod & Watch Consumer Recover

```bash
# Redeploy producer
kubectl apply -f test-fuse-producer.yaml

# Watch if consumer automatically recovers
kubectl logs -f -n fuse-test fuse-consumer

# Check consumer status
kubectl get pod -n fuse-test fuse-consumer -o wide

# Expected:
# - Consumer needs liveness probe to restart after producer death
# - OR consumer has retry logic to detect fresh mount
# - If neither: mount stays broken, need manual restart
```

---

## Phase 6: Cleanup & Analysis — 10 min

### 6.1 Cleanup

```bash
# Delete test namespace (clears all test pods)
kubectl delete namespace fuse-test

# Clean up host-level files on w2
ssh root@k3s-w2 "sudo rm -rf /tmp/fuse-test-bridge"

# Verify cleanup
kubectl get namespace fuse-test 2>&1 || echo "Namespace deleted successfully"
```

### 6.2 Document Results

Fill in the **Results** section below with actual outcomes:

---

## Results & Analysis

### Phase 1 Results: Host Setup
- [ ] FUSE module loaded?
- [ ] `user_allow_other` enabled? (Y/N)
- [ ] Test directory created successfully?

**Notes**: 

### Phase 2 Results: Producer Pod
- [ ] Pod deployed without errors?
- [ ] Pod status: Running / CrashLoopBackOff / other
- [ ] Files appeared in `/tmp/fuse-test-bridge` on host? (Y/N)
- [ ] Can host read files created by pod? (Y/N)

**Producer logs**:
```
[paste relevant lines here]
```

**Host verification** (from w2):
```
[paste `ls -la /tmp/fuse-test-bridge/` output]
```

### Phase 3 Results: Consumer Pod (Same Node)
- [ ] Consumer pod deployed?
- [ ] Consumer detected producer marker?
- [ ] Consumer able to read files? (Y/N)
- [ ] Any permission errors?

**Consumer logs** (SUCCESS case):
```
[paste logs showing SUCCESS]
```

**Consumer logs** (FAILURE case):
```
[paste logs showing what failed]
```

### Phase 4 Results: Cross-Node Test
- [ ] Attempted cross-node test? (Y/N)
- [ ] If yes, result: Success / Failed as expected (hostPath same-node only) / Other

**Notes**: 

### Phase 5 Results: Stale Mount & Recovery
- [ ] Producer deletion: How long until consumer noticed?
- [ ] Consumer state after producer death: Still running / Crashed / Stuck
- [ ] After producer restart: Consumer automatically recovers? (Y/N)
- [ ] If not automatic: Manual restart needed?

**Critical finding for HA**: Does CIFS auto-reconnect behavior exist here?

---

## Success Criteria & Interpretation

### ✅ SUCCESS: All Phases Complete Without Errors

**Interpretation**: FUSE propagation works with `user_allow_other` on k3s-w2. 

**Next steps**: 
1. Test on w1 with real Decypharr pod
2. Measure performance vs current SMB/CIFS
3. Plan migration if superior

**Migration path**: Replace SMB layer with direct FUSE + hostPath approach.

### ⚠️ PARTIAL SUCCESS: Phases 1-3 Work, Phase 5 Fails

**Interpretation**: FUSE can propagate and be accessed, but stale mounts are a problem.

**Next steps**:
1. Add liveness probe to consumer pods that detects stale mounts
2. Consumer pod auto-restarts when mount becomes inaccessible
3. Acceptable for homelab use (Plex brief pause + auto-recovery)
4. Consider this as alternative to SMB if simpler overall

**Migration path**: Worth pursuing IF liveness probe recovery is acceptable.

### ❌ FAILURE: Producer Pod Can't Create Files in hostPath

**Interpretation**: Bidirectional propagation or /tmp/fuse-test-bridge access blocked.

**Troubleshooting**: 
```bash
# Check producer pod logs for permission errors
kubectl describe pod -n fuse-test fuse-producer

# Check if hostPath mount actually appears in pod
kubectl exec -it -n fuse-test fuse-producer -- ls -la /mnt/dfs

# Check SELinux or AppArmor constraints (if applicable)
sudo getenforce  # On w2

# Verify kubelet has /tmp access
ssh root@k3s-w2 "ls -ld /tmp"
```

**Decision**: Direct hostPath FUSE approach won't work on this k3s setup. **Stick with SMB/CIFS** (proven working).

---

## Fallback: If FUSE Creation is Complex

If getting a working FUSE mount in Alpine container is difficult, use **simplified test**:

```yaml
# Simplified producer: just writes files to Bidirectional volume
containers:
- name: writer
  image: alpine:3.19
  command: ["/bin/sh", "-c"]
  args:
    - |
      mkdir -p /mnt/data
      echo "test-$(date +%s)" > /mnt/data/file.txt
      while true; do
        echo "$(date): Still running" >> /mnt/data/log.txt
        sleep 10
      done
  volumeMounts:
  - name: test-vol
    mountPath: /mnt/data
    mountPropagation: Bidirectional

volumes:
- name: test-vol
  hostPath:
    path: /tmp/test-data
    type: DirectoryOrCreate
```

This tests **Bidirectional propagation without FUSE**, isolating the propagation mechanism from FUSE complexity. If this fails, FUSE definitely won't work.

---

## Commands Cheat Sheet

```bash
# Setup on w2 host
ssh root@k3s-w2
sudo bash -c 'echo "user_allow_other" >> /etc/fuse.conf'
sudo mkdir -p /tmp/fuse-test-bridge

# Deploy test pods
kubectl create namespace fuse-test
kubectl apply -f test-fuse-producer.yaml
kubectl apply -f test-fuse-consumer.yaml

# Monitor
kubectl logs -f -n fuse-test fuse-producer
kubectl logs -f -n fuse-test fuse-consumer
kubectl get pods -n fuse-test -o wide

# Check host-level mount
ssh root@k3s-w2 "ls -la /tmp/fuse-test-bridge/"

# Kill & recover test
kubectl delete pod -n fuse-test fuse-producer --grace-period=0 --force
kubectl apply -f test-fuse-producer.yaml

# Cleanup
kubectl delete namespace fuse-test
ssh root@k3s-w2 "sudo rm -rf /tmp/fuse-test-bridge"
```

---

## Timeline

- **Phase 1**: 15 min (host setup)
- **Phase 2**: 20 min (producer pod + verification)
- **Phase 3**: 10 min (consumer pod + verification)
- **Phase 4**: 15 min (cross-node test, expected to fail)
- **Phase 5**: 10 min (stale mount test)
- **Phase 6**: 10 min (cleanup + analysis)

**Total**: ~90 minutes

---

## Risk Assessment

**Risk Level**: LOW
- **Node**: w2 (non-production secondary)
- **Changes**: Reversible (just `/etc/fuse.conf` and `/tmp` directory)
- **Rollback**: Delete namespace, revert `/etc/fuse.conf`
- **Production Impact**: None (w1 is unaffected)

---

**Date Created**: 2026-02-28  
**Status**: Ready to execute  
**Next Action**: Run Phases 1-2 on w2, report results
