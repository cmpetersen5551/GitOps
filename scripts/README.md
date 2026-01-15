# Scripts

Helper scripts for GitOps repository management.

## Structure

```
scripts/
├── validate              # Repository validation script
├── .yamllint             # YAML linting configuration
└── failover/             # HA failover/failback tooling
    ├── failover          # Non-interactive failover script
    ├── failover.json     # Service configuration
    └── README.md         # Failover documentation
```

## validate

Repository validation - run before committing:

```bash
scripts/validate
```

Checks:
- ✓ Kustomize builds succeed
- ✓ Kubernetes resources valid (dry-run)
- ✓ YAML syntax (using .yamllint config)
- ✓ No unresolved placeholders
- ✓ PV/PVC storage capacity matches
- ✓ All HA services in failover config

**No shell extension** - following Unix convention for executable scripts.

## failover

Automated HA failover/failback by Git commits:

```bash
./scripts/failover/failover promote   # Failover to backup
./scripts/failover/failover demote    # Failback to primary
```

See [failover/README.md](failover/README.md) for details.

## .yamllint

YAML linting configuration - used by validate script.

Move to scripts/ so it stays with the validation tool that uses it.
