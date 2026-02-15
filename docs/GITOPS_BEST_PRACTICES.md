# GitOps Best Practices & Architecture

This document captures patterns and lessons from repository analysis and SeaweedFS migration experience.

## Repository Structure (Exemplary)

Your repository demonstrates solid GitOps separation of concerns:

```
clusters/homelab/
├── flux-system/              # Flux bootstrapping (auto-generated)
├── apps/                     # Application manifests
│   ├── media/                  (Sonarr, Prowlarr, etc)
│   └── kustomization.yaml
├── infrastructure/           # Shared infrastructure
│   ├── longhorn/               (HA storage)
│   ├── metallb/                (BGP load balancer)
│   ├── traefik/                (reverse proxy)
│   └── kustomization.yaml
└── kustomization.yaml        # Root kustomization
```

**Why This Works**:
- Clear separation between workloads (apps/) and infrastructure (infrastructure/)
- Each component has its own kustomization.yaml
- Dependency chain allows infrastructure to reconcile before apps
- Easy to find and modify related pieces

## Dependency Management in Flux

**Pattern**: Use `dependsOn` to enforce reconciliation order:

```yaml
# clusters/homelab/cluster/apps-kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
metadata:
  name: apps
spec:
  # This ensures infrastructure deploys first
  dependsOn:
    - name: infrastructure
  path: ./apps
  sourceRef:
    kind: GitRepository
    name: flux-system
```

**Best Practice**: 
- infrastructure → apps (infrastructure must be ready before workloads)
- Use `timeout` to fail fast on issues: `timeout: 5m`
- Monitor with `flux get kustomizations` to see ready status

## Secrets Management (Not Yet Implemented)

**CRITICAL GAP**: If you need to add secrets (API keys, passwords), implement sops-age encryption:

```bash
# 1. Install age tool
brew install age

# 2. Generate key
age-keygen -o age.key

# 3. Store key securely (1Password, encrypted drive)

# 4. Create Kubernetes secret in flux-system
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=$PWD/age.key

# 5. Add .sops.yaml to repo root
```

```yaml
# .sops.yaml (controls what gets encrypted)
creation_rules:
  - path_regex: secrets.yaml$
    encrypted_regex: ^(data|stringData)$
    age: <your-age-public-key>
```

**Usage**:
```bash
# Encrypt before committing
sops --encrypt secrets.yaml

# Flux automatically decrypts when applying (with sops-age secret)
```

## Storage Architecture Decisions

### Problem: Choosing Between Solutions
When evaluating **SeaweedFS vs Longhorn**, key questions:
1. **Minimum Node Requirement**: SeaweedFS needs 3+, Longhorn works with 2
2. **Operational Complexity**: SeaweedFS has more tuning, Longhorn is Kubernetes-native
3. **Failover Behavior**: SeaweedFS requires quorum, Longhorn does zero-copy failover
4. **Recovery Procedure**: SeaweedFS needs volume reassignment, Longhorn auto-rebalances

**Decision Framework**:
```
If 2 nodes → Longhorn
If 3+ nodes → Choose based on ops complexity preference
If SPOF acceptable → NFS/local storage is fine
If high availability critical → Must have replication
```

### Anti-Pattern: Mixing Storage Solutions
❌ **Don't**: Use SeaweedFS for some PVCs and Longhorn for others  
✅ **Do**: Pick one primary storage, use secondary only for non-critical data

## Application Manifests (StatefulSet Pattern)

**Template** for HA-aware applications with Longhorn:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: myapp
  namespace: apps
spec:
  serviceName: myapp
  replicas: 1  # Or more if app supports clustering
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      # CRITICAL: Use required affinity for storage nodes
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node.longhorn.io/storage
                    operator: In
                    values: [enabled]
      
      # Tolerate storage node taints
      tolerations:
        - key: node.longhorn.io/storage
          operator: Equal
          value: enabled
          effect: NoSchedule
      
      containers:
        - name: myapp
          image: myimage:latest
          resources:
            requests:
              memory: "512Mi"
              cpu: "100m"
            limits:
              memory: "1Gi"
              cpu: "500m"
          volumeMounts:
            - name: config
              mountPath: /config
  
  volumeClaimTemplates:
    - metadata:
        name: config
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: longhorn-simple
        resources:
          requests:
            storage: 10Gi
