# GitOps Repository Foundation Review

**Review Date:** January 15, 2026  
**Cluster Type:** k3s homelab (Proxmox + Unraid)  
**GitOps Tool:** Flux v2  
**Current State:** Single Sonarr application with HA failover

---

## Executive Summary

Your GitOps foundation is **solid** with excellent architectural decisions. The repository structure, documentation, and dependency management are exemplary. However, there are critical security gaps and operational improvements needed before scaling to additional services.

**Key Strengths:**
- ✅ Well-structured repository with clear separation of concerns
- ✅ Comprehensive documentation (Architecture, Hardware, Operations)
- ✅ Proper dependency chains in Flux Kustomizations
- ✅ Innovative VolSync HA pattern with static PVs
- ✅ Validation script prevents common errors

**Priority Improvements Needed:**
- 🔴 No secrets management (critical security gap)
- 🔴 Missing `.gitignore` (risk of exposing sensitive data)
- 🟡 MetalLB webhook secret requires manual bootstrap
- 🟡 No backup strategy beyond VolSync replication
- 🟡 Missing observability/monitoring stack

---

## 🔴 CRITICAL (Must Fix Before Adding Services)

### 1. **Secrets Management - No Encryption in Place**

**Issue:** No secrets encryption solution implemented. All secrets would be stored in plain text if added to Git.

**Risk:** Credentials, API tokens, SSH keys exposed in version control history forever.

**Current State:**
```bash
# No secrets found currently, but infrastructure is missing:
$ grep -r "kind: Secret" clusters/
# Only RBAC references, no actual secrets
```

**Recommendation:** Implement Mozilla SOPS with age encryption (Flux native)

**Action Items:**
- [ ] Install `age` CLI tool: `brew install age`
- [ ] Generate age key pair: `age-keygen -o age.key`
- [ ] Store private key securely (1Password, local encrypted storage)
- [ ] Create Kubernetes secret with age key:
  ```bash
  cat age.key | kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=/dev/stdin
  ```
- [ ] Add SOPS configuration to repository:
  ```yaml
  # .sops.yaml (create in repo root)
  creation_rules:
    - path_regex: .*.yaml
      encrypted_regex: ^(data|stringData)$
      age: <your-age-public-key>
  ```
- [ ] Update Flux Kustomization with decryption:
  ```yaml
  # clusters/homelab/cluster/apps-kustomization.yaml
  spec:
    decryption:
      provider: sops
      secretRef:
        name: sops-age
  ```
- [ ] Test with sample secret:
  ```bash
  # Create test secret
  kubectl create secret generic test-secret --from-literal=password=mysecret --dry-run=client -o yaml > secret.yaml
  # Encrypt
  sops --encrypt --in-place secret.yaml
  # Verify encrypted fields
  cat secret.yaml  # Should show encrypted data
  ```

