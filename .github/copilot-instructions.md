# Copilot Instructions for GitOps Cluster

**Repo**: cmpetersen5551/GitOps, branch: `main` | k3s homelab, Flux v2, Longhorn 2-node HA

## Rules

1. **Always Flux** — commit + push, never `kubectl apply`. Force sync: `flux reconcile kustomization apps --with-source`
2. **No credentials/usernames/IPs in this repo** — stored in personal AI memory only
3. **New workloads**: use `longhorn-simple` StorageClass, copy affinity/tolerations from `clusters/homelab/apps/media/sonarr/statefulset.yaml`

## Don't Repeat These Mistakes

- ❌ SeaweedFS — needs 3+ nodes for HA, won't work here
- ❌ SMB/Samba/dfs-mounter — replaced by direct FUSE propagation; do not re-add
- ❌ `noreparse` CIFS option — requires kernel 6.15+; nodes on 6.12/6.8
- ❌ `replicaSoftAntiAffinity: true` — breaks 2-node Longhorn (must be `false`)
- ❌ `preferredDuringScheduling` only without `required` — pods drift to cp1
- ❌ `enableServiceLinks: true` on Decypharr — injects bad `DECYPHARR_PORT` env var
- ❌ Health probes on Decypharr — all endpoints 401 until UI auth setup

## Reference Docs

| Doc | What's in it |
|-----|-------------|
| `docs/STATE.md` | Current nodes, pods, PVCs, infra |
| `docs/DECISIONS.md` | HA strategy, DFS arch, storage choices + rejected alternatives + node setup runbook |
| `docs/GOTCHAS.md` | Symptom → root cause → fix index |

**Last Updated**: 2026-02-28
