# Validation and Testing Guide for OVS Balance-SLB

This guide provides procedures to validate that balance-slb is working correctly, including traffic distribution, failover behavior, and integration with NetworkManager.

## Prerequisites

```bash
# Access node via debug pod
oc debug node/<node-name> -- chroot /host bash

# Or SSH directly
ssh core@<node-ip>
sudo -i
```

---

## 1. Topology Validation

### 1.1 Verify OVS Bridges

```bash
ovs-vsctl show
```

**Expected output:**
```
Bridge br-phy
    Port patch-phy-to-ex
        Interface patch-phy-to-ex
            type: patch
            options: {peer=patch-ex-to-phy}
    Port ovs-bond
        Interface ens33
            type: system
        Interface ens34
            type: system
Bridge br-ex
    Port patch-ex-to-phy
        Interface patch-ex-to-phy
            type: patch
            options: {peer=patch-phy-to-ex}
    Port br-ex
        Interface br-ex
            type: internal
```

### 1.2 Verify Bond Configuration

```bash
ovs-appctl bond/show ovs-bond
```

**Expected output:**
```
---- ovs-bond ----
bond_mode: balance-slb
bond may use recirculation: no, Recirc-ID : -1
bond-hash-basis: 0
updelay: 0 ms
downdelay: 0 ms
lacp_status: off
lacp_fallback_ab: false
active-backup primary: <none>

slave ens33: enabled
  may_enable: true
  hash 0-127: 128

slave ens34: enabled
  may_enable: true
  hash 128-255: 128
```

### 1.3 Verify IP Configuration

```bash
ip addr show br-ex
```

**Expected:**
- IP address assigned to `br-ex`
- State: UP
- MTU: 9000 (or configured value)

### 1.4 Verify Patch Ports

```bash
ovs-vsctl list interface patch-ex-to-phy
ovs-vsctl list interface patch-phy-to-ex
```

**Check for:**
- `type: patch`
- `options: {peer=<peer-name>}`

---

## 2. Traffic Flow Validation

### 2.1 Install tcpdump (via toolbox)

```bash
# Enter toolbox
toolbox

# Inside toolbox
dnf install -y tcpdump
```

### 2.2 Monitor Traffic on Physical NICs

Open two terminals and monitor both NICs:

**Terminal 1 - ens33:**
```bash
toolbox tcpdump -i ens33 -n -c 50
```

**Terminal 2 - ens34:**
```bash
toolbox tcpdump -i ens34 -n -c 50
```

**Generate traffic:**
```bash
# From another terminal on the same node
ping -c 10 <gateway-ip>
curl -I https://api.<cluster-domain>:6443
```

### 2.3 Monitor Traffic on OVS Bridges

```bash
# Traffic on br-ex (internal interface with IP)
toolbox tcpdump -i br-ex -n -c 20

# Traffic stats on bond
ovs-appctl dpif/show
```

### 2.4 Understanding Traffic Path

```
OUTBOUND TRAFFIC (from node to network):
┌────────────────────────────────────────────────────────────────────┐
│ Application (e.g., kubelet)                                        │
│         │                                                          │
│         ▼                                                          │
│ ┌─────────────┐                                                    │
│ │   br-ex     │  tcpdump -i br-ex  ← See traffic with node IP     │
│ │ (internal)  │                                                    │
│ └──────┬──────┘                                                    │
│        │                                                           │
│ ┌──────┴──────┐                                                    │
│ │ patch-ex    │  (virtual, no tcpdump possible)                   │
│ └──────┬──────┘                                                    │
│        │                                                           │
│ ┌──────┴──────┐                                                    │
│ │   br-phy    │  ovs-appctl fdb/show br-phy ← See MAC learning    │
│ └──────┬──────┘                                                    │
│        │                                                           │
│ ┌──────┴──────┐                                                    │
│ │  ovs-bond   │  ovs-appctl bond/show ← See hash distribution     │
│ └──────┬──────┘                                                    │
│   ┌────┴────┐                                                      │
│   ▼         ▼                                                      │
│ ens33     ens34   tcpdump -i ens33/ens34 ← See physical traffic   │
└────────────────────────────────────────────────────────────────────┘
```

### 2.5 Detailed tcpdump Examples

