# Copilot Instructions for GitOps Repository

## Repository Overview

This is a Flux v2-based GitOps repository managing a small Kubernetes cluster (k3s) on Proxmox and Unraid.

**Key Technologies:**
- **Flux v2** - GitOps orchestration
- **Kustomize** - Resource composition
- **VolSync** - PVC replication for HA
- **K3s** - Lightweight Kubernetes on Proxmox LXC + Unraid Docker

## Repository Structure

```
GitOps/
├── .github/
│   └── copilot-instructions.md  # This file
├── validate.sh                  # Pre-commit validation script
└── clusters/
    └── homelab/
        ├── docs/                # Documentation
        │   ├── README.md        # Quick start & repository overview
        │   ├── ARCHITECTURE.md  # System design & reconciliation flow
        │   ├── HARDWARE.md      # Node inventory & storage topology
        │   └── OPERATIONS.md    # Operational runbook & troubleshooting
        ├── kustomization.yaml   # Root kustomization (entrypoint)
        ├── cluster/             # Flux Kustomization CRs (orchestration)
        ├── infrastructure/      # Platform components (CRDs, controllers, storage)
        ├── operations/          # Operational tooling (monitoring, failover)
        ├── apps/                # User applications (organized by category)
        └── flux-system/         # Flux bootstrap (read-only)
```

## Critical Concepts

### 1. GitOps Model
- **Source of Truth:** Git repository
- **Reconciliation:** Flux continuously watches for changes (1-min interval)
- **Automation:** All state changes via Git commits, never manual `kubectl apply`
- **Recovery:** Entire cluster recreatable from Git

### 2. Reconciliation Hierarchy (Dependency Chain)
```
infrastructure-crds
  ↓ (CRDs must exist first)
infrastructure-controllers
  ↓ (Controllers manage CRs)
infrastructure-storage
  ↓ (PVs must exist before PVCs)
operations
  ↓ (Monitoring/failover setup)
apps
  ↓ (Apps use above resources)
```

**Why:** Ensures proper startup order and prevents resource binding failures.

### 3. HA Stateful Applications Pattern
All stateful apps follow this pattern:

**PersistentVolumes** (in `infrastructure/storage/`):
- `pv-<app>-primary` → k3s-w1 (labeled `role=primary`)
- `pv-<app>-backup` → k3s-w2 (labeled `role=backup`)

**VolSync Replication** (in `apps/<category>/<app>/`):
- ReplicationSource on primary PVC
- ReplicationDestination on backup PVC
- Syncthing method for continuous sync

**Failover:** If primary node fails, deployment can switch to backup PVC/node.

### 4. Kustomize vs Flux Kustomization
- **Kustomize** (lowercase k) - Tool for composing YAML. Used in: `infrastructure/`, `operations/`, `apps/`
- **Flux Kustomization** (uppercase K, CRD) - Flux resource telling Flux what to watch/reconcile. Used in: `cluster/`

### 5. Single Source of Truth
- **One representation per resource:** No duplicates across directories
- **Cross-directory references:** PVs defined once, PVCs reference them
- **Dependency management:** Flux `dependsOn` controls reconciliation order

## Before Committing Changes

**Run validation:**
```bash
./scripts/validate/validate
```

This checks:
- ✓ All Kustomize builds succeed
- ✓ Kubernetes resources are valid (dry-run)
- ✓ No unresolved placeholders
- ✓ YAML syntax valid

**Do not commit if validation fails.**

## Common Tasks

### Adding a New Application
1. Create folder: `clusters/homelab/apps/<category>/<app>/`
2. Add manifests: `deployment.yaml`, `service.yaml`, `kustomization.yaml`
3. If stateful with HA:
   - Add PVs to `clusters/homelab/infrastructure/storage/<app>.yaml`
   - Add PVCs to `clusters/homelab/apps/<category>/<app>/pvc.yaml`
   - Add VolSync CRs to `clusters/homelab/apps/<category>/<app>/volsync.yaml`
4. Update `clusters/homelab/apps/kustomization.yaml` to include new category
5. Create Flux Kustomization in `clusters/homelab/cluster/<category>-kustomization.yaml` if needed
6. Commit and push - Flux reconciles automatically

### Modifying Existing Resources
- Edit manifests in Git
- Commit and push
- Flux detects change and reconciles within 1 minute
- **Do not edit directly in cluster** (GitOps principle)

### Verifying Changes
```bash
# Check Flux reconciliation status
flux get kustomizations -n flux-system

# View events
flux events --all-namespaces --watch

# Preview what would be applied (if cluster access)
flux diff kustomization <name> --path=clusters/homelab/<path>
```

## Critical Rules

1. **No secrets in Git** - Use Flux secrets management for sensitive data
2. **No manual kubectl apply** - All changes via Git commits
3. **Validate before commit** - Run `./scripts/validate/validate` always
4. **Keep single source of truth** - Never duplicate resource definitions
5. **Respect dependency chains** - Don't break Flux `dependsOn` order
6. **Test in non-prod first** - Use dry-run validation before applying to cluster

## Documentation

- **clusters/homelab/docs/README.md** - Quick start & overview
- **clusters/homelab/docs/ARCHITECTURE.md** - System design, deployment model, storage architecture
- **clusters/homelab/docs/HARDWARE.md** - Node inventory, storage layout, HA patterns
- **clusters/homelab/docs/OPERATIONS.md** - Operational runbook, monitoring, troubleshooting, disaster recovery

## AI Agent Notes

This repository is structured for autonomous modification by AI agents:
- Validation script (`./scripts/validate/validate`) confirms changes are syntactically valid
- Dependency chains ensure proper reconciliation order
- Single source of truth prevents conflicts
- Clear folder structure and naming conventions

**Before making changes:**
1. Understand current structure (read this file + relevant docs)
2. Plan changes respecting dependency chains
3. Make changes to Git files
4. Run `./scripts/validate/validate` - must pass before proceeding
5. Commit only after validation passes

**Do not:**
- Make changes directly to cluster (manual kubectl)
- Create duplicate resource definitions
- Ignore validation failures
- Break dependency chains in `cluster/` directory
