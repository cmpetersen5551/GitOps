# StatefulSet Conversion & Storage Simplification Plan

**Date:** February 14, 2026  
**Status:** Ready for Implementation  
**Goal:** Fix RWO PVC failover + simplify SeaweedFS topology

---

## Executive Summary

This plan addresses two critical improvements:

1. **Convert Sonarr/Prowlarr to StatefulSets** - Prevents PVC recreation during failover
2. **Remove w3 from storage topology** - Simplify to w1 ↔ w2 replication only

**Current Problem:**
- Deployments with separate PVCs recreate empty PVCs when pods die
- Results in data loss during node failures
- Fencing controller handles VolumeAttachment cleanup, but doesn't prevent PVC recreation

**Solution:**
- StatefulSets maintain stable PVC identity across pod restarts
- Combined with fencing controller = fully automatic HA failover
- Simpler storage topology (w1 + w2) with same HA guarantees

**Estimated Time:** 2 hours  
**Risk Level:** Medium (requires Sonarr data restoration)

---

## Part 1: StatefulSet Conversion

### What Changes

**Current (Deployment):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sonarr
spec:
  replicas: 1
  template:
    spec:
      volumes:
        - name: config-volume
          persistentVolumeClaim:
            claimName: pvc-sonarr  # ← Separate PVC resource
```

**Problem:** When pod dies, new pod with random name binds to PVC. If PVC was deleted during cleanup, new empty PVC is created.

**New (StatefulSet):**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sonarr
spec:
  serviceName: sonarr-headless  # ← Required
  replicas: 1
  volumeClaimTemplates:  # ← PVC owned by StatefulSet
    - metadata:
        name: config
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: seaweedfs-storage
        resources:
          requests:
            storage: 5Gi
```

**Benefits:**
- ✅ Pod name is stable: `sonarr-0` (not `sonarr-abc123`)
- ✅ PVC name is stable: `config-sonarr-0` (bound to pod)
- ✅ PVC persists across pod restarts/reschedules
- ✅ PVC only deleted when StatefulSet is deleted
- ✅ Works with fencing controller for automatic failover

### Files to Modify

#### 1. Sonarr

**Create new files:**
- `clusters/homelab/apps/media/sonarr/statefulset.yaml` (replaces deployment.yaml)
- `clusters/homelab/apps/media/sonarr/service-headless.yaml` (new requirement)

**Modify:**
- `clusters/homelab/apps/media/sonarr/kustomization.yaml` - Update resource list
- `clusters/homelab/apps/media/sonarr/service.yaml` - Add selector for statefulset

**Delete:**
- `clusters/homelab/apps/media/sonarr/deployment.yaml` (replaced)
- `clusters/homelab/apps/media/sonarr/pvc.yaml` (replaced by volumeClaimTemplate)

#### 2. Prowlarr

**Same pattern as Sonarr:**
- Create `statefulset.yaml` with volumeClaimTemplate
- Create `service-headless.yaml`
- Update `kustomization.yaml`
- Delete `deployment.yaml` and `pvc.yaml`

### Implementation Steps

#### Step 1: Backup Current State

```bash
# Backup Sonarr PVC data
kubectl get pvc -n media pvc-sonarr -o yaml > /tmp/pvc-sonarr-backup.yaml

# Backup old PV (has replicated database)
kubectl get pv pvc-06fe669d-c0f9-4f30-be46-08f5412812d8 -o yaml > /tmp/pv-sonarr-old.yaml

# Note: Old database is already replicated on w2's SeaweedFS volume server
```

#### Step 2: Create Headless Service for Sonarr

```yaml
# clusters/homelab/apps/media/sonarr/service-headless.yaml
apiVersion: v1
kind: Service
metadata:
  name: sonarr-headless
  namespace: media
spec:
  clusterIP: None  # ← Headless
  selector:
    app: sonarr
  ports:
    - port: 8989
      name: http
```

#### Step 3: Create StatefulSet for Sonarr

