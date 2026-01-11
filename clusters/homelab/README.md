# Homelab — Overview

Purpose
- High-level documentation for the homelab cluster: hardware, topology, and operational runbook.
- Flux bootstrapped this cluster and manages the `flux-system` manifests. Do not edit Flux bootstrap manifests directly.

Contents
- `HARDWARE.md` — node inventory, topology, and storage layout.
- `OPERATIONS.md` — runbook: storage, sync, GPU roles, checks, and troubleshooting.
- `flux-system/` — Flux bootstrap artifacts (managed by Flux; do not modify).

Flux — short note
- Flux v2 bootstrapped this cluster and continuously reconciles this repository. Make any desired changes in Git and let Flux apply them. Use `flux` CLI or `kubectl` to inspect status (examples in `OPERATIONS.md`).

Quick pointers
- Inspect nodes:
```bash
kubectl get nodes -o wide
```
- Inspect Flux:
```bash
flux get sources git -n flux-system
flux get kustomizations -n flux-system
```

Next steps
- Read `HARDWARE.md` to understand the cluster topology and storage layout.
- Read `OPERATIONS.md` for operational tasks, common commands, and troubleshooting.

Adding services
- New services (e.g., Sonarr) live in their own folders under `clusters/homelab/` and are included via the `flux-system` kustomization. See `sonarr/` for an example deployment and storage configuration.
