# SeaweedFS Issues and Findings

**Date:** February 11, 2026  
**Context:** HA failover testing for Sonarr/Prowlarr media workloads

## Critical Issue Discovered

### Data Integrity Problem with RWX Storage Class

**Storage Class:** `seaweedfs-ha-rwx`  
**Severity:** CRITICAL - Data corruption/loss  
**Status:** NOT PRODUCTION READY

#### Symptoms

When using the `seaweedfs-ha-rwx` storage class (ReadWriteMany):

1. **Files show size but contain no readable data**
   ```bash
   # File shows 49 bytes
   $ ls -lh /config/config.xml
   -rw-r--r-- 1 abc users 49 Feb 12 04:40 /config/config.xml
   
   # But cat returns nothing
   $ cat /config/config.xml
   (empty output)
   ```

2. **Multiple files affected**
   - config.xml: 49 bytes reported, empty content
   - DataProtection keys: 0 bytes (never written)
   - Database files: Created but unreadable

3. **Application Impact**
   - Sonarr crashed repeatedly with "Document is empty" errors
   - Database operations failed
   - Applications unable to start or maintain state

#### Testing Details

**Test Date:** February 11-12, 2026  
**Affected Applications:** Sonarr (tested), likely affects all workloads  
**PVC Configuration:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-sonarr
spec:
  accessModes:
    - ReadWriteMany  # BROKEN
  storageClassName: seaweedfs-ha-rwx  # BROKEN
  resources:
    requests:
      storage: 5Gi
```

**Evidence:**
```bash
# Pod: sonarr-956c47c5c-rqt8n
$ kubectl exec -n media sonarr-956c47c5c-rqt8n -- ls -lah /config/
-rw------- 1 abc users    0 Feb 12 04:46 /config/asp/key-*.xml  # 0 bytes!
-rw-r--r-- 1 abc users   49 Feb 12 04:47 /config/config.xml     # Shows size
-rw-r--r-- 1 abc users    0 Feb 12 04:46 /config/sonarr.pid

$ kubectl exec -n media sonarr-956c47c5c-rqt8n -- cat /config/config.xml
# Returns EMPTY despite showing 49 bytes
```

## Working Configuration

### seaweedfs-single (RWO) - VERIFIED WORKING

**Storage Class:** `seaweedfs-single`  
**Access Mode:** ReadWriteOnce  
**Status:** PRODUCTION READY (current configuration)

#### Verification

**Test Date:** February 12, 2026  
**Test Application:** Sonarr (pod: sonarr-6498b6fc99-tpdg2)

```bash
# Files are properly written and readable
$ kubectl exec -n media sonarr-6498b6fc99-tpdg2 -- find /config -type f -exec ls -lh {} \;
-rw------- 1 abc users 1000 Feb 12 04:53 /config/asp/key-*.xml  # Actual data!
-rw-r--r-- 1 abc users  508 Feb 12 04:53 /config/config.xml
-rw-r--r-- 1 abc users  27K Feb 12 04:53 /config/logs/sonarr.debug.txt
-rw-r--r-- 1 abc users 244K Feb 12 04:54 /config/logs/sonarr.txt
-rw-r--r-- 1 abc users 4.0K Feb 12 04:53 /config/sonarr.db

# Content is readable
$ kubectl exec -n media sonarr-6498b6fc99-tpdg2 -- head -5 /config/config.xml
<Config>
  <BindAddress>*</BindAddress>
  <Port>8989</Port>
  <SslPort>9898</SslPort>
  <EnableSsl>False</EnableSsl>
```

**Current Production PVC:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-sonarr
  namespace: media
spec:
  accessModes:
    - ReadWriteOnce  # WORKING
  storageClassName: seaweedfs-single  # WORKING
  resources:
    requests:
      storage: 5Gi
```

**Result:** Application healthy and stable
- Sonarr: `1/1 Running` 
- Database migrations completed successfully
- Files properly persisted across pod restarts

## Root Cause Analysis

### Underlying Architecture Issue

**Problem:** SeaweedFS volume servers use `local-path` storage  
**Impact:** Not truly HA - volumes tied to specific nodes

```bash
$ kubectl get pv | grep seaweedfs
pvc-5f2227f5-...  100Gi  RWO  Bound  seaweedfs/mount0-seaweedfs-volume-1  local-path  ...
pvc-89defcd4-...  100Gi  RWO  Bound  seaweedfs/mount0-seaweedfs-volume-0  local-path  ...
pvc-a9b137ab-...  100Gi  RWO  Bound  seaweedfs/mount0-seaweedfs-volume-2  local-path  ...
```

This means:
1. SeaweedFS volume servers store data on node-local `local-path` PVCs
2. When a node fails, its SeaweedFS volume data is unavailable
3. RWX volumes can't access replicas on other nodes
4. **Result:** Volume mount timeouts and data integrity issues

### CSI Driver Issues

**Mount Timeout Problems:**
- Default CSI driver timeouts too aggressive for failover scenarios
- Added mount options to `seaweedfs-ha-rwx` storage class (may not fully resolve data integrity issues):
  ```yaml
  mountOptions:
    - retry=3
    - connectTimeout=60s
    - readTimeout=90s
    - writeTimeout=90s
  ```