```yaml
# clusters/homelab/apps/media/sonarr/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: sonarr
  namespace: media
  labels:
    app: sonarr
spec:
  serviceName: sonarr-headless  # ← Links to headless service
  replicas: 1
  selector:
    matchLabels:
      app: sonarr
  # Use OnDelete to prevent automatic restarts during updates
  updateStrategy:
    type: OnDelete
  # Ordered pod management (wait for ready before starting next)
  podManagementPolicy: OrderedReady
  template:
    metadata:
      labels:
        app: sonarr
    spec:
      securityContext:
        fsGroup: 1000
        runAsNonRoot: false
        runAsUser: 0
      # Node affinity: Prefer w1 (primary), allow w2 (backup) as failover
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: workload-priority
                    operator: In
                    values:
                      - primary
            - weight: 10
              preference:
                matchExpressions:
                  - key: workload-priority
                    operator: In
                    values:
                      - backup
      # Tolerations: Allow scheduling on w2 despite PreferNoSchedule taint
      tolerations:
        - key: role
          operator: Equal
          value: backup
          effect: PreferNoSchedule
        # Faster failover: Evict after 30 seconds
        - key: node.kubernetes.io/unreachable
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 30
        - key: node.kubernetes.io/not-ready
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 30
      containers:
        - name: sonarr
          image: linuxserver/sonarr:4.0.16
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8989
              name: http
          env:
            - name: PUID
              value: "1000"
            - name: PGID
              value: "1000"
            - name: TZ
              value: "UTC"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 1000m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /ping
              port: 8989
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /ping
              port: 8989
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          startupProbe:
            httpGet:
              path: /ping
              port: 8989
            initialDelaySeconds: 0
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 60
          volumeMounts:
            - name: config  # ← Matches volumeClaimTemplate name
              mountPath: /config
  # PVC template - creates PVC automatically per pod
  volumeClaimTemplates:
    - metadata:
        name: config  # ← Will create PVC: config-sonarr-0
        labels:
          app: sonarr
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: seaweedfs-storage
        resources:
          requests:
            storage: 5Gi
```

#### Step 4: Update Kustomization

```yaml
# clusters/homelab/apps/media/sonarr/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: media
resources:
  - statefulset.yaml       # ← Changed from deployment.yaml
  - service.yaml
  - service-headless.yaml  # ← New
  - ingress.yaml
  # Removed: pvc.yaml (now in volumeClaimTemplate)
```

#### Step 5: Clean Up Old Resources

```bash
# Delete old Deployment and PVC manually BEFORE applying StatefulSet
kubectl delete deployment -n media sonarr
kubectl delete pvc -n media pvc-sonarr

# Old PV pvc-06fe669d... should now be Available (has your database)
kubectl get pv pvc-06fe669d-c0f9-4f30-be46-08f5412812d8
```

#### Step 6: Deploy StatefulSet via Git

```bash
cd /Users/Chris/Source/GitOps

# Commit StatefulSet changes
git add clusters/homelab/apps/media/sonarr/
git commit -m "Convert Sonarr to StatefulSet for HA failover"
git push

# Flux will reconcile automatically
flux reconcile kustomization apps -n flux-system
```

#### Step 7: Restore Old Database

**Option A: Bind new PVC to old PV (manual)**
```bash
# Wait for new PVC to be created
kubectl get pvc -n media config-sonarr-0 -w

# If it binds to NEW empty PV, delete it and bind to old PV
kubectl delete pvc -n media config-sonarr-0

# Patch old PV to remove claimRef
kubectl patch pv pvc-06fe669d-c0f9-4f30-be46-08f5412812d8 \
  -p '{"spec":{"claimRef":null}}'

# Recreate StatefulSet to trigger new PVC
kubectl delete sts -n media sonarr
flux reconcile kustomization apps -n flux-system

# New PVC should bind to old Available PV
```

**Option B: Copy data from old PV (safer)**
```bash
# Mount both PVs in a temporary pod
# Copy /config from old PV to new PVC
# More complex but guarantees no data loss
```

