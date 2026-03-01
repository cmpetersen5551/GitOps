# Gotchas & Fixes

Indexed problem-solution pairs. Each entry: symptom → root cause → fix. No narrative.

---

## Longhorn

### RWX volume stuck "attaching" to cp1 instead of storage node
- **Symptom**: `AttachVolume.Attach failed... Waiting for volume share to be available`; volume shows `Node ID: k3s-cp1`
- **Cause**: Share-manager pods (system-managed) have no nodeSelector and schedule to cp1
- **Fix**: Add to HelmRelease defaultSettings:
  ```yaml
  systemManagedComponentsNodeSelector: "node.longhorn.io/storage:enabled"
  taintToleration: "node.longhorn.io/storage=enabled:NoSchedule"
  ```
- StorageClass `diskSelector`/`nodeSelector` do NOT control share-manager placement — only replica placement.

### Longhorn disks not auto-created after labeling node
- **Cause**: Used `node.longhorn.io/storage=enabled` label only; disk creation needs a different label
- **Fix**: Also apply `node.longhorn.io/create-default-disk=true` to each storage node

### RWX mount fails with "mount program didn't pass remote address"
- **Cause**: `nfs-common` not installed on the mounting host
- **Fix**: `apt-get install -y nfs-common` on every node that will mount RWX volumes

### 2-node setup — replica scheduling fails
- **Cause**: `replicaSoftAntiAffinity: true` (default) tries to spread to 3+ nodes
- **Fix**: Set `replicaSoftAntiAffinity: false` in HelmRelease

---

## FUSE / k3s Mount Propagation

### FUSE mount not propagating from container to host
- **Cause**: k3s root filesystem is mounted `rprivate`; `hostPath` volumes on the root fs block propagation
- **Fix**: Mount the *parent directory* with `Bidirectional`, not the specific FUSE target path
  ```yaml
  - name: dfs-host
    hostPath:
      path: /mnt         # mount parent, not /mnt/dfs
      type: Directory
    mountPropagation: Bidirectional
  ```
- Containers bind FUSE at `/mnt/dfs` → propagates to host `/mnt/dfs` via the Bidirectional parent

### Consumer pod can't see FUSE mount from decypharr
- **Cause**: Consumer uses `emptyDir` instead of `hostPath` for the DFS volume, or uses wrong propagation direction
- **Fix**: Consumer must use `hostPath: /mnt/dfs` with `mountPropagation: HostToContainer`

---

## Longhorn RecurringJobs

### Recurring backup job runs but finds 0 volumes
- **Symptom**: CronJob executes, but logs show "Found 0 volumes with recurring job {name}"
- **Cause**: RecurringJob `spec.groups: []` (empty) doesn't match any volume label groups. Volumes are labeled `recurring-job-group.longhorn.io/default=enabled`
- **Fix**: Set `groups: ["default"]` in RecurringJob spec to match the `default` label group on volumes
- All Longhorn volumes get the `recurring-job-group.longhorn.io/default=enabled` label automatically on creation unless custom groups are defined

### Multiple backup jobs each create redundant backups of all volumes
- **Symptom**: 5 separate RecurringJobs each target all 9 volumes, creating 45 backups per night instead of 9
- **Cause**: All volumes share the same label group; each job with matching `groups: ["default"]` targets all of them
- **Fix**: Use a single consolidated RecurringJob instead of per-app jobs (see DECISIONS.md)
- For single-purpose backup, one job scales better than trying to manage per-app schedules

### `noreparse` CIFS mount option causes failure
- **Cause**: `noreparse` requires kernel 6.15+; cluster nodes run 6.12 (Debian 13) and 6.8 (Proxmox VE w3)
- **Fix**: Remove `noreparse` from any CIFS mount options

---

## Decypharr

### Pod env var `DECYPHARR_PORT=tcp://IP:PORT` causes startup failure
- **Cause**: k3s injects service environment variables; `DECYPHARR_PORT` clashes with blackhole image's port parser
- **Fix**: Set `enableServiceLinks: false` in pod spec

