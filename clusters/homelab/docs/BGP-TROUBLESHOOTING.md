# BGP Troubleshooting Guide - UDM Route Installation Issue

## Problem Summary

BGP session is established and routes are received in the BGP RIB, but routes are NOT being installed into the kernel routing table (`show ip route bgp` returns nothing).

## Root Cause Analysis

### What BGP Route Installation Should Look Like

In FRR (the routing software UniFi uses), this is the normal flow:
1. BGP receives route from peer → stored in BGP RIB
2. BGP runs best-path selection → marks best routes with `*>`
3. **Zebra (FRR's kernel interface) automatically installs best routes into kernel FIB**
4. Routes appear in kernel routing table (`show ip route`)

### Common Misconceptions

- **WRONG**: `redistribute bgp` installs routes into kernel
- **RIGHT**: `redistribute bgp` redistributes BGP routes to **other routing protocols** or neighbors
- **WRONG**: Routes need special config to install in kernel
- **RIGHT**: BGP routes **automatically install** when they're the best path (if zebra is working)

## Diagnostic Steps

### 1. Check Zebra Status

On the UDM, run:
```bash
# Check if zebra is running
ps aux | grep zebra

# Check FRR daemons status
vtysh -c "show daemons"
```

**Expected**: Both `zebra` and `bgpd` should be running.

### 2. Check BGP-Zebra Connection

```bash
vtysh

# Inside vtysh:
show bgp summary
# Look for "Zebra connection" or similar

# Check if routes are being sent to zebra
debug zebra rib
debug zebra kernel
```

### 3. Verify Route Selection

```bash
vtysh -c "show ip bgp 192.168.1.50/32"
```

**Expected output**:
```
BGP routing table entry for 192.168.1.50/32
Paths: (1 available, best #1)
  65001
    192.168.1.29 from 192.168.1.29 (172.16.0.2)
      Origin IGP, metric 0, localpref 100, valid, external, best (First path received)
      Last update: ...
```

The `best` keyword is critical - only best paths install in kernel.

### 4. Check for `--no_kernel` Flag

```bash
# Check how bgpd was started
ps aux | grep bgpd | grep -o "\-\-no[_-]kernel"
```

If this returns anything, BGP was started with kernel route installation **disabled**. This is rare but possible.

## Solutions

### Solution 1: Simplified Configuration (RECOMMENDED)

Upload this minimal config to your UDM:

```
router bgp 65000
 bgp router-id 192.168.1.1
 neighbor 192.168.1.120 remote-as 65001
 neighbor 192.168.1.120 description k3s-w1
 neighbor 192.168.1.29 remote-as 65001
 neighbor 192.168.1.29 description k3s-w2
 neighbor 192.168.1.243 remote-as 65001
 neighbor 192.168.1.243 description k3s-cp1
 address-family ipv4 unicast
  neighbor 192.168.1.120 activate
  neighbor 192.168.1.29 activate
  neighbor 192.168.1.243 activate
 exit-address-family
line vty
```

**Changes made**:
- Removed `redistribute bgp` (not needed and potentially problematic)
- Removed `redistribute connected` (optional, re-add if you want UDM to announce its networks)
- Removed `passive` (not needed for eBGP)
- Removed `soft-reconfiguration inbound` (not critical for basic operation)

### Solution 2: Restart FRR/Zebra

Sometimes zebra loses connection to the kernel:

```bash
# On UDM (SSH)
/etc/init.d/zebra restart
/etc/init.d/bgpd restart

# Or restart all FRR daemons
killall -9 zebra bgpd watchfrr
# Wait a few seconds, then reload config via UniFi UI
```

### Solution 3: Check VRF Context

UniFi might be using VRFs. Check:

```bash
vtysh -c "show vrf"
vtysh -c "show ip route vrf all"
```

If your BGP routes are in a non-default VRF, they won't appear in the main routing table.

### Solution 4: Force Route Installation (Debug Only)

If routes still won't install, you can manually add them to troubleshoot:

```bash
# Add VIP route manually to confirm connectivity works
ip route add 192.168.1.50 via 192.168.1.29

# Test connectivity
ping 192.168.1.50

# Remove manual route
ip route del 192.168.1.50
```

If manual route works, the issue is definitely with BGP→kernel installation, not connectivity.

## Verification After Fix

After applying the fixed config and restarting FRR:

```bash
# 1. Check BGP session
vtysh -c "show bgp summary"
# All neighbors should show "Established" with routes received

# 2. Check BGP routes
vtysh -c "show ip bgp"
# Should show routes with * (valid) > (best)

# 3. Check kernel routes (THE CRITICAL TEST)
vtysh -c "show ip route bgp"
# Should now show BGP routes!

# Or use Linux native command:
ip route show proto bgp
```

**Expected `show ip route bgp` output**:
```
Codes: K - kernel route, C - connected, S - static, R - RIP,
       O - OSPF, I - IS-IS, B - BGP, E - EIGRP, N - NHRP,
       T - Table, v - VNC, V - VNC-Direct, A - Babel, F - PBR,
       f - OpenFabric,
       > - selected route, * - FIB route, q - queued, r - rejected, b - backup
       t - trapped, o - offload failure

B>* 192.168.1.50/32 [20/0] via 192.168.1.29, eth0, weight 1, 00:01:23
```

## Advanced Debugging

If routes still don't install:

```bash
# Enable comprehensive debugging
vtysh
debug bgp zebra
debug zebra rib
debug zebra kernel
debug zebra events

# Watch logs in real-time
tail -f /var/log/frr/frr.log

# Or if using syslog:
tail -f /var/log/syslog | grep -E 'bgpd|zebra'
```

## Known Issues

### UniFi-Specific Quirks

1. **FRR version**: UniFi may use an older FRR version with bugs. Check version:
   ```bash
   vtysh -c "show version"
   ```

2. **Config persistence**: UniFi may overwrite FRR configs on reboot. Always upload via UI or use `set-inform` to persist.

3. **Firewall interference**: UniFi firewall might block BGP traffic. Ensure port 179 is allowed between UDM and k3s nodes.

### FRR/Zebra Common Issues

1. **Zebra not running**: Most common cause. Restart zebra daemon.

2. **VRF mismatch**: BGP routes in wrong VRF context.

3. **Route table permissions**: Zebra needs CAP_NET_ADMIN to modify routes.

4. **Conflicting routes**: If a static route exists for the same prefix, BGP might not install (check admin distance).

## Next Steps

1. Apply the simplified config from Solution 1
2. Restart FRR daemons (Solution 2)
3. Run verification steps
4. If still failing, enable debug logs and share output

## Reference

- FRR BGP Documentation: https://docs.frrouting.org/en/latest/bgp.html
- FRR Zebra Documentation: https://docs.frrouting.org/en/latest/zebra.html
- RFC 4271 (BGP-4): https://datatracker.ietf.org/doc/html/rfc4271
