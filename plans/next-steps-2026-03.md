# Next Steps — Spring 2026 Roadmap

**Date**: March 1, 2026  
**Status**: Planning phase  
**Owner**: Chris

---

## Overview

Three strategic initiatives converge on a critical blocker: secret management. This plan prioritizes backfilling gaps (backups), automating updates (Renovate), establishing secure credential handling (SOPS), then executing the two major features (C# apps, Live TV stack).

### Key Insight
Both the **Live TV stack** and **C# automation apps** require storing credentials securely in git. This blocks both tracks until **SOPS + age** is in place.

---

## Phase 1: Foundation (Weeks 1–2)

### 1.1 Backups — Extend Longhorn Recurring Jobs

**Status**: ✅ COMPLETED (2026-03-01)

**Scope**: Protect all Longhorn volumes (9 total) with nightly automated backups.

**What was delivered** (optimized approach):
- Single consolidated `RecurringJob` named `backup-all-volumes` (not per-app jobs)
- Backs all 9 cluster volumes labeled `recurring-job-group.longhorn.io/default=enabled` in one nightly run
- Schedule: 3:00 AM UTC daily
- Retention: 7 daily backups, with automatic cleanup of oldest
- Destination: `nfs://192.168.1.29:/mnt/cache/longhorn_backup` (incremental snapshots)
- Snapshot naming: `backup-a-{uuid}` (from job name prefix)
- File: `clusters/homelab/infrastructure/longhorn/recurring-backup-all.yaml`

**Why consolidated instead of per-app**: All volumes share the same label group (`default`). Separate per-app jobs would redundantly back all 9 volumes 5 times per night (wasteful). Single job is simpler, faster, and appropriate for homelab.

**Issue & fix during implementation**:
- Initial attempt with 4 app-specific jobs + `groups: []` → found 0 volumes (groups selector was empty)
- Root cause: RecurringJob must specify matching volume group label name in `spec.groups` field
- Solution: Changed to `groups: ["default"]` and consolidated to single job

**Verification** (test run completed):
- Deployed and tested with manual job trigger
- All 9 volumes backed up successfully (~260 MB composite backup)
- First scheduled run: 2026-03-02 at 3:00 AM UTC
- Longhorn UI shows completed backups with `backup-a-` prefix

**Effort**: ~30 min initial + 20 min troubleshooting + 10 min optimization = 60 min total

---

### 1.2 Renovate — Automated Dependency Updates

**Scope**: Keep Flux HelmReleases and container images pinned and up-to-date.

**Why Renovate over Dependabot**: Renovate understands Flux `HelmRelease` chart versions and container tags in k8s manifests. Dependabot does not.

**Implementation**:
1. Create `renovate.json` at repo root with:
   - `extends: ["config:base"]`
   - `helm` datasource enabled (auto-discovers `HelmRelease` in manifests)
   - Container image auto-discovery in k8s manifests
   - Auto-merge for patch/minor updates (optional; conservative: just open PRs)
   - Schedule: `["after 10pm every weekday", "before 5am every weekday"]`

2. Create GitHub Actions workflow (`.github/workflows/renovate.yml`):
   - Runs on schedule (nightly) or manual trigger
   - Calls official `renovatebot/renovate` action
   - Posts PRs to main branch

3. Pin container images to specific tags (not `latest`):
   - `linuxserver/sonarr:4.0.16` is good
   - `cy01/blackhole:beta` → consider finding a tagged release instead
   - `radarr:latest` → pin to a specific version

**Reference files to create**:
- `renovate.json` (root)
- `.github/workflows/renovate.yml` (GitHub Actions)

**Verification**:
- Renovate app appears in repo settings as an installed app
- Test with a manual workflow trigger
- Verify first PR opens for an available update (e.g., Longhorn chart bump)

**Effort**: ~45 min. One-time setup, then passive.

---

## Phase 2: Security Foundation (Week 2–3)

### 2.1 SOPS + age Secret Management

**Scope**: Enable encrypted secrets in git, Flux-native decryption at deploy time.

**Why now**: Both Live TV stack and C# apps need credentials (Pluto login, sportsebook keys, Sonarr API keys). This blocks both.

**Implementation**:
1. **Generate age keypair** locally:
   ```bash
   age-keygen -o age.key
   ```

2. **Create K8s Secret from private key** (bootstrap):
   ```bash
   kubectl create secret generic sops-age \
     --from-file=age.agekey=age.key \
     -n flux-system
   ```

3. **Create `.sops.yaml` at repo root**:
   ```yaml
   creation_rules:
     - path_regex: clusters/.*\.ya?ml$
       encrypted_regex: ^(data|stringData)$
       key_groups:
         - age:
             - <PUBLIC_KEY_OUTPUT_FROM_age-keygen>
   ```

4. **Create Flux `SecretProviderClass`** (or direct `SecretProviderClass/Secret` resources):
   - Reference `sops-age` secret in `flux-system` namespace
   - Flux automatically decrypts SOPS-sealed secrets on reconciliation

5. **Encrypt first secret** (example: Pluto credentials):
   ```bash
   sops --encrypt clusters/homelab/apps/media/pluto-for-channels-secret.yaml > clusters/homelab/apps/media/pluto-for-channels-secret.enc.yaml
   ```

6. **Add to `.gitignore`**:
   ```
   age.key
   *.dec.yaml
   ```

**Reference files to create**:
- `.sops.yaml` (repo root)
- Example encrypted secret in `clusters/homelab/apps/media/`
- Flux `Kustomization` to auto-decrypt

**Documentation**:
- How to add a new secret (edit in plaintext, encrypt, commit)
- How to decrypt locally for review (one-time before commit)
- Age key recovery procedures

**Verification**:
- Encrypt a test value → commit → Flux reconciles → secret appears in cluster
- Verify plaintext secret is NOT in git history
- Test pod can read the secret environment variable

**Effort**: ~1–2 hours. Done once, unlocks future work.

**Blocking dependency for**: Phase 4 (C# apps) and Phase 5 (Live TV).

---

## Phase 3: Observability Foundation (Week 3–4)

### 3.1 Monitoring Stack — kube-prometheus-stack + Loki + Grafana

**Scope**: Node metrics, pod logs, Longhorn health, custom C# job logs.

**Why**: Without log aggregation, C# job output vanishes when the pod terminates. Also foundational before adding 5+ live TV services.

**Implementation**:
1. **kube-prometheus-stack** (Prometheus + Grafana + AlertManager):
   - `HelmRelease` in `clusters/homelab/infrastructure/`
   - Deploy to `monitoring` namespace
   - Storage: Longhorn RWO (10Gi for Prometheus TSDB, 5Gi for Grafana)
   - Traefik ingress for Grafana (`grafana.homelab`)

2. **Loki** (log aggregation):
   - `HelmRelease` in `clusters/homelab/infrastructure/`
   - Deploy to `monitoring` namespace
   - Storage: Longhorn RWO (20Gi for log chunks)
   - No ingress needed (Grafana queries it internally)

3. **Promtail** (log collector):
   - `DaemonSet` on all nodes
   - Scrapes pod logs, sends to Loki
   - Already included in many kube-prometheus-stack Helm charts

4. **Dashboards**:
   - Longhorn volume health (CPU, replica status, backup success)
   - Node CPU, memory, disk usage
   - Sonarr/Radarr API response times (if instrumented)
   - C# job execution times and error rates

5. **Alerting** (simple rules):
   - PVC usage >85%
   - Node CPU >80%
   - Pod restart count >0 in 1 hour
   - Longhorn replica rebuild failures

**Reference files to create**:
- `clusters/homelab/infrastructure/monitoring/` (new folder)
  - `kustomization.yaml`
  - `kube-prometheus-helmrelease.yaml`
  - `loki-helmrelease.yaml`
  - `namespace.yaml`
  - `pvc-prometheus.yaml` (Longhorn RWO, 10Gi)
  - `pvc-loki.yaml` (Longhorn RWO, 20Gi)
  - `pvc-grafana.yaml` (Longhorn RWO, 5Gi) — if using persistent storage
  - `ingress-grafana.yaml` (Traefik, `grafana.homelab`)

**Verification**:
- Grafana accessible at `http://grafana.homelab`
- Pre-built dashboards available (Prometheus, Longhorn)
- Pod logs visible in Loki data source
- First custom C# job logs appear in Loki after Phase 4

**Effort**: ~2–3 hours. Heavy lifting on Helm values tuning.

**Blocking dependency for**: Phase 4 (logs for C# jobs) and Phase 5 (observability during Live TV expansion).

---

## Phase 4: C# App Platform + First App (Weeks 4–6)

### 4.1 Repository: Create `sonarr-utils` repo

**Scope**: First C# app — root folder / tag manager for Sonarr+Radarr.

**Setup**:
1. **New GitHub repo**: `cmpetersen5551/sonarr-utils` (private or public)
2. **Technology stack**:
   - `.NET 9` (or latest LTS)
   - `WorkerService` / `IHostedService` for graceful shutdown
   - `Serilog` for structured logging to stdout
   - `HttpClient` factory pattern for Sonarr/Radarr API calls
   - `IOptions<SonarrSettings>` for config injection

3. **Project structure**:
   ```
   sonarr-utils/
   ├── .github/workflows/
   │   ├── build-push-ghcr.yml         # Build + publish to GHCR on release
   │   └── renovate.json               # Auto-update deps
   ├── src/
   │   ├── SonarrUtils/
   │   │   ├── Program.cs              # DI setup, IHostedService
   │   │   ├── Services/
   │   │   │   ├── SonarrClient.cs     # API wrapper
   │   │   │   ├── RadarrClient.cs     # API wrapper
   │   │   │   └── RootFolderManager.cs # Business logic
   │   │   ├── Models/
   │   │   │   ├── SonarrSettings.cs
   │   │   │   └── RootFolder.cs
   │   │   └── Dockerfile
   │   └── SonarrUtils.Tests/
   ├── .dockerignore
   ├── Dockerfile
   ├── sonarr-utils.sln
   └── README.md
   ```

4. **Dockerfile** (multi-stage):
   ```dockerfile
   FROM mcr.microsoft.com/dotnet/sdk:9.0 AS builder
   WORKDIR /build
   COPY . .
   RUN dotnet publish -c Release -o /app

   FROM mcr.microsoft.com/dotnet/runtime:9.0
   WORKDIR /app
   COPY --from=builder /app .
   ENTRYPOINT ["./SonarrUtils"]
   ```

5. **GitHub Actions workflow** — on release tag:
   - Build multi-arch images (linux/amd64, linux/arm64)
   - Push to GHCR: `ghcr.io/cmpetersen5551/sonarr-utils:v1.0.0`
   - Tag as `:latest`

### 4.2 Business Logic: Root Folder + Tag Manager

**Purpose**: Utility to bulk-update Sonarr/Radarr root folders and tags.

**Example commands**:
```bash
# List all root folders in Sonarr
sonarr-utils list-root-folders --sonarr-url http://sonarr:8989 --api-key <key>

# Tag all series in a root folder
sonarr-utils tag-series \
  --sonarr-url http://sonarr:8989 \
  --api-key <key> \
  --root-folder /mnt/tv \
  --tag "4k-only"

# Move series from one root folder to another
sonarr-utils migrate-root-folder \
  --sonarr-url http://sonarr:8989 \
  --api-key <key> \
  --from /mnt/tv \
  --to /mnt/tv-4k \
  --tag "4k-only"
```

**Implementation approach**:
- Bare minimum: list, tag (no actual move, to avoid breaking things)
- Advanced: dry-run mode → actual execution
- Logging: every operation logged with structured Serilog output

### 4.3 Deploy to K8s

**K8s manifests** (in GitOps repo):
1. `clusters/homelab/apps/media/sonarr-utils/`
   - `namespace.yaml` (or reuse `media` namespace)
   - `kustomization.yaml`
   - `cronjob.yaml` — example CronJob (e.g., daily tag sync)
   - `secret.yaml` (SOPS-encrypted)
     - `SONARR_API_KEY`
     - `SONARR_URL`
     - `RADARR_API_KEY`
     - `RADARR_URL`

2. **CronJob example**:
   ```yaml
   apiVersion: batch/v1
   kind: CronJob
   metadata:
     name: sonarr-utils-sync-tags
   spec:
     schedule: "0 2 * * *"  # Daily 2 AM
     jobTemplate:
       spec:
         template:
           spec:
             containers:
             - name: sonarr-utils
               image: ghcr.io/cmpetersen5551/sonarr-utils:latest
               args: ["tag-sync", "--dry-run"]
               env:
               - name: SONARR_API_KEY
                 valueFrom:
                   secretKeyRef:
                     name: sonarr-utils-secrets
                     key: api-key
               - name: SONARR_URL
                 value: http://sonarr:8989
             restartPolicy: OnFailure
   ```

**Logs**:
- Captured by Loki (Promtail scrapes pod logs)
- Visible in Grafana under `SonarrUtils` app
- Query: `{pod="sonarr-utils-sync-tags-*"}` in Loki

**Verification**:
- Deploy CronJob → wait for next scheduled run (or manually trigger `Job`)
- Check `kubectl logs pod/sonarr-utils-sync-tags-xxxxx`
- Verify logs appear in Loki/Grafana

**Effort**: ~8–12 hours (C# development + testing + integration).

---

## Phase 5: Live TV Stack (Weeks 6–8)

### 5.1 Channels DVR

**Container**: `fancybits/channels-dvr`  
**Port**: 8089  
**Storage**:
- Config: Longhorn RWO, 20Gi, `config-channels-dvr`
- Recordings: existing `pvc-media-nfs` (Unraid, RWX)

**Manifests**:
- `clusters/homelab/apps/media/channels-dvr/`
  - `namespace.yaml` (reuse `media`)
  - `kustomization.yaml`
  - `pvc-config.yaml` (Longhorn RWO, 20Gi)
  - `statefulset.yaml`
  - `service.yaml` (ClusterIP)
  - `service-headless.yaml`
  - `ingress.yaml` (Traefik, `channels.homelab`)

**StatefulSet key details**:
- Affinity: `preferredDuringScheduling` + `required` for w1/w2 (follow `sonarr` pattern from `clusters/homelab/apps/media/sonarr/statefulset.yaml`)
- Volume mounts:
  - `/opt/channels` → `config-channels-dvr` PVC
  - `/mnt/recordings` → `pvc-media-nfs` (mount path for DVR recordings)
- Resource requests: 2 CPU, 4Gi RAM (conservative; adjust after first run)

### 5.2 pluto-for-channels

**Container**: `jonmaddox/pluto-for-channels`  
**Port**: 8080  
**Storage**: Stateless (no PVC needed)
**Secrets**: `PLUTO_USERNAME`, `PLUTO_PASSWORD` (SOPS-encrypted secret)

**Manifests**:
- `clusters/homelab/apps/media/pluto-for-channels/`
  - `kustomization.yaml`
  - `deployment.yaml` (lightweight, no affinity needed)
  - `service.yaml` (ClusterIP)
  - `ingress.yaml` (Traefik, `pluto.homelab`)
  - `secret.yaml` (SOPS-encrypted)

**Environment variables**:
- `PLUTO_USERNAME` → from secret
- `PLUTO_PASSWORD` → from secret
- `START=10000` (channel numbering)

### 5.3 EPlusTV

**Container**: `tonywagner/eplustv`  
**Port**: 8000  
**Storage**: Longhorn RWO, 5Gi, `config-eplustv`
**Secrets**: Sports provider credentials (ESPN+, FloSports, etc. — user defines)

**Manifests**:
- `clusters/homelab/apps/media/eplustv/`
  - `kustomization.yaml`
  - `pvc-config.yaml` (Longhorn RWO, 5Gi)
  - `deployment.yaml`
  - `service.yaml`
  - `ingress.yaml` (Traefik, `eplustv.homelab`)
  - `secret.yaml` (SOPS-encrypted, sports provider env vars)

### 5.4 Dispatcharr

**Container**: `ghcr.io/dispatcharr/dispatcharr` (all-in-one mode)  
**Port**: 9191  
**Storage**: Longhorn RWO, 10Gi, `data-dispatcharr`

**Manifests**:
- `clusters/homelab/apps/media/dispatcharr/`
  - `kustomization.yaml`
  - `pvc-data.yaml` (Longhorn RWO, 10Gi)
  - `deployment.yaml`
  - `service.yaml`
  - `ingress.yaml` (Traefik, `dispatcharr.homelab`)

### 5.5 Teamarr

**Container**: `ghcr.io/pharaoh-labs/teamarr`  
**Port**: 9195  
**Storage**: Longhorn RWO, 5Gi, `data-teamarr`

**Manifests**:
- `clusters/homelab/apps/media/teamarr/`
  - `kustomization.yaml`
  - `pvc-data.yaml` (Longhorn RWO, 5Gi)
  - `deployment.yaml`
  - `service.yaml`
  - `ingress.yaml` (Traefik, `teamarr.homelab`)

### 5.6 Patch: Update `media/kustomization.yaml`

Add all five new services to the base kustomize file:
```yaml
resources:
  - channels-dvr/kustomization.yaml
  - pluto-for-channels/kustomization.yaml
  - eplustv/kustomization.yaml
  - dispatcharr/kustomization.yaml
  - teamarr/kustomization.yaml
```

### 5.7 Integration: Channels DVR + Custom Channels

**Manual setup in Channels app**:
1. Open Channels DVR admin UI (`http://channels.homelab:8089`)
2. Add custom channel sources:
   - pluto-for-channels: `http://pluto-for-channels:8080/epg.xml`
   - EPlusTV: `http://eplustv:8000/xmltv.xml`
   - Dispatcharr: M3U/EPG from Dispatcharr admin UI
   - Teamarr: Sports EPG

**Backup**: Channels DVR config includes custom channel mappings; backed up nightly via Longhorn.

**Verification**:
- All 5 containers running in `media` namespace
- All services accessible via ingress routes
- Channels DVR sees custom channels from pluto-for-channels
- Recordings land on Unraid NFS (verify via `ls /mnt/recordings`)
- Loki captures all service logs

**Effort**: ~4–6 hours (manifests + testing).

---

## Delivery Order & Dependencies

```
Phase 1: Backups + Renovate
    ↓ (independent)
Phase 2: SOPS
    ↓ (BLOCKS Phases 4 & 5)
Phase 3: Monitoring (in parallel with Phase 2)
    ↓
Phase 4: C# app platform (depends on SOPS + Monitoring)
    ↓ (independent after Phase 2 & 3)
Phase 5: Live TV stack (depends on SOPS, benefits from Monitoring)
```

**Parallelizable**:
- Phase 1 + Phase 2 + Phase 3 can overlap
- Phase 4 and Phase 5 can run in parallel after Phase 2 completes

---

## Timeline Estimate

| Phase | Effort | Slack | Total |
|-------|--------|-------|-------|
| 1: Backups | 0.5 h | 0.5 h | **1 h** |
| 1: Renovate | 0.75 h | 0.25 h | **1 h** |
| 2: SOPS + age | 1.5 h | 0.5 h | **2 h** |
| 3: Monitoring | 2.5 h | 1 h | **3.5 h** |
| 4: C# app setup + first app | 10 h | 2–4 h | **12–14 h** |
| 5: Live TV (5 services) | 5 h | 1–2 h | **6–8 h** |
| **Total** | ~20 h | ~5 h | **~25 h (3–4 weeks part-time)** |

---

## Summary

1. **Backups + Renovate** (Week 1): Fast wins, no dependencies
2. **SOPS** (Week 2): Unlocks credentials handling
3. **Monitoring** (Week 2–3): Observability for everything that follows
4. **C# platform** (Weeks 4–6): Invest in tooling, reusable pattern
5. **Live TV** (Weeks 6–8): Deploy 5 services, integrate with Channels DVR

Each phase is scoped, has clear verification steps, and leaves the system in a healthy state.

