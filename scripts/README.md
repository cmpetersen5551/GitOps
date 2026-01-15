# Failover Scripts

Simple, GitOps-native failover management for stateful applications with HA setup (VolSync + dual PVCs).

## Usage

Run the interactive failover menu:

```bash
./scripts/failover.sh
```

Or directly with Python:

```bash
./scripts/failover
```

### Workflow

1. **Script loads** all services from `clusters/homelab/operations/failover-api/configmap.yaml`
2. **Interactive menu** displays available services and actions
3. **You select:**
   - Which service to failover (e.g., Sonarr)
   - Which action: Promote (to backup) or Demote (to primary)
4. **Script confirms** changes before proceeding
5. **Edits deployment** YAML (changes PVC and nodeSelector)
6. **Commits and pushes** to GitHub
7. **Flux applies** the change within ~1 minute

## Failover Sequence

### Before Failover (Primary Running)
```
Node k3s-w1 (primary)
  └─ Sonarr pod
    └─ mounts: pvc-sonarr → PV mounted on k3s-w1
```

### Trigger Failover
```bash
./scripts/failover.sh
# Select: sonarr → promote
# Confirms changes
# Edits: deployment.yaml
  # pvc-sonarr → pvc-sonarr-backup
  # nodeSelector.role: primary → backup
# Commits: "failover: sonarr - failover to backup"
# Pushes to GitHub
```

### During Failover (1-2 minutes)
```
1. Flux detects change (within 1 min)
2. Pod on k3s-w1 evicts (can't match nodeSelector: role=backup)
3. Kubernetes schedules pod to k3s-w2
4. Pod starts on k3s-w2 and mounts pvc-sonarr-backup
5. VolSync has been syncing in background, data is current
6. Service available on k3s-w2
```

### After Failover (Backup Running)
```
Node k3s-w2 (backup)
  └─ Sonarr pod
    └─ mounts: pvc-sonarr-backup → PV mounted on k3s-w2
```

## Failback (Return to Primary)

When the primary node recovers:

```bash
./scripts/failover.sh
# Select: sonarr → demote
# Confirms changes
# Edits: deployment.yaml
  # pvc-sonarr-backup → pvc-sonarr
  # nodeSelector.role: backup → primary
# Commits: "failover: sonarr - failback to primary"
# Pushes
# Flux applies
# Pod reschedules to k3s-w1
```

## Requirements

### For the Script
- **Python 3.6+** (usually available on macOS/Linux)
- **Git** (already required for GitOps)
- **yq** (optional, for YAML editing - script falls back to sed if not installed)
- **kubectl** (optional, for monitoring - not required for script)

### For Services
- **VolSync** set up with replication source/destination
- **Two PVCs** per service: `pvc-<service>` and `pvc-<service>-backup`
- **Two PVs** with nodeAffinity: one for each worker node
- **Deployment** with `nodeSelector.role: primary` and single replica
- **ConfigMap entry** in `clusters/homelab/operations/failover-api/configmap.yaml`

## Adding New HA Services

When you add a new service with HA setup:

1. Create PVs in `infrastructure/storage/<service>.yaml`
2. Create PVCs in `apps/<category>/<service>/pvc.yaml`
3. Create VolSync ReplicationSource/Destination
4. Set deployment nodeSelector to primary
5. **Add to ConfigMap:**

```yaml
# clusters/homelab/operations/failover-api/configmap.yaml
services:
  newservice:
    namespace: category
    deployment: newservice
    volume_name: newservice-data    # Must match volume in deployment spec
    primary_pvc: pvc-newservice
    backup_pvc: pvc-newservice-backup
    primary_node_label: primary
    backup_node_label: backup
```

6. Run `./validate.sh` to confirm setup is complete

## How It Works

### Script Implementation

- **`scripts/failover`** - Python script that:
  - Reads services from ConfigMap
  - Shows interactive menu
  - Edits deployment YAML (using yq or sed)
  - Commits to Git
  - Pushes to GitHub

- **`scripts/failover.sh`** - Bash wrapper that:
  - Checks Git is clean
  - Confirms we're in repo root
  - Calls Python script

### Git-Native Design

Instead of the old approach (directly patching cluster with kubectl):
- Script edits manifest files
- Changes are committed to Git
- Flux sees the Git change (single source of truth)
- Flux applies the change
- No conflicts, fully auditable

### Why Not HTTP API?

The original failover-api deployment:
- Required Docker build (not available locally)
- Required always-running pods
- Was overkill for rare manual operations
- Made failover dependent on another service

This script approach:
- Runs locally, on demand
- Simple Python + bash
- No infrastructure overhead
- Works immediately
- Better for infrequent manual operations

## Monitoring During Failover

Watch the pod reschedule in real-time:

```bash
# Terminal 1: Watch pod status
kubectl get pods -n media -o wide --watch

# Terminal 2: Trigger failover
./scripts/failover.sh
# Select sonarr → promote

# Watch in Terminal 1:
# NAME                 READY   STATUS      NODE      AGE
# sonarr-xxxxx         1/1     Terminating k3s-w1    5m
# sonarr-yyyyy         0/1     Pending     k3s-w2    2s
# sonarr-yyyyy         0/1     ContainerCreating k3s-w2    3s
# sonarr-yyyyy         1/1     Running     k3s-w2    8s
```

## Troubleshooting

### Script doesn't find Python
```bash
# Use explicit Python 3
python3 scripts/failover
```

### yq not installed
```bash
# Install yq
brew install yq  # macOS
apt install yq   # Linux

# Script works without it (uses sed fallback)
```

### Git errors
```bash
# Ensure you're in repo root
cd ~/Source/GitOps

# Check Git is clean
git status

# Check remote is configured
git remote -v
```

### Service not in menu
1. Verify service is added to ConfigMap
2. Run `./validate.sh` to check config
3. Restart script

### Pod doesn't reschedule
1. Check Flux reconciliation: `flux get kustomizations`
2. Check deployment was modified: `git log -1`
3. Wait up to 1 minute for Flux to detect change
4. Check pod status: `kubectl describe pod -n media <pod-name>`

## Future Enhancements

- [ ] Non-interactive mode: `./failover.sh sonarr promote`
- [ ] Dry-run mode: `./failover.sh sonarr promote --dry-run`
- [ ] Automatic healthcheck before allowing failover
- [ ] Slack notification on completion
- [ ] Automatic failback on primary recovery
- [ ] Web UI wrapper (if monitoring integration needed)

## Security Notes

- Script edits local files, no secrets involved
- Changes committed to Git (full audit trail)
- Only requires Git push access (no SSH keys to the cluster)
- Safe to run multiple times (commits idempotent file changes)
