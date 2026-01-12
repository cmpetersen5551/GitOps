# Architecture & Design

**Quick overview:** This document provides detailed technical design.

This cluster implements a GitOps model using Flux v2 for declarative infrastructure management. All resources are defined in this Git repository and automatically reconciled to the cluster.

## Deployment Model: GitOps with Flux

**Flow:**
1. Changes committed to Git
2. Flux continuously watches the repository (1-minute interval)
3. Flux calculates desired state and applies manifests
4. If cluster diverges, Flux automatically corrects it

**Benefits:**
- Auditability: All changes tracked in Git
- Repeatability: Same manifests always produce same state
- Automation: No manual kubectl apply needed
- Recovery: Recreate cluster from Git history

## Reconciliation Hierarchy

Flux Kustomizations are ordered with explicit dependencies to ensure proper startup:

```
infrastructure-crds (Custom Resource Definitions)
    ↓
infrastructure-controllers (Operators like VolSync)
    ↓
infrastructure-storage (Persistent Volumes for failover)
    ↓
operations (Monitoring and failover automation)
    ↓
apps (Applications that use the above)
```

**Why this order?**
- CRDs must exist before CRs can be created
- Controllers must be running to manage resources
- Storage must exist before applications try to mount it
- Operational tooling waits for infrastructure
- Applications deploy last once everything is ready

## Directory Structure Rationale

### `cluster/` — Flux Orchestration Layer
Contains **Flux Kustomization CRs** (not actual workloads). These are instructions that tell Flux:
- What directory to watch
- What dependencies exist
- How often to reconcile
- Validation rules

**Why separate?** Keeps orchestration metadata distinct from actual resources, following Flux best practices.

### `infrastructure/` — Platform Components
System-level resources that applications depend on:
- **crds/** — VolSync Custom Resource Definitions
- **controllers/** — VolSync operator deployment
- **storage/** — Persistent Volumes (static, node-affinity based)

**Why?** These must deploy before applications can use them.

### `operations/` — Operational Tooling
Resources for monitoring and management:
- **volsync-failover/** — Monitoring pods and failover automation scripts

**Why separate?** Operational concerns are distinct from infrastructure and applications.

### `apps/` — User Applications
Actual workloads (e.g., Sonarr, Radarr, Plex, etc.) organized by category:
- Each app in its own folder (e.g., `media/sonarr/`, `media/radarr/`)
- Deployments, Services, Ingresses, PersistentVolumeClaims
- Each defines its own resource requirements and replicas

**Why here?** Clear separation between platform (infrastructure) and tenant workloads (apps).

### `flux-system/` — Bootstrap Bootstrap
Managed by Flux CLI, contains:
- Flux controller deployments
- Git repository configuration
- System bootstrap metadata

**Why read-only?** Flux manages its own bootstrap; manual edits can break reconciliation.

## Storage Architecture

### Problem Statement
Stateful applications (e.g., Sonarr, Radarr, etc.) need high availability:
- Need persistent storage for configuration and state
- Should failover between k3s-w1 (primary) and k3s-w2 (backup) if needed
- Data must be synchronized to minimize loss during failover

### Solution: VolSync + Static PVs

**Pattern for HA Stateful Apps:**

**Static PersistentVolumes** (in `infrastructure/storage/`):
- `pv-<app>-primary` — bound to k3s-w1 via nodeAffinity
- `pv-<app>-backup` — bound to k3s-w2 via nodeAffinity (optional)
- Both point to `/data/pods/<app>` (local directories on respective nodes)
- Example: `pv-sonarr-primary`, `pv-sonarr-backup`

**VolSync Replication** (managed by infrastructure-controllers):
- ReplicationSource on primary PVC
- ReplicationDestination on backup PVC
- Syncthing method for continuous sync
- Enables failover with minimal data loss
- Works for any app with persistent state

**PersistentVolumeClaims** (in `apps/<category>/<app>/`):
- `pvc-<app>` claims primary PV
- `pvc-<app>-backup` claims backup PV (optional)
- Applications mount these claims
- Example: `pvc-sonarr`, `pvc-sonarr-backup`
**Failover Automation** (in `operations/volsync-failover/`):
- Monitor pod watches primary node health
- Executes failover script if node becomes unready
- Updates deployment to use backup PVC
- Optionally syncs data back on recovery

## Dependency Resolution

Flux resolves dependencies at reconciliation time:

```yaml
# apps-kustomization.yaml
dependsOn:
  - infrastructure-storage    # Wait for PVs to exist
  - operations                # Wait for failover setup
```

This ensures:
1. PVs are created before PVCs are applied
2. PVCs can successfully bind to PVs
3. Applications don't start until storage is ready
4. Failover automation is in place

## Kustomize vs Flux Kustomization

**Kustomize** (lowercase k) — Kubernetes packaging tool
- Located in: `infrastructure/`, `operations/`, `apps/` directories
- Files: `kustomization.yaml`
- Purpose: Package and build manifests
- Example: `infrastructure/kustomization.yaml` includes `./crds`, `./controllers`, `./storage`

**Flux Kustomization** (capital K, CRD) — Flux resource
- Located in: `cluster/` directory
- Files: `*.yaml` (e.g., `infrastructure-crds.yaml`)
- Purpose: Tell Flux what to watch and reconcile
- Example: Points to `./clusters/homelab/infrastructure/crds/` with dependencies

**How they work together:**
Flux Kustomization → points to directory → runs `kustomize build` → applies resulting manifests

## Security Considerations

- **RBAC Scoping:** VolSync controller has minimal required permissions (not cluster-admin)
- **No Secrets in Git:** All sensitive data (SSH keys, API tokens) must be excluded
- **Immutable Bootstrap:** Flux bootstrap manifests should not be manually edited
- **GitOps Trust:** All state changes via Git commits, not manual kubectl

## References

- [Flux Documentation](https://fluxcd.io/docs/)
- [Kustomize Documentation](https://kustomize.io/)
- [VolSync Documentation](https://volsync.readthedocs.io/)
