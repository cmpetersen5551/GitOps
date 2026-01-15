# MetalLB + BGP on UniFi Equipment - Research Findings

**Date:** January 15, 2026  
**Purpose:** Real-world examples and best practices for MetalLB BGP with UniFi equipment

---

## Executive Summary

Found multiple working examples of MetalLB/Cilium + BGP on UniFi equipment (UDM-SE, UDM-Pro, UCG-Max). Key findings:

- **✅ It works!** Multiple users have successfully deployed this configuration
- **⚠️ Gotchas exist:** Most issues are around UniFi BGP config syntax and connected route precedence
- **🔧 Solution available:** Well-documented configurations from multiple sources

---

## Key Resources

### 1. **Blog: BGP with Cilium and UniFi** ⭐ BEST RESOURCE
- **Link:** https://blog.stonegarden.dev/articles/2025/11/bgp-cilium-unifi/
- **Author:** Vegard S. Hagen (StonehomeGarden)
- **Hardware:** UniFi Cloud Gateway Max (UCG-Max), Kubernetes on Proxmox
- **Status:** ✅ Working (November 2025)

**Configuration Details:**
```bash
# Router (UniFi): AS 65100, IP 192.168.1.1
# Cilium Cluster: AS 65200
# IP Pool: 172.20.10.0/24 (separate VLAN)
# Nodes: 192.168.1.100, .101, .102
```

**Working UniFi BGP Config:**
```frr
router bgp 65100
  bgp router-id 192.168.1.1
  no bgp ebgp-requires-policy
  
  neighbor HOMELAB peer-group
  neighbor HOMELAB remote-as 65200
  
  neighbor 192.168.1.100 peer-group HOMELAB
  neighbor 192.168.1.101 peer-group HOMELAB
  neighbor 192.168.1.102 peer-group HOMELAB
exit
```

**Key Insights:**
- ✅ Uses Cilium but principles apply to MetalLB
- ✅ Separate VLAN for BGP-advertised IPs (optional but recommended)
- ✅ Comprehensive troubleshooting section
- ✅ Step-by-step configuration guide
- ⚠️ BGP-advertised IPs don't respond to ICMP/ping (known limitation)
- 🎯 **CRITICAL:** `ip prefix-list` entries must come AFTER `router bgp` statement in UniFi config

### 2. **Reddit: Weird Issue with UniFi BGP and MetalLB**
- **Link:** https://www.reddit.com/r/homelab/comments/1o06xdf/
- **Hardware:** UDM-SE 4.3.6, MetalLB v0.15.2, 8 servers
- **Status:** ⚠️ Troubleshooting (October 2025)

**Configuration:**
```bash
# Router: AS 64501, IP 10.10.1.1
# MetalLB: AS 64500
# VIPs: 10.10.1.2, 10.10.1.4, 10.10.1.5
# Nodes: 10.10.1.11 through 10.10.1.18
```

**Problem Encountered:**
- BGP routing table showed routes correctly
- But main routing table had connected routes taking precedence
- VIPs in same subnet as management network (10.10.1.0/24)

**Root Cause (from u/PeriodicallyIdiotic):**
> "The more pressing issue is that `10.10.1.0/24` is already configured as a prefix on 'router', so connected routes will take precedence over BGP learned routes regardless."

**Solution:**
- **MUST use separate subnet for BGP-advertised VIPs**
- Cannot be in same /24 as connected interfaces
- Example: Use 192.168.88.0/24 for management, 192.168.64.0/24 for BGP VIPs

**Additional Issues:**
- User reported zebra process crashing on UDM (support ticket opened)
- Suggests potential UniFi firmware stability issues with BGP

### 3. **Reddit: MetalLB on k3s HA - BGP setup for UDM-SE**
- **Link:** https://www.reddit.com/r/kubernetes/comments/1ia0uuv/
- **Hardware:** UDM-SE, k3s cluster (3 control + 3 workers)
- **Status:** ✅ SOLVED (January 2024)

**Configuration:**
```bash
# Router: AS 65000
# MetalLB: AS 65000 (same AS - iBGP)
# VIPs: 10.100.100.100/31
```