```bash
# Enter toolbox first
toolbox

# 1. Capture on br-ex (see all node traffic before distribution)
tcpdump -i br-ex -n -c 50 -e  # -e shows MAC addresses

# 2. Capture on physical NICs (see distributed traffic)
# Terminal 1:
tcpdump -i ens33 -n -c 50 -e

# Terminal 2:
tcpdump -i ens34 -n -c 50 -e

# 3. Capture specific traffic (e.g., API server)
tcpdump -i br-ex -n port 6443

# 4. Capture ICMP only
tcpdump -i ens33 -n icmp
tcpdump -i ens34 -n icmp

# 5. Show packet sizes (useful for MTU issues)
tcpdump -i ens33 -n -e -c 20 | awk '{print $NF}'

# 6. Capture to file for analysis
tcpdump -i br-ex -n -c 1000 -w /tmp/br-ex-capture.pcap
```

### 2.6 Verify Traffic is Using Both NICs

```bash
# Method 1: Watch packet counters in real-time
watch -n 1 'echo "=== ens33 ===" && cat /sys/class/net/ens33/statistics/tx_packets && \
            echo "=== ens34 ===" && cat /sys/class/net/ens34/statistics/tx_packets'

# Method 2: OVS interface statistics
ovs-vsctl list interface ens33 | grep -E "^(name|statistics)"
ovs-vsctl list interface ens34 | grep -E "^(name|statistics)"

# Method 3: Compare before/after traffic generation
# Before:
cat /sys/class/net/ens33/statistics/tx_packets
cat /sys/class/net/ens34/statistics/tx_packets

# Generate traffic (from VMs with different MACs)
# ...

# After:
cat /sys/class/net/ens33/statistics/tx_packets
cat /sys/class/net/ens34/statistics/tx_packets
```

**Important Note:** With balance-slb, traffic from a single source MAC will use only ONE interface. To see traffic on both NICs, you need:
- Multiple VMs (different MAC addresses)
- Or traffic from external sources with different MACs

### 2.4 Verify Balance-SLB Distribution

```bash
# Show MAC-to-port mappings
ovs-appctl fdb/show br-phy

# Show bond hash distribution
ovs-appctl bond/hash ovs-bond
```

**Understanding output:**
- Balance-SLB distributes based on source MAC + VLAN
- Different source MACs → potentially different interfaces
- Same source MAC → same interface (until rebalance)

### 2.5 Monitor Bond Statistics

```bash
# Detailed bond stats
ovs-appctl bond/show ovs-bond

# Interface statistics
ovs-vsctl list interface ens33 | grep -E "(statistics|name)"
ovs-vsctl list interface ens34 | grep -E "(statistics|name)"
```

**Check for:**
- `rx_packets`, `tx_packets` incrementing on both interfaces
- No excessive `rx_errors` or `tx_errors`

---

## 3. Failover Testing

### 3.1 Check Current Bond State

```bash
# Before test
ovs-appctl bond/show ovs-bond
```

Note which interfaces are `enabled`.

### 3.2 Simulate NIC Failure

**Option A: Administratively disable interface**
```bash
# Disable ens34
ip link set ens34 down

# Check bond status immediately
ovs-appctl bond/show ovs-bond

# Verify connectivity maintained
ping -c 5 <gateway-ip>
```

**Option B: Physical disconnect (if possible)**
- Disconnect cable from ens34
- Monitor bond status

### 3.3 Verify Failover Occurred

```bash
ovs-appctl bond/show ovs-bond
```

**Expected:**
```
slave ens33: enabled
  may_enable: true

slave ens34: disabled        # <-- Should show disabled
  may_enable: false
```

### 3.4 Verify Traffic Continues

```bash
# All traffic should now use ens33
toolbox tcpdump -i ens33 -n -c 20

# No traffic on ens34
toolbox tcpdump -i ens34 -n -c 5  # Should timeout with no packets
```

### 3.5 Restore Interface

```bash
# Re-enable ens34
ip link set ens34 up

# Wait a few seconds, then verify
sleep 5
ovs-appctl bond/show ovs-bond
```

**Expected:** Both interfaces show `enabled` again.

### 3.6 Verify Rebalancing

After restore, traffic should distribute again:

```bash
# Generate traffic
for i in {1..100}; do ping -c 1 <gateway> > /dev/null; done

# Check both interfaces have traffic
ovs-vsctl list interface ens33 | grep statistics
ovs-vsctl list interface ens34 | grep statistics
```

---

## 4. NetworkManager Integration

### 4.1 Verify NM Connections

```bash
nmcli connection show
```

**Expected connections:**
```
NAME              TYPE           DEVICE
ovs-if-br-ex      ovs-interface  br-ex
br-ex             ovs-bridge     br-ex
br-phy            ovs-bridge     br-phy
...
```

### 4.2 Verify NM is NOT Managing Physical NICs Directly

```bash
nmcli device status
```

**Expected:**
- `ens33` and `ens34` should show as `unmanaged` or managed by OVS
- `br-ex` should be `connected`

