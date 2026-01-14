# Operations & Runbook

**Quick overview:** This document provides detailed operational procedures.

This guide covers operational tasks, monitoring, troubleshooting, and recovery procedures. It assumes familiarity with Kubernetes and Flux. Refer to [ARCHITECTURE.md](ARCHITECTURE.md) for system design details.

## Core Principles

1. **Git is Source of Truth** — All state changes go through Git commits
2. **Flux is Autopilot** — Changes in Git automatically deploy to cluster
3. **Immutable Infrastructure** — Prefer redeploying to manual fixes
4. **Observe First** — Check current state before making changes

## Storage & Synchronization

### NFS Media Library (`/data/media`)
**Purpose:** Shared read-only media library for media stack apps (Sonarr, Radarr, Plex, etc.)

**Health checks:**
```bash
# Verify NFS mounts on workers
kubectl debug node/k3s-w1 -it --image=ubuntu:22.04
  mount | grep /data/media
  ls -la /data/media/    # Should show media files

kubectl debug node/k3s-w2 -it --image=ubuntu:22.04
  mount | grep /data/media
  ls -la /data/media/
```

**If mount fails:**
```bash
# On Proxmox (for k3s-w1)
sudo mount -t nfs -o vers=3 <unraid-ip>:/mnt/user/media /mnt/media

# On k3s-w1 LXC: verify bind mount
cat /etc/pve/lxc/k3s-w1.conf | grep media
```

### Pod Storage Synchronization (`/data/pods`)
**Purpose:** Replicate application state between primary and backup nodes for HA stateful apps

**Managed by:** VolSync operator (in infrastructure-controllers)

**Check replication status (Example: Sonarr):**
```bash
# View ReplicationSource (primary) - replace 'sonarr-source' with your app name
kubectl get replicationsource -n media sonarr-source -o yaml

# View ReplicationDestination (backup) - replace 'sonarr-dest' with your app name
kubectl get replicationdestination -n media sonarr-dest -o yaml

# Check Syncthing pods managing the replication
kubectl get pods -n media | grep syncthing
kubectl logs -n media <syncthing-pod> --tail=50

# View PVC status in media namespace
kubectl get pvc -n media

# For other namespaces, replace 'media' with your namespace
kubectl get pvc -n <namespace>
```

**Check local directories:**
```bash
# On k3s-w1 (primary node)
ls -lh /data/pods/sonarr/
ls -lh /data/pods/<app-name>/    # Check other apps here

# On k3s-w2 (backup node)
ls -lh /data/pods/sonarr/
ls -lh /data/pods/<app-name>/
```

**If sync is stuck:**
```bash
# Restart Syncthing pods
kubectl delete pod -n media -l syncthing.io/role=source
kubectl delete pod -n media -l syncthing.io/role=destination

# Trigger Flux reconcile to rebuild
flux reconcile kustomization infrastructure-storage -n flux-system
```

## Monitoring & Health Checks

### Cluster Health
```bash
# Node status
kubectl get nodes -o wide
kubectl describe node k3s-w1
kubectl describe node k3s-w2

# Core pods
kubectl get pods -n flux-system
kubectl get pods -n kube-system
kubectl get pods -A | grep -v Running
```

### Flux Status
```bash
# Git source connection
flux get sources git -n flux-system

# All Kustomizations
flux get kustomizations -n flux-system

# Detailed kustomization status (shows path, interval, last revision)
flux get kustomization -n flux-system -A -o yaml

# Watch reconciliation events
flux events --all-namespaces --watch

# Kustomization events
flux events --for Kustomization/infrastructure-storage -n flux-system
```

### Application Status (Template)

For any application deployed in `apps/`, use this pattern:
```bash
# Replace <namespace> with your app's namespace (e.g., media, database)
# Replace <app-label> with your app's label selector (e.g., app=sonarr)
# Replace <service-name> with your service name

# Pod status
kubectl get pods -n <namespace>
kubectl describe pod -n <namespace> -l app=<app-label>
kubectl logs -n <namespace> -l app=<app-label> --tail=100

# Service and ingress
kubectl get svc -n <namespace>
kubectl get ingress -n <namespace>

# Port forward for testing (if needed)
kubectl port-forward -n <namespace> svc/<service-name> <local-port>:<container-port>
```

