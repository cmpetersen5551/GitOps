# DFS Troubleshooting Findings

**Date**: 2026-02-26 (resolved 2026-02-27)  
**Status**: ✅ RESOLVED — DaemonSet + hostPath approach working (commit `64f462b`)  
**Issue**: DFS files not visible in Sonarr/Radarr despite NFS server running  
**Root Cause**: Two bugs in the DaemonSet script — mount check always returned true, and missing NFS port options caused mount to hang  

---

## Summary

The DaemonSet + hostPath + `HostToContainer` propagation architecture described in `DFS_ARCHITECTURE_PLAN.md` **is correct and works on k3s**. The failure was two bugs in the DaemonSet shell script; the architecture itself needed no changes.

---

## Investigation Timeline

### Phase 1: Sonarr 404 Error (✅ Fixed)
- **Symptom**: `sonarr.homelab` returned "404 page not found"
- **Root Cause**: Pod had a stale `dfs-mounter` sidecar from old architecture (SFTP mount)
- **Fix**: Deleted pod to force recreation with clean StatefulSet spec
- **Result**: Sonarr running correctly

### Phase 2: Empty DFS Mount
- **Symptom**: Sonarr's `/mnt/dfs` was completely empty
- **Verified working**:
  - `decypharr-streaming-0:/mnt/dfs` — FUSE mounted, 3GB mkv file confirmed ✅
  - `rclone serve nfs` listening on port 2049 inside the pod ✅
  - Service `decypharr-streaming-nfs.media.svc.cluster.local:2049` reachable from pods ✅
- **Checked but dismissed too early**: DaemonSet pod was "Running" and "Healthy" ← the bug was here

### Phase 3: DaemonSet Mount Never Happening
- **Discovery**: The DaemonSet pod had `/dev/sda1 ext4` at `/mnt/decypharr-dfs` in its `/proc/mounts`
  - This was leftover from early CIFS mount attempts that created an ext4 artifact
  - The pod's mount check (`mountpoint -q`) reported TRUE because of this ext4 artifact
  - **NFS was never attempted** — the script's pre-check falsely indicated "already mounted"
- **Confirmed via live inspection**:
  ```bash
  kubectl exec -n media dfs-mounter-<pod> -- cat /proc/mounts | grep decypharr
  # Output: /dev/sda1 /mnt/decypharr-dfs ext4 ...
  # (no NFS entry — NFS was never mounted)
  ```

### Phase 4: Testing the Fix
- **Manual NFS mount with original options (hangs)**:
  ```bash
  mount -t nfs -o vers=3,soft,timeo=10 decypharr-streaming-nfs...:/ /mnt/decypharr-dfs
  # Result: TIMEOUT — hangs waiting for portmapper (port 111)
  ```
- **Manual NFS mount with correct port options (succeeds)**:
  ```bash
  mount -t nfs -o vers=3,port=2049,mountport=2049,tcp,nolock,soft,timeo=3,retrans=1 \
    decypharr-streaming-nfs...:/ /mnt/decypharr-dfs
  # Result: SUCCESS — mounted in ~1 second
  ```
- **Host propagation verified immediately**:
  ```bash
  ssh root@k3s-w1 "ls /mnt/decypharr-dfs/"
  # Output: __all__  __bad__  nzbs  torrents  version.txt ✅
  ```
- **Sonarr access verified end-to-end**:
  ```bash
  kubectl exec -n media sonarr-0 -- ls /mnt/dfs/
  # Output: __all__  __bad__  nzbs  torrents  version.txt ✅
  ```

---

## Root Cause: Two Bugs in the DaemonSet Script

### Bug 1: `mountpoint -q` false-positive (NFS never attempted)

The script checked `mountpoint -q /mnt/decypharr-dfs` to decide whether to run the NFS mount.

