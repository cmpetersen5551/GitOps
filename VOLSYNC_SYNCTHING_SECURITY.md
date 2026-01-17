# VolSync Syncthing Mover: Security Configuration and Linux Capabilities

## Overview

VolSync's Syncthing mover runs as a containerized data mover pod in Kubernetes. The security configuration is critical for handling file ownership, permissions, and capabilities in restricted environments.

---

## 1. Linux Capabilities Requirements

### Syncthing Mover Security Context (Unprivileged - Default)

By default, Syncthing runs **unprivileged** with **ALL capabilities dropped**:

```go
SecurityContext: &corev1.SecurityContext{
    AllowPrivilegeEscalation: ptr.To(false),
    Capabilities: &corev1.Capabilities{
        Drop: []corev1.Capability{"ALL"},
    },
    Privileged:             ptr.To(false),
    ReadOnlyRootFilesystem: ptr.To(true),
}
```

### Syncthing Mover Security Context (Privileged - Optional)

When **privileged** mode is enabled (via namespace annotation), Syncthing adds three critical capabilities:

```go
podSpec.Containers[0].SecurityContext.Capabilities.Add = []corev1.Capability{
    "DAC_OVERRIDE", // Read/write all files regardless of permissions
    "CHOWN",        // Change file ownership (chown system call)
    "FOWNER",       // Set permission bits and modification times without ownership
}
```

**Note:** For Syncthing specifically (not rsync-tls), there is no explicit `RunAsUser = 0` requirement when privileged mode is used.

---

## 2. Capability Details

### DAC_OVERRIDE
- **Purpose:** Bypass Discretionary Access Control (DAC) checks
- **Use Case:** Read/write files regardless of file permissions
- **Required When:** Files have restrictive permissions that don't match the container's UID/GID
- **Kernel Level:** Allows bypassing uid/gid checks

### CHOWN
- **Purpose:** Change file ownership (UID/GID)
- **System Call:** `chown()`, `fchown()`, `fchownat()`
- **Use Case:** Preserve original file ownership during sync operations
- **Required When:** Syncing to ReadWriteMany (RWX) PVCs where ownership must be preserved
- **Limitation:** Without this capability, files are always owned by the running UID

### FOWNER
- **Purpose:** Set permission bits and times on files without owning them
- **System Calls:** `chmod()`, `utimes()`, `futimens()`
- **Use Case:** Restore original file permissions and timestamps
- **Required When:** File metadata (permissions, access times) must be preserved exactly
- **Limitation:** Without this, Syncthing cannot set file permissions other than what the current UID allows

---

## 3. ReplicationSource Configuration for Syncthing

### Basic Unprivileged Configuration (Default)

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: my-app-data
  namespace: my-namespace
spec:
  sourcePVC: data-pvc
  syncthing:
    peers:
      - id: remote-syncthing-id
        address: "tcp://remote-host:22000"
```

**Default Behavior:**
- Runs without elevated capabilities
- All capabilities dropped
- Non-privileged security context
- Cannot change file ownership
- Cannot set arbitrary permissions
- Best effort to preserve data

### Privileged Configuration (With Capabilities)

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: my-app-data
  namespace: my-namespace
  # Namespace must have the annotation below
spec:
  sourcePVC: data-pvc
  syncthing:
    peers:
      - id: remote-syncthing-id
        address: "tcp://remote-host:22000"
    # Optional: Override security context
    moverSecurityContext:
      runAsUser: 1000
      fsGroup: 1000
```

### Enabling Privileged Movers at Namespace Level

```bash
# Annotate namespace to allow privileged movers
kubectl annotate namespace my-namespace \
  volsync.backube/privileged-movers=true
```

**YAML equivalent:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-namespace
  annotations:
    volsync.backube/privileged-movers: "true"
```

---

## 4. Custom Security Context Configuration

The `moverSecurityContext` field allows you to customize the pod security context:

```yaml
spec:
  syncthing:
    moverSecurityContext:
      runAsUser: 65534        # nobody user
      runAsGroup: 65534       # nogroup
      fsGroup: 65534          # Set fsGroup for volume ownership
      runAsNonRoot: true      # Enforce non-root