**Example (Sonarr):**
```bash
# Sonarr in media namespace
kubectl get pods -n media
kubectl describe pod -n media -l app=sonarr
kubectl logs -n media -l app=sonarr --tail=100

# Service and ingress
kubectl get svc -n media
kubectl get ingress -n media

# Port forward to test (runs on port 8989 internally)
kubectl port-forward -n media svc/sonarr 8989:80
# Then: curl http://localhost:8989/ping
```

## Troubleshooting

### Flux Not Reconciling

**Symptoms:** Changes in Git not applying to cluster

**Diagnosis:**
```bash
# Check git source status
flux get sources git -n flux-system -v

# Check kustomization status
flux get kustomizations -n flux-system -v

# View kustomization controller logs
kubectl logs -n flux-system -l app=kustomize-controller -f
```

**Fix:**
```bash
# Force reconciliation
flux reconcile kustomization apps -n flux-system --with-source

# Check for syntax errors in manifests
flux build kustomization apps --source GitRepository/flux-system -n flux-system
```

### PVC Not Binding

**Symptoms:** PVC stuck in Pending state

**Diagnosis:**
```bash
# Check PVC status
kubectl describe pvc -n <namespace> <pvc-name>

# Check PV status
kubectl get pv -o wide
kubectl describe pv <pv-name>

# Check node labels
kubectl get nodes --show-labels
```

**Fix:**
- Ensure PV and PVC have matching capacity
- Verify node labels match nodeAffinity selectors
- Check that storage paths exist on nodes

### Application Pod Not Starting

**Symptoms:** Pod stuck in Pending or CrashLoopBackOff

**Diagnosis:**
```bash
# Get pod details
kubectl describe pod -n <namespace> <pod-name>

# Check logs
kubectl logs -n <namespace> <pod-name> --previous  # If it crashed

# Check events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

**Common causes:**
- PVC not binding (see above)
- Resource limits too low
- Image pull errors
- Config/secret missing

### VolSync Replication Not Syncing

**Symptoms:** ReplicationSource/Destination show errors

**Diagnosis:**
```bash
# Check ReplicationSource
kubectl get replicationsource -n <namespace> -o yaml

# Check ReplicationDestination
kubectl get replicationdestination -n <namespace> -o yaml

# Check Syncthing pod logs
kubectl logs -n <namespace> -l syncthing.io/role=source --tail=100
kubectl logs -n <namespace> -l syncthing.io/role=destination --tail=100

# Check disk space on nodes
kubectl debug node/k3s-w1 -it --image=ubuntu:22.04
  df -h /data/pods/
```

**Common fixes:**
- Restart Syncthing pods: `kubectl delete pod -n <namespace> -l syncthing.io/role=source`
- Check node disk space
- Verify network connectivity between nodes
- Trigger full resync (see ReplicationSource/Destination CRs for options)

### MetalLB Controller Not Starting / CrashLoopBackOff

**Symptoms:** MetalLB controller pod restarts repeatedly with cert-rotation errors in logs

**Root cause:** MetalLB controller requires a TLS secret (`webhook-server-cert`) in the `metallb-system` namespace, even when running in L2 mode (no webhooks active). This secret is **not auto-created** by MetalLB and must be manually bootstrap during initial cluster setup.

**Diagnosis:**
```bash
# Check controller pod logs
kubectl logs -n metallb-system -l app=metallb,component=controller --tail=100

# Look for cert-rotation errors like:
# "error": "secret \"webhook-server-cert\" not found"

# Verify secret exists
kubectl get secret -n metallb-system webhook-server-cert
# If secret doesn't exist, the pod will keep restarting
```

**Fix (Bootstrap for New Clusters):**

Create a self-signed TLS certificate and secret:

```bash
# Generate self-signed cert (valid for 10 years)
openssl req -x509 -newkey rsa:4096 -keyout tls.key -out tls.crt -days 3650 -nodes \
  -subj "/CN=webhook.metallb-system.svc.cluster.local"

# Create secret in metallb-system namespace
kubectl create secret tls webhook-server-cert -n metallb-system \
  --cert=tls.crt --key=tls.key

# Verify
kubectl get secret -n metallb-system webhook-server-cert

