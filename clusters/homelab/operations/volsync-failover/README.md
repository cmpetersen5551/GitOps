VolSync failover/failback automation
===================================

What this does
--------------
This folder provides a lightweight in-cluster monitor and scripts to perform:

- automatic failover (primary -> backup) when the primary worker is detected down
- deterministic failback (backup -> primary) using an rsync Job

Design
------
- VolSync continues running primary -> backup for near-real-time replication.
- A monitor Pod watches Node readiness and calls the `failover.sh` script.
- `failover.sh` supports `--promote` (failover) and `--failback` (rsync-based failback).
- The rsync Job performs a final, verifiable copy from `pvc-sonarr-backup` -> `pvc-sonarr`.

Safety
------
- Default behavior is `--dry-run` until you pass `--confirm`.
- The monitor requires replication checks (you can tune thresholds).
- RBAC is limited to the needed verbs/resources.

Quick test commands
-------------------
Dry-run a promotion from a pod with kubectl available:

```bash
kubectl -n operations run --rm -i --restart=Never tool --image=bitnami/kubectl -- sh -c '/etc/volsync-failover/failover.sh --promote --dry-run'
```

Manually apply the rsync Job for failback (example):

```bash
kubectl -n media apply -f clusters/homelab/operations/volsync-failover/rsync-job.yaml
kubectl -n media wait --for=condition=complete job/volsync-rsync --timeout=10m
```

Files
-----
- `configmap.yaml` - contains `monitor.sh`, `failover.sh`, and `rsync-job.yaml` template
- `monitor-deployment.yaml` - Deployment that runs the monitor loop
- `rbac.yaml` - ServiceAccount, ClusterRole and ClusterRoleBinding for the monitor
- `rsync-job.yaml` - Job template copied from ConfigMap; used for failback
- `failover.sh` - the promotion/failback driver (also in ConfigMap)