### 4.3 Understanding NM + OVS Relationship

```
┌──────────────────────────────────────────────────────────────────────┐
│                        NetworkManager                                 │
│                                                                       │
│  Responsibilities:                                                    │
│  - IP address assignment (on br-ex ovs-interface)                    │
│  - DNS configuration                                                  │
│  - Routing table                                                      │
│  - Persisting OVS connection profiles                                │
│                                                                       │
│  Does NOT handle:                                                     │
│  - Bond failover detection                                           │
│  - Traffic distribution                                               │
│  - Physical link monitoring                                          │
└──────────────────────────────────────────────────────────────────────┘
                                │
                                │ nmstate configures
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     Open vSwitch (OVS)                                │
│                                                                       │
│  Responsibilities:                                                    │
│  - Bond management (balance-slb)                                     │
│  - Link failure detection (carrier sense)                            │
│  - Automatic failover (sub-second)                                   │
│  - Traffic hash distribution                                         │
│  - MAC learning and forwarding                                       │
│                                                                       │
│  Failover behavior:                                                   │
│  - Monitors link state via kernel (carrier detect)                   │
│  - On link loss: immediately redirects all traffic to remaining NIC  │
│  - On link restore: rebalances hashes across both NICs               │
│  - No NM involvement required for failover                           │
└──────────────────────────────────────────────────────────────────────┘
```

### 4.4 Failover Deep Dive

**Why NetworkManager doesn't handle failover:**

```
Traditional Linux Bond (kernel):
  NM → configures bond → kernel handles failover

OVS Bond (balance-slb):
  NM → configures OVS profiles → OVS daemon handles failover
                                      │
                                      └── ovs-vswitchd monitors links
                                          and manages traffic flow
```

**Failover sequence when ens34 fails:**

```
Time 0ms:    ens34 link down detected by kernel
Time 1ms:    Kernel notifies OVS via netlink
Time 2ms:    ovs-vswitchd marks ens34 as disabled in bond
Time 3ms:    All hash buckets reassigned to ens33
Time 4ms:    Traffic continues through ens33
             (NetworkManager is not involved)
```

**Verify with:**
```bash
# Watch OVS bond state changes in real-time
ovs-appctl bond/show ovs-bond

# Check OVS logs for failover events
journalctl -u ovs-vswitchd -f
```

### 4.5 What NetworkManager Actually Manages

```bash
# List NM connection profiles
nmcli connection show

# Example output:
NAME                 TYPE            DEVICE
ovs-if-br-ex         ovs-interface   br-ex      # ← IP lives here
ovs-port-br-ex       ovs-port        br-ex
ovs-bridge-br-ex     ovs-bridge      br-ex
ovs-bridge-br-phy    ovs-bridge      br-phy
ovs-port-bond        ovs-port        ovs-bond   # ← Bond port definition
ovs-if-ens33         ovs-interface   ens33      # ← Slave interface
ovs-if-ens34         ovs-interface   ens34      # ← Slave interface
```

**NM profile hierarchy:**
```
ovs-bridge-br-ex
    └── ovs-port-br-ex
            └── ovs-if-br-ex (IP: 10.132.254.11/24)
    └── ovs-port-patch-ex-to-phy
            └── ovs-if-patch-ex-to-phy

ovs-bridge-br-phy
    └── ovs-port-patch-phy-to-ex
            └── ovs-if-patch-phy-to-ex
    └── ovs-port-bond (balance-slb)
            └── ovs-if-ens33
            └── ovs-if-ens34
```

### 4.6 Critical: IP Stability During Failover

**Why the IP never changes:**

```
                    ┌─────────────┐
                    │   br-ex     │ ◄── IP: 10.132.254.11
                    │ (internal)  │     Always stable
                    └──────┬──────┘
                           │
                    ┌──────┴──────┐
                    │ patch ports │  ◄── Virtual connection
                    └──────┬──────┘      Never fails
                           │
                    ┌──────┴──────┐
                    │   br-phy    │
                    └──────┬──────┘
                           │
                    ┌──────┴──────┐
                    │  ovs-bond   │  ◄── Failover happens HERE
                    │ balance-slb │      Below the IP layer
                    └──────┬──────┘
                      ┌────┴────┐
                      │         │
                   ens33     ens34
                    ▲          ✗
                    │       (failed)
                    │
              All traffic
              redirected
```

The IP is assigned to `br-ex` (ovs-interface), which is a **virtual internal port**. 
Physical NIC failures happen "below" this layer, so:
- IP remains assigned and reachable
- Routes don't change
- TCP connections survive (if timeout allows)
- Applications see no interface change

