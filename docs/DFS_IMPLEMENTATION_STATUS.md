# DFS Implementation Status & Architecture (2026-02-28)

**Date**: 2026-02-28  
**Status**: ✅ FULLY OPERATIONAL - SMB/CIFS with HA  
**Objective**: Provide high-availability DFS (RealDebrid) shared storage for Sonarr, Radarr, and other media applications

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                    DECYPHARR-STREAMING POD (k3s-w1)            │
│                                                                 │
│  ┌──────────────────┐              ┌──────────────────┐        │
│  │   decypharr      │              │     smbd 4.22.8  │        │
│  │  (cy01/blackhole)│              │  (Samba server)  │        │
│  │                  │              │                  │        │
│  │ DFS FUSE mount   │──────────────│ SMB share export │        │
│  │  /mnt/dfs        │  (same       │  port 445        │        │
│  │                  │   namespace) │  (read-only)     │        │
│  └──────────────────┘              └──────────────────┘        │
│         │                                    │                 │
│   RealDebrid API                      ClusterIP Service        │
│   (symlink torrent)                   decypharr-streaming-smb  │
└─────────────────────────────────────────────────────────────────┘
                          │
                          │ SMB/CIFS
                          │
┌─────────────────────────────────────────────────────────────────┐
│              DFS-MOUNTER DAEMONSET (all nodes)                 │
│                                                                 │
│  ┌──────────────────────────────────┐                          │
│  │ nsenter (host network namespace) │                          │
│  │                                  │                          │
│  │ mount -t cifs //10.43.X.X/dfs \  │                          │
│  │       /mnt/decypharr-dfs         │                          │
│  │       (kernel mount device)      │                          │
│  └──────────────────────────────────┘                          │
│              │                                                  │
│   hostPath propagation (shared)                                │
│              │                                                  │
│    /mnt/decypharr-dfs  (on host k3s-w1, k3s-w2, k3s-w3)       │
└─────────────────────────────────────────────────────────────────┘
                          │
                          │ CIFS mount (kernel)
                          │
┌─────────────────────────────────────────────────────────────────┐
│              CONSUMER PODS (Sonarr, Radarr, etc.)              │
│                                                                 │
│  Bind-mount: /mnt/decypharr-dfs → /mnt/dfs (read-only CIFS)  │
│  Create symlinks: /mnt/streaming-media/downloads/$app/ → /mnt/dfs/
│  Import episodes/movies via symlinks                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation Timeline

| Date | Event | Status |
|------|-------|--------|
| 2026-02-24 | Initial architecture designed | Planning |
| 2026-02-26 | NFS → SMB/CIFS migration | ✅ Deployed |
| 2026-02-27 | Initial LD_PRELOAD nlink shim (dirs only) | ⚠️ Partial |
| 2026-02-28 | Extended nlink shim to regular files | ✅ Complete |

---

## Key Components

### 1. Decypharr-Streaming StatefulSet

**Role**: FUSE mount manager + SMB server

**Container**: `cy01/blackhole:latest`  
**Processes**:
- `decypharr`: Manages DFS FUSE mount at `/mnt/dfs` (connects to RealDebrid API)
- `smbd`: Samba 4.22.8 server exporting `/mnt/dfs` as SMB share on port 445

**LD_PRELOAD Nlink Fix**:
```bash
# Compiled at startup in initContainer
gcc -shared -fPIC -o /tmp/fix_nlink.so /tmp/fix_nlink.c -ldl

# Launched with:
LD_PRELOAD=/tmp/fix_nlink.so /usr/sbin/smbd -i -d 3

# Patches stat() syscalls to set st_nlink:
# - Directories: st_nlink=0 → 2
# - Regular files: st_nlink=0 → 1
# (Samba treats st_nlink=0 as deleted inode, rejects over SMB)
```

**Startup Process**:
1. Compile LD_PRELOAD shim
2. Wait for FUSE mount
3. Start smbd with LD_PRELOAD
4. Export `/mnt/dfs` as read-only SMB share

**Failover Behavior**:
- Pod can move from w1 → w2 (Descheduler + active-passive HA)
- Longhorn volume reattaches to new node
- Service IP stays same (ClusterIP: `decypharr-streaming-smb.media.svc.cluster.local`)
- dfs-mounter automatically reconnects within 60s (soft mount + actimeo=1)

### 2. DFS-Mounter DaemonSet

**Role**: Mount SMB share on all nodes via CIFS kernel client

**Pod Hosts**: k3s-w1, k3s-w2, k3s-w3 (all nodes)

**Mounter Script**:
```bash
# Use nsenter to run mount in host network namespace
nsenter --net=/var/run/netns/cni0 mount -t cifs \
  //decypharr-streaming-smb.media.svc.cluster.local/dfs \
  /mnt/decypharr-dfs \
  -o vers=3.0,sec=none,cache=strict,soft,nounix,reparse=nfs,actimeo=1
```

