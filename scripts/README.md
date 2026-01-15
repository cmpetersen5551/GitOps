# Scripts

Helper scripts for GitOps repository management.

## Structure

```
scripts/
├── README.md             # This file
├── validate/             # Validation tooling
│   ├── validate          # Repository validation script
│   └── .yamllint         # YAML linting configuration
└── failover/             # HA failover/failback tooling
    ├── failover          # Non-interactive failover script
    ├── failover.json     # Service configuration
    └── README.md         # Failover documentation
```

## validate

Repository validation - run before committing:

```bash
scripts/validate/validate
```

Checks:
- ✓ Kustomize builds succeed
- ✓ Kubernetes resources valid (dry-run)
- ✓ YAML syntax (using scripts/validate/.yamllint)
- ✓ No unresolved placeholders
- ✓ PV/PVC storage capacity matches
- ✓ All HA services in failover config

## failover

Automated HA failover/failback by Git commits:

```bash
scripts/failover/failover promote   # Failover to backup
scripts/failover/failover demote    # Failback to primary
```

See [failover/README.md](failover/README.md) for details.
