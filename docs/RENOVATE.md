# Renovate Setup & Troubleshooting

**Date**: March 1, 2026  
**Version**: Renovate 43.43.2+ (Mend-hosted)

---

## Overview

Renovate is configured to auto-detect and propose updates for:
- **Helm charts** (in `HelmRelease` manifests)
- **Container images** (in Kubernetes manifests: `image:` fields)
- **Flux** (special case: dashboard only, requires manual approval)

Configuration: [renovate.json](../renovate.json)

---

## Common Mistakes & Fixes

### ❌ Deprecated Presets

**Error**: Renovate config validation fails silently or produces cryptic errors.

**Root cause**: `config:base` was deprecated in Renovate v37.

**Fix**: Replace with `config:recommended`
```json
{
  "extends": [
    "config:recommended",
    ":dependencyDashboard",
    ":semanticCommits"
  ]
}
```

---

### ❌ Invalid Manager Config Objects

**Error**: Renovate skips entire chunks of config or fails to recognize managers.

**Root cause**: Using language/category names instead of actual manager names.

**Examples**:
```json
// ❌ WRONG: helm and docker are categories, not manager names
{
  "helm": { "enabled": true },
  "docker": { "enabled": true }
}

// ✅ CORRECT: Use actual manager names
{
  "helmv3": { "enabled": true },
  "kubernetes": { "enabled": true },
  "dockerfile": { "enabled": true },
  "docker-compose": { "enabled": true }
}
```

**Valid manager names** (for this repo):
- `helmv3` — Helm 3 (detects `Chart.yaml` + `HelmRelease`)
- `kubernetes` — K8s manifests (detects images, custom managers)
- `flux` — Flux resources (detects `HelmRelease`, `GitRepository`, etc.)
- `dockerfile` — Dockerfile base image updates (not used here)

---

### ❌ Invalid postUpdateOptions

**Error**: Config validation error or option silently ignored.

**Root cause**: Option name is misspelled or doesn't exist.

**Examples**:
```json
// ❌ WRONG: yarnDedupeModules doesn't exist
{
  "postUpdateOptions": ["gomodTidy", "yarnDedupeModules", "npmDedupe"]
}

// ✅ CORRECT (or omit entirely for IaC repos):
{
  "postUpdateOptions": [
    "yarnDedupeFewer",    // If needed
    "yarnDedupeHighest"   // If needed
  ]
}

// ✅ BEST for pure IaC (no dependencies): omit entirely
// No postUpdateOptions = no artifact updates needed
```