**Working UDM-SE Config (from u/clintkev251):**
```frr
router bgp 65510
 bgp ebgp-requires-policy
 bgp router-id 10.250.10.1
 maximum-paths 1
 
 neighbor metallb peer-group
 neighbor metallb remote-as 65511
 neighbor metallb activate
 neighbor metallb soft-reconfiguration inbound
 neighbor 10.250.10.16 peer-group metallb
 neighbor 10.250.10.18 peer-group metallb
 neighbor 10.250.10.104 peer-group metallb
 neighbor 10.250.10.73 peer-group metallb
 neighbor 10.250.10.189 peer-group metallb
 neighbor 10.250.10.48 peer-group metallb
 neighbor 10.250.10.8 peer-group metallb
 neighbor 10.250.10.196 peer-group metallb

 address-family ipv4 unicast
  redistribute connected
  neighbor metallb activate
  neighbor metallb route-map ALLOW-ALL in
  neighbor metallb route-map ALLOW-ALL out
  neighbor metallb next-hop-self
 exit-address-family

route-map ALLOW-ALL permit 10
```

**Critical Fix:**
> "I also need to set the `ebgpMultiHop` to `true`. It seems that because my router 192.168.1.1 and my k3s nodes are in different subnetworks, there is more than 1 hop between each."

**MetalLB Configuration:**
```yaml
apiVersion: metallb.io/v2beta2
kind: BGPPeer
metadata:
  name: example
  namespace: metallb-system
spec:
  myASN: 65000
  peerASN: 65000
  peerAddress: 192.168.1.1
  ebgpMultiHop: true  # CRITICAL if nodes in different subnet than router
```

### 4. **Reddit: "Highly" Available Homelab**
- **Link:** https://www.reddit.com/r/homelab/comments/1ld7nsd/
- **Hardware:** Mikrotik switches, pfSense routers (no UniFi for routing)
- **Status:** ✅ Working (July 2024)
- **Note:** User specifically mentions switching AWAY from UniFi due to lack of BGP/MLAG support at the time

**Why User Left UniFi:**
> "No support for MLAG on the original unifi AGG switch, no BGP support without hacks. Used to be no failover / HA solution for the dream machine, not to mention IPv6 barely working."

**Current State (2026):** UniFi has since added native BGP support in UI (v4.1.10+)

### 5. **Reddit: For VIP, do you use ARP or BGP?**
- **Link:** https://www.reddit.com/r/homelab/comments/1nked0d/
- **Hardware:** UniFi router (UDM), Kubernetes + kube-vip + MetalLB
- **Status:** ✅ Converted to BGP successfully (October 2024)

**User Experience:**
- Started with ARP mode in MetalLB
- Successfully converted to BGP after UniFi added UI support
- Used both kube-vip (control plane) and MetalLB (services)

**Benefits Noted:**
- Saves extra hop
- Pushes load balancing to core switch
- Multiple nodes can carry VIP instead of only one
- Faster switchover latency
- Learning opportunity

---

## Common Configuration Patterns

### AS Number Selection

**Private AS Numbers (RFC 1930):**
- 2-octet: `64512` - `65534` (most common)
- 4-octet: `4200000000` - `4294967294`

**Examples Found:**
- 64500/64501 (MetalLB/Router)
- 65000/65000 (iBGP - same AS)
- 65100/65200 (Cilium example)
- 65510/65511 (UDM-SE example)

### IP Address Patterns

**✅ WORKING:**
- Management: `192.168.1.0/24`, BGP Pool: `172.20.10.0/24` (Separate VLANs)
- Management: `10.250.10.0/24`, BGP Pool: `10.100.100.0/24` (Different subnets)

**❌ NOT WORKING:**
- Management: `10.10.1.0/24`, BGP Pool: `10.10.1.0/24` (Same subnet!)

### UniFi BGP Configuration Template

**Minimal Working Config:**
```frr
router bgp 65100
  bgp router-id 192.168.1.1
  no bgp ebgp-requires-policy
  
  neighbor METALLB peer-group
  neighbor METALLB remote-as 65200
  
  neighbor 192.168.1.100 peer-group METALLB
  neighbor 192.168.1.101 peer-group METALLB
  neighbor 192.168.1.102 peer-group METALLB
exit
```