```

**Key Points:**
- Pod-level security context affects all containers
- If matched to your primary workload's context, file permissions work consistently
- Without matching UIDs, permission issues may occur during sync
- FSGroup enables automatic volume permission handling

---

## 5. Known Issues & Solutions

### Issue #1: Permission Denied Errors When Syncing

**Symptoms:**
```
Permission denied while opening file
Failed to set file ownership
Could not create file: permission denied
```

**Root Causes:**
1. **Source UID/GID mismatch:** Files owned by user A, but Syncthing runs as user B
2. **Missing CHOWN capability:** Cannot change ownership to user B
3. **Missing DAC_OVERRIDE:** Cannot write to files owned by other users
4. **Missing FOWNER:** Cannot set permission bits without owning the file

**Solutions:**

**Option 1: Use Privileged Movers**
```bash
kubectl annotate namespace your-ns volsync.backube/privileged-movers=true
```

**Option 2: Match Security Context to Source Workload**
```yaml
# Check source workload's securityContext
kubectl get deployment my-app -o yaml | grep -A 5 securityContext:

# Apply same context to mover
spec:
  syncthing:
    moverSecurityContext:
      runAsUser: 1000        # Match your app's UID
      fsGroup: 1000          # Match your app's GID
```

**Option 3: Pre-emptively Fix Ownership**
```bash
# Before starting replication
kubectl exec -it pod-name -- chown -R 1000:1000 /data
```

### Issue #2: VolSync Pod Won't Start (OOMKilled)

**Cause:** Syncthing uses significant memory during sync

**Solution:**
```yaml
spec:
  syncthing:
    moverResources:
      limits:
        memory: "2Gi"
      requests:
        memory: "512Mi"
```

### Issue #3: Syncthing Mover Running as UID 0 Without Privileges

**Symptoms:**
- Pod runs as UID 0 (root)
- No capabilities granted
- Cannot read/write files

**Context:** This occurs on distributions (like K3s) that don't auto-assign non-root UIDs when Pod Security Standards aren't enforced.

**Solution:** Explicitly provide moverSecurityContext OR enable privileged movers:
```yaml
spec:
  syncthing:
    moverSecurityContext:
      runAsUser: 1000
      runAsNonRoot: true
```

---

## 6. Best Practices for Running Syncthing in Restricted Containers

### 1. **Default to Unprivileged**
- Start without elevated capabilities
- Syncthing can sync data without special privileges in most cases
- Reduces security surface area

### 2. **Match Security Context to Workload**
```yaml
# Get your workload's context
kubectl get pod/my-app -o jsonpath='{.spec.securityContext}'

# Apply to mover
spec:
  syncthing:
    moverSecurityContext:
      runAsUser: <workload-uid>
      fsGroup: <workload-gid>
```

### 3. **Use Privileged Only When Necessary**
Enable privileged movers ONLY when:
- Files have varying ownerships that must be preserved
- RWX volumes need exact permission preservation
- Special metadata (xattrs, ACLs) must be restored

### 4. **Test Permission Preservation Requirements**
Before configuring, verify what actually needs to be preserved:
```bash
# List file ownership in source
find /data -ls | head -20

# Check if files have special permissions
stat /data/file.txt

# Test UID/GID requirements
ls -n /data
```

### 5. **Monitor Mover Pod Logs**
```bash
# Watch mover logs for permission errors
kubectl logs -f deployment/volsync-syncthing-src-<name> -c syncthing

# Look for warnings like:
# "Permission denied"
# "Operation not permitted"
# "Cannot set owner"
```

### 6. **Use ReadOnlyRootFilesystem**
All movers should run with read-only root filesystem:
```yaml
securityContext:
  readOnlyRootFilesystem: true
```
This is automatically configured by VolSync.

### 7. **Drop All Capabilities by Default**
```yaml
securityContext:
  capabilities:
    drop: ["ALL"]  # Syncthing handles this automatically
```

---

## 7. Implementation Recommendations

### Scenario A: Dev/Test Environment (No Special Permissions)
**Configuration:**
- No namespace annotation
- Default unprivileged security
- No custom moverSecurityContext

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: app-data-sync
  namespace: default
spec:
  sourcePVC: app-data
  syncthing:
    peers:
      - id: remote-device-id
        address: "tcp://remote.example.com:22000"
```

