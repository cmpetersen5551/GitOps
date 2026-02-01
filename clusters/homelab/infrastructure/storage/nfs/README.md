# Unraid NFS exports (Phase 3)

Add the following exports on the Unraid host to expose media and transcode shares used by the cluster.

Example /etc/exports entries on Unraid (or via the Unraid GUI export settings):

/mnt/user/media         *(ro,sync,no_subtree_check,no_root_squash)
/mnt/user/transcode     *(rw,sync,no_subtree_check,no_root_squash)

Mounting examples (on Proxmox / other hosts):

```bash
mkdir -p /mnt/unraid/media /mnt/unraid/transcode
mount -t nfs 192.168.1.29:/mnt/user/media /mnt/unraid/media
mount -t nfs 192.168.1.29:/mnt/user/transcode /mnt/unraid/transcode
```

Notes:
- `pv-nfs-media.yaml` is created as a ReadOnlyMany PV; pods that need write access (e.g. transcode) should use the transcode PV/PVC.
- `pv-nfs-transcode.yaml` is ReadWriteMany for ephemeral transcode data.
- Adjust sizes and server IP as appropriate for your environment.