### Decypharr health probes always return 401
- **Cause**: All endpoints require auth which is set up via web UI post-first-start
- **Fix**: Remove all liveness/readiness/startup probes; process lifecycle is sufficient

### Wrong Decypharr image
- `ghcr.io/cowboy/decypharr:latest` → 403 Forbidden (private)
- `sirrobot01/decypharr:latest` → doesn't exist
- **Correct**: `cy01/blackhole:beta` (streaming), `cy01/blackhole:latest` (download)

---

## Victoria Logs

### Pod won't schedule (nodeSelector/tolerations ignored)
- **Symptom**: Pod stays `Pending`; `nodeSelector` or `tolerations` in kustomize patches are ineffective
- **Cause**: Kustomize strategic-merge patches on Helm-rendered StatefulSets are unreliable for generated pods; the chart has its own value paths
- **Fix**: Use native chart values in HelmRelease: `server.nodeSelector`, `server.tolerations`, `vector.tolerations`

### Ingress returns 404 (`logs.homelab` works but every path returns 404)
- **Symptom**: `http://logs.homelab` returns 404 from Traefik
- **Cause**: Helm chart generates the Service with a name like `victoria-logs-victoria-logs-server`, not matching the release name. Ingress backend pointed at non-existent service name.
- **Fix**: Add a bridge `Service` in the same namespace that selects the chart-generated pod and exposes port 9428. Point the Ingress at this bridge service.

### Vector DaemonSet doesn't collect logs from storage/control-plane nodes
- **Symptom**: Logs from pods on k3s-w1, k3s-w2, or k3s-cp1 missing from VictoriaLogs
- **Cause**: Vector DaemonSet has no tolerations by default; won't schedule on tainted nodes
- **Fix**: Set `vector.tolerations` in HelmRelease to include both storage taint and control-plane taint

### API returns "unsupported path requested" or 404
- **Symptom**: `curl http://logs.homelab/select/logsql` returns an error
- **Cause**: `/select/logsql` does not exist. The correct endpoint is `/select/logsql/query`
- **Fix**: Use `POST /select/logsql/query` with `--data-urlencode 'query=<LogsQL>'`

### Response parsing fails (`jq '.[]'` returns error)
- **Symptom**: `jq '.[]'` on API response throws parse errors
- **Cause**: The API returns **JSONL** (JSON Lines) — one JSON object per **line**, not a JSON array. Each line is a separate JSON object.
- **Fix**: Parse line-by-line: `curl ... | jq -r '"[" + ._time + "] " + ._msg'` (not `'.[]'`)

### Field names `.timestamp`, `.message`, `.pod` don't exist
- **Symptom**: `jq` extracts `null` for expected fields
- **Cause**: VictoriaLogs always uses `_time`, `_msg`, `_stream` as core field names. Kubernetes metadata field names depend on Vector's config and differ from what you might expect.
- **Fix**: Run `./docs/vlogs-troubleshoot.sh fields` to discover exact indexed field names before writing queries

### URL encoding with `jq -sRr @uri` fails for complex queries
- **Cause**: `jq @uri` doesn't reliably encode all special chars (e.g., `|`, `(`, `)`) needed in LogsQL
- **Fix**: Use `curl --data-urlencode 'query=<value>'`; curl handles encoding correctly

---

### Files in /mnt/dfs show as `?????????` (inaccessible)
- **Cause**: This was the Samba/FUSE `st_nlink=0` bug from the old SMB architecture. SMB is gone.
- **Current arch**: If files are inaccessible now, check FUSE propagation — verify decypharr-streaming is running and `/mnt/dfs` exists on the host

### Sonarr/Radarr scheduling to cp1
- **Cause**: Missing `requiredDuringSchedulingIgnoredDuringExecution` affinity for storage nodes
- **Fix**: Add required nodeAffinity for `node.longhorn.io/storage=enabled` plus storge node taint toleration

### Radarr image tag not found (ErrImagePull)
- **Cause**: Pinned tag `5.2.5` doesn't exist in registry
- **Fix**: Use `linuxserver/radarr:latest`; verify tags exist on Docker Hub before pinning

---

## MetalLB / BGP