#### Step 8: Verify Sonarr

```bash
# Check pod status
kubectl get pods -n media -l app=sonarr

# Check PVC binding
kubectl get pvc -n media config-sonarr-0

# Access Sonarr UI
# Should show original configuration (series, settings, etc.)
```

#### Step 9: Repeat for Prowlarr

Apply same pattern:
- Create statefulset.yaml
- Create service-headless.yaml
- Update kustomization.yaml
- Delete old deployment and PVC
- Deploy via Git

---

## Part 2: Simplify SeaweedFS Storage Topology

### Current State

```yaml
volumes:
  proxmox:
    replicas: 2  # w1 + w3
    rack: "proxmox"
  unraid:
    replicas: 1  # w2
    rack: "unraid"

replicationPlacement: "010"  # 2 copies across zones
```

**Pods running:**
- `seaweedfs-volume-proxmox-0` on w1
- `seaweedfs-volume-proxmox-1` on w3
- `seaweedfs-volume-unraid-0` on w2

### Target State

```yaml
volumes:
  proxmox:
    replicas: 1  # Only w1
    rack: "proxmox"
    nodeSelector: |
      kubernetes.io/hostname: k3s-w1
  unraid:
    replicas: 1  # Only w2
    rack: "unraid"
    nodeSelector: |
      kubernetes.io/hostname: k3s-w2

replicationPlacement: "010"  # Same - 2 copies across zones
```

**Pods after change:**
- `seaweedfs-volume-proxmox-0` on w1 only
- `seaweedfs-volume-unraid-0` on w2 only
- w3: No volume server (pure GPU compute)

### Why This Works

**"010" replication = 2 copies across zones:**
- Data written to w1 → replicated to w2 ✅
- Data written to w2 → replicated to w1 ✅
- HA maintained: Survives w1 OR w2 failure ✅

**No HA degradation:**
- If Proxmox host dies → w1 dies → data on w2
- If Unraid host dies → w2 dies → data on w1
- Same failover behavior as before

**Capacity sufficient:**
- w1: 150GB + w2: 100GB = 250GB total
- Current usage: ~10-15GB (Sonarr + Prowlarr)
- 25x overcapacity

### Implementation Steps

#### Step 1: Update SeaweedFS HelmRelease

```yaml
# clusters/homelab/infrastructure/seaweedfs/helmrelease.yaml

# Find the volumes: section and update:
volumes:
  proxmox:
    enabled: true
    replicas: 1  # ← Changed from 2
    dataCenter: "dc1"
    rack: "proxmox"
    
    affinity: ""
    
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
    
    # Pin to w1 only (remove w3)
    nodeSelector: |
      kubernetes.io/hostname: k3s-w1
      sw-volume: "true"
    
    # Remove GPU toleration (not needed anymore)
    # tolerations: ""  # ← Delete this section
    
    dataDirs:
      - name: data
        type: "persistentVolumeClaim"
        size: "150Gi"  # ← Can increase from 100Gi if desired
        storageClass: "local-path"
        maxVolumes: 150

  unraid:
    enabled: true
    replicas: 1  # ← No change
    dataCenter: "dc1"
    rack: "unraid"
    
    affinity: ""
    
    resources:
      requests:
        cpu: 250m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
    
    # Pin to w2 only
    nodeSelector: |
      kubernetes.io/hostname: k3s-w2
      sw-volume: "true"
    
    dataDirs:
      - name: data
        type: "persistentVolumeClaim"
        size: "100Gi"
        storageClass: "local-path"
        maxVolumes: 100
```

#### Step 2: Commit and Deploy

```bash
cd /Users/Chris/Source/GitOps

git add clusters/homelab/infrastructure/seaweedfs/helmrelease.yaml
git commit -m "Simplify SeaweedFS: Remove w3 volume server, keep w1+w2 only"
git push

# Flux reconciles
flux reconcile kustomization infrastructure-seaweedfs -n flux-system
```

#### Step 3: Verify Volume Server Removal