**Estimated Time:** 2 hours  
**References:** 
- [Flux SOPS Guide](https://fluxcd.io/flux/guides/mozilla-sops/)
- [Age Encryption](https://github.com/FiloSottile/age)

---

### 2. **Missing .gitignore - Risk of Committing Secrets**

**Issue:** No `.gitignore` file at repository root. Easy to accidentally commit secrets, local configs, or sensitive data.

**Risk:** Accidentally pushing unencrypted secrets, temporary files with credentials, local test data.

**Current State:**
```bash
$ ls -la .gitignore
ls: .gitignore: No such file or directory
```

**Recommendation:** Create comprehensive `.gitignore` immediately

**Action Items:**
- [ ] Create `.gitignore` in repository root:
  ```gitignore
  # Secrets and sensitive data
  *.key
  *.pem
  *.p12
  *.pfx
  age.key
  age.txt
  sops.yaml
  secret-*.yaml
  *-secret.yaml
  .sops.yaml.local
  
  # Flux bootstrap (contains sensitive repo details)
  # Note: We keep flux-system/ but be careful with it
  
  # Kustomize temporary builds
  kustomization-*.yaml
  
  # Editor and IDE
  .vscode/
  .idea/
  *.swp
  *.swo
  *~
  .DS_Store
  
  # Temporary validation outputs
  /tmp/
  *.tmp
  
  # Local testing
  test-*.yaml
  local-*.yaml
  
  # Terraform state (if used later)
  *.tfstate
  *.tfstate.backup
  .terraform/
  
  # kubeconfig files (if stored locally)
  kubeconfig*
  *.kubeconfig
  
  # Backup files
  *.bak
  *.backup
  
  # Python/script artifacts
  __pycache__/
  *.pyc
  .pytest_cache/
  venv/
  .env
  ```

**Estimated Time:** 15 minutes

---

### 3. **MetalLB Webhook Secret Requires Manual Bootstrap**

**Issue:** MetalLB controller crashes without manually created TLS secret, even in L2 mode where webhooks aren't used. Documented in [OPERATIONS.md](clusters/homelab/docs/OPERATIONS.md) but not automated.

**Risk:** New cluster deployments fail. Bootstrap process requires manual intervention. Not truly "cluster from Git".

**Current State:**
- Manual secret creation documented in troubleshooting section
- Secret not stored in Git (correct for TLS cert, but breaks GitOps)
- Every new cluster deployment requires manual step

**Recommendation:** Implement one of two solutions:

**Option A: Use Flux to Generate Cert (Recommended)**
```yaml
# clusters/homelab/infrastructure/metallb/webhook-cert-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: metallb-webhook-cert-bootstrap
  namespace: metallb-system
  annotations:
    argocd.argoproj.io/hook: PreSync
    helm.sh/hook: pre-install
spec:
  template:
    spec:
      serviceAccountName: metallb-webhook-cert-generator
      restartPolicy: OnFailure
      containers:
      - name: cert-generator
        image: registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.4.1
        imagePullPolicy: IfNotPresent
        args:
          - create
          - --host=webhook.metallb-system.svc,webhook.metallb-system.svc.cluster.local
          - --namespace=metallb-system
          - --secret-name=webhook-server-cert
          - --cert-name=tls.crt
          - --key-name=tls.key
```

**Option B: Use cert-manager (If you plan to add it)**
```yaml
# clusters/homelab/infrastructure/metallb/webhook-cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: webhook-server-cert
  namespace: metallb-system
spec:
  secretName: webhook-server-cert
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  dnsNames:
    - webhook.metallb-system.svc
    - webhook.metallb-system.svc.cluster.local
```

**Action Items:**
- [ ] Choose solution (Option A for simplicity, Option B if adding cert-manager)
- [ ] Implement chosen solution
- [ ] Add RBAC for cert generation job (Option A)
- [ ] Update dependency: `infrastructure-metallb` should depend on cert job/issuer
- [ ] Test fresh cluster deployment without manual intervention
- [ ] Update [OPERATIONS.md](clusters/homelab/docs/OPERATIONS.md) to remove manual step

**Estimated Time:** 3-4 hours (includes testing)

---

### 4. **No Backup Strategy Beyond VolSync**

**Issue:** VolSync only protects PV data between nodes. No cluster state backup (etcd), no PV external backup, no disaster recovery beyond "redeploy from Git + manual data restore".

**Risk:**
- Catastrophic failure (both nodes down) = complete data loss
- Accidental deletion of PVC = data gone
- Cluster corruption = lengthy manual recovery
- Configuration drift not captured in Git

**Current State:**
```yaml
# Only VolSync for PV replication between nodes
# No external backups
# No etcd snapshots
# No Velero or similar
```

**Recommendation:** Implement multi-layer backup strategy

**Action Items:**

**Layer 1: etcd Snapshots (Control Plane)**
- [ ] Configure k3s automatic etcd snapshots:
  ```bash
  # On k3s-cp1, add to k3s service config
  --etcd-snapshot-schedule-cron="0 */6 * * *"  # Every 6 hours
  --etcd-snapshot-retention=14                  # Keep 14 snapshots
  --etcd-snapshot-dir=/var/lib/rancher/k3s/server/db/snapshots
  ```
- [ ] Sync snapshots to NFS: `rsync -av /var/lib/rancher/k3s/server/db/snapshots/ /mnt/backups/etcd/`
- [ ] Document etcd restore procedure in [OPERATIONS.md](clusters/homelab/docs/OPERATIONS.md)

**Layer 2: Velero for Kubernetes Resources + PV Data (Recommended)**
- [ ] Deploy Velero with restic for PV backups
- [ ] Configure backup to Unraid NFS or S3-compatible storage (MinIO on Unraid?)
- [ ] Schedule daily backups:
  ```yaml
  # clusters/homelab/operations/velero/
  apiVersion: velero.io/v1
  kind: Schedule
  metadata:
    name: daily-backup
    namespace: velero
  spec:
    schedule: "0 2 * * *"  # 2 AM daily
    template:
      includedNamespaces:
        - "*"
      defaultVolumesToFsBackup: true
  ```
- [ ] Test restore procedure quarterly

**Layer 3: Git History Protection**
- [ ] Enable GitHub branch protection on `main`
- [ ] Require pull request reviews for critical paths
- [ ] Configure GitHub repository backup (download archive weekly)

**Estimated Time:** 1-2 days (includes testing)  
**Priority:** Implement before adding more stateful applications

---

### 5. **No `.sops.yaml` Configuration**

**Issue:** Related to #1. Even if SOPS is installed later, no configuration file means inconsistent encryption.

**Risk:** Some secrets encrypted with different keys, others missed entirely.

**Action Items:**
- [ ] Create `.sops.yaml` in repository root (see #1 above)
- [ ] Add to Git: `git add .sops.yaml && git commit -m "Add SOPS encryption config"`
- [ ] Document key rotation procedure

**Estimated Time:** 30 minutes (part of #1)

---

## 🟡 HIGH PRIORITY (Needed for Production Readiness)

### 6. **No Observability Stack**

**Issue:** Monitoring relies on manual `kubectl` and `flux` CLI commands. No centralized metrics, logs, or alerting.

**Current Gaps:**
- No Prometheus for metrics collection
- No Grafana for visualization
- No AlertManager for notifications
- No log aggregation (Loki)
- No distributed tracing
- No SLO/SLA tracking

**Recommendation:** Deploy lightweight observability stack

**Action Items:**

**Phase 1: Metrics (1-2 days)**
- [ ] Deploy kube-prometheus-stack (Prometheus + Grafana + AlertManager)
  ```yaml
  # clusters/homelab/infrastructure/monitoring/
  # Use Helm chart via HelmRelease CRD
  ```
- [ ] Configure ServiceMonitors for:
  - [ ] Flux controllers
  - [ ] MetalLB
  - [ ] Traefik
  - [ ] VolSync
  - [ ] Node metrics (node-exporter)
  - [ ] Application metrics (Sonarr, future apps)

**Phase 2: Logs (1 day)**
- [ ] Deploy Loki for log aggregation
- [ ] Deploy Promtail on all nodes
- [ ] Configure log retention (7-14 days for homelab)

**Phase 3: Alerts (1 day)**
- [ ] Configure AlertManager
- [ ] Define critical alerts:
  - Node down
  - Flux reconciliation failures
  - PVC nearly full
  - VolSync replication lag
  - Pod crash loops
- [ ] Integrate with notification channel (Discord, Slack, email)

**Phase 4: Dashboards (2 days)**
- [ ] Import standard Grafana dashboards
- [ ] Create custom dashboards for:
  - [ ] Cluster overview
  - [ ] Flux reconciliation status
  - [ ] VolSync replication health
  - [ ] Application health (per namespace)

**Estimated Time:** 1 week total  
**Storage Impact:** ~20-50GB for metrics/logs (configure retention)

---

### 7. **Flux Notification Controller Not Configured**

**Issue:** No automated notifications for Flux events. Only manual monitoring via `flux events`.

**Risk:** Reconciliation failures go unnoticed. Deployment issues discovered late.

**Current State:**
```bash
$ kubectl get providers -n flux-system
No resources found.
```

**Recommendation:** Configure Flux notifications

**Action Items:**
- [ ] Create notification provider (Discord/Slack):
  ```yaml
  # clusters/homelab/infrastructure/notifications/discord-provider.yaml
  apiVersion: notification.toolkit.fluxcd.io/v1beta3
  kind: Provider
  metadata:
    name: discord
    namespace: flux-system
  spec:
    type: discord
    address: <webhook-url-from-sops-secret>
    secretRef:
      name: discord-webhook
  ```
- [ ] Create alerts for critical Kustomizations:
  ```yaml
  # clusters/homelab/infrastructure/notifications/critical-alerts.yaml
  apiVersion: notification.toolkit.fluxcd.io/v1beta3
  kind: Alert
  metadata:
    name: critical-infrastructure
    namespace: flux-system
  spec:
    providerRef:
      name: discord
    eventSeverity: error
    eventSources:
      - kind: Kustomization
        name: 'infrastructure-*'
      - kind: GitRepository
        name: flux-system
    suspend: false
  ```
- [ ] Test notifications with intentional error
- [ ] Document notification channels in [OPERATIONS.md](clusters/homelab/docs/OPERATIONS.md)

**Estimated Time:** 2-3 hours

---

### 8. **Missing Resource Requests/Limits on Infrastructure**

**Issue:** Some infrastructure components lack resource requests/limits, risking resource contention and OOM kills.

**Current State:**
```yaml
# VolSync controller has `resources: {}` (empty)
# MetalLB controller/speaker have limits but minimal requests
```

**Recommendation:** Set appropriate resource limits

**Action Items:**
- [ ] Add resource requests to VolSync:
  ```yaml
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
  ```
- [ ] Review and adjust MetalLB resources based on actual usage
- [ ] Set resource quotas per namespace:
  ```yaml
  # clusters/homelab/apps/media/resourcequota.yaml
  apiVersion: v1
  kind: ResourceQuota
  metadata:
    name: media-quota
    namespace: media
  spec:
    hard:
      requests.cpu: "4"
      requests.memory: 8Gi
      limits.cpu: "8"
      limits.memory: 16Gi
      persistentvolumeclaims: "10"
  ```
- [ ] Document resource allocation in [HARDWARE.md](clusters/homelab/docs/HARDWARE.md)

**Estimated Time:** 3-4 hours

---

### 9. **No PodDisruptionBudgets (PDBs)**

**Issue:** No PDBs defined. During voluntary disruptions (node drain, upgrades), all pods can be evicted simultaneously.

**Risk:** Service downtime during maintenance. Traefik downtime = no ingress access.

**Recommendation:** Add PDBs for critical services

**Action Items:**
- [ ] Add PDB for Traefik:
  ```yaml
  # clusters/homelab/infrastructure/traefik/pdb.yaml
  apiVersion: policy/v1
  kind: PodDisruptionBudget
  metadata:
    name: traefik
    namespace: kube-system
  spec:
    minAvailable: 1
    selector:
      matchLabels:
        app.kubernetes.io/name: traefik
  ```
- [ ] Add PDB for MetalLB speaker:
  ```yaml
  # clusters/homelab/infrastructure/metallb/pdb.yaml
  apiVersion: policy/v1
  kind: PodDisruptionBudget
  metadata:
    name: speaker
    namespace: metallb-system
  spec:
    maxUnavailable: 1
    selector:
      matchLabels:
        component: speaker
  ```
- [ ] Add PDBs for future HA applications

**Estimated Time:** 1-2 hours

---

### 10. **No NetworkPolicies (Security)**

**Issue:** Default Kubernetes network policy is allow-all. Any pod can talk to any pod.

**Risk:** 
- Compromised application pod can access all cluster services
- No network segmentation between namespaces
- No defense-in-depth

**Recommendation:** Implement namespace-level network policies

**Action Items:**
- [ ] Create default deny-all policy per namespace:
  ```yaml
  # clusters/homelab/apps/media/network-policy.yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: default-deny-all
    namespace: media
  spec:
    podSelector: {}
    policyTypes:
      - Ingress
      - Egress
  ```
- [ ] Create allow policies for legitimate traffic:
  ```yaml
  # Allow Traefik ingress
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: allow-traefik-ingress
    namespace: media
  spec:
    podSelector:
      matchLabels:
        app: sonarr
    policyTypes:
      - Ingress
    ingress:
      - from:
          - namespaceSelector:
              matchLabels:
                name: kube-system
            podSelector:
              matchLabels:
                app.kubernetes.io/name: traefik
        ports:
          - protocol: TCP
            port: 8989
  ```
- [ ] Allow DNS egress (all pods need this):
  ```yaml
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: allow-dns-egress
    namespace: media
  spec:
    podSelector: {}
    policyTypes:
      - Egress
    egress:
      - to:
          - namespaceSelector:
              matchLabels:
                name: kube-system
        ports:
          - protocol: UDP
            port: 53
  ```
- [ ] Test connectivity after applying policies

**Estimated Time:** 1 day (includes testing)  
**Impact:** May break existing connectivity - test thoroughly

---

## 🟢 MEDIUM PRIORITY (Operational Improvements)

### 11. **Hardcoded Image Tags Without Update Automation**

**Issue:** Image tags are hardcoded (e.g., `linuxserver/sonarr:4.0.16`, `traefik:v3.0.1`). No automation for updates.

**Current State:**
```yaml
# Sonarr
image: linuxserver/sonarr:4.0.16

# Traefik
image: traefik:v3.0.1

# VolSync
image: quay.io/backube/volsync:0.14.0
```

**Options:**

**Option A: Manual Updates (Current, Acceptable for Homelab)**
- Pros: Full control, stable versions
- Cons: Requires manual monitoring, easy to forget

**Option B: Flux Image Automation (Recommended for Production)**
- Pros: Automated scanning, automatic PRs for updates
- Cons: Adds complexity, may auto-update to breaking versions

**Option C: Renovate Bot (Alternative)**
- Pros: Comprehensive dependency updates (not just images)
- Cons: Requires GitHub integration

**Recommendation:** Implement Flux Image Automation with careful semver policies

**Action Items:**
- [ ] Deploy Flux image-reflector-controller and image-automation-controller
- [ ] Create ImageRepository resources:
  ```yaml
  # clusters/homelab/infrastructure/image-automation/sonarr-image.yaml
  apiVersion: image.toolkit.fluxcd.io/v1beta2
  kind: ImageRepository
  metadata:
    name: sonarr
    namespace: flux-system
  spec:
    image: linuxserver/sonarr
    interval: 1h
  ```
- [ ] Create ImagePolicy with semver filter:
  ```yaml
  apiVersion: image.toolkit.fluxcd.io/v1beta2
  kind: ImagePolicy
  metadata:
    name: sonarr
    namespace: flux-system
  spec:
    imageRepositoryRef:
      name: sonarr
    policy:
      semver:
        range: 4.0.x  # Only patch updates
  ```
- [ ] Enable ImageUpdateAutomation to create PRs:
  ```yaml
  apiVersion: image.toolkit.fluxcd.io/v1beta2
  kind: ImageUpdateAutomation
  metadata:
    name: flux-system
    namespace: flux-system
  spec:
    git:
      checkout:
        ref:
          branch: main
      commit:
        author:
          email: fluxcdbot@users.noreply.github.com
          name: fluxcdbot
        messageTemplate: 'chore: update image {{range .Updated.Images}}{{println .}}{{end}}'
      push:
        branch: image-updates
    sourceRef:
      kind: GitRepository
      name: flux-system
    update:
      path: ./clusters/homelab
      strategy: Setters
  ```
- [ ] Add image policy markers to deployments:
  ```yaml
  spec:
    containers:
      - name: sonarr
        image: linuxserver/sonarr:4.0.16  # {"$imagepolicy": "flux-system:sonarr"}
  ```

**Estimated Time:** 4-6 hours  
**Decision:** Can defer if manual updates acceptable for homelab

---

### 12. **Inconsistent Flux Reconciliation Intervals**

**Issue:** Flux Kustomizations have varying intervals (1m, 10m). Root Kustomization uses 10m, but most use 1m.

**Current State:**
```yaml
# flux-system (root): interval: 10m
# infrastructure-*: interval: 1m
# apps: interval: 1m
```

**Recommendation:** Standardize intervals based on change frequency

**Action Items:**
- [ ] Update root Kustomization to 1m for consistency:
  ```yaml
  # clusters/homelab/flux-system/gotk-sync.yaml
  spec:
    interval: 1m0s  # Change from 10m0s
  ```
- [ ] Consider increasing infrastructure intervals to 5m (changes less frequent):
  ```yaml
  # Less critical infrastructure
  spec:
    interval: 5m
  ```
- [ ] Keep apps at 1m (fast feedback for app updates)
- [ ] Document interval strategy in [ARCHITECTURE.md](clusters/homelab/docs/ARCHITECTURE.md)

**Rationale:**
- 1m: Acceptable for homelab, quick feedback
- 5m: Reduces API load for stable infrastructure
- 10m: Too slow for iterative development

**Estimated Time:** 30 minutes

---

### 13. **Missing `retryInterval` on Flux Kustomizations**

**Issue:** No `retryInterval` configured. Flux waits for full `interval` before retrying after failure.

**Impact:** Failed reconciliation waits 1-10 minutes before retry. Slows recovery.

**Recommendation:** Add `retryInterval: 30s` to all Kustomizations

**Action Items:**
- [ ] Update all Flux Kustomizations in [clusters/homelab/cluster/](clusters/homelab/cluster/):
  ```yaml
  spec:
    interval: 1m
    retryInterval: 30s  # Add this
    timeout: 3m
  ```

**Estimated Time:** 15 minutes

---

### 14. **No Health Checks on Flux Kustomizations**

**Issue:** Some Kustomizations may not have proper health checks (`wait: true` is set, but timeout may be too short).

**Current State:**
```yaml
# Most have:
wait: true
timeout: 2m  # May be too short for some resources
```

**Recommendation:** Review and adjust timeouts

**Action Items:**
- [ ] Increase timeout for MetalLB and Traefik (LoadBalancer provisioning is slow):
  ```yaml
  # infrastructure-metallb.yaml
  spec:
    timeout: 5m  # Already set, good
  
  # infrastructure-traefik.yaml  
  spec:
    timeout: 5m  # Already set, good
  ```
- [ ] Consider adding `healthChecks` for critical resources:
  ```yaml
  spec:
    healthChecks:
      - apiVersion: apps/v1
        kind: Deployment
        name: controller
        namespace: metallb-system
  ```

**Estimated Time:** 1-2 hours

---

### 15. **VolSync ReplicationSource Missing Peer Configuration**

**Issue:** [volsync.yaml](clusters/homelab/apps/media/sonarr/volsync.yaml) has commented-out peer configuration. Manual setup required after deployment.

**Current State:**
```yaml
# peers:
# - ID: <backup-syncthing-id>
#   address: tcp://<backup-service-address>:22000
```

**Recommendation:** Automate peer discovery or document post-deployment steps

**Action Items:**

**Option A: Post-Install Job (Recommended)**
- [ ] Create job that queries Syncthing IDs and patches ReplicationSources
- [ ] Run as Flux PostBuild hook

**Option B: Manual Documentation (Current)**
- [ ] Document peer configuration steps in [OPERATIONS.md](clusters/homelab/docs/OPERATIONS.md)
- [ ] Add to "Common Tasks" → "Adding HA Application"

**Option C: Use VolSync Syncthing Auto-Discovery (If Supported)**
- [ ] Research if VolSync supports automatic peer discovery
- [ ] Implement if available

**Estimated Time:** 3-4 hours (Option A), 30 min (Option B)

---

### 16. **No Pod Security Standards/Policies**

**Issue:** No Pod Security Standards (PSS) or Pod Security Policies (deprecated) enforced. Pods can run privileged, use host network, etc.

**Risk:** 
- Malicious or compromised pod can escalate privileges
- Accidental misconfiguration allows dangerous permissions

**Recommendation:** Implement Pod Security Standards (PSS)

**Action Items:**
- [ ] Enable PSS at namespace level:
  ```yaml
  # clusters/homelab/apps/media/namespace.yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: media
    labels:
      pod-security.kubernetes.io/enforce: restricted
      pod-security.kubernetes.io/audit: restricted
      pod-security.kubernetes.io/warn: restricted
  ```
- [ ] Adjust application deployments to comply with `restricted` PSS:
  - Remove `privileged: true`
  - Set `runAsNonRoot: true`
  - Drop all capabilities
  - Set read-only root filesystem where possible
- [ ] Exception for infrastructure (metallb-speaker needs `NET_RAW`):
  ```yaml
  # clusters/homelab/infrastructure/metallb/namespace.yaml
  metadata:
    labels:
      pod-security.kubernetes.io/enforce: baseline  # More permissive
  ```

**Estimated Time:** 1 day (includes fixing non-compliant pods)

---

### 17. **Traefik Dashboard Disabled**

**Issue:** Traefik dashboard is disabled (`--api.dashboard=false`). No visibility into routing rules, middleware, or request metrics.

**Current State:**
```yaml
args:
  - "--api.dashboard=false"
  - "--api.insecure=true"  # Insecure but dashboard disabled anyway
```

**Recommendation:** Enable dashboard with authentication

**Action Items:**
- [ ] Enable dashboard in [deployment.yaml](clusters/homelab/infrastructure/traefik/deployment.yaml):
  ```yaml
  args:
    - "--api.dashboard=true"
    - "--api.insecure=false"  # Secure it
  ```
- [ ] Create Ingress with BasicAuth:
  ```yaml
  # clusters/homelab/infrastructure/traefik/dashboard-ingress.yaml
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: traefik-dashboard
    namespace: kube-system
    annotations:
      traefik.ingress.kubernetes.io/router.middlewares: kube-system-basic-auth@kubernetescrd
  spec:
    rules:
      - host: traefik.homelab
        http:
          paths:
            - path: /
              pathType: Prefix
              backend:
                service:
                  name: traefik
                  port:
                    number: 9000
  ```
- [ ] Create BasicAuth middleware (credentials from SOPS):
  ```yaml
  apiVersion: traefik.containo.us/v1alpha1
  kind: Middleware
  metadata:
    name: basic-auth
    namespace: kube-system
  spec:
    basicAuth:
      secret: traefik-dashboard-auth
  ```

**Estimated Time:** 1-2 hours

---

### 18. **No LimitRanges in Namespaces**

**Issue:** No default resource limits. Pods can request unbounded CPU/memory, potentially starving other pods.

**Risk:** Single runaway pod can consume all node resources.

**Recommendation:** Set namespace-level LimitRanges

**Action Items:**
- [ ] Create LimitRange for media namespace:
  ```yaml
  # clusters/homelab/apps/media/limitrange.yaml
  apiVersion: v1
  kind: LimitRange
  metadata:
    name: media-limits
    namespace: media
  spec:
    limits:
      - max:
          cpu: "4"
          memory: 8Gi
        min:
          cpu: 50m
          memory: 64Mi
        default:
          cpu: 500m
          memory: 512Mi
        defaultRequest:
          cpu: 100m
          memory: 256Mi
        type: Container
      - max:
          storage: 100Gi
        min:
          storage: 1Gi
        type: PersistentVolumeClaim
  ```
- [ ] Apply to all namespaces

**Estimated Time:** 1-2 hours

---

## 🔵 LOW PRIORITY (Nice to Have)

### 19. **No Pre-Commit Hooks**

**Issue:** Validation script exists but isn't enforced. Easy to forget to run before committing.

**Recommendation:** Add pre-commit hook

**Action Items:**
- [ ] Install pre-commit framework: `brew install pre-commit`
- [ ] Create `.pre-commit-config.yaml`:
  ```yaml
  repos:
    - repo: local
      hooks:
        - id: gitops-validate
          name: GitOps Validation
          entry: ./scripts/validate/validate
          language: script
          pass_filenames: false
          always_run: true
  ```
- [ ] Install hook: `pre-commit install`
- [ ] Test with intentional error

**Estimated Time:** 30 minutes

---

### 20. **Flux Controllers Not HA**

**Issue:** Flux controllers run with single replica. Control plane failure stops GitOps reconciliation.

**Current State:**
```yaml
# flux-system/gotk-components.yaml
# All controllers have replicas: 1
```

**Impact:** Low (homelab single control-plane anyway). Future concern with HA control plane.

**Recommendation:** Defer until HA control plane implemented

**Action Items:**
- [ ] When adding HA control plane, update Flux controllers:
  ```yaml
  # Create clusters/homelab/infrastructure/flux-ha/
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: kustomize-controller
    namespace: flux-system
  spec:
    replicas: 2  # Change from 1
    # ... add leader election settings
  ```

**Estimated Time:** 2-3 hours  
**Priority:** Defer until control plane HA exists

---

### 21. **Missing Operations Directory in Repository**

**Issue:** [ARCHITECTURE.md](clusters/homelab/docs/ARCHITECTURE.md) mentions `operations/volsync-failover/` directory, but it doesn't exist in current structure.

**Current State:**
```bash
$ ls clusters/homelab/operations/
ls: clusters/homelab/operations/: No such file or directory
```

**Recommendation:** Create operations directory with failover monitoring

**Action Items:**
- [ ] Create directory: `mkdir -p clusters/homelab/operations/volsync-failover`
- [ ] Move failover scripts or create monitoring deployment
- [ ] Create Flux Kustomization:
  ```yaml
  # clusters/homelab/cluster/operations-kustomization.yaml
  apiVersion: kustomize.toolkit.fluxcd.io/v1
  kind: Kustomization
  metadata:
    name: operations
    namespace: flux-system
  spec:
    interval: 1m
    path: ./clusters/homelab/operations
    prune: true
    wait: true
    timeout: 3m
    dependsOn:
      - name: infrastructure-storage
    sourceRef:
      kind: GitRepository
      name: flux-system
  ```
- [ ] Update root kustomization to include operations layer

**Estimated Time:** 2-3 hours

---

### 22. **No Renovate Bot or Dependabot**

**Issue:** No automated dependency updates for Kubernetes manifests, Helm charts (future), or GitHub Actions (if added).

**Recommendation:** Add Renovate Bot for comprehensive dependency management

**Action Items:**
- [ ] Enable Renovate on GitHub repository
- [ ] Configure `renovate.json`:
  ```json
  {
    "extends": ["config:base"],
    "kubernetes": {
      "fileMatch": ["clusters/.+\\.yaml$"]
    },
    "regexManagers": [
      {
        "fileMatch": ["clusters/.+\\.yaml$"],
        "matchStrings": [
          "image:\\s*(?<depName>[^:]+):(?<currentValue>[^\\s]+)"
        ],
        "datasourceTemplate": "docker"
      }
    ],
    "packageRules": [
      {
        "matchUpdateTypes": ["major"],
        "automerge": false
      },
      {
        "matchUpdateTypes": ["minor", "patch"],
        "automerge": true,
        "automergeType": "pr"
      }
    ]
  }
  ```

**Estimated Time:** 1-2 hours  
**Alternative:** Use Flux Image Automation (see #11)

---

### 23. **No CI/CD Pipeline**

**Issue:** No GitHub Actions or CI pipeline to run validation, linting, security scans on PRs.

**Recommendation:** Add basic CI pipeline

**Action Items:**
- [ ] Create `.github/workflows/validate.yaml`:
  ```yaml
  name: Validate GitOps
  on:
    pull_request:
      branches: [main]
    push:
      branches: [main]
  
  jobs:
    validate:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4
        - name: Setup tools
          run: |
            curl -s https://fluxcd.io/install.sh | sudo bash
            brew install kubectl kustomize yamllint
        - name: Run validation
          run: ./scripts/validate/validate
        - name: Security scan
          uses: aquasecurity/trivy-action@master
          with:
            scan-type: 'config'
            scan-ref: 'clusters/'
  ```

**Estimated Time:** 2-3 hours

---

### 24. **Traefik Using `v3.0.1` (Not Latest)**

**Issue:** Traefik image is pinned to `v3.0.1`. Current latest is `v3.0.4` (January 2026) with security fixes.

**Recommendation:** Update to latest v3.0.x

**Action Items:**
- [ ] Update [traefik/deployment.yaml](clusters/homelab/infrastructure/traefik/deployment.yaml):
  ```yaml
  image: traefik:v3.0.4  # or latest v3.0.x
  ```
- [ ] Test ingress functionality after update
- [ ] Review changelog for breaking changes

**Estimated Time:** 30 minutes

---

### 25. **No `.yamllint` in Repository Root**

**Issue:** Validation script uses `scripts/validate/.yamllint` but not documented or visible.

**Recommendation:** Move to repository root for visibility

**Action Items:**
- [ ] `mv scripts/validate/.yamllint .yamllint`
- [ ] Update validation script path: `yamllint -c .yamllint clusters/`
- [ ] Commit and document

**Estimated Time:** 5 minutes

---

### 26. **Documentation Could Include Troubleshooting Decision Tree**

**Issue:** [OPERATIONS.md](clusters/homelab/docs/OPERATIONS.md) has troubleshooting sections but no decision tree for common issues.

**Recommendation:** Add flowchart or decision tree

**Example Structure:**
```
Pod Not Starting?
  ├─ Status: Pending
  │  ├─ Check PVC binding
  │  └─ Check node resources
  ├─ Status: CrashLoopBackOff
  │  ├─ Check logs
  │  └─ Check liveness/readiness probes
  └─ Status: ImagePullBackOff
     └─ Check image tag exists
```

**Estimated Time:** 2-3 hours

---

### 27. **Missing Cost Tracking/Resource Utilization**

**Issue:** No visibility into resource utilization trends, capacity planning data.

**Recommendation:** Add Kubecost or similar

**Action Items:**
- [ ] Deploy Kubecost (free tier):
  ```yaml
  # clusters/homelab/infrastructure/kubecost/
  # Helm chart via HelmRelease
  ```
- [ ] Configure cost allocation by namespace
- [ ] Set up resource efficiency reports

**Estimated Time:** 3-4 hours  
**Value:** Low for homelab, high for multi-tenant clusters

---

## Architecture & Design Feedback

### ✅ Strengths

1. **Excellent Repository Structure**
   - Clear separation: `cluster/` (orchestration) vs `infrastructure/` vs `apps/`
   - Dependency hierarchy is textbook Flux best practice
   - Single source of truth maintained

2. **Outstanding Documentation**
   - [ARCHITECTURE.md](clusters/homelab/docs/ARCHITECTURE.md) explains design decisions
   - [HARDWARE.md](clusters/homelab/docs/HARDWARE.md) documents topology
   - [OPERATIONS.md](clusters/homelab/docs/OPERATIONS.md) provides runbook
   - `.copilot-instructions.md` aids AI-assisted development

3. **Innovative HA Pattern**
   - Static PVs with node affinity + VolSync replication
   - GitOps-friendly failover (edit deployment in Git)
   - No complex CSI drivers or external storage required

4. **Validation Automation**
   - Pre-commit validation script catches errors
   - Checks Kustomize builds, YAML syntax, PV/PVC matching
   - Failover configuration validation

5. **Security Conscious (Mostly)**
   - Traefik runs as non-root
   - Read-only root filesystem where possible
   - Capabilities dropped in containers
   - RBAC properly scoped (VolSync, MetalLB)

### ⚠️ Areas of Concern

1. **Security Gaps** (Critical)
   - No secrets encryption (SOPS/sealed-secrets)
   - No network policies (all traffic allowed)
   - No `.gitignore` (risk of committing secrets)
   - No Pod Security Standards enforced

2. **Operational Gaps** (High)
   - No backups beyond VolSync replication
   - No monitoring/observability stack
   - No alerting for failures
   - Manual MetalLB webhook cert bootstrap

3. **Resiliency Gaps** (Medium)
   - No PodDisruptionBudgets
   - Single-replica Flux controllers
   - Missing health checks on some Kustomizations
   - No LimitRanges or ResourceQuotas

---

## Implementation Priority Roadmap

### 🔴 Phase 1: Security Foundations (Must Do First)
**Estimated Time:** 1 week

1. Add `.gitignore` (15 min)
2. Implement SOPS with age encryption (2 hours)
3. Create `.sops.yaml` configuration (30 min)
4. Test secret encryption/decryption (1 hour)
5. Automate MetalLB webhook cert (3-4 hours)
6. Add NetworkPolicies (1 day)

**Outcome:** No more security vulnerabilities blocking service additions

---

### 🟡 Phase 2: Operational Excellence (Needed for Scale)
**Estimated Time:** 2 weeks

7. Deploy observability stack (1 week)
   - Prometheus + Grafana
   - Loki + Promtail
   - AlertManager + alerts
8. Configure Flux notifications (2-3 hours)
9. Implement backup strategy (1-2 days)
   - etcd snapshots
   - Velero deployment
   - Test restore procedure
10. Add PodDisruptionBudgets (1-2 hours)
11. Implement LimitRanges and ResourceQuotas (1-2 hours)

**Outcome:** Cluster is observable, backed up, and production-ready

---

### 🟢 Phase 3: Operational Improvements (Refine & Optimize)
**Estimated Time:** 1 week

12. Add Pod Security Standards (1 day)
13. Standardize Flux reconciliation intervals (30 min)
14. Add `retryInterval` to Kustomizations (15 min)
15. Enable Traefik dashboard with auth (1-2 hours)
16. Add resource requests to infrastructure (3-4 hours)
17. Document VolSync peer configuration (30 min)

**Outcome:** Cluster follows best practices, stable and secure

---

### 🔵 Phase 4: Developer Experience (Nice to Have)
**Estimated Time:** 1 week

18. Add pre-commit hooks (30 min)
19. Setup CI/CD pipeline (2-3 hours)
20. Implement image update automation (4-6 hours)
21. Create operations directory structure (2-3 hours)
22. Add Renovate Bot (1-2 hours)
23. Update Traefik to latest (30 min)
24. Move `.yamllint` to root (5 min)

**Outcome:** Streamlined development workflow, automated maintenance

---

## Summary Statistics

- **Critical Issues:** 5
- **High Priority:** 13
- **Medium Priority:** 8
- **Low Priority:** 8
- **Total Action Items:** 34
- **Estimated Total Time:** 6-8 weeks (if done sequentially)
- **Realistic Timeline:** 2-3 months (parallel work + testing)

---

## Final Recommendations

### Before Adding More Services:

**Must Complete (Non-Negotiable):**
1. ✅ Implement SOPS secrets management
2. ✅ Add `.gitignore` 
3. ✅ Deploy observability stack
4. ✅ Implement backup strategy
5. ✅ Automate MetalLB webhook cert

**Should Complete (Strongly Recommended):**
6. Add NetworkPolicies
7. Configure Flux notifications
8. Add PodDisruptionBudgets
9. Implement Pod Security Standards
10. Add LimitRanges and ResourceQuotas

**Can Defer (Nice to Have):**
11. Image update automation
12. CI/CD pipeline
13. Flux HA
14. Advanced monitoring (Kubecost)

---

## Conclusion

Your GitOps foundation is **excellent** from an architectural standpoint. The structure, documentation, and HA patterns demonstrate deep understanding of Kubernetes and GitOps principles. 

However, **critical security gaps** (secrets management, network policies) and **operational gaps** (backups, monitoring) must be addressed before scaling to additional services. 

**Recommended Approach:**
1. Complete Phase 1 (Security Foundations) immediately - 1 week
2. Complete Phase 2 (Operational Excellence) before adding services - 2 weeks  
3. Add 1-2 new applications while testing observability/backup
4. Complete Phase 3 iteratively as cluster grows
5. Phase 4 can be done anytime for convenience

**Strengths to Maintain:**
- Keep excellent documentation up to date
- Continue validation script usage
- Maintain single source of truth pattern
- Extend HA patterns to new stateful apps

**Final Assessment:** 🟢 **Solid foundation, production-ready after Phase 1+2**

---

*This review generated on January 15, 2026. Re-review recommended after implementing Phase 1 security fixes.*