### BGP routes in RIB but not installed in kernel routing table
- **Symptom**: `show ip bgp` shows routes with `*>` (best), but `show ip route bgp` returns nothing
- **Cause**: Usually zebra is not running or lost its connection to bgpd; FRR should install best-path BGP routes into the kernel FIB automatically via zebra — no `redistribute bgp` needed
- **Fix**: On UDM, check `ps aux | grep zebra` and `vtysh -c "show daemons"`; restart FRR if zebra is missing. Also verify bgpd wasn't started with `--no_kernel` flag.

### BGP VIPs unreachable despite routes being installed
- **Cause**: MetalLB VIP pool subnet overlaps with a connected interface subnet (e.g., both on `192.168.1.0/24`); connected routes take precedence over BGP routes
- **Fix**: VIP pool **must** be a separate subnet (e.g., `192.168.100.0/24`) not assigned to any physical interface on the UDM

---

## Pulsarr

### Pulsarr can't reach Sonarr/Radarr ("ConnectionRefused" on localhost:8989 / localhost:7878)
- **Symptom**: Logs show `"path": "http://localhost:8989/api/v3/notification"` with `ConnectionRefused`
- **Cause**: Pulsarr defaults to `localhost` when no Sonarr/Radarr URL is configured. Must be set via UI using cluster-internal DNS.
- **Fix**: In pulsarr UI, set Sonarr URL to `http://sonarr.media.svc.cluster.local` and Radarr URL to `http://radarr.media.svc.cluster.local` (port 80 — the service port, not the app port)

### Pulsarr webhook callback times out from Sonarr/Radarr ("Operation timed out")
- **Symptom**: Logs show `"Operation timed out (pulsarr.media.svc.cluster.local:3003)"` when Sonarr/Radarr try to reach pulsarr
- **Cause**: Pulsarr was configured with `port=3003` and used that in webhook URLs, but the Kubernetes Service only exposes port 80 (→ targetPort 3003). Sonarr/Radarr tried to connect on port 3003 which has no service listener.
- **Fix**: In ConfigMap `.env`, set `port=80` (external service port) and `listenPort=3003` (internal bind port). `baseUrl` should omit the port (defaults to 80). Per pulsarr docs: `port` = external/webhook port, `listenPort` = internal bind port.

### Pulsarr root folder dropdown missing entries (browser issue)
- **Symptom**: Pulsarr UI shows some root folders (e.g., tvshows) but not others (e.g., movies), despite all being accessible via Radarr API
- **Cause**: Browser cache stale UI state
- **Fix**: Hard refresh (Cmd+Shift+R) or clear browser cache. The API returns all folders correctly; it's a frontend rendering issue.

### `ip prefix-list` entries not taking effect on UDM
- **Cause**: In UniFi's FRR config, `ip prefix-list` entries must appear **after** the `router bgp` block
- **Fix**: Reorder config so `router bgp` comes first, then prefix-list definitions below it

---

## Traefik / Ingress

### 404 after pod is running
- **Cause**: Service exposes non-standard port (e.g., `7878`) but Ingress targets port `80`
- **Fix**: Service `port: 80, targetPort: <app-port>`; Ingress `backend.service.port.number: 80`

### Ingress routing not working despite annotation
- **Cause**: Used `router.entrypoints: web,websecure`; correct Traefik entrypoint names are `http`/`https`
- **Fix**: Use `traefik.ingress.kubernetes.io/router.entrypoints: http` (or `http,https`)

---

## Flux / GitOps

### Changes applied but cluster doesn't reflect them
- **Cause**: Flux hasn't reconciled yet (default interval is several minutes)
- **Fix**: `flux reconcile kustomization apps --with-source` to force immediate sync
- Never `kubectl apply` directly for Flux-managed resources — it will be overwritten on next reconcile

### Flux reconcile fails with "not found" for removed resource
- **Cause**: Removed a kustomization resource reference but the CRD/object still exists in cluster
- **Fix**: Delete the object from cluster first (`kubectl delete`), then remove from kustomization

---

## HA / Failover

