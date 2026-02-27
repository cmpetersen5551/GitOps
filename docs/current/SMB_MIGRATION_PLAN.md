# SMB/Samba Migration Plan for DFS Sharing

**Date**: 2026-02-26  
**Status**: PLANNED — not yet implemented  
**Context**: Improving on the current NFS DaemonSet approach to eliminate pod restart churn, enable safe Plex integration, and remove fragile liveness probe hacks.

---

## Why We Are Reconsidering NFS

The current working solution (DaemonSet + kernel NFS + hostPath HostToContainer) has one significant operational weakness: **NFS soft mount staleness**.

When Decypharr-streaming restarts (pod restart, deployment, crash), the rclone NFS server disappears briefly. The Linux kernel CIFS client on a soft NFS mount marks that mount as permanently broken and returns `EIO` on all subsequent I/O — even after the server comes back. **The only recovery is unmounting and remounting**, which in Kubernetes means restarting the consumer pod.

### Current workaround (fragile)

To handle this, consumer pods (Sonarr, Radarr) were given a combined HTTP + DFS liveness probe:

```yaml
livenessProbe:
  exec:
    command:
      - /bin/sh
      - -c
      - 'wget -qO/dev/null http://127.0.0.1:8989/ping 2>/dev/null && timeout 3 stat /mnt/dfs >/dev/null 2>&1'
  periodSeconds: 60
  failureThreshold: 2
```

When the DFS mount goes stale, the probe fails twice and Kubernetes restarts the pod — which gets a fresh NFS mount.

### Why this is unacceptable for Plex

Plex cannot have the same liveness probe pattern. If someone is streaming a movie from Unraid NFS and Decypharr-streaming restarts for an unrelated reason, Plex would be killed mid-stream. Even for Sonarr/Radarr, pod restarts:
- Interrupt in-progress imports
- Lose queue state
- Cause unnecessary downtime

---

## Why CIFS/SMB Fixes This

The Linux kernel **CIFS client** (`mount -t cifs`) has built-in automatic server reconnect. When the SMB server disappears:

1. Kernel queues pending I/O
2. CIFS client retries connection in the background
3. Once server comes back, I/O resumes automatically
4. **No mount becomes permanently stale. No pod restart required.**

For Plex specifically: playback pauses briefly during Decypharr restart, then continues. No pod killed, no session lost.

---

## Why rclone Cannot Serve SMB

`rclone serve smb` does **not exist** in rclone v1.73.1 (the version shipped in `cy01/blackhole:beta`). Available serve subcommands: `dlna`, `docker`, `ftp`, `http`, `nfs`, `restic`, `s3`, `sftp`, `webdav`. This was confirmed when CIFS was briefly attempted (commit `767d937`, abandoned `edd0d35`).

**Solution**: Add a **Samba sidecar** (`smbd`) to the `decypharr-streaming` pod.

---

## Architecture: Samba Sidecar

### Why a sidecar works here (unlike past sidecar attempts)

Previous sidecar attempts (rclone NFS, sshfs) failed because of the **emptyDir mount namespace isolation** problem: kubelet creates separate bind-mount peer groups per container, so a FUSE mount in one container never appears in another.

A Samba sidecar is different because **Samba does not need to see the FUSE mount propagated**. It runs in the **same pod** as Decypharr, which means it runs in the same mount namespace. It reads `/mnt/dfs` directly — no emptyDir, no propagation, no peer group issue. This is the same reason `rclone serve nfs` works inside `decypharr-streaming` today.

### Component diagram

```
decypharr-streaming pod (same mount namespace)
├── container: decypharr
│   └── FUSE mounts /mnt/dfs via /dev/fuse
└── container: smbd (sidecar)
    └── reads /mnt/dfs directly (same mount namespace)
    └── serves SMB on port 445

dfs-mounter DaemonSet (on each storage/GPU node)
└── mount -t cifs //decypharr-streaming.media.svc.cluster.local/dfs /mnt/decypharr-dfs
    └── kernel CIFS client — auto-reconnects on server restart

Consumer pods (Sonarr, Radarr, Plex)
└── hostPath: /mnt/decypharr-dfs (HostToContainer)
    └── sees /mnt/dfs content — no FUSE, no NFS, no stale mounts
```

### What changes vs current NFS approach