```bash
# Should see seaweedfs-volume-proxmox-1 (w3) terminating
kubectl get pods -n seaweedfs -o wide -w

# Final state: Only 2 volume servers
# seaweedfs-volume-proxmox-0 on w1
# seaweedfs-volume-unraid-0 on w2
```

#### Step 4: Verify Data Still Accessible

```bash
# Check for Sonarr data on w2
kubectl exec -n seaweedfs seaweedfs-volume-unraid-0 -- \
  ls -lh /data/ | grep pvc-06fe669d

# Should still show replicated Sonarr database files
```

#### Step 5: Clean Up w3 Node Label (Optional)

```bash
# Remove sw-volume label from w3 (documentation purposes)
kubectl label node k3s-w3 sw-volume-

# Keep gpu=true label and taint for ClusterPlex
```

---

## Part 3: Testing & Validation

### Test 1: StatefulSet PVC Persistence

```bash
# Delete Sonarr pod, verify PVC preserved
kubectl delete pod -n media sonarr-0

# Wait for pod recreation
kubectl get pods -n media -l app=sonarr -w

# PVC should stay: config-sonarr-0
kubectl get pvc -n media config-sonarr-0

# Pod should mount same PVC, config restored
# Access Sonarr UI, verify series still there
```

### Test 2: Node Failover (w1 → w2)

**Prerequisite: w1 is back online after previous tests**

```bash
# Drain w1
kubectl drain k3s-w1 --ignore-daemonsets --delete-emptydir-data

# Watch Sonarr pod
kubectl get pods -n media -o wide -w

# Should see:
# 1. sonarr-0 on w1 Terminating
# 2. Fencing controller force-deletes VolumeAttachment (after 30s)
# 3. Fencing controller force-deletes pod (after 30s)
# 4. sonarr-0 recreated on w2 (Pending → Running)
# 5. PVC config-sonarr-0 mounts successfully
# 6. Sonarr accessible with data intact

# Verify PVC bound
kubectl get pvc -n media config-sonarr-0 -o wide

# Should show: Bound, RWO, seaweedfs-storage
```

### Test 3: Failback (w2 → w1)

```bash
# Uncordon w1
kubectl uncordon k3s-w1

# Wait for descheduler (runs every 2 minutes)
# Or manually trigger
kubectl delete pod -n kube-system -l app=descheduler

# Watch Sonarr pod move back to w1
kubectl get pods -n media -o wide -w

# Should see:
# 1. sonarr-0 on w2 Terminating
# 2. sonarr-0 recreated on w1
# 3. PVC mounts successfully on w1
# 4. Sonarr accessible with data intact
```

### Test 4: SeaweedFS Replication

```bash
# Access SeaweedFS shell
kubectl exec -it -n seaweedfs seaweedfs-master-0 -- /bin/sh
weed shell

# Check cluster topology
> cluster.status

# Should show:
# - 2 volume servers (w1, w2)
# - Both in different racks (proxmox, unraid)

# Check volume list
> volume.list

# Should show:
# - Volumes distributed across w1 and w2
# - Replication type: 010 (2 copies)

# Exit
> exit
exit
```

### Test 5: Write Performance

```bash
# Create test PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-write-performance
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: seaweedfs-storage
  resources:
    requests:
      storage: 1Gi
EOF

# Mount in test pod and write data
kubectl run test-writer --rm -it --image=alpine \
  --overrides='{"spec":{"volumes":[{"name":"test","persistentVolumeClaim":{"claimName":"test-write-performance"}}],"containers":[{"name":"test","image":"alpine","volumeMounts":[{"mountPath":"/data","name":"test"}]}]}}' \
  -- sh -c "dd if=/dev/zero of=/data/test.dat bs=1M count=100 && sync"

# Should complete without errors
# Performance should be acceptable (10-50 MB/s typical for NAS-backed storage)

# Cleanup
kubectl delete pvc test-write-performance
```

---

## Rollback Procedures

### If StatefulSet Fails

