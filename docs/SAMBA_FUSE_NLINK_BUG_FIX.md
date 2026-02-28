# Samba/FUSE st_nlink Bug Fix (2026-02-28)

**Date**: 2026-02-28  
**Status**: ✅ RESOLVED  
**Severity**: Critical — Files unreadable via SMB despite existing on FUSE  
**Root Cause**: LD_PRELOAD nlink shim incompletely fixed Samba 4.x inode deletion logic  
**Fix**: Extend nlink patch to regular files (not just directories)  

---

## Problem Statement

After deploying the SMB/CIFS migration:
- Sonarr logs showed `FileNotFoundException: Could not find file '/mnt/dfs/__all__/...mkv'`
- Sonarr could list directories `ls /mnt/dfs/__all__/` → shows files
- Sonarr could NOT stat files: `stat /mnt/dfs/__all__/.../file.mkv` → "No such file or directory"
- File permissions displayed as `?????????` in symlink target directories
- Samba SMB protocol error: `NT_STATUS_OBJECT_NAME_NOT_FOUND`

## Root Cause Analysis

### How Sonarr Accesses DFS Files

1. **decypharr-streaming** pod:
   - Runs `decypharr` (FUSE filesystem for RealDebrid DFS at `/mnt/dfs`)
   - Runs `smbd` (Samba 4.22.8) on port 445
   - Exports `/mnt/dfs` as a read-only SMB share

2. **dfs-mounter** DaemonSet:
   - Mounts SMB share via CIFS client: `mount -t cifs //10.43.244.160/dfs /mnt/dfs`
   - Propagates mount via hostPath to node's `/mnt/decypharr-dfs`

3. **Sonarr** pod:
   - Bind-mounts `/mnt/decypharr-dfs` from host as `/mnt/dfs`
   - Accesses files via this CIFS mount
   - Creates symlinks: `/mnt/streaming-media/downloads/sonarr/file.mkv → /mnt/dfs/__all__/.../file.mkv`
   - Follows symlinks when processing episodes

### The Critical Bug: Samba Treats st_nlink=0 as Deleted

**Samba 4.x property**: Any inode (file or directory) with `st_nlink = 0` is treated as a **deleted/unlinked inode** and returns `NT_STATUS_OBJECT_NAME_NOT_FOUND` at the SMB protocol level.

```
SMB client requests file stat → 
Samba calls stat() on FUSE filesystem → 
FUSE returns st_nlink=0 for any file →
Samba thinks inode is unlinked/deleted →
Samba returns TStatus rejection to client →
CIFS client reports "No such file or directory"
```

**decypharr's FUSE (hanwen/go-fuse)** returns `st_nlink = 0` for **all entries** — both directories and regular files. This is the hanwen/go-fuse library's default behavior (matches Linux tmpfs).

### Why the Previous Fix Was Incomplete

The initial LD_PRELOAD shim (commit `64f462b`) patched the bug **only for directories**:

```c
static void fix(struct stat *s) {
    if (s && S_ISDIR(s->st_mode) && s->st_nlink == 0) s->st_nlink = 2;  // ✅ directories only
}
```

**Result**: 
- Directories were stat-able → `readdir` worked → Sonarr could list files
- Regular files were NOT patched → still had `st_nlink = 0` → Samba returned error on stat/open
- Files showed as `?????????` (inaccessible inode, no metadata)
- Symlinks to these files failed: `readlink -f symlink` would fail

### Diagnosis Walkthrough

```bash
# From inside Sonarr pod:
$ ls -la /mnt/dfs/__all__/Directory/
-rwxr-xr-x 1 root root 3054076824 ...  # BEFORE FIX: -????????? (inode metadata unavailable)

$ stat /mnt/dfs/__all__/Directory/file.mkv
stat: cannot statx '...file.mkv': No such file or directory  # ← Samba rejecting FUSE result

$ readlink /mnt/streaming-media/downloads/sonarr/Dir/file.mkv
/mnt/dfs/__all__/Directory/file.mkv  # Symlink target correct

$ stat /mnt/streaming-media/downloads/sonarr/Dir/file.mkv  # Via symlink
stat: cannot statx '...file.mkv': No such file or directory  # ← Still fails (stat() on FUSE through symlink)
```

## The Fix

Extend the LD_PRELOAD shim to patch **all inodes** with `st_nlink = 0`, not just directories:

```c
static void fix(struct stat *s) {
    if (s && s->st_nlink == 0) {
        if (S_ISDIR(s->st_mode)) s->st_nlink = 2;  // directories
        else s->st_nlink = 1;                       // regular files
    }
}
```

**Why these specific values?**
- Directories: `st_nlink = 2` (standard for directories: one for parent, one for self `.` entry)
- Regular files: `st_nlink = 1` (standard for regular files with no hard links)

