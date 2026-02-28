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

## Sonarr / Radarr

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