**Production-Ready Config (with policies):**
```frr
router bgp 65100
  bgp router-id 192.168.1.1
  bgp ebgp-requires-policy
  bgp bestpath as-path multipath-relax
  maximum-paths 3
  
  neighbor METALLB peer-group
  neighbor METALLB remote-as 65200
  neighbor METALLB password hunter2
  
  neighbor 192.168.1.100 peer-group METALLB
  neighbor 192.168.1.101 peer-group METALLB
  neighbor 192.168.1.102 peer-group METALLB
  
  address-family ipv4 unicast
    redistribute connected
    neighbor METALLB activate
    neighbor METALLB next-hop-self
    neighbor METALLB soft-reconfiguration inbound
    neighbor METALLB route-map RM-METALLB-IN in
    neighbor METALLB route-map RM-METALLB-OUT out
  exit-address-family
exit

! Accept BGP VIPs from MetalLB
ip prefix-list METALLB-IN seq 10 permit 172.20.10.0/24 le 32
route-map RM-METALLB-IN permit 10
  match ip address prefix-list METALLB-IN
exit

! Advertise management network to MetalLB
ip prefix-list METALLB-OUT seq 10 permit 192.168.1.0/24
route-map RM-METALLB-OUT permit 10
  match ip address prefix-list METALLB-OUT
exit
```

---

## Critical Gotchas & Solutions

### 1. **Connected Route Precedence** ⚠️ CRITICAL
**Problem:** BGP routes won't be used if they're in the same subnet as a connected interface.

**Solution:** Use separate VLAN/subnet for BGP-advertised IPs.
```
BAD:  Management 10.10.1.0/24, VIPs 10.10.1.2-10.10.1.5
GOOD: Management 192.168.1.0/24, VIPs 172.20.10.0/24
```

### 2. **eBGP Multi-Hop Required** ⚠️ CRITICAL
**Problem:** Peering fails if nodes are in different subnet than router gateway.

**Solution:** Enable `ebgpMultiHop` in MetalLB configuration.
```yaml
apiVersion: metallb.io/v2beta2
kind: BGPPeer
metadata:
  name: unifi-router
  namespace: metallb-system
spec:
  myASN: 65200
  peerASN: 65100
  peerAddress: 192.168.1.1
  ebgpMultiHop: true  # Required if nodes not in same /24 as router
```

### 3. **UniFi Config Ordering** ⚠️ IMPORTANT
**Problem:** `ip prefix-list` entries disappear if declared before `router bgp` statement.

**Solution:** Always put `ip prefix-list` and `route-map` AFTER the `exit` from `router bgp` block.

```frr
# WRONG - prefix-list will be discarded
ip prefix-list METALLB-IN seq 10 permit 172.20.10.0/24 le 32
router bgp 65100
  ...
exit

# CORRECT
router bgp 65100
  ...
exit
ip prefix-list METALLB-IN seq 10 permit 172.20.10.0/24 le 32
```

### 4. **BGP IPs Don't Respond to Ping** ℹ️ EXPECTED
**Issue:** Services accessible via BGP-advertised IPs won't respond to ICMP/ping requests.

**Status:** Known limitation, open GitHub issue: cilium/cilium#14118

**Workaround:** Use application-level health checks (HTTP, TCP) instead of ping.

### 5. **UniFi Firmware Stability** ⚠️ WATCH FOR
**Reported Issues:**
- Zebra process crashes (UDM-SE 4.3.6)
- BGP config not properly applied on some firmware versions

**Recommendation:** 
- Use latest stable UniFi firmware (4.4.x+ as of 2025)
- Check `/var/log/frr/` logs on UDM via SSH
- Monitor with `systemctl status frr`

---

## Troubleshooting Guide

### On UniFi Router (SSH Access)

```bash
# Check FRR service status
systemctl status frr
service frr restart  # if needed

# View running BGP config
vtysh -c "show running-config"

# Check BGP peers
vtysh -c "show ip bgp summary"

# View BGP routes
vtysh -c "show ip bgp"

# Check specific neighbor
vtysh -c "show ip bgp neighbors 192.168.1.100"

# View received routes from neighbor
vtysh -c "show ip bgp neighbors 192.168.1.100 received-routes"

# View filtered routes
vtysh -c "show ip bgp neighbors 192.168.1.100 filtered-routes"

# Check route-maps
vtysh -c "show route-map"

# Check prefix-lists
vtysh -c "show ip prefix-list"
```

