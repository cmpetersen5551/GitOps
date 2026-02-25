# DFS Mount Strategy: In-Pod Sidecar Decision

**Date**: 2026-02-24 (Updated 2026-02-25)  
**Status**: ✅ Implemented — rclone colocated in decypharr container (no propagation needed)  
**Context**: How Sonarr, Radarr, Plex, and ClusterPlex workers access `/mnt/dfs` from the decypharr-streaming FUSE mount  

---

## Problem Statement

Decypharr-streaming creates a FUSE mount at `/mnt/dfs` (RealDebrid DFS cache). Consumer apps (Sonarr, Radarr, Plex, ClusterPlex worker) need read/write access to this mount to:
- **Sonarr/Radarr**: manage symlinks, track media files for import
- **Plex**: resolve symlinks at streaming time
- **ClusterPlex worker (w3)**: access source files for GPU transcoding

### Constraints

| Constraint | Impact |
|---|---|
| FUSE mounts are per-process, not per-host | Cannot share FUSE directly across pods without propagation |
| 2-node HA (w1 primary, w2 failover) | Mount strategy must survive pod movement between nodes |
| w3 is a separate physical node (GPU) | ClusterPlex worker cannot use hostPath, needs network access |
| MetalLB pool is small (10 IPs: 192.168.100.101-110) | Plex and ClusterPlex orchestrator will need LB IPs |
| kubelet uses host DNS, not CoreDNS | ClusterIP service names unresolvable for kubelet-level NFS mounts |

---

## Root Cause: Why Sonarr/Radarr Were Stuck in `ContainerCreating`

Three compounding bugs found and resolved across two debugging sessions:

### Bug 1: emptyDir instead of hostPath in decypharr-streaming (Initial Fix)

```yaml
# WRONG - plain emptyDir is isolated per pod, FUSE mount cannot propagate
volumes:
  - name: dfs
    emptyDir:
      sizeLimit: 1Gi
```

The decypharr process creates a FUSE mount at `/mnt/dfs` inside its container. For this to be visible to the rclone-nfs-server sidecar (and eventually to other pods), it must propagate **through the host kernel**. This requires a volume type that the container runtime mounts with correct shared propagation semantics.

Changing to `hostPath` was the first fix attempted, but it was only partially correct — see Bug 1b below.

### Bug 1b: hostPath FUSE propagation unreliable in k3s (Root Cause — Fixed 2026-02-25)

```yaml
# STILL WRONG - hostPath from a plain directory is unreliable for FUSE propagation
volumes:
  - name: dfs
    hostPath:
      path: /mnt/k8s/decypharr-streaming-dfs
      type: DirectoryOrCreate
```

This was the intermediate fix that still failed. FUSE mounts propagating via `hostPath` require the host path's parent mount to be in a **shared peer group** (`MS_SHARED`). On k3s, `/mnt/k8s/` sits on the root filesystem which is typically `rprivate` (private propagation). Even though the container's bind-mount is set to `rshared` for Bidirectional, the FUSE mount could not propagate further than the kubelet's pod volume directory — it never appeared on the host path, so the rclone-nfs-server sidecar saw an empty directory.

