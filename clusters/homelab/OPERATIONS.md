# Operations & Runbook

Scope
- Operational guidance for non-Flux tasks: storage, Syncthing, GPU usage, checks, and quick recovery steps.
- Flux bootstrap and its manifests are managed by Flux — do not edit `clusters/homelab/flux-system` or Flux-managed resources directly.

Storage & sync
- Media:
  - Source: Unraid NFS export.
  - Flow: Unraid NFS → Proxmox host mount → bind mount → `k3s-w1`.
  - `k3s-w2` mounts the same NFS export directly.
- Pods:
  - `/data/pods` is local on each worker and is NOT on the NFS export.
  - `/data/pods` is synchronized across workers via Syncthing (external process). Ensure Syncthing is healthy before relying on pod-local data.

GPU workload strategy
- `k3s-w1`: primary GPU node (preferred scheduling).
- `k3s-w2`: failover GPU node; manual or automated failover strategies may be used.
- Use node labels/taints to steer GPU workloads, e.g. label `node.kubernetes.io/gpu=true`.

Ingress & DNS
- k3s default Traefik is present — use it as the cluster reverse-proxy unless replaced.
- DNS/edge routing is TBD; document later when decided.

Common checks & commands
- Nodes:
```bash
kubectl get nodes -o wide
```
- Flux sources & kustomizations:
```bash
flux get sources git -n flux-system
flux get kustomizations -n flux-system
```
- Inspect kustomization (shows `path`, `interval`, `lastAppliedRevision`):
```bash
flux get kustomization <name> -n flux-system -o yaml
```
- Trigger an immediate reconcile (safe):
```bash
flux reconcile kustomization <name> -n flux-system
```
- Flux controller status & logs:
```bash
kubectl get pods -n flux-system
kubectl logs -n flux-system deployment/kustomize-controller --tail=200
```
- Check kustomization status & events:
```bash
kubectl describe kustomization <name> -n flux-system
flux events --for Kustomization/<name> -n flux-system
```

Backup & restore notes
- Back up:
  - Important application data under `/data/pods` (sync first).
  - Any critical manifest snapshots or cluster state (outside Flux-managed manifests).
- Restore:
  - Re-establish mounts and Syncthing sync before restoring pod data.
  - Let Flux reapply manifests after node/storage readiness confirmed.

Troubleshooting quick hits
1. Verify NFS mounts on `k3s-w1` and `k3s-w2` for `/data/media`.
2. Confirm Syncthing status and recent syncs for `/data/pods`.
3. Check pod readiness: `kubectl get pods -A` and `kubectl describe pod`.
4. Check Flux sync: `flux get kustomizations -n flux-system` and `kubectl describe kustomization <name> -n flux-system`.
5. Check GPU node readiness and drivers on `k3s-w1`/`k3s-w2`.

Flux / Kustomize references (for future edits)
- Flux docs: https://fluxcd.io/docs/
- Bootstrap: https://fluxcd.io/docs/guides/flux-bootstrap/
- GitRepository: https://fluxcd.io/docs/components/source/gitrepository/
- Kustomization: https://fluxcd.io/docs/components/kustomize/kustomization/
- Flux CLI: https://fluxcd.io/docs/cmd/

Safety
- Never store secrets, SSH keys, or tokens in repo docs. Flux uses referenced secrets for repo access; do not include their contents in documentation.