A Kubernetes `hostPath` volume bind-mounts the host directory into the container. This bind-mount **is itself a mountpoint** from the kernel's perspective. So `mountpoint -q /mnt/decypharr-dfs` always returns true — regardless of whether NFS is mounted there or not.

**Effect**: The "mount if not mounted" branch was never reached. NFS was never attempted on any pod start or loop iteration since the DaemonSet was first deployed.

**Fix**: Check specifically for an NFS filesystem type in `/proc/mounts`:
```bash
# BEFORE (always true — checks if anything is at that path):
if ! mountpoint -q /mnt/decypharr-dfs; then mount ...; fi

# AFTER (correctly checks for NFS specifically):
if ! grep -q '/mnt/decypharr-dfs nfs' /proc/mounts; then mount ...; fi
```

### Bug 2: Missing `port=2049,mountport=2049,tcp,nolock` options (mount hangs)

`rclone serve nfs` does **not** run a portmapper (rpcbind) daemon. The Linux kernel NFS client contacts portmapper (port 111) by default to discover which port the NFS server is using.

Without explicit port options, `mount -t nfs` sends a portmapper RPC to port 111, gets no response, and hangs until a hard timeout fires — preventing the mount script loop from completing.

**Fix**: Explicitly specify all ports and disable locking:
```
vers=3,port=2049,mountport=2049,tcp,nolock,soft,timeo=10,retrans=3,rsize=32768,wsize=32768
```

- `port=2049,mountport=2049`: bypass portmapper entirely, contact NFS server directly
- `tcp`: force TCP transport (rclone's NFS server uses TCP)
- `nolock`: disable NLM file locking (rclone's go-nfs doesn't implement NLM)

---

## What Earlier Analysis Got Wrong

Several conclusions written during debugging turned out to be incorrect:

| Earlier Claim | Actual Truth |
|---|---|
| "k3s's rprivate peer group prevents Bidirectional hostPath propagation" | FALSE. containerd places hostPath volumes in the host's `shared:1` peer group. Propagation works without any node prep. |
| "DaemonSet approach does not work reliably on this k3s setup" | FALSE. Two script bugs were the only problem. Architecture is sound. |
| "go-nfs deadlocks when backed by FUSE" | NOT CONFIRMED in DaemonSet context. May have occurred with in-pod emptyDir sidecar, but the NFS server was responsive and healthy throughout the DaemonSet investigation. |
| "Should pivot to direct Kubernetes NFS volumes in Sonarr/Radarr" | WRONG. Unnecessary. DaemonSet approach works and is preferable (works for w3/ClusterPlex cross-node; avoids kubelet-level NFS limitations). |

**Note on the "pivot" commit**: Commit `6b633a6` documented a pivot to direct NFS volumes in the StatefulSets, but that change was **documentation only — it was never applied to the YAML manifests**. Sonarr and Radarr continued using `hostPath` throughout. This was fortunate, as the hostPath approach is correct.

---

## Propagation: Why hostPath Works on k3s Without Node Prep

The earlier theory that k3s's root filesystem being `rprivate` prevents hostPath propagation was tested and disproved.

When kubelet creates a `hostPath` volume with `mountPropagation: Bidirectional`, containerd bind-mounts the host directory into the container using the host's existing peer group. The `/mnt/decypharr-dfs` directory on the host participates in the root filesystem peer group `shared:1`. A kernel VFS mount (NFS) made inside the container at that path propagates through `shared:1` back to the host namespace.

The earlier confusion came from interpreting `cat /proc/self/mountinfo | grep ' /mnt '` returning nothing as "the `/mnt` tree cannot propagate." The correct interpretation is just that `/mnt` is not its own separate mount — it's part of the root filesystem, which **is** in `shared:1`.

---

## Files Changed to Resolve

- `clusters/homelab/infrastructure/dfs-mounter/daemonset.yaml` — Fixed two bugs in mount loop script (commit `64f462b`)

No other changes were needed. Sonarr, Radarr, and decypharr-streaming StatefulSets were already correct.