```

**Key Points**:
- `serviceName` allows StatefulSet pods to have stable DNS
- `nodeAffinity: required` ensures pod only goes to storage nodes
- `tolerations` match node taints
- `storageClassName: longhorn-simple` uses HA-optimized StorageClass

## Monitoring & Observability (Recommendations)

These are **not yet implemented** but should be added for production:

1. **Longhorn Monitoring**
   ```bash
   # Install Prometheus ServiceMonitor
   kubectl apply -f longhorn-prometheus-serviceMonitor.yaml
   # Then scrape: longhorn-system:9500/metrics
   
   # Useful queries:
   # - longhorn_volume_actual_size_bytes
   # - longhorn_volume_state (1 = healthy, 0 = degraded)
   # - longhorn_replica_count (should be 2 per volume)
   ```

2. **Flux Status**
   ```bash
   # Monitor reconciliation
   flux get kustomizations --watch
   flux get sources git --watch
   
   # Alerts if ready=false
   ```

3. **Application Health**
   ```bash
   # Use kubectl top + Prometheus for resource usage
   kubectl top pods -n media
   ```

## Anti-Patterns to Avoid

### ❌ 1. Hardcoding Node Names
```yaml
# BAD: Pod will fail if node is down
nodeSelector:
  kubernetes.io/hostname: k3s-w1
```

**Good**: Use labels
```yaml
# GOOD: Pod finds any node with label
nodeSelector:
  node.longhorn.io/storage: enabled
```

### ❌ 2. Mixing Preferred and Required Affinity
```yaml
# BAD: Pod might schedule on wrong node
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:  # Soft constraint!
      - preference:
          matchExpressions:
            - key: node.longhorn.io/storage
```

**Good**: Use required for critical workloads
```yaml
# GOOD: Pod will NOT schedule if affinity can't be met
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:   # Hard constraint
```

### ❌ 3. No Requests/Limits
```yaml
# BAD: Pod can consume all node resources
containers:
  - image: myapp
    # No resources defined!
```

**Good**: Define requests and limits
```yaml
resources:
  requests:           # Scheduler needs this for bin-packing
    memory: "512Mi"
    cpu: "100m"
  limits:             # Pod evicted if exceeds
    memory: "1Gi"
    cpu: "500m"
```

### ❌ 4. Hardcoding Secrets in Manifests
```yaml
# BAD: Credentials in Git history!
env:
  - name: API_KEY
    value: "supersecret123"
```

**Good**: Use Kubernetes Secrets + sops encryption
```yaml
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: myapp-secrets
        key: api-key
```

### ❌ 5. Not Using Init Containers for Dependencies
```yaml
# BAD: App starts before database is ready
containers:
  - name: app
    image: myapp
    # Assumes mydb is ready immediately
```

**Good**: Use init containers to wait for dependencies
```yaml
initContainers:
  - name: wait-for-db
    image: busybox
    command: ['sh', '-c', 'until nc -z mydb 5432; do sleep 1; done']
spec:
  containers:
    - name: app
      image: myapp
      # Now guaranteed mydb is accessible
```

## Testing Changes Safely

### Before Committing
```bash
# 1. Validate manifests locally
kubectl apply -f clusters/homelab/apps/media/ --dry-run=client

# 2. Check for obvious issues
kustomize build clusters/homelab/ | kubeval

# 3. Test in dry-run mode against cluster
kubectl apply -k clusters/homelab/ --dry-run=server

# 4. Commit to feature branch
git checkout -b feature/mychange
git add .
git commit -m "Add feature X"

# 5. Monitor Flux reconciliation
flux get kustomizations -w

# 6. Check pod status
kubectl get pods -n media -w

# 7. If all good, merge to v2
git checkout v2
git merge feature/mychange
```

### Rollback Strategy
```bash
# If something breaks, quickly revert
git revert <commit-hash>
git push

# Flux will immediately start reconciling old state
flux get kustomizations    # Watch the rollback
```

## Learning from This Repository's History

This migration from SeaweedFS → Longhorn teaches:

1. **Do research before committing**: SeaweedFS failure was discovered after deep investigation. Could have been avoided with upfront research.
2. **Document assumptions**: Why was SeaweedFS chosen? What should have been validated?
3. **Test incrementally**: Don't make all changes at once. Sonarr migration was validated before Prowlarr.
4. **Keep decision logs**: Future changes benefit from understanding past reasoning.

---

## References

- **Flux Documentation**: https://fluxcd.io/docs/
- **k3s Docs**: https://docs.k3s.io/
- **Longhorn**: https://longhorn.io/docs/
- **Kubernetes Best Practices**: https://kubernetes.io/docs/concepts/configuration/overview/
- **kustomize Docs**: https://kustomize.io/

---

**Status**: Active  
**Last Updated**: 2026-02-15  
**Next Review**: After production HA testing cycle