## Lessons Learned

### HA Requirements NOT Met

1. **Storage Backend Must Be Resilient**
   - SeaweedFS volumes need networked storage (NFS, Ceph, etc.) instead of `local-path`
   - Current architecture: Volume data lives on node-local storage = single point of failure

2. **RWX Requires Proper Replication**
   - SeaweedFS replication settings insufficient if underlying storage is not HA
   - Replication parameter: `"010"` (1 replica) - but replica on failed node is inaccessible

3. **Data Integrity Must Be Validated**
   - File metadata vs actual data mismatch indicates serious issue
   - Not just a mount timeout problem - data is genuinely corrupted/inaccessible

### Successful Workarounds

1. **Hard Node Selector + RWO Storage**
   - Pin workload to specific node with `nodeSelector: role: primary`
   - Use `seaweedfs-single` with RWO access mode
   - **Trade-off:** No automatic failover, but data integrity guaranteed

2. **Increased Startup Probe Timeouts**
   - Database migrations can take 3-5 minutes on first startup
   - Default 2.5 min timeout caused unnecessary pod restarts
   - Solution: 10 minute startup probe timeout
   ```yaml
   startupProbe:
     periodSeconds: 10
     failureThreshold: 60  # 10 minutes total
   ```

## Current Production State

### Working Configuration

**Application:** Sonarr  
**Node:** k3s-w1 (pinned with `nodeSelector: role: primary`)  
**Storage:** `seaweedfs-single` (RWO)  
**Status:** ✅ Healthy and stable

**Deployment Strategy:**
```yaml
spec:
  nodeSelector:
    role: primary  # Hard-pinned to w1
  volumes:
    - name: config-volume
      persistentVolumeClaim:
        claimName: pvc-sonarr  # seaweedfs-single, RWO
```

### Known Limitations

1. **No HA Failover**
   - Workloads will NOT automatically migrate to backup node
   - If w1 fails, manual intervention required
   - Acceptable for non-critical media workloads

2. **Storage Classes Status**
   - ✅ `seaweedfs-single` - Working, production use
   - ❌ `seaweedfs-ha-rwx` - BROKEN, do not use
   - ⚠️ `seaweedfs-ha` - Untested with current architecture
   - ℹ️ `seaweedfs-storage` - Legacy, review usage

## Next Steps for True HA

### Requirements for Proper SeaweedFS HA

1. **Fix Volume Server Storage Backend**
   - Replace `local-path` with networked storage for volume server data
   - Options: NFS, Longhorn, Ceph RBD, or cloud block storage
   - Ensures volume data survives node failures

2. **Validate RWX Implementation**
   - After fixing storage backend, re-test `seaweedfs-ha-rwx`
   - Verify data integrity with comprehensive read/write tests
   - Test failover scenarios with actual data

3. **Implement Proper Replication**
   - Review SeaweedFS replication settings
   - Ensure replicas distributed across nodes
   - Test that replicas remain accessible during node failure

4. **Documentation**
   - Review SeaweedFS operator CRD and topology configuration
   - Document proper HA setup for future reference
   - See: SEAWEEDFS_CSI_DEPLOYMENT_PLAN.md and related documents

### Recommended Approach

**Phase 1:** Keep current working configuration
- Continue using `seaweedfs-single` for stability
- Accept manual intervention for node failures
- Document recovery procedures

**Phase 2:** Research and plan SeaweedFS HA
- Deep-dive into SeaweedFS architecture
- Design proper storage backend
- Test in isolated environment

**Phase 3:** Gradual migration to HA
- Start with non-critical workloads
- Comprehensive testing and validation
- Maintain RWO fallback option

## References

- **Related Documents:**
  - SEAWEEDFS_CSI_DEPLOYMENT_PLAN.md
  - SEAWEEDFS_HA_ARCHITECTURE.md
  - SEAWEEDFS_ROOT_CAUSE_ANALYSIS.md
  - CLUSTERPLEX_HA_IMPLEMENTATION_PLAN.md

- **Git History:**
  - Revert commit: `3df9ec4` - Restored working configuration
  - HA testing commits: `1766e04` through `99284c2`

- **Key Commands for Diagnosis:**
  ```bash
  # Check PV storage classes
  kubectl get pv -o wide | grep seaweedfs
  
  # Verify file integrity in volume
  kubectl exec -n media <pod> -- find /config -type f -exec ls -lh {} \;
  kubectl exec -n media <pod> -- cat /config/config.xml
  
  # Check SeaweedFS topology
  kubectl get seaweed -n seaweedfs -o yaml
  
  # Review CSI driver logs
  kubectl logs -n seaweedfs-csi-driver -l app=seaweedfs-csi-driver
  ```

## Summary

**TLDR:**
- ✅ `seaweedfs-single` (RWO) works - use for production
- ❌ `seaweedfs-ha-rwx` (RWX) has data integrity issues - DO NOT USE
- ⚠️ SeaweedFS volume servers use `local-path` storage = not truly HA
- 🎯 True HA requires networked storage backend for volume servers
