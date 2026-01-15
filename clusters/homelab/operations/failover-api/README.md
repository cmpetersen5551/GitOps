# Failover API

HTTP-triggered GitOps failover automation for stateful applications with node-bound storage.

## Overview

The Failover API provides a simple HTTP interface to trigger automated failover/failback operations for services configured with VolSync replication across cluster nodes.

**Key features:**
- ✅ **Dynamic configuration** - Add services via ConfigMap, no code changes needed
- ✅ **GitOps-native** - Commits changes to Git, Flux reconciles automatically
- ✅ **High availability** - Runs on multiple nodes with pod disruption budgets
- ✅ **Multiple services** - Single API handles 20+ services
- ✅ **Dry-run support** - Test before executing
- ✅ **Audit trail** - All operations committed to Git with timestamps

## Architecture

```
User / Monitoring System
        │
        ├─ curl /api/failover/sonarr/promote
        │
        ▼
    Failover API (HA Deployment)
        │
        ├─ Clone Git repo
        ├─ Update deployment.yaml (PVC + nodeSelector)
        ├─ Git commit + push
        │
        ▼
    GitHub (GitOps Repository)
        │
        ├─ Flux watches for changes
        │
        ▼
    Flux Kustomization Controller
        │
        ├─ Detects updated manifests
        ├─ Applies to cluster
        │
        ▼
    Pod Rescheduled
        │
        ├─ Old pod evicts from primary node
        ├─ New pod starts on backup node with backup PVC
        │
        ▼
    Service Available on Backup Node
```

## Configuration

### Adding Services

Edit [configmap.yaml](configmap.yaml) to add services:

```yaml
services:
  sonarr:
    namespace: media
    deployment: sonarr
    volume_name: sonarr-data
    primary_pvc: pvc-sonarr
    backup_pvc: pvc-sonarr-backup
    primary_node_label: primary
    backup_node_label: backup
  radarr:  # New service
    namespace: media
    deployment: radarr
    volume_name: radarr-data
    primary_pvc: pvc-radarr
    backup_pvc: pvc-radarr-backup
    primary_node_label: primary
    backup_node_label: backup
```

**Required fields:**
- `namespace` - Kubernetes namespace where deployment runs
- `deployment` - Deployment name (must match manifest file location)
- `volume_name` - Volume name in pod spec (exact match required)
- `primary_pvc` / `backup_pvc` - PVC names to swap
- `primary_node_label` / `backup_node_label` - Node selector labels

### High Availability Setup

The Failover API runs as a multi-replica deployment:

**Current setup (2 worker nodes):**
```yaml
replicas: 2  # One pod on k3s-w1, one on k3s-w2
affinity:    # Pod anti-affinity spreads across nodes
```

**For 3+ worker nodes:**
Update `replicas` in [deployment.yaml](deployment.yaml) and adjust `minAvailable` in [pdb.yaml](pdb.yaml).

## Usage

### List Configured Services

```bash
curl http://failover-api.operations.svc.cluster.local/api/services
```

Response:
```json
{
  "count": 2,
  "services": ["sonarr", "radarr"]
}
```

### Promote to Backup (Failover)

```bash
# Dry run (no changes)
curl http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote?dry-run=true

# Execute
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote
```

Response:
```json
{
  "status": "success",
  "service": "sonarr",
  "action": "promote",
  "message": "Successfully performed backup failover for sonarr"
}
```

### Demote to Primary (Failback)

```bash
# Dry run
curl http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote?dry-run=true

# Execute
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote
```

### Check Service Status

```bash
curl http://failover-api.operations.svc.cluster.local/api/failover/sonarr/status
```

Response:
```json
{
  "service": "sonarr",
  "namespace": "media",
  "deployment": "sonarr",
  "primary_pvc": "pvc-sonarr",
  "backup_pvc": "pvc-sonarr-backup",
  "primary_node": "primary",
  "backup_node": "backup"
}
```

### Health Check

```bash
curl http://failover-api.operations.svc.cluster.local/api/health
```

## Integration with Monitoring

### From External Monitoring (Port-Forward)

```bash
# Create port-forward from your laptop
kubectl -n operations port-forward svc/failover-api 8080:8080

# Trigger failover from monitoring system
curl http://localhost:8080/api/failover/sonarr/promote
```

### From Home Assistant

Create an automation that triggers failover when node is down:

