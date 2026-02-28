# FUSE Propagation Test — Quick Start 

**Location**: w2 (secondary storage node)  
**Time**: ~90 minutes  
**Risk**: Low (w2 is non-production)

---

## One-Command Test (Full Automated)

```bash
chmod +x scripts/test-fuse-propagation.sh
./scripts/test-fuse-propagation.sh
```

This runs all phases automatically with logging.

---

## Manual Step-by-Step (If You Want Control)

### Phase 1: Host Setup (Run on w2 host, 5 min)

```bash
# SSH to w2
ssh root@k3s-w2

# Enable user_allow_other
sudo bash -c 'echo "user_allow_other" >> /etc/fuse.conf'

# Verify
grep -q "user_allow_other" /etc/fuse.conf && echo "✓ Enabled" || echo "✗ Failed"

# Create test directory
sudo mkdir -p /tmp/fuse-test-bridge
sudo chmod 755 /tmp/fuse-test-bridge
sudo touch /tmp/fuse-test-bridge/.marker-host

# Verify
ls -la /tmp/fuse-test-bridge/

# Exit SSH
exit
```

### Phase 2: Deploy Producer (Run from your machine, 5 min)

```bash
# Create namespace
kubectl create namespace fuse-test

# Deploy producer pod
kubectl apply -f clusters/homelab/testing/fuse-propagation-test/producer.yaml

# Wait and check status
sleep 10
kubectl get pod -n fuse-test -o wide
kubectl logs -f -n fuse-test fuse-producer
```

**Expected output**: 
```
=== FUSE Producer Starting ===
...
producer-started-<timestamp>
=== Producer Ready, Keeping Alive ===
```

### Phase 3: Deploy Consumer (Run from your machine, 5 min)

```bash
# Deploy consumer
kubectl apply -f clusters/homelab/testing/fuse-propagation-test/consumer.yaml

# Wait and watch logs
sleep 15
kubectl logs -f -n fuse-test fuse-consumer
```

**Expected output**:
```
=== FUSE Consumer Starting ===
...
SUCCESS: Producer marker found at <timestamp>
=== Full /mnt/dfs Contents ===
...
[Consumer Ready]
```

### Phase 4: Test Stale Mount (10 min)

```bash
# Delete producer (kill it)
kubectl delete pod -n fuse-test fuse-producer --grace-period=0 --force

# Watch consumer logs real-time
kubectl logs -f -n fuse-test fuse-consumer

# What happens? 
# Option A: Consumer keeps running and detects "Mount became inaccessible" → auto-exits
# Option B: Consumer continues fine (stale mount not detected immediately)
```

### Phase 5: Test Recovery (10 min)

```bash
# Redeploy producer
kubectl apply -f clusters/homelab/testing/fuse-propagation-test/producer.yaml

# Check if consumer automatically recovers
sleep 10
kubectl logs -n fuse-test fuse-consumer | tail -20

# Check if mount is accessible again
kubectl get pod -n fuse-test fuse-consumer -o wide
```

### Cleanup (3 min)

```bash
# Delete test namespace
kubectl delete namespace fuse-test

# Clean up host
ssh root@k3s-w2 "sudo rm -rf /tmp/fuse-test-bridge"
```

---

## Real-Time Monitoring (During Test)

Open 3 terminal tabs:

**Tab 1 - Producer logs**:
```bash
kubectl logs -f -n fuse-test fuse-producer
```

**Tab 2 - Consumer logs**:
```bash
kubectl logs -f -n fuse-test fuse-consumer
```

**Tab 3 - Pod status**:
```bash
watch kubectl get pods -n fuse-test -o wide
```

---

## Key Observations to Look For

### SUCCESS Indicators ✓
- [ ] Producer pod Running and writing files
- [ ] `ls -la /tmp/fuse-test-bridge/` on w2 shows producer files
- [ ] Consumer logs show "SUCCESS: Producer marker found"
- [ ] Both pods remain Running

### FAILURE Indicators ✗
- [ ] Producer pod CrashLoopBackOff
- [ ] Consumer logs show "ERROR: Producer marker never appeared"
- [ ] Permission denied errors in logs
- [ ] "Transport endpoint is not connected" errors

### Stale Mount Indicators ⚠
- [ ] After producer deleted, consumer stops seeing mount
- [ ] Consumer either crashes or detects error
- [ ] After producer restarts, consumer needs restart to work again

---

## If Something Goes Wrong

### Producer stuck in CrashLoopBackOff

```bash
# Check detailed error
kubectl describe pod -n fuse-test fuse-producer

# Check logs from previous run
kubectl logs --previous -n fuse-test fuse-producer

# Check if /tmp/fuse-test-bridge exists on w2
ssh root@k3s-w2 "ls -ld /tmp/fuse-test-bridge"

# Check kubelet can access it
ssh root@k3s-w2 "ls -la /tmp | grep fuse"
```

### Consumer can't connect to producer

```bash
# Check if producer is actually creating files
ssh root@k3s-w2 "ls -la /tmp/fuse-test-bridge/"

# Wait longer (producer takes 30-60s to start fully)
sleep 30
kubectl logs -n fuse-test fuse-consumer | tail -20

# Force consumer to restart
kubectl delete pod -n fuse-test fuse-consumer
kubectl apply -f clusters/homelab/testing/fuse-propagation-test/consumer.yaml
```

### Mount shows "Transport endpoint is not connected"

```bash
# This means FUSE mount is stale (expected after producer restart)
# Check stale mount behavior section in FUSE_PROPAGATION_TEST_PLAN.md

# Verify producer is running
kubectl get pod -n fuse-test fuse-producer

# Check both pods status
kubectl describe pod -n fuse-test fuse-producer
kubectl describe pod -n fuse-test fuse-consumer
```

---

## Decision Tree After Test

```
                     ┌─ SUCCESS: Yes ──→ FUSE propagation works!
                     │                   Next: Test on w1, Measure perf
Test Completes ──────┤
                     │
                     └─ FAILURE: No ──→ Fundamental limitation confirmed
                                       Keep SMB/CIFS, pursue Option D (go-fuse fix)
                                       
              ┌─ Yes ──→ Auto-recovery possible!
              │         Can replace SMB with detection + restart logic
Stale Mount ──┤
              │
              └─ No ──→ Manual restart needed
                       SMB auto-reconnect is superior
                       Stick with SMB/CIFS
```

---

## Useful Debugging Commands

```bash
# Check all test resources
kubectl get all -n fuse-test

# Delete everything and start over
kubectl delete namespace fuse-test --wait=true

# Check pod events
kubectl describe pod -n fuse-test <pod-name>

# Real-time pod state
watch kubectl get pods -n fuse-test -o wide

# Stream all logs
kubectl logs -f -n fuse-test --all-containers=true -l testing=true

# Check w2 mount points
ssh root@k3s-w2 "mount | grep fuse"

# Check w2 file system
ssh root@k3s-w2 "df /tmp/fuse-test-bridge"

# Kill and force-remove pod
kubectl delete pod -n fuse-test <pod-name> --grace-period=0 --force
```

---

## Expected Timeline

- **Phase 1 (Host setup)**: 5 min
- **Phase 2 (Producer deploy)**: 5 min  
- **Phase 3 (Consumer deploy)**: 5 min
- **Phase 4 (Stale mount test)**: 15 min (with waiting)
- **Phase 5 (Recovery test)**: 15 min (with waiting)
- **Cleanup**: 3 min

**Total**: ~45 minutes (faster with automated script)

---

**Questions?** Check the detailed test plan: `docs/FUSE_PROPAGATION_TEST_PLAN.md`