This is confirmed behavior by Kubernetes maintainer jsafrane in [kubernetes/kubernetes#95049](https://github.com/kubernetes/kubernetes/issues/95049):

> *"Mount propagation really works only for hostpath volumes, where there are no global/local bind-mounts and a container gets directly the host directory as a docker volume."*

And the official Kubernetes documentation explicitly cautions:

> *"Mount propagation is a low-level feature that does not work consistently on all volume types. The Kubernetes project recommends only using mount propagation with `hostPath` or **memory-backed `emptyDir`** volumes."*

**The correct fix**: use `emptyDir: {medium: Memory}` (tmpfs). kubelet creates a fresh tmpfs mount point that the container runtime correctly marks as `rshared`. We tested this — it still did not work.

**Root cause of failure with memory-backed emptyDir**: Even though the Kubernetes docs recommend this approach, kubelet creates a separate bind-mount of the same tmpfs for each container in the pod. Each bind-mount lands in a different mount peer group. Inspecting `/proc/X/mountinfo` inside the containers confirmed that the FUSE mount peer group (ID 549 in decypharr) and the rclone sidecar's peer group (ID 303) are disconnected. The FUSE mount propagates from decypharr into kubelet's intermediate path, but not into the rclone sidecar's mount namespace.

**This is a fundamental limitation of Kubernetes**: mount propagation between containers in the same pod is broken regardless of volume type, because each container's volume mount is a separate bind-mount with its own peer group. There is no supported way to share a live FUSE mount between two containers in the same pod via volume mounts alone.

### Bug 1c: Final fix — run rclone in the same container as decypharr (2026-02-25)

Since `rclone` is already present in the `cy01/blackhole:beta` image at `/usr/local/bin/rclone`, the solution is to **eliminate the sidecar entirely** and run rclone inside the decypharr container. Both processes share the same mount namespace — no propagation is needed at all.

```yaml
# CORRECT - both processes in the same mount namespace
containers:
  - name: decypharr
    command: ["/bin/sh", "-c"]
    args:
      - |
        mkdir -p /mnt/dfs
        /usr/bin/decypharr --config /config &
        DECYPHARR_PID=$!
        # Wait for FUSE mount to appear
        until grep -q ' /mnt/dfs ' /proc/mounts 2>/dev/null; do
          sleep 2
        done
        # rclone serves /mnt/dfs directly (same mount namespace)
        while kill -0 $DECYPHARR_PID 2>/dev/null; do
          rclone serve nfs /mnt/dfs --addr=0.0.0.0:2049 || true
          sleep 5
        done
```

### Bug 2: Wrong NFS export path

```yaml
# WRONG - rclone exports /mnt/dfs as root (/), not as /mnt/dfs
nfs:
  path: /mnt/dfs  # This would look for a subdirectory that doesn't exist
```

`rclone serve nfs /mnt/dfs` exports that directory as NFS root `/`. Clients must mount at path `/`, not `/mnt/dfs`. 

### Bug 3: kubelet cannot resolve ClusterIP for NFS

kubelet-level `nfs:` volume mounts use **host DNS** (not CoreDNS). The ClusterIP `10.43.200.129` is a virtual IP managed by kube-proxy's iptables rules, which work for pod network traffic but not for the host kernel's NFS client. This caused perpetual `ContainerCreating` - the kubelet could never complete the NFS mount handshake.

---

## Options Considered

### Option B: In-Pod Mount Sidecar (✅ CHOSEN)

Add a small sidecar to each consumer pod that performs the NFS mount **from within the pod's network namespace**:

```
Consumer pod (Sonarr/Radarr/Plex/Worker):
  ┌─────────────────────────────────────────┐
  │  dfs-mounter sidecar                    │
  │  - Runs: mount -t nfs -o vers=3 <service-dns>:/ /mnt/dfs │
  │  - Uses CoreDNS ✅ (pod network ns)     │
  │  - Retries every 15s if mount lost      │
  │  - mountPropagation: Bidirectional      │
  │           │                             │
  │           ▼ shared emptyDir             │
  │  main container (sonarr/plex/etc.)     │
  │  - mountPropagation: HostToContainer   │
  │  - Sees /mnt/dfs once sidecar mounts   │
  └─────────────────────────────────────────┘
```

### Option C: MetalLB LoadBalancer IP

Assign a stable BGP-advertised IP to `decypharr-streaming-nfs`. kubelet uses the real routed IP (bypassing kube-proxy) for the `nfs:` volume mount. Static IP resolves the DNS problem.

---

## Why Option B Was Chosen for Long-Term Success

| Criteria | Option B (Sidecar) | Option C (MetalLB IP) |
|---|---|---|
| **HA failover**: pod starts before NFS ready | ✅ Sidecar reconnects in background, pod starts immediately | ❌ Pod stays in `ContainerCreating` if NFS not ready at schedule time |
| **w3 ClusterPlex worker** | ✅ Identical sidecar pattern, no special handling | ✅ Same LB IP, works cross-node |
| **MetalLB IP pool** (10 IPs) | ✅ No IP consumed | ❌ Consumes 1 IP from limited pool |
| **DNS resilience** (no hardcoded IPs) | ✅ CoreDNS, service name is stable | ⚠️ IP stable but must manage address pool allocation |
| **NFS blip recovery** | ✅ Auto-remounts within 15s | ⚠️ `soft` mount = ESTALE I/O errors; pod may need restart |
| **Consumer pod privilege** | ⚠️ `SYS_ADMIN` capability added | ✅ No privilege change |
| **Manifest changes required** | 3 manifests (sonarr, radarr, + future plex/worker) | 1 service + 2 manifests (nfs path fix) |

**The decisive factors:**

1. **HA across failover**: In the w1→w2 failover scenario, decypharr-streaming-0 must restart on w2 before consumer pods can use it. With Option C, Sonarr/Radarr would be stuck in `ContainerCreating` until decypharr fully starts. With Option B, they start immediately and the sidecar connects in the background — this is the correct HA behavior.

2. **w3 is next**: The ClusterPlex worker on w3 uses the same sidecar pattern. Option B gives us zero additional work when deploying Plex/w3. Option C would also work for w3 but wastes a MetalLB IP.

3. **MetalLB pool conservation**: Plex needs a LoadBalancer IP for external Plex clients. ClusterPlex orchestrator may also need one. With only 10 IPs available, burning one on an internal NFS service is wasteful.

4. **NFSv4 over ClusterIP works in pod networking**: NFSv4 uses a single TCP connection to port 2049, no portmapper. kube-proxy iptables handles this correctly from inside pod network namespaces. The kubelet-level problem doesn't apply.

---

## Architecture: Full DFS Mount Chain

```
┌──────────────────────────────────────────────────────────────┐
│ Node: k3s-w1 (or k3s-w2 after failover)                     │
│                                                              │
│  ┌─────────────────────────────────────┐                    │
│  │ decypharr-streaming-0 pod           │                    │
│  │                                     │                    │
│  │  [decypharr container] (privileged) │                    │
│  │   SAME mount namespace as rclone    │                    │
│  │                                     │                    │
│  │   /usr/bin/decypharr --config /config  (background)     │
│  │       ↓ creates FUSE mount                              │
│  │   /mnt/dfs → RealDebrid DFS FUSE                        │
│  │       ↓ same process namespace                          │
│  │   rclone serve nfs /mnt/dfs --addr=0.0.0.0:2049        │
│  │       ↓ serves DFS content directly as NFSv4            │
│  │   port 2049 (no volume/propagation needed)              │
│  └─────────────────────────────────────┘                    │
│         │                                                    │
│         ▼ ClusterIP service (CoreDNS resolvable)            │
│  decypharr-streaming-nfs.media.svc.cluster.local:2049       │
└──────────────────────────────────────────────────────────────┘
         │
         ▼ NFSv4 (single TCP conn, works via kube-proxy in pod netns)
┌─────────────────────────────────────────────────────────────┐
│ Consumer pod on w1/w2 (Sonarr, Radarr, Plex)               │
│                                                             │
│  ┌─────────────────────────────────────────────────┐       │
│  │  [dfs-mounter sidecar]                          │       │
│  │   Uses CoreDNS → resolves service               │       │
│  │   mount -t nfs -o vers=3 <service>:/ /mnt/dfs           │       │
│  │   Retries every 15s if mount lost               │       │
│  │   mountPropagation: Bidirectional               │       │
│  │             │                                   │       │
│  │             ▼ shared emptyDir within pod        │       │
│  │  [main container: sonarr/radarr/plex]           │       │
│  │   mountPropagation: HostToContainer             │       │
│  │   /mnt/dfs available once sidecar mounts        │       │
│  └─────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ Node: k3s-w3 (GPU, different physical host)                 │
│                                                             │
│  ┌─────────────────────────────────────────────────┐       │
│  │  ClusterPlex Worker pod                         │       │
│  │   SAME sidecar pattern as above                 │       │
│  │   Cross-node: NFSv4 → pod network → kube-proxy │       │
│  │   → service → decypharr pod on w1/w2            │       │
│  └─────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

---

## Implementation

### decypharr-streaming changes

**Eliminated the rclone-nfs-server sidecar container entirely.** The `cy01/blackhole:beta` image already ships rclone at `/usr/local/bin/rclone`. Running it in the same container as decypharr means both processes share a mount namespace — rclone sees `/mnt/dfs` directly without any volume mount propagation.

**Removed the `dfs` emptyDir volume** — no longer needed since FUSE and NFS server are in the same container.

**Startup sequence:**
1. `mkdir -p /mnt/dfs` — ensure mount point directory exists
2. `decypharr --config /config &` — start decypharr in background (creates FUSE at `/mnt/dfs`)
3. Wait until `/proc/mounts` shows `/mnt/dfs` — FUSE is ready
4. `rclone serve nfs /mnt/dfs --addr=0.0.0.0:2049` — serve DFS as NFSv4
5. Restart loop: if rclone crashes, restart it while decypharr is still running

### Consumer pod changes (Sonarr, Radarr — and Plex/worker when deployed)

No changes to consumer pods — the `decypharr-streaming-nfs` ClusterIP service still answers on port 2049. Consumer pod dfs-mounter sidecars continue using:

```yaml
mount -t nfs -o vers=3,port=2049,mountport=2049,tcp,nolock,soft,timeo=30,retrans=3 \
  decypharr-streaming-nfs.media.svc.cluster.local:/ /mnt/dfs

containers:
  - name: dfs-mounter
    image: alpine:3.19
    command: ["/bin/sh", "-c"]
    args:
    - |
      apk add --no-cache nfs-utils --quiet
      mkdir -p /mnt/dfs
      while true; do
        if ! mountpoint -q /mnt/dfs; then
          mount -t nfs -o vers=3,port=2049,mountport=2049,tcp,nolock,soft,timeo=30,retrans=3 \
            decypharr-streaming-nfs.media.svc.cluster.local:/ /mnt/dfs \
            && echo "DFS mounted" || echo "DFS mount failed, retrying..."
        fi
        sleep 15
      done
    securityContext:
      capabilities:
        add: ["SYS_ADMIN"]
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 64Mi
    volumeMounts:
    - name: dfs-shared
      mountPath: /mnt/dfs
      mountPropagation: Bidirectional

  - name: sonarr  # (or radarr, plex, etc.)
    volumeMounts:
    - name: dfs-shared
      mountPath: /mnt/dfs
      mountPropagation: HostToContainer
```

---

## HA Failover Behavior

### w1 → w2 failover (decypharr AND sonarr move)
1. w1 fails → Longhorn detects node down (~60s)
2. `decypharr-streaming-0` rescheduled to w2
   - Decypharr re-establishes FUSE mount at `/mnt/dfs` (local to container)
   - rclone starts serving NFSv4 once FUSE is ready (~5–30s for DFS reconnect)
3. `sonarr-0` rescheduled to w2 simultaneously
   - **Pod starts immediately** (no NFS dependency at schedule time)
   - `dfs-mounter` sidecar begins retrying mount loop
   - Once decypharr-streaming is ready, sidecar connects → `/mnt/dfs` appears in sonarr container
   - Total extra latency: 0–15s for sidecar retry cycle
4. `decypharr-streaming-nfs` ClusterIP unchanged — rclone in the decypharr container on w2 now answers it

### w1 recovers (automatic failback via descheduler)
1. Descheduler detects pods on w2 violating `preferredDuringScheduling` (prefer w1)
2. Evicts pods → they reschedule to w1
3. decypharr re-establishes FUSE on w1; sonarr sidecar remounts NFS within 15s
4. Zero manual intervention required

---

## Future: Plex and ClusterPlex Worker (Phase 7)

Both use the **identical consumer sidecar pattern**. Template to copy:

```yaml
# Add to any new consumer pod's spec.containers:
- name: dfs-mounter
  image: alpine:3.19
  command: ["/bin/sh", "-c"]
  args:
  - |
    apk add --no-cache nfs-utils --quiet
    mkdir -p /mnt/dfs
    while true; do
      if ! mountpoint -q /mnt/dfs; then
        mount -t nfs -o vers=3,port=2049,mountport=2049,tcp,nolock,soft,timeo=30,retrans=3 \
          decypharr-streaming-nfs.media.svc.cluster.local:/ /mnt/dfs \
          && echo "DFS mounted" || echo "DFS mount failed, retrying..."
      fi
      sleep 15
    done
  securityContext:
    privileged: true  # Required for Bidirectional mountPropagation
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi
  volumeMounts:
  - name: dfs-shared
    mountPath: /mnt/dfs
    mountPropagation: Bidirectional

# Add to spec.volumes:
- name: dfs-shared
  emptyDir: {}
```

ClusterPlex worker on w3 uses this exact template. The NFSv4 connection traverses pod networking → kube-proxy → ClusterIP → decypharr-streaming pod (wherever it is). No hostPath, no special handling for cross-node.

---

## Files Changed

| File | Change |
|---|---|
| `clusters/homelab/apps/media/decypharr-streaming/statefulset.yaml` | Merged rclone into decypharr container; removed rclone-nfs-server sidecar and dfs emptyDir volume |
| `clusters/homelab/apps/media/sonarr/statefulset.yaml` | In-pod dfs-mounter sidecar (unchanged) |
| `clusters/homelab/apps/media/radarr/statefulset.yaml` | In-pod dfs-mounter sidecar (unchanged) |

`service-nfs.yaml` is unchanged — ClusterIP is correct for this pattern (resolved by CoreDNS inside pods, not by kubelet).