```yaml
automation:
  - alias: Failover Sonarr on K3S-W1 Failure
    trigger:
      platform: state
      entity_id: binary_sensor.k3s_w1_available
      to: "off"
    action:
      - service: rest_command.failover_sonarr
        data: {}

rest_command:
  failover_sonarr:
    url: "http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote"
    method: POST
```

### MetalLB / Traefik Failover

**Good news:** MetalLB and Traefik handle failover automatically!

**Why:**
- MetalLB advertises service IPs from any healthy node
- Traefik watches Ingress resources cluster-wide
- When deployment reschedules to backup node, endpoints update automatically
- Traffic routes to the new pod IP without manual intervention

**What happens during failover:**
1. Pod on primary node (k3s-w1) evicts
2. New pod scheduled on backup node (k3s-w2)
3. Endpoint controller updates Service with new pod IP
4. MetalLB re-advertises service IP (may change egress path, data plane transparent)
5. Traefik detects endpoint change via watch
6. Traffic routes to new pod automatically

**Testing failover connectivity:**
```bash
# Before failover
kubectl get endpoints -n media sonarr

# Trigger failover
curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote

# After failover - endpoint IP should change
kubectl get endpoints -n media sonarr

# Traffic automatically follows the new endpoint
curl http://sonarr.yourdomain.com/api/system/status
```

## Workflow Example: Node Failure

### Scenario: Primary node (k3s-w1) goes down

**Timeline:**
- **T+0m:** k3s-w1 becomes unreachable
- **T+1m:** Kubernetes marks node as `NotReady`
- **T+5m:** You notice the issue and decide to failover
- **T+5m:** Trigger failover manually:
  ```bash
  curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/promote
  ```
- **T+5m:** Failover API commits updated manifests to Git
- **T+6m:** Flux detects Git change (1-minute reconciliation interval)
- **T+6m:** Flux applies updated deployment (pod on backup node)
- **T+6m:** Sonarr pod starts on k3s-w2, mounts `pvc-sonarr-backup`
- **T+7m:** Sonarr becomes ready, service available again
- **T+11m:** k3s-w1 recovers, rejoins cluster (optional manual failback)
- **T+11m:** Trigger failback:
  ```bash
  curl -X POST http://failover-api.operations.svc.cluster.local/api/failover/sonarr/demote
  ```
- **T+12m:** Flux applies updated deployment (pod back on primary node)
- **T+12m:** Sonarr pod starts on k3s-w1, mounts `pvc-sonarr`

**Total downtime:** ~6-7 minutes (detection + failover)

## Security Considerations

### SSH Key Handling
- Mounts `flux-system` secret (read-only) from `flux-system` namespace
- Uses SSH for Git operations (no credentials in environment)
- SSH keys extracted to `/run/secrets/ssh-identity` with mode `0400`

### RBAC
- Only reads from `flux-system` secret (limited to specific key)
- Only reads own config from `failover-api-config` ConfigMap
- No cluster API modifications (pure Git operations)
- Service account restricted to `operations` namespace

### Pod Security
- Runs as non-root user (UID 1000)
- Read-only root filesystem
- Capabilities dropped (no special privileges)
- Memory-backed `/tmp` prevents disk writes
- Health checks ensure availability

## Troubleshooting

### Service not responding

```bash
# Check pod status
kubectl get pods -n operations -l app=failover-api

# Check logs
kubectl logs -n operations -l app=failover-api

# Test from within cluster
kubectl run -it --rm test --image=curlimages/curl -- \
  curl http://failover-api.operations.svc.cluster.local:8080/api/health
```

### Git operation fails

```bash
# Check if flux-system secret exists
kubectl get secret flux-system -n flux-system

# Verify SSH key has write access on GitHub
# Go to: https://github.com/settings/keys
# Your deploy key should have "Allow write access" enabled

# Test SSH connection from pod
kubectl run -it --rm ssh-test --image=alpine:latest -- sh
  apk add openssh-client
  ssh -i /path/to/key git@github.com
```

### Pod doesn't find deployment

```bash
# Check ConfigMap is correct
kubectl get configmap failover-api-config -n operations -o yaml

# Verify deployment file exists
git ls-tree -r main -- clusters/homelab/apps/media/sonarr/deployment.yaml
```

## Future Enhancements

- [ ] Metrics/Prometheus integration
- [ ] Automatic failover on node unhealthiness (watches node status)
- [ ] Email/Slack notifications on failover
- [ ] Web UI for manual controls
- [ ] Automatic failback on primary recovery
- [ ] Cross-cluster failover support
- [ ] Rate limiting for failover requests