**Valid options** (see [Renovate docs](https://docs.renovatebot.com/configuration-options/#postupdateoptions)):
- `gomodTidy` — Go module tidying (Go repos)
- `npmDedupe` — npm deduplication (npm repos)
- `yarnDedupeFewer`, `yarnDedupeHighest` — Yarn deduplication (npm/yarn repos)
- None of these apply to Kubernetes IaC repos

---

## Special Case: Flux Updates

### Problem

`gotk-components.yaml` is a **machine-generated** file (output of `flux install --export`). It contains:
- Namespace + RBAC
- CRDs for Flux resources
- Deployments + ConfigMaps for Flux controllers
- Individual container image tags

Renovate can update only the image tags, leaving CRDs stale if there are schema changes in a new Flux version.

### Solution

**Prevent auto-creation of PRs** for this file:

```json
{
  "packageRules": [
    {
      "description": "Flux: show in dashboard but never auto-create a PR. gotk-components.yaml is generated; upgrade via 'flux install --export' manually.",
      "matchManagers": ["flux"],
      "matchPackageNames": ["fluxcd/flux2"],
      "dependencyDashboardApproval": true
    }
  ]
}
```

**Effect**: Updates appear in Dependency Dashboard but require a manual checkbox to create a PR.

### How to Upgrade Flux Correctly

```bash
# 1. Check available versions
flux --version

# 2. Export new version manifest
flux install --version=v2.8.1 --export > clusters/homelab/flux-system/gotk-components.yaml

# 3. Review changes
git diff clusters/homelab/flux-system/gotk-components.yaml

# 4. Commit and push (Flux reconciles automatically)
git add clusters/homelab/flux-system/gotk-components.yaml
git commit -m "chore: upgrade Flux to v2.8.1"
git push origin main
```

---

## Dependency Dashboard

**Location**: Issue #11 in this repo  
**Purpose**: Centralized view of all available updates

**Fields**:
- **Awaiting Schedule**: Updates scheduled for a future time window
- **Detected Dependencies**: Versions currently running in manifests

**Manual Actions**:
- ✅ Check a checkbox to trigger PR creation immediately (bypasses schedule)
- ✅ Check the "Run Renovate" box to force a full re-scan

---

## Registry Aliases

For compatibility with Renovate, `lscr.io` (linuxserver.io registry) is aliased to `ghcr.io`:

```json
{
  "registryAliases": {
    "lscr.io": "ghcr.io"
  }
}
```

This allows Renovate to resolve image versions from the actual source without special handling.

---

## Image Versioning Rules

**linuxserver images** — strict `X.Y.Z` semver only:
```json
{
  "description": "linuxserver images: only track clean X.Y.Z short tags, ignore full build tags like 1.43.0.10492-121068a07-ls294",
  "matchDatasources": ["docker"],
  "matchPackagePatterns": ["^(lscr\\.io/linuxserver|linuxserver)/"],
  "versioning": "semver",
  "allowedVersions": "/^\\d+\\.\\d+\\.\\d+$/"
}
```

**pulsarr** — block beta and -node tags:
```json
{
  "description": "pulsarr: only track stable releases, ignore -beta and -node tags",
  "matchPackageNames": ["lakker/pulsarr"],
  "versioning": "semver",
  "allowedVersions": "!/beta|node/"
}
```

**profilarr** — v-prefixed semver:
```json
{
  "description": "profilarr uses v-prefixed semver tags",
  "matchPackageNames": ["santiagosayshey/profilarr"],
  "versioning": "semver"
}
```

---

## Troubleshooting

### "Package lookup failures" in Mend portal

**Cause**: Renovate is trying to look up a package that doesn't exist on the registry.

**Solution**:
1. Check the file path in the warning
2. Verify the package name / image URI is correct
3. If it's a false positive (e.g., `renovatebot/renovate-action`), remove the file that references it

**Example**: GitHub Actions workflow `renovate.yml` was causing Renovate to track `renovatebot/renovate-action` as a dependency. Since the Mend-hosted app is already running, the workflow is redundant → removed.

### Config validation errors

**Steps**:
1. Check [Renovate docs](https://docs.renovatebot.com/configuration-options/) for exact option names
2. Verify manager names against [supported managers list](https://docs.renovatebot.com/modules/manager/#supported-managers)
3. Use `extends: ["config:recommended"]` as the baseline
4. Test config locally:
   ```bash
   npm install -g renovate
   renovate --validate-config renovate.json
   ```

### Updates not appearing in dashboard

**Possible causes**:
1. Package matching rules are too restrictive (`allowedVersions`)
2. Schedule is in the future (check "Awaiting Schedule" section)
3. Version is pre-release and `ignoreUnstable: true` (default)

**Fix**: Wait for next Renovate run (check Mend portal for last run time) or manually trigger via Dependency Dashboard checkbox.

---

## References

- [Renovate Docs](https://docs.renovatebot.com/)
- [Configuration Options](https://docs.renovatebot.com/configuration-options/)
- [Supported Managers](https://docs.renovatebot.com/modules/manager/#supported-managers)
- [Package Rules](https://docs.renovatebot.com/configuration-options/#packagerules)
- [Flux GitHub Releases](https://github.com/fluxcd/flux2/releases)