### Scenario B: Production with Ownership Preservation
**Configuration:**
- Enable privileged movers (after namespace admin approval)
- Explicitly set moverSecurityContext
- Set appropriate resource limits

```yaml
# First: Annotate namespace
kubectl annotate namespace prod volsync.backube/privileged-movers=true

# Then: Configure replication
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: prod-data-sync
  namespace: prod
spec:
  sourcePVC: production-data
  syncthing:
    peers:
      - id: remote-prod-device
        address: "tcp://remote-prod.example.com:22000"
    moverSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
      fsGroupChangePolicy: "OnRootMismatch"
    moverResources:
      limits:
        memory: "2Gi"
      requests:
        memory: "512Mi"
```

### Scenario C: Kubernetes Native (Matching Workload Context)
**Configuration:**
- Extract actual workload UID/GID
- Apply to mover
- No privileged mode required

```bash
# Get workload context
kubectl get deployment myapp -o jsonpath='{.spec.template.spec.securityContext}'

# Extract values (e.g., uid: 65534, gid: 65534)
```

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: myapp-sync
  namespace: apps
spec:
  sourcePVC: myapp-data
  syncthing:
    peers:
      - id: backup-system-id
        address: "tcp://backup.local:22000"
    moverSecurityContext:
      runAsUser: 65534        # Match workload
      runAsGroup: 65534
      fsGroup: 65534
      fsGroupChangePolicy: "OnRootMismatch"
```

---

## 8. Troubleshooting Checklist

- [ ] **Check namespace annotation:** `kubectl get ns -o yaml | grep privileged-movers`
- [ ] **Verify mover pod is running:** `kubectl get pods | grep volsync-syncthing`
- [ ] **Check mover logs for errors:** `kubectl logs <mover-pod> -c syncthing`
- [ ] **Verify source file permissions:** `ls -la /data`
- [ ] **Check container security context:** `kubectl get pod <pod> -o jsonpath='{.spec.securityContext}'`
- [ ] **Confirm Syncthing is reachable:** Test peer connectivity
- [ ] **Monitor resource usage:** `kubectl top pod <mover-pod>`
- [ ] **Check ReplicationSource status:** `kubectl get replicationsource -o wide`
- [ ] **Verify volume mounts:** `kubectl describe pod <mover-pod>`
- [ ] **Test with unprivileged first:** Always start without capabilities

---

## 9. Key VolSync Mover Behaviors

### Unprivileged Mode (Default)
- All capabilities dropped
- Container security: `securityContext.capabilities.drop = ["ALL"]`
- No privilege escalation allowed
- Files created/modified as container's UID/GID
- Cannot change existing file ownership
- Cannot set arbitrary permissions

### Privileged Mode (With Annotation)
- Adds: CHOWN, FOWNER, DAC_OVERRIDE
- Container runs with specific UID (configurable)
- Can modify ownership and permissions
- Can write to restricted files
- Higher security surface - use only when necessary

### Security Context Field (`moverSecurityContext`)
- **Pod-level control** of UID/GID
- Applied at `.spec.<mover>.moverSecurityContext`
- Affects all containers in mover pod
- Propagates to volumes via fsGroup

---

## 10. External Resources

- **VolSync Permission Model Documentation:** https://volsync.backube/documentation/
- **Kubernetes Security Context:** https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
- **Linux Capabilities Man Pages:** `man 7 capabilities`
- **VolSync GitHub Repository:** https://github.com/backube/volsync

---

## Summary

**Key Takeaways:**

1. **Default is safe:** Syncthing runs unprivileged by default with all capabilities dropped
2. **Capabilities matter:** CHOWN, FOWNER, and DAC_OVERRIDE are critical for permission preservation
3. **Control at two levels:** 
   - Pod-level: `moverSecurityContext` sets UID/GID
   - Namespace-level: `volsync.backube/privileged-movers` annotation enables capabilities
4. **Match your workload:** Use the same security context as your primary application for best results
5. **Test first:** Start unprivileged and only enable privileges if file metadata preservation is required

