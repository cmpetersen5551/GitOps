# Repository Reference Guide

## Directory Structure

```
clusters/homelab/
├── cluster/                    # Flux Kustomization CRs (orchestration layer)
│   ├── infrastructure-crds.yaml
│   ├── infrastructure-controllers.yaml
│   ├── infrastructure-storage.yaml
│   ├── apps-kustomization.yaml
│   └── operations-kustomization.yaml
├── infrastructure/             # Platform components
│   ├── crds/                   # Custom Resource Definitions (VolSync)
│   ├── controllers/            # Operators (VolSync controller)
│   └── storage/                # Persistent Volumes for apps
├── operations/                 # Operational tooling
│   └── volsync-failover/       # Monitoring and failover automation
├── apps/                       # Applications (organized by category)
│   ├── media/                  # Media stack apps
│   │   ├── sonarr/             # PVR application
│   │   ├── radarr/             # Movie manager (future)
│   │   └── plex/               # Media server (future)
│   └── database/               # Database apps (future)
└── flux-system/                # Flux bootstrap (managed by Flux CLI)
```

## Key Design Decisions

**For detailed explanation, see [ARCHITECTURE.md](ARCHITECTURE.md)**

1. **Infrastructure-as-Code** — All workloads defined in Git, Flux reconciles continuously
2. **Layered Dependencies** — Infrastructure > Operations > Applications ensures proper startup order
3. **Static PVs for HA Stateful Apps** — Stateful applications use static PVs with node affinity for high availability
4. **VolSync Replication** — Syncthing method automatically syncs app state between primary and backup nodes
5. **Extensible Structure** — Each app category and app follows the same pattern, making it easy to add new services

## Testing & Validation

Run validation script:
```bash
./validate.sh
```

For detailed validation steps, see [.copilot-instructions.md](../../.github/copilot-instructions.md)
