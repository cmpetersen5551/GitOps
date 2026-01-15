# Failover Scripts

Simple, non-interactive failover/failback for HA services.

## Usage

```bash
# Failover to backup node
./scripts/failover promote

# Failback to primary node  
./scripts/failover demote
```

## Configuration

Service definitions are in `scripts/failover.json`:

```json
{
  "services": {
    "sonarr": {
      "namespace": "media",
      "deployment": "sonarr",
      "volume_name": "sonarr-data",
      "primary_pvc": "pvc-sonarr",
      "backup_pvc": "pvc-sonarr-backup",
      "primary_node_label": "primary",
      "backup_node_label": "backup"
    }
  }
}
```

## How It Works

1. Script reads service config from `failover.json`
2. Script edits the deployment manifest to switch PVC and node selector
3. Changes are committed to Git
4. Push triggers Flux reconciliation (within 1 minute)
5. Deployment pod is scheduled on the new node with the new PVC
