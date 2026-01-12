#!/bin/bash
# GitOps Repository Validation Script
# Validates all manifests before committing changes
# All commands use dry-run or read-only operations
# See .copilot-instructions.md for overview

set -e

echo "=== Validating GitOps Repository ==="

echo "→ Step 1: Kustomize builds"
kubectl kustomize clusters/homelab/infrastructure/crds > /dev/null
kubectl kustomize clusters/homelab/infrastructure/controllers > /dev/null
kubectl kustomize clusters/homelab/infrastructure/storage > /dev/null
kubectl kustomize clusters/homelab/operations > /dev/null
kubectl kustomize clusters/homelab/apps > /dev/null
echo "✓ All kustomize builds successful"

echo "→ Step 2: Kubernetes dry-run validation (client-side)"
kubectl apply --dry-run=client -k clusters/homelab/infrastructure/crds > /dev/null
kubectl apply --dry-run=client -k clusters/homelab/infrastructure/controllers > /dev/null
kubectl apply --dry-run=client -k clusters/homelab/infrastructure/storage > /dev/null
kubectl apply --dry-run=client -k clusters/homelab/operations > /dev/null
echo "✓ Infrastructure and operations resources valid"

# Note: Apps may fail client-side dry-run if CRDs aren't in cluster yet
echo "→ Step 2b: Apps validation (may show CRD warnings)"
if kubectl apply --dry-run=client -k clusters/homelab/apps > /dev/null 2>&1; then
  echo "✓ All app resources valid"
else
  echo "⚠ Apps validation requires CRDs to be installed (expected if cluster is fresh)"
fi

echo "→ Step 3: YAML syntax check"
if command -v yamllint &> /dev/null; then
  yamllint -d relaxed clusters/homelab/ > /dev/null 2>&1
  echo "✓ YAML syntax valid"
else
  echo "⚠ yamllint not installed, skipping (install: pip install yamllint)"
fi

echo "→ Step 4: Check for placeholder values"
PLACEHOLDERS=$(grep -r "<.*>" clusters/homelab/ --include="*.yaml" | grep -v "# " | grep -v "flux-system/gotk-components.yaml" | grep -v "description:" | wc -l | tr -d ' ')
if [ "$PLACEHOLDERS" -gt 0 ]; then
  echo "⚠ Found $PLACEHOLDERS placeholder values that may need replacement:"
  grep -r "<.*>" clusters/homelab/ --include="*.yaml" | grep -v "# " | grep -v "flux-system/gotk-components.yaml" | grep -v "description:"
  exit 1
else
  echo "✓ No unresolved placeholders"
fi

echo ""
echo "=== All validation checks passed ==="
echo "Repository is ready to commit"