### Deployment

**File**: [clusters/homelab/apps/media/decypharr-streaming/statefulset.yaml](../clusters/homelab/apps/media/decypharr-streaming/statefulset.yaml)

**Commit**: `560581c` — "fix: extend nlink shim to regular files (st_nlink=1)"

**Steps**:
1. Updated the LD_PRELOAD C shim in the StatefulSet initContainer
2. Committed and pushed to trigger Flux reconciliation
3. Deleted `decypharr-streaming-0` pod (OnDelete strategy) to redeploy with new shim
4. Pod recompiled `fix_nlink.c` and launched smbd with `LD_PRELOAD=/tmp/fix_nlink.so`
5. Restarted `dfs-mounter` DaemonSet to remount CIFS with updated Samba service
6. Verified: `ls` and `stat` both work on regular files through CIFS

### Verification

```bash
# AFTER FIX:
$ kubectl exec -n media sonarr-0 -- ls -la /mnt/dfs/__all__/Directory/
-rwxr-xr-x 1 root root 3054076824 ...  # ✅ Proper permissions (not ?????????)

$ kubectl exec -n media sonarr-0 -- stat /mnt/dfs/__all__/Directory/file.mkv
  File: ...file.mkv
  Size: 3054076824      Blocks: 5965000    IO Block: 1048576 regular file
  Links: 1  # ✅ st_nlink=1 (patched correctly)
  Access: (0755/-rwxr-xr-x)

$ kubectl exec -n media sonarr-0 -- readlink -f /mnt/streaming-media/downloads/sonarr/Dir/file.mkv
/mnt/dfs/__all__/Directory/file.mkv  # ✅ Resolves without error
```

## Impact

- **Sonarr**: Can now stat files via symlinks → episode import succeeds
- **Radarr**: Can now stat movie files via symlinks → library management succeeds
- **ClusterPlex/Plex**: Can now read movie/show metadata → streaming works

## Lessons Learned

### 1. Samba's Inode Deletion Logic

Samba 4.x uses `st_nlink` as a marker for inode deletion state, not just a link count. This is different from typical filesystem semantics where `st_nlink = 0` is unusual but not impossible (e.g., open files on unlink).

**Implication**: When mounting filesystems with non-standard stat results (FUSE, network filesystems), ensure all inode types have reasonable `st_nlink` values. Empty nlink fields can trigger special inode-death logic in servers.

### 2. LD_PRELOAD Shims for Cross-Layer compatibility

Using `LD_PRELOAD` to patch syscall results is a powerful but fragile technique:
- ✅ Works well for stat() family syscalls (used by most apps)
- ✅ Transparent to the application
- ❌ Easy to miss edge cases (e.g., only patching one inode type)
- ❌ Debugging is difficult (need strace/ltrace to see real vs patched values)

**Best practice**: Document exactly which syscalls are wrapped and which stat fields are patched. Consider adding logging to the shim:

```c
if (s && s->st_nlink == 0) {
    fprintf(stderr, "[fix_nlink] patching %s (st_mode=0%o, orig_nlink=0)\n", 
            p, s->st_mode);
    // ...
}
```

### 3. Testing Symlinks Through Export Layers

When testing FUSE→Samba→CIFS symlinks, test at each layer:

```bash
# Layer 1: FUSE (decypharr-streaming container)
stat /mnt/dfs/__all__/Directory/file.mkv

# Layer 2: SMB (smbclient from another pod)
smbclient //10.43.244.160/dfs -c "ls __all__" -N

# Layer 3: CIFS (host mount)
ls /mnt/decypharr-dfs/__all__/

# Layer 4: CIFS→Symlink (consumer pod)
stat /mnt/streaming-media/downloads/sonarr/.../file.mkv
```

This compartmentalization helps isolate which layer has the issue.

---

## References

- **Samba 4 File Handling**: https://wiki.samba.org/index.php/Samba_4.x_File_Sharing
- **hanwen/go-fuse**: https://github.com/hanwen/go-fuse
- **Linux FUSE Mount Propagation**: https://www.kernel.org/doc/html/latest/filesystems/fuse.html
- **Kubernetes Mount Propagation**: https://kubernetes.io/docs/concepts/storage/volumes/#mount-propagation

---

## Timeline

| Date | Event |
|------|-------|
| 2026-02-26 | SMB/CIFS migration replaces NFS |
| 2026-02-27 | Initial nlink shim deployed (directories only) |
| 2026-02-28 | Sonarr reports files as "not found" |
| 2026-02-28 | Root cause: nlink shim didn't patch regular files |
| 2026-02-28 | Fix applied and verified ✅ |