### 4.4 Verify NM Doesn't Interfere After Reboot

```bash
# Check NM logs for OVS-related messages
journalctl -u NetworkManager -b | grep -i ovs

# Verify configuration persisted
cat /etc/nmstate/openshift/applied  # Should exist
```

### 4.5 Test NM Reload (Non-Disruptive)

```bash
# Reload NM configuration
nmcli connection reload

# Verify OVS topology unchanged
ovs-vsctl show

# Verify connectivity
ping -c 3 <gateway>
```

---

## 5. VM Traffic Distribution Test

This test validates that VMs with different MAC addresses use different physical NICs.

### 5.1 Prerequisites

- OpenShift Virtualization installed
- At least 2 VMs running on the node

### 5.2 Identify VM MAC Addresses

```bash
# List VMs and their interfaces
oc get vmi -A -o wide

# Get MAC addresses from OVS
ovs-appctl fdb/show br-ex
```

### 5.3 Monitor Traffic per VM

```bash
# Filter tcpdump by VM MAC
toolbox tcpdump -i ens33 -n ether host <vm1-mac>
toolbox tcpdump -i ens34 -n ether host <vm2-mac>
```

**Expected:**
- Different VMs may use different physical NICs
- Same VM always uses same NIC (consistent hashing)

---

## 6. Performance Baseline

### 6.1 Measure Throughput

```bash
# Install iperf3 in toolbox
toolbox dnf install -y iperf3

# Run iperf3 server on another host
iperf3 -s

# From node (client)
toolbox iperf3 -c <server-ip> -t 30 -P 4
```

### 6.2 Compare Single vs Both NICs

```bash
# Test with both NICs
iperf3 -c <server-ip> -t 30 -P 4

# Disable one NIC and test again
ip link set ens34 down
iperf3 -c <server-ip> -t 30 -P 4
ip link set ens34 up
```

**Note:** With balance-slb, single-flow throughput is limited to one NIC. Multiple flows from different MACs can aggregate bandwidth.

---

## 7. Automated Validation Script

```bash
#!/bin/bash
# validate-balance-slb.sh

echo "=== OVS Balance-SLB Validation ==="
echo ""

echo "1. Checking OVS topology..."
ovs-vsctl show | grep -E "(Bridge|Port|Interface|type:)"
echo ""

echo "2. Checking bond status..."
ovs-appctl bond/show ovs-bond 2>/dev/null || echo "Bond not found"
echo ""

echo "3. Checking IP on br-ex..."
ip -4 addr show br-ex | grep inet
echo ""

echo "4. Testing connectivity..."
ping -c 3 -W 2 $(ip route | grep default | awk '{print $3}') > /dev/null && echo "Gateway: OK" || echo "Gateway: FAILED"
echo ""

echo "5. Checking interface statistics..."
for iface in ens33 ens34; do
    rx=$(cat /sys/class/net/$iface/statistics/rx_packets 2>/dev/null || echo "N/A")
    tx=$(cat /sys/class/net/$iface/statistics/tx_packets 2>/dev/null || echo "N/A")
    echo "$iface: RX=$rx TX=$tx"
done
echo ""

echo "6. Checking NM connections..."
nmcli -t -f NAME,TYPE,DEVICE connection show --active | grep -E "(ovs|br-)"
echo ""

echo "=== Validation Complete ==="
```

---

## 8. Quick Reference Commands

| Purpose | Command |
|---------|---------|
| Show OVS topology | `ovs-vsctl show` |
| Show bond status | `ovs-appctl bond/show ovs-bond` |
| Show MAC table | `ovs-appctl fdb/show br-phy` |
| Show bond hash | `ovs-appctl bond/hash ovs-bond` |
| Monitor interface | `toolbox tcpdump -i <iface> -n` |
| Check NM connections | `nmcli connection show` |
| Interface stats | `ovs-vsctl list interface <iface>` |
| Force rebalance | `ovs-appctl bond/rebalance ovs-bond` |

---

## 9. Expected vs Problem Indicators

### Healthy State

- Both NICs show `enabled` in bond
- Traffic visible on both interfaces (with multiple sources)
- IP reachable on br-ex
- No errors in `ovs-vsctl list interface`
- NM shows OVS connections active

### Problem Indicators

| Symptom | Possible Cause |
|---------|----------------|
| One NIC always disabled | Cable/hardware issue, check `dmesg` |
| No traffic on ens34 | Single source MAC, expected behavior |
| Bond not found | OVS not configured, check nmstate |
| High error count | MTU mismatch, duplex issues |
| NM recreating connections | `configure-ovs.sh` overwriting config |