```bash
# Revert to Deployment
cd /Users/Chris/Source/GitOps
git revert HEAD  # Revert StatefulSet commit
git push

# Manually delete StatefulSet
kubectl delete sts -n media sonarr

# Delete StatefulSet PVC
kubectl delete pvc -n media config-sonarr-0

# Restore old PVC yaml
kubectl apply -f /tmp/pvc-sonarr-backup.yaml

# Flux will recreate Deployment
flux reconcile kustomization apps -n flux-system
```

### If SeaweedFS Change Fails

```bash
# Revert HelmRelease change
cd /Users/Chris/Source/GitOps
git revert HEAD  # Revert w3 removal commit
git push

# Flux recreates w3 volume server
flux reconcile kustomization infrastructure-seaweedfs -n flux-system

# Verify 3 volume servers return
kubectl get pods -n seaweedfs -l app.kubernetes.io/component=volume
```

---

## Success Criteria

- ✅ Sonarr running as StatefulSet with stable PVC
- ✅ Prowlarr running as StatefulSet with stable PVC
- ✅ Sonarr UI shows original configuration (series, indexers, etc.)
- ✅ Node failover (w1 → w2) completes automatically in <90 seconds
- ✅ Failback (w2 → w1) works via descheduler
- ✅ SeaweedFS has 2 volume servers (w1, w2)
- ✅ w3 has no volume server pod running
- ✅ Replication "010" still functional
- ✅ Data accessible after simulated failures

---

## Timeline

| Task | Duration | Dependencies |
|------|----------|--------------|
| Create StatefulSet manifests | 30 min | None |
| Deploy Sonarr StatefulSet | 15 min | Manifests ready |
| Restore Sonarr database | 15 min | StatefulSet deployed |
| Deploy Prowlarr StatefulSet | 15 min | Sonarr tested |
| Update SeaweedFS HelmRelease | 10 min | StatefulSets stable |
| Verify volume topology | 10 min | SeaweedFS updated |
| Run failover tests | 20 min | All deployed |
| Documentation | 15 min | Tests passed |
| **Total** | **~2 hours** | |

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Old database not restorable | Low | High | Old PV backed up, data replicated on w2 |
| StatefulSet misconfiguration | Low | Medium | Test on Sonarr first, rollback available |
| SeaweedFS data loss during w3 removal | Very Low | Critical | Data already replicated to w2, verify before removing |
| Fencing controller doesn't work with StatefulSet | Very Low | Medium | Fencing is PVC-agnostic, should work identically |
| Sonarr migrations fail on startup | Low | Medium | Copy old database, worst case: fresh install + restore |

---

## Post-Implementation

### Monitoring

Monitor these metrics after implementation:

```bash
# StatefulSet health
kubectl get sts -n media

# PVC status
kubectl get pvc -n media

# Failover time (from node NotReady to pod Running)
# Target: <90 seconds

# SeaweedFS volume distribution
kubectl exec -n seaweedfs seaweedfs-master-0 -- weed shell -c cluster.status
```

### Future Improvements

1. **Add Prometheus metrics** for failover time tracking
2. **Alerting** when pod stuck Pending > 2 minutes
3. **Automated testing** with Chaos Mesh (simulate node failures)
4. **Database backups** (Velero or custom cron job)

---

## Conclusion

This plan addresses the root cause of PVC data loss during failover (Deployment pattern) and simplifies the storage topology (remove unnecessary w3 volume server) while maintaining:

- ✅ HA failover across physical hosts (Proxmox ↔ Unraid)
- ✅ Automatic pod rescheduling (fencing controller)
- ✅ Automatic failback (descheduler)
- ✅ Sufficient storage capacity (250GB vs ~10GB used)
- ✅ Clear architecture (w3 = GPU only, w1+w2 = storage+compute)

**Recommendation:** Proceed with implementation during a maintenance window when w1 is back online.

---

**Author:** GitHub Copilot  
**Date:** February 14, 2026  
**Status:** Ready for Review & Implementation
