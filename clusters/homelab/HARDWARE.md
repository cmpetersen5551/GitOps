# Hardware & Topology

Summary
- Small k3s cluster with mixed hosting: Proxmox (VM + LXC) and Unraid (container).
- Planned: add two additional control-plane nodes later for HA.

Nodes
- `k3s-cp1` — control-plane (VM on Proxmox). NOTE: this control-plane does NOT have a `/data` mount.
- `k3s-w1` — worker (LXC on Proxmox). Primary GPU access.
- `k3s-w2` — worker (Rancher/k3s in Docker on Unraid). GPU enabled, used as failover.

Storage layout
- Worker nodes expose `/data` as follows:
  - `/data/media` — media content from an Unraid NFS export.
    - Flow: Unraid NFS export → mounted on Proxmox host → bind-mounted into `k3s-w1` LXC.
    - `k3s-w2` mounts the same Unraid NFS export directly.
  - `/data/pods` — application pod persistent data.
    - This folder is NOT provided by NFS. Each worker has a local `/data/pods` that is synchronized between workers using Syncthing (external process).

Topology (ASCII)
- Unraid (NFS server)
  ├─ Proxmox host (bind-mount of NFS)
  │  ├─ `k3s-cp1` (VM) — no `/data` mount
  │  └─ `k3s-w1` (LXC) — `/data/media` bind-mounted
  └─ `k3s-w2` (container on Unraid) — mounts Unraid NFS directly

Notes
- `k3s-w1` is primary for GPU workloads; `k3s-w2` is failover.
- `/data/pods` sync is handled by Syncthing (not managed by Flux).
- No IPs, credentials, or other sensitive data are recorded here.