### Pod stuck on dead node, not rescheduling
- **Cause**: Kubernetes default `node.kubernetes.io/unreachable` toleration is 5 minutes
- **Fix**: Already patched in all media pod specs:
  ```yaml
  tolerations:
    - key: node.kubernetes.io/unreachable
      operator: Exists
      effect: NoExecute
      tolerationSeconds: 30
    - key: node.kubernetes.io/not-ready
      operator: Exists
      effect: NoExecute
      tolerationSeconds: 30
  ```

### Pod not returning to w1 after w1 recovery
- **Cause**: Descheduler not running, or pod doesn't have `preferredDuringScheduling` affinity for w1
- **Fix**: Verify descheduler CronJob is running (`kubectl get cronjob -n kube-system descheduler`); confirm pod spec has `preferredDuringScheduling` for `node.longhorn.io/primary=true`

---

## Plex / NFS-server pod

### NFS server pod reports "no valid exports" / fails to export
- **Cause**: `mountPropagation` was missing on the hostPath volumeMount. Without `HostToContainer`, the FUSE mount at `/mnt/dfs` created by decypharr-streaming is invisible inside the NFS server pod — it sees an empty directory, so `exportfs` finds nothing to export.
- **Fix**: Set `mountPropagation: HostToContainer` on the hostPath volumeMount for `/mnt/dfs`/`/export/dfs` inside the NFS server pod. The image choice is irrelevant — this will fail with any image if propagation is wrong.

### NFS PV needs a stable server address but pod IP changes
- **Cause**: NFS PVs are mounted at the kubelet (node) level, so they can't use in-cluster DNS (`*.svc.cluster.local`). Pod IPs change on every restart.
- **Fix**: Pin the service `spec.clusterIP` in the Service manifest and use that IP in the PV's `nfs.server` field. kube-proxy's iptables rules on each node forward ClusterIP traffic to the current pod IP, providing transparent HA routing.

### Static NFS PV breaks after Longhorn PVC is deleted and recreated
- **Symptom**: Plex pod on w3 can't mount `plex-config` or `streaming-media` after a PVC was deleted/recreated; volume mount hangs or fails with "connection refused".
- **Cause**: Longhorn RWX volumes use share-manager pods, each with their own Service. Deleting a PVC destroys that Service and creates a new one on recreation — with a **new ClusterIP**. The static PV still points to the old, now-defunct IP.
- **Fix**: After recreating a Longhorn RWX PVC, get the new share-manager Service ClusterIP:
  ```bash
  kubectl get svc -n longhorn-system | grep share-manager
  ```
  Then update the corresponding static PV's `spec.nfs.server` field and commit. This only applies to volumes accessed by w3 (which lacks the Longhorn CSI driver); w1/w2 use CSI directly and are unaffected.
- **Prevention**: Treat `pvc-plex-config` and `pvc-streaming-media` as permanent. Use `persistentVolumeReclaimPolicy: Retain` on all associated static PVs.

### Longhorn share-manager shuts down when no CSI consumers exist
- **Symptom**: Plex pod on w3 loses `/config` with NFS mount errors; `pvc-nfs-plex-config` returns connection refused.
- **Cause**: Longhorn only keeps share-manager running while at least one pod has the volume CSI-mounted. Plex on w3 uses a static NFS PV (not CSI — w3 is LXC and cannot use Longhorn iSCSI). With no CSI mounts, Longhorn detects "no consumers" and shuts down share-manager → NFSv4 export disappears.
- **Fix**: The `plex-config-holder` Deployment on w1/w2 CSI-mounts `pvc-plex-config` permanently, keeping share-manager alive. Verify it's running: `kubectl get deployment plex-config-holder -n media`. If deleted accidentally, share-manager will stop within minutes.

### w3 (Proxmox LXC) cannot use Longhorn CSI driver
- **Cause**: Longhorn CSI uses iSCSI-backed block devices. LXC containers block the cgroup device access required for iSCSI, so the Longhorn CSI node plugin on w3 cannot attach volumes.
- **Fix**: Any Longhorn RWX volume that w3 needs must be wrapped in a static NFS PV pointing at the share-manager ClusterIP. Requires the plex-config-holder trick above. This is a permanent architectural constraint — do not attempt to install Longhorn CSI on w3.
