#!/bin/bash
# Failover Script - Interactive wrapper
# Usage: ./scripts/failover (no arguments, interactive menu)

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Check if we're in the right directory
if [ ! -f "$REPO_ROOT/clusters/homelab/operations/failover-api/configmap.yaml" ]; then
    echo "Error: Not in GitOps repository root"
    exit 1
fi

# Ensure we're in the repo root
cd "$REPO_ROOT"

# Check Git status
if [ -z "$(git status --short)" ]; then
    : # Clean, continue
else
    echo "Warning: Git working directory has uncommitted changes"
    echo "Please commit or stash changes before running failover"
    exit 1
fi

# Run Python script
python3 "$SCRIPT_DIR/failover" "$@"