### On Kubernetes Cluster

```bash
# Check MetalLB speaker logs
kubectl logs -n metallb-system -l component=speaker

# Check BGP peer status (if using Cilium CLI)
cilium bgp peers

# Check advertised routes
cilium bgp routes advertised ipv4 unicast

# Check available routes
cilium bgp routes available ipv4 unicast

# Check MetalLB BGPPeer status
kubectl get bgppeer -n metallb-system -o yaml

# Check MetalLB IPAddressPool
kubectl get ipaddresspool -n metallb-system
```

### Common Error Messages

**"BGP session not established"**
- Check firewall rules (TCP port 179)
- Verify AS numbers match configuration
- Check if `ebgpMultiHop` needed
- Verify router can reach node IPs

**"No route to VIP"**
- Check if VIP in connected subnet (must be separate)
- Verify BGP routes installed: `vtysh -c "show ip bgp"`
- Check prefix-list allows VIP range
- Verify `redistribute connected` if needed

**"Prefix-list not applied"**
- Ensure prefix-list comes AFTER `router bgp` block
- Check syntax with `show ip prefix-list`
- Restart FRR: `service frr restart`

---

## Comparison: Our Setup vs. Working Examples

### What We Have
```yaml
Router: UDM-Pro (10.0.1.1)
Router AS: 64501
MetalLB AS: 64500
Nodes: 10.0.1.11, 10.0.1.12, 10.0.1.13
VIP Range: 10.0.1.100-10.0.1.110
Network: 10.0.1.0/24 (single subnet)
```

### Problems Identified

1. **❌ VIPs in Same Subnet as Management**
   - VIPs: `10.0.1.100-110` 
   - Nodes: `10.0.1.11-13`
   - Router: `10.0.1.1`
   - All in `10.0.1.0/24` → Connected routes take precedence!

2. **❓ Possible Missing ebgpMultiHop**
   - If nodes on different VLAN, may need this setting

### Recommended Changes

**Option 1: Separate VLAN (Preferred)**
```yaml
Management VLAN: 10.0.1.0/24
  - Router: 10.0.1.1
  - Nodes: 10.0.1.11-13

BGP Services VLAN: 10.0.2.0/24 (new VLAN)
  - VIP Pool: 10.0.2.100-110
  - Router Gateway: 10.0.2.1
```

**Option 2: Different Subnet (Alternative)**
```yaml
Keep existing: 10.0.1.0/24 (management)
Change VIPs to: 172.20.10.0/24 (BGP services)
```

**Updated MetalLB Configuration:**
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: primary-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.0.2.100-10.0.2.110  # Separate subnet!
  avoidBuggyIPs: false
---
apiVersion: metallb.io/v2beta1
kind: BGPPeer
metadata:
  name: udm-pro
  namespace: metallb-system
spec:
  myASN: 64500
  peerASN: 64501
  peerAddress: 10.0.1.1
  sourceAddress: 10.0.1.11  # Use management IP for peering
  ebgpMultiHop: true         # Required since VIPs on different subnet
```

**Updated UniFi Configuration:**
```frr
router bgp 64501
  bgp router-id 10.0.1.1
  bgp ebgp-requires-policy
  bgp bestpath as-path multipath-relax
  maximum-paths 3
  
  neighbor METALLB peer-group
  neighbor METALLB remote-as 64500
  
  neighbor 10.0.1.11 peer-group METALLB
  neighbor 10.0.1.12 peer-group METALLB
  neighbor 10.0.1.13 peer-group METALLB
  
  address-family ipv4 unicast
    redistribute connected
    neighbor METALLB activate
    neighbor METALLB next-hop-self
    neighbor METALLB soft-reconfiguration inbound
    neighbor METALLB route-map RM-METALLB-IN in
    neighbor METALLB route-map RM-METALLB-OUT out
  exit-address-family
exit