# Clean up local files
rm tls.key tls.crt
```

**Why this is needed:** The MetalLB controller includes webhook cert-rotation logic in its startup sequence. Even in L2 mode (where webhooks are not active), the controller attempts to manage this secret. If missing, the controller crashes. This is undocumented behavior in MetalLB and should be done during cluster bootstrap, before FluxCD deploys MetalLB.

**Note:** Do not store this secret in Git. It's cluster-specific and should be created manually during bootstrap. If deploying to a new cluster, repeat the above steps.

## Common Tasks

### Adding a New Application

1. Create app folder structure:
   ```bash
   mkdir -p apps/<category>/<app-name>
   ```

2. Create manifests (deployment, service, etc.)

3. If stateful with HA requirements:
   - Create PVs in `infrastructure/storage/<app>.yaml`
   - Create PVCs in `apps/<category>/<app>/pvc.yaml`
   - Create ReplicationSource/Destination CRs if VolSync needed

4. Create `kustomization.yaml`:
   ```yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - deployment.yaml
     - service.yaml
     # ... other resources
   ```

5. Update `apps/kustomization.yaml` to include new category

6. Create Flux Kustomization in `cluster/<category>-kustomization.yaml` if needed

7. Commit to Git, Flux reconciles automatically

### Scaling an Application

```bash
# Scale deployment directly (temporary, not persisted in Git)
kubectl scale deployment -n <namespace> <app-name> --replicas=<count>

# For permanent scaling, edit deployment in Git:
# - Update `replicas:` field in apps/<category>/<app>/deployment.yaml
# - Commit and push
# - Flux reconciles automatically
```

### Updating an Application

```bash
# Update image tag in apps/<category>/<app>/deployment.yaml
# Example:
#   spec:
#     containers:
#     - name: app
#       image: sonarr:4.0.0.123  # Change version here

# Commit and push to Git
git add apps/<category>/<app>/deployment.yaml
git commit -m "Update <app> to version X.Y.Z"
git push

# Flux detects change and rolls out update automatically
# Monitor the rollout:
kubectl rollout status deployment -n <namespace> <app-name> -w
```

### Manual Failover (Emergency)

**Note:** Only do this if primary node is completely down and won't recover

```bash
# 1. Verify backup node is healthy
kubectl get nodes -o wide

# 2. Update deployment to use backup PVC and run on backup node
# Edit apps/<category>/<app>/deployment.yaml:
#   - Change PVC from pvc-<app> to pvc-<app>-backup
#   - Change nodeAffinity to target backup node

# 3. Commit to Git
git add apps/<category>/<app>/deployment.yaml
git commit -m "Manual failover: <app> to backup node"
git push

# 4. Monitor recovery
kubectl rollout status deployment -n <namespace> <app-name> -w

# 5. Once primary recovers:
# - Let VolSync catch up (monitor ReplicationSource status)
# - Change deployment back to primary PVC and node
# - Commit and push
# - Flux rolls out the failback
```

## Security Notes

- Never store secrets, SSH keys, or tokens in repo docs. Flux uses referenced secrets for repo access; do not include their contents in documentation.
- Always use RBAC to scope permissions (see `infrastructure/controllers/` for examples)
- Verify all Ingress resources have proper authentication (not exposed here)
- Use sealed-secrets or external-secrets for sensitive data (future enhancement)

## Disaster Recovery

### Full Cluster Recovery from Git

If the cluster is destroyed, recreate from Git:

```bash
# 1. Bootstrap Flux (assuming k3s is already running)
flux bootstrap github \
  --owner=<github-user> \
  --repo=GitOps \
  --branch=main \
  --path=clusters/homelab

# 2. Flux automatically reconciles all infrastructure and apps

# 3. Verify recovery
kubectl get pods -A
flux get kustomizations -n flux-system
```

### Recovering from Accidental Deletion

If someone accidentally deletes a resource:

```bash
# 1. Recover from Git history
git log --oneline -- apps/<category>/<app>/

# 2. Checkout deleted file
git checkout <commit-hash> -- apps/<category>/<app>/<file>

# 3. Commit and push
git commit -m "Restore deleted <file>"
git push

# 4. Flux reconciles and restores resource
flux reconcile kustomization apps -n flux-system --with-source
```

## Performance & Resource Limits

Monitor resource usage:
```bash
# Pod CPU/Memory usage
kubectl top pods -n <namespace>

# Node resource usage
kubectl top nodes

# Describe node for resource allocations
kubectl describe node <node-name>
```

If resource limits need tuning:
1. Edit deployment in `apps/<category>/<app>/deployment.yaml`
2. Adjust `resources.requests` and `resources.limits`
3. Commit to Git
4. Flux reconciles

## References

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Flux Documentation](https://fluxcd.io/docs/)
- [Kustomize Documentation](https://kustomize.io/)
- [VolSync Documentation](https://volsync.readthedocs.io/)