**Mount Options**:
- `vers=3.0`: NFSv3 compatibility (kernel CIFS can speak NFSv3 wrapping)
- `sec=none`: No authentication (Samba configured with guest access)
- `cache=strict`: Drop caches immediately (safe for read-only)
- `soft`: Fail fast on timeout (better than default hard mount hang)
- `nounix`: Don't request Unix extensions (avoid compatibility issues)
- `reparse=nfs`: Handle reparse-point symlinks correctly
- `actimeo=1`: Cache freshness 1 second (avoids stale data after Sonarr imports)

**Propagation**:
- mounts to `/mnt/decypharr-dfs` (hostPath volume, `HostToContainer` propagation)
- Available on host at `/mnt/decypharr-dfs`
- Available in consumer pods via bind-mount

### 3. Consumer Pods (Sonarr, Radarr, Prowlarr, etc.)

**Mount**: Bind-mount from host's `/mnt/decypharr-dfs` as `/mnt/dfs` (read-only CIFS)

**Workflow Example (Sonarr)**:
1. Episode downloaded to `/mnt/streaming-media/downloads/sonarr/Show/Season/Episode.mkv`
2. Decypharr-streaming receives `symlink` action from Sonarr API
3. Decypharr creates `/mnt/dfs/__all__/Show S01E01.../Episode.mkv` (RealDebrid source)
4. Sonarr creates symlink: `/mnt/streaming-media/downloads/sonarr/Show/.../import.mkv → /mnt/dfs/__all__/...`
5. Sonarr stat() the symlink target to verify before importing
6. Sonarr imports episode from linked source

**Critical**: Symlink following must work correctly (requires st_nlink ≠ 0)

---

## Known Limitations & Workarounds

### 1. Samba 4.x Treats st_nlink=0 as Deleted

**Impact**: Files with `st_nlink=0` cannot be stat'd over SMB protocol

**Root Cause**: FUSE (hanwen/go-fuse) returns `st_nlink=0` for all entries

**Workaround**: LD_PRELOAD shim patches stat() syscalls before Samba sees results

**Fix Status**: ✅ Deployed (commit `560581c`)

### 2. CIFS Soft Mount Timeout

**Impact**: Long network delays cause `mount -t cifs` to fail

**Root Cause**: Kernel CIFS default `echo_interval=60`, `timeo=20`

**Configured**: `soft` flag + `actimeo=1` (1-second cache)

**Behavior**: Connection issues fail queries within seconds (acceptable for read-only access)

### 3. No Hard Symlink Support Over CIFS

**Impact**: Cannot use `ln -H` (hard links) to RealDebrid files

**Workaround**: Always use soft symlinks (`ln -s`)

---

## Testing & Verification

### 1. Verify FUSE Mount (from decypharr-streaming)

```bash
kubectl exec -n media decypharr-streaming-0 -- ls -la /mnt/dfs/__all__/
# Output: directory listing with -rwxr-xr-x permissions ✅
```

### 2. Verify SMB Server

```bash
kubectl exec -n media decypharr-streaming-0 -- netstat -tlnp | grep :445
# Output: smbdl (PID) listening on 0.0.0.0:445 ✅
```

### 3. Verify CIFS Mount (from dfs-mounter)

```bash
kubectl exec -n media dfs-mounter-xyz -- mount | grep decypharr-dfs
# Output: //10.43.X.X/dfs /mnt/decypharr-dfs type cifs ✅
```

### 4. Verify Symlink Resolution (from Sonarr)

```bash
kubectl exec -n media sonarr-0 -- stat /mnt/dfs/__all__/ShowName.../file.mkv
# Output: Size, Links: 1, Access: (0755/-rwxr-xr-x) ✅
```

### 5. End-to-End Symlink Test

```bash
# In Sonarr container:
ln -s '/mnt/dfs/__all__/Too Hot to Handle S06E02.../file.mkv' \
     '/mnt/streaming-media/test-symlink.mkv'
stat '/mnt/streaming-media/test-symlink.mkv'
# Output: Resolves successfully, size matches ✅
```

---

## Troubleshooting Quick Reference

| Problem | Check |
|---------|-------|
| Files show as `?????????` | LD_PRELOAD shim not loaded or st_nlink still 0 |
| `stat: No such file or directory` | Samba protocol error; check nlink shim |
| CIFS mount hangs | Network connectivity or Samba service down |
| Symlink broken | Check target exists in `/mnt/dfs` |
| Import fails silently | Check Sonarr can stat() symlink targets |

See [SAMBA_FUSE_NLINK_BUG_FIX.md](./SAMBA_FUSE_NLINK_BUG_FIX.md) for detailed troubleshooting.

---

## Recent Changes

**2026-02-28**: Fixed critical nlink bug (commit `560581c`)
- Extended LD_PRELOAD shim to patch regular files (not just directories)
- Samba now correctly serves files over SMB (st_nlink=1)
- All consumer apps (Sonarr, Radarr, etc.) can now stat/open DFS files

**2026-02-26**: NFS → SMB/CIFS migration (commit `64f462b`)
- Removed rclone-nfs-server sidecar
- Added Samba 4.22.8 to decypharr-streaming container
- Implemented dfs-mounter DaemonSet with CIFS kernel client
- Simplified architecture (no requirement for MetalLB/BGP)