| Component | Current (NFS) | New (SMB) |
|---|---|---|
| `decypharr-streaming` | rclone serve nfs in main container | add `smbd` sidecar, keep rclone nfs for now or remove |
| `dfs-mounter` DaemonSet | `mount -t nfs` | `mount -t cifs` |
| Mount check | `grep nfs /proc/mounts` | `grep cifs /proc/mounts` |
| Sonarr/Radarr liveness probe | HTTP + DFS stat (fragile) | HTTP only (clean) |
| Sonarr/Radarr init container | `wait-for-dfs` (blocks startup) | Remove — CIFS reconnects automatically |
| Plex liveness probe | HTTP only (DFS check would be dangerous) | HTTP only |
| Recovery on Decypharr restart | Pod restart (~2 min downtime) | Automatic reconnect (seconds of pause) |

---

## Implementation Plan

### Phase 1: Samba sidecar in decypharr-streaming

Add `smbd` as a sidecar container in the `decypharr-streaming` StatefulSet/Deployment:

- Image: `ghcr.io/servercontainers/samba` or `dperson/samba` or build minimal Alpine + samba package
- Share: `/mnt/dfs` as read-only anonymous share (guest ok)
- Port: 445 (SMB) — exposed as ClusterIP service
- No auth required (internal cluster only, same security model as current NFS)
- Volume mount: shared `dfs` volume (already present in pod) with `mountPropagation: HostToContainer` from the main Decypharr container

Minimal `smb.conf`:
```ini
[global]
  workgroup = WORKGROUP
  server string = decypharr-dfs
  security = user
  map to guest = Bad User
  guest account = nobody
  log level = 1

[dfs]
  path = /mnt/dfs
  browseable = yes
  read only = yes
  guest ok = yes
  force user = nobody
```

### Phase 2: Update dfs-mounter DaemonSet

Replace `mount -t nfs` with `mount -t cifs`:

```bash
mount -t cifs \
  //decypharr-streaming.media.svc.cluster.local/dfs \
  /mnt/decypharr-dfs \
  -o guest,uid=0,gid=0,file_mode=0755,dir_mode=0755,vers=3.0
```

Update mount check:
```bash
grep -q '/mnt/decypharr-dfs cifs' /proc/mounts
```

Nodes need `cifs-utils` kernel module available. On k3s Ubuntu nodes this is typically already present (`modprobe cifs`).

### Phase 3: Revert consumer pod liveness probes

Remove the DFS check from Sonarr and Radarr liveness probes — back to simple HTTP:

```yaml
livenessProbe:
  httpGet:
    path: /ping
    port: 8989
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 3
```

Remove `wait-for-dfs` init containers from Sonarr and Radarr.

### Phase 4: Plex deployment (when added)

Plex gets a clean HTTP-only liveness probe from day one. No DFS staleness risk.

---

## Key Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `cifs-utils` not installed on k3s nodes | Check with `modprobe cifs` before applying; install if needed |
| SMB guest auth rejected by kernel CIFS | Test with `smbclient -N //svc/dfs` from DaemonSet pod before switching |
| DNS resolution timing (ClusterIP not ready at mount time) | DaemonSet already handles retry loop — same as NFS |
| smbd process dies inside sidecar | Add liveness probe to smbd sidecar (simple `smbclient -N //localhost/dfs` check) |
| Port 445 blocked by network policy | Verify no NetworkPolicy restricts 445 in media namespace |
| Performance regression vs NFS | SMB is slightly higher overhead; acceptable for streaming use case |

---

## What This Does NOT Change

- The DaemonSet pattern itself — still needed (kernel VFS mount on host, propagated via hostPath)
- `decypharr-streaming` serving both RealDebrid DFS and usenet streaming
- Sonarr/Radarr architecture, storage, or symlink handling
- `streaming-media` volume (Longhorn RWX) for Decypharr → Sonarr symlinks
- NFS mounts for Unraid media library — completely separate, unaffected

---

## Decision Gate

Before implementing, verify:

1. `cifs-utils` available on k3s-w1, k3s-w2, k3s-w3: `ssh k3s-w1 modprobe cifs && echo ok`
2. Samba image choice — prefer minimal Alpine-based to keep image small
3. Confirm CIFS reconnect works in practice: mount a test CIFS share, restart the server, verify I/O resumes without remount

If CIFS reconnect does **not** work transparently in the containerized context (e.g. due to ClusterIP DNS TTL issues), fall back to the current NFS approach + liveness probe. This is the primary risk.
