# SeaweedFS Configuration Clarification & Fixes

**Date:** January 17, 2026  
**Status:** Configuration validated and ready for deployment

---

## Issue 1: The `/buckets` Path in StorageClass

### What is `/buckets`?

`/buckets` is **NOT where applications store data directly**. It is the **base directory in the SeaweedFS Filer's namespace** where PVC mount points are created.

**Flow:**
1. Application creates PVC: `pvc-sonarr` with StorageClass `seaweedfs`
2. CSI driver tells Filer to create directory: `/buckets/pvc-sonarr/`
3. Filer registers this with SeaweedFS volume servers
4. CSI driver FUSE-mounts `/buckets/pvc-sonarr/` into the pod at the requested mountPath
5. App sees a normal filesystem but I/O goes through Filer → distributed storage

**In practice:** Your Sonarr pod with `mountPath: /config` actually mounts Filer's `/buckets/pvc-sonarr/` there.

### Why `/buckets`?

The Filer uses `/buckets` as a convention for auto-creating object storage buckets. When `WEED_FILER_BUCKETS_FOLDER: /buckets` is set (default in chart), PVCs automatically become S3-accessible buckets.

---

## Issue 2: Duplication - values.yaml vs ConfigMap

### Problem
We had two copies of nearly identical configuration:
- `clusters/homelab/infrastructure/seaweedfs/values.yaml` - Git source
- `clusters/homelab/cluster/infrastructure-seaweedfs-values-configmap.yaml` - Flux namespace

This violates the GitOps single-source-of-truth principle.

### Solution
**Kept both but clarified their purpose:**

1. **`clusters/homelab/infrastructure/seaweedfs/values.yaml`** - **True source of truth**
   - Lives in Git alongside other infrastructure configs
   - Used for reference and documentation
   - Can be deployed standalone: `helm install -f values.yaml`

2. **`clusters/homelab/cluster/infrastructure-seaweedfs-values-configmap.yaml`** - **ConfigMap for Flux**
   - Flux reads HelmRelease values from ConfigMaps in `flux-system` namespace
   - This ConfigMap is generated from values.yaml (kept in sync manually)
   - **Better practice:** Could automate this with Kustomize `configMapGenerator`, but would require restructuring

**Why keep the duplication:**
- Flux architecture requires values to be in ConfigMaps/Secrets in the Flux namespace
- Separation of concerns: `infrastructure/` is platform setup, `cluster/` is Flux orchestration
- This is a known GitOps pattern trade-off

**Future improvement:** Use `configMapGenerator` in Kustomization to auto-generate ConfigMap from values.yaml.

---

## Issue 3: Version Pinning for SeaweedFS Helm Chart

### Change
Updated `infrastructure-seaweedfs-helmrelease.yaml`:

**Before:**
```yaml
chart:
  spec:
    chart: seaweedfs
    version: "*"  # Use latest - risk of breaking changes!
```

**After:**
```yaml
chart:
  spec:
    chart: seaweedfs
    version: ">=3.0.0 <4.0.0"  # Allows patch updates, prevents major breaks
```

### Rationale
- Seaweedfs follows semantic versioning
- v3.x is stable for Kubernetes deployments
- `>=3.0.0 <4.0.0` allows security patches/bug fixes but prevents breaking v4 release
- Flux will automatically pull latest patch version (e.g., 3.75.1 → 3.76.0)
- To lock specific version, use: `version: "3.75.1"`

### How to check latest:
```bash
helm repo update seaweedfs
helm search repo seaweedfs/seaweedfs --versions | head -10
```

---

## Issue 4: Affinity Configuration Alignment with Helm Chart

### Problem
Previous affinity configuration used Helm template variables that don't work in ConfigMaps:

```yaml
# WRONG - templates don't render in ConfigMaps:
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: {{ template "seaweedfs.name" . }}  # ❌ Not rendered!
```

### Solution

**Use chart defaults by setting affinity to empty string:**

```yaml
# CORRECT - use chart's built-in pod anti-affinity:
master:
  affinity: ""      # ← Empty = use chart defaults

volume:
  affinity: ""      # ← Empty = use chart defaults

filer:
  affinity: ""      # ← Empty = use chart defaults
```

### How the chart handles affinity:

When `affinity: ""` (empty/blank), the SeaweedFS Helm chart applies **its own default pod anti-affinity rules**:

```yaml
# Chart defaults (when you don't override):
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          app.kubernetes.io/name: seaweedfs
          app.kubernetes.io/instance: <release-name>
          app.kubernetes.io/component: <master|volume|filer>
      topologyKey: kubernetes.io/hostname
```

This ensures:
- Multiple masters spread across different nodes
- Multiple volume servers spread across different nodes
- Multiple filers spread across different nodes

### NodeSelector is still needed:

For **volume servers**, we explicitly set `nodeSelector` to constrain to nodes with `sw-volume: true`:

```yaml
volume:
  nodeSelector: |
    sw-volume: "true"  # ← Only volume servers run on these nodes
  affinity: ""         # ← But spread across them via anti-affinity
```

This combination:
- ✅ Constrains volume servers to k3s-w1 and k3s-w2 (nodeSelector)
- ✅ Spreads them across different nodes if replicas > 1 (affinity)
- ✅ Respects rack labels for `010` replication (master handles)

---

## Updated File Structure

```
clusters/homelab/
├── infrastructure/seaweedfs/
│   ├── namespace.yaml              # SeaweedFS namespace
│   ├── rbac.yaml                   # ServiceAccounts, ClusterRoles
│   ├── storageclass.yaml           # StorageClass with replication: 010
│   ├── values.yaml                 # ⭐ SOURCE OF TRUTH for config
│   └── kustomization.yaml          # Ties above resources together
│
└── cluster/
    ├── infrastructure-seaweedfs-helmrepository.yaml
    ├── infrastructure-seaweedfs-helmrelease.yaml  # Pinned to v3.x
    ├── infrastructure-seaweedfs-values-configmap.yaml  # Mirror of values.yaml for Flux
    └── infrastructure-seaweedfs-kustomization.yaml    # Flux Kustomization CR
```

---

## Validation Checklist

- ✅ All YAML syntax valid
- ✅ All Kustomize builds succeed
- ✅ No unresolved placeholders
- ✅ Namespace and RBAC configured
- ✅ StorageClass with correct replication parameters
- ✅ HelmRelease version pinned to v3 series
- ✅ Values properly structured for Helm chart
- ✅ Affinity uses chart defaults (empty string)
- ✅ Volume servers constrained to sw-volume=true nodes

---

## Next Steps

1. **Commit these changes to Git:**
   ```bash
   git add -A
   git commit -m "Fix SeaweedFS Helm values: pin version, remove template variables, clarify affinity"
   git push
   ```

2. **Flux will automatically deploy SeaweedFS within 1 minute**

3. **Verify deployment:**
   ```bash
   kubectl get pods -n seaweedfs -w
   kubectl get storageclasses | grep seaweedfs
   ```

4. **Test with dummy PVC:**
   ```bash
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: test-seaweedfs
     namespace: default
   spec:
     accessModes:
       - ReadWriteMany
     resources:
       requests:
         storage: 1Gi
     storageClassName: seaweedfs
   EOF
   
   # Wait for PVC to be Bound
   kubectl get pvc test-seaweedfs -w
   ```

---

**Author:** GitHub Copilot  
**Validated:** ✓ Passes ./scripts/validate/validate