! Accept BGP services from MetalLB (NEW subnet)
ip prefix-list METALLB-IN seq 10 permit 10.0.2.0/24 le 32
route-map RM-METALLB-IN permit 10
  match ip address prefix-list METALLB-IN
exit

! Advertise management network to MetalLB
ip prefix-list METALLB-OUT seq 10 permit 10.0.1.0/24
route-map RM-METALLB-OUT permit 10
  match ip address prefix-list METALLB-OUT
exit
```

---

## Additional Resources Referenced

### Blog Posts & Tutorials
1. Gerard Samuel - "Setup Kubernetes Cilium BGP with UniFi v4.1 Router"
2. Sander Sneekes - "Advanced Kubernetes Networking BGP with Cilium and UDM Pro"
3. Raj Singh - "Cilium UniFi BGP Configuration"
4. Zak Thompson - "Ubiquity UniFi, K3s, BGP, and MetalLB"

### Documentation
- Cilium BGP Control Plane: https://docs.cilium.io/en/latest/network/bgp-control-plane/
- UniFi BGP Help: https://help.ui.com/hc/en-us/articles/16271338193559
- MetalLB BGP: https://metallb.universe.tf/configuration/bgp/
- FRR BGP Documentation: https://docs.frrouting.org/en/latest/bgp.html

### Community Forums
- UniFi Community: Limited discussion, mostly about ISP peering
- r/homelab: Active discussions, multiple working examples
- r/kubernetes: Technical discussions, troubleshooting help

---

## Key Takeaways

1. **✅ MetalLB + UniFi BGP works** - Multiple confirmed working setups in production homelabs
   
2. **⚠️ Separate subnets REQUIRED** - Most common failure mode is VIPs in same subnet as management

3. **🔧 ebgpMultiHop often needed** - Enable if nodes and router on different subnets/VLANs

4. **📝 UniFi config order matters** - Put prefix-lists AFTER router bgp block

5. **🚀 UniFi BGP support improving** - Native UI support added v4.1.10, getting better with each release

6. **📚 Good documentation exists** - Especially the Stonegarden blog post (comprehensive!)

7. **⚡ Performance benefits real** - Users report better failover times, load distribution

8. **🎯 Testing recommended** - Start simple (no policies), then add route-maps/prefix-lists

---

## Next Steps for Implementation

1. **Design Phase:**
   - [ ] Choose new VLAN/subnet for BGP services (recommend 10.0.2.0/24)
   - [ ] Decide on AS numbers (current 64500/64501 are fine)
   - [ ] Plan IP allocations in new subnet

2. **Network Setup:**
   - [ ] Create new VLAN in UniFi (VLAN 2)
   - [ ] Configure router interface for new subnet
   - [ ] Test connectivity from nodes to new gateway

3. **UniFi BGP Configuration:**
   - [ ] Create BGP config file following template above
   - [ ] Upload via UniFi UI → Settings → Policy Table → Dynamic Routing
   - [ ] Verify with `vtysh -c "show ip bgp summary"`

4. **MetalLB Configuration:**
   - [ ] Update IPAddressPool to new subnet
   - [ ] Add ebgpMultiHop: true to BGPPeer
   - [ ] Update prefix-lists if using route-maps

5. **Testing:**
   - [ ] Deploy test service with LoadBalancer type
   - [ ] Verify BGP routes advertised: `cilium bgp routes advertised`
   - [ ] Test connectivity from client network
   - [ ] Check failover (kill a speaker pod, verify no downtime)

6. **Production Rollout:**
   - [ ] Update existing services gradually
   - [ ] Monitor BGP session stability
   - [ ] Document any issues/workarounds specific to environment

---

## Conclusion

Real-world examples confirm MetalLB + BGP on UniFi equipment is viable and working well for many users. The critical requirement is using separate subnets for BGP-advertised services vs management traffic. With proper configuration following the patterns documented by the community, this setup provides better resilience and performance than ARP mode.

The Stonegarden blog post provides the most comprehensive and up-to-date guide available as of November 2025, with full working configurations and troubleshooting guidance.

**Confidence Level:** HIGH - Multiple independent confirmations of working setups
**Risk Level:** MEDIUM - Some gotchas but well-documented workarounds exist
**Recommendation:** PROCEED with implementation using separate VLAN approach
