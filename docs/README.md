# GitOps Cluster Documentation

## Active Documentation

### 🚀 Getting Started
- **[LONGHORN_NODE_SETUP.md](./LONGHORN_NODE_SETUP.md)** - Node configuration requirements
  - Node labels and taints for storage
  - Verification commands
  - How Longhorn disk auto-creation works

### 📊 Architecture & Operations
- **[LONGHORN_HA_MIGRATION.md](./LONGHORN_HA_MIGRATION.md)** - Complete HA setup reference
  - 2-node HA architecture
  - Key learnings (Longhorn + GitOps patterns)
  - Failover behavior
  - Troubleshooting guide

- **[CLUSTER_STATE_SUMMARY.md](./CLUSTER_STATE_SUMMARY.md)** - Current cluster snapshot
  - Health check (nodes, storage, apps)
  - Recent changes log
  - HA failover test checklist
  - Production hardening recommendations

### 🏗️ Infrastructure Guides
- **[NFS_STORAGE.md](./NFS_STORAGE.md)** - NFS mount configuration
  - Unraid export setup
  - PV/PVC templates
  - Read-only vs read-write mounts

### 💡 Best Practices
- **[GITOPS_BEST_PRACTICES.md](./GITOPS_BEST_PRACTICES.md)** - GitOps patterns & anti-patterns
  - Repository structure rationale
  - Dependency management
  - Storage architecture decisions
  - Application StatefulSet templates
  - Secrets management with sops-age
  - Testing changes safely
  - Common anti-patterns to avoid

---

## Archive

Historical planning documents are in [archive/](./archive/):

### SeaweedFS Planning (Superseded by Longhorn)
- `SEAWEEDFS_ROOT_CAUSE_ANALYSIS.md` - Why SeaweedFS failed with 2 nodes
- `SEAWEEDFS_ANALYSIS_AND_PLAN.md` - Initial evaluation
- `SEAWEEDFS_HA_ARCHITECTURE.md` - Proposed topology
- `SEAWEEDFS_CONFIG_CLARIFICATION.md` - Configuration learnings
- `SEAWEEDFS_CSI_IMPLEMENTATION.md` - Driver implementation details
- `SEAWEEDFS_ISSUES_AND_FINDINGS.md` - Debugging notes
- `CSI_IMPLEMENTATION_SUMMARY.md` - CSI driver patterns

### HA Path Planning (Historical exploration)
- `ACTIVE_PASSIVE_HA_PLAN.md` - Earlier HA approaches
- `INCREMENTAL_HA_PATH.md` - Migration planning
- `STATEFULSET_AND_STORAGE_SIMPLIFICATION_PLAN.md` - Application design
- `CLUSTERPLEX_HA_IMPLEMENTATION_PLAN.md` - Alternative approach
- `REVIEW_FINDINGS.md` - Repository review assessment
- `COMPLETE_ORIGINAL_ARCHITECTURE.md` - Original system design

---

## Copilot Instructions

GitHub Copilot context is stored in [.github/copilot-instructions.md](../.github/copilot-instructions.md).
This file provides AI assistants working in this codebase with essential cluster info.

---

## Quick Links

### Essential Commands
```bash
# Cluster health
kubectl get nodes -L node.longhorn.io/storage
kubectl get volumes.longhorn.io -n longhorn-system
flux get all

# Monitor storage pods
kubectl get pods -n media -o wide -w

# Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# Watch Flux reconciliation
flux get kustomizations -w
```

### Key Files by Purpose
| Need | File |
|------|------|
| **Set up storage nodes** | LONGHORN_NODE_SETUP.md |
| **Understand HA architecture** | LONGHORN_HA_MIGRATION.md |
| **Check cluster health** | CLUSTER_STATE_SUMMARY.md |
| **Add new workloads** | GITOPS_BEST_PRACTICES.md |
| **Configure NFS mounts** | NFS_STORAGE.md |
| **Debug issues** | LONGHORN_HA_MIGRATION.md (Troubleshooting section) |

---

## Documentation Philosophy

✅ **What's Here**:
- Operational run-books for common tasks
- Architecture decisions and their rationale
- Troubleshooting procedures
- Design patterns and best practices
- Lessons learned from implementations

🔶 **What's NOT Here**:
- Kubernetes API reference (see upstream docs)
- Longhorn tuning parameters (see Longhorn docs)
- k3s installation (see k3s docs)

**Philosophy**: This documentation captures *decision context* and *operational knowledge specific to this cluster*. It complements (not replaces) upstream documentation.

---

## Contributing

When updating documentation:
1. Keep runbooks concise and actionable
2. Link to upstream docs for detailed explanations
3. Include "why" not just "what"
4. Document decisions that took time to discover
5. Update LONGHORN_HA_MIGRATION.md if architecture changes
6. Archive outdated plans (don't delete)

---

**Last Updated**: 2026-02-15  
**Cluster Status**: ✅ Operational (Longhorn HA, Sonarr active)  
**Next**: HA failover testing, Prowlarr scale-up, backup strategy
