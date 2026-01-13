# Troubleshooting OVS Balance-SLB Deployment

When deploying OpenShift with OVS balance-slb using the Assisted Installer, you may encounter various issues. This guide documents common problems and their solutions.

---

## Known Issues

### OpenShift 4.20 + Balance-SLB Incompatibility

**Status:** As of January 2026, OpenShift 4.20 with balance-slb configuration fails during bootstrap, even when network configuration is applied correctly.

**Symptoms:**
- Installation stuck at ~61% ("Waiting for bootkube")
- OVS topology appears correct on masters
- Bootstrap node cannot transition to master
- Only 2 of 3 masters register with the cluster

**Workaround:** Use OpenShift 4.19 until this issue is resolved.

---

## Installation Stuck at ~53%

### Symptoms
- Installation hangs around 53%
- No explicit error in Assisted Installer UI
- Nodes appear to be up but cluster doesn't progress

### Root Causes and Fixes

#### Cause 1: Hostname Mismatch

The `nmstate-configuration.sh` script uses **short hostname** (`hostname -s`), but manifests often use **FQDN**.

**Symptom:**
```
No configuration found at /etc/nmstate/openshift/ocp-dualstack-0.yml or /etc/nmstate/openshift/cluster.yml
```

**Fix:** Use short hostname in MachineConfig file paths:
```yaml
# WRONG
path: /etc/nmstate/openshift/ocp-dualstack-0.baremetalbr.com.yml

# CORRECT
path: /etc/nmstate/openshift/ocp-dualstack-0.yml
```

#### Cause 2: Missing Controller Field (nmstate 2.2.54+)

OpenShift 4.19+ uses nmstate 2.2.54, which requires explicit `controller` field for `ovs-interface`.

**Symptom:**
```
NmstateError: InvalidArgument: Connection(MissingSetting):ovs-interface: setting required for connection of type 'ovs-interface'
```

**Fix:** Add `controller` field and list interface as bridge port:

```yaml
# Bridge must list the internal interface as a port
- name: br-ex
  type: ovs-bridge
  state: up
  bridge:
    allow-extra-patch-ports: true
    port:
    - name: patch-ex-to-phy
    - name: br-ex              # ADD THIS

# Interface must reference its controller
- name: br-ex
  type: ovs-interface
  state: up
  controller: br-ex            # ADD THIS
  copy-mac-from: ens33
  ipv4:
    enabled: true
    address:
    - ip: 10.132.254.11
      prefix-length: 24
```

#### Cause 3: Ignition Version Mismatch

Different OpenShift versions require different Ignition spec versions.

**Symptom:**
```
Ignition has failed. Please ensure your config is valid. Note that only Ignition spec v3.0.0+ configs are accepted.
```

**Fix:** Use correct Ignition version:

| OpenShift | Ignition Spec |
|-----------|---------------|
| 4.17, 4.18 | 3.2.0 |
| 4.19+ | 3.4.0 |

#### Cause 4: Directory Creation Conflict (4.19+)

OpenShift 4.19+ automatically creates `/run/nodeip-configuration`.

**Symptom:**
```
error removing existing file /sysroot/run/nodeip-configuration
```

**Fix:** Remove the `directories` section from MachineConfig:
```yaml
# REMOVE THIS SECTION for 4.19+
# directories:
# - path: /run/nodeip-configuration
#   mode: 0755
#   overwrite: true
```

For 4.17/4.18, **keep** the directories section:
```yaml
storage:
  directories:
  - path: /run/nodeip-configuration
    mode: 0755
    overwrite: true
```

---

## Installation Stuck at ~61%

### Symptoms
- Installation hangs at 61% ("Waiting for bootkube")
- CPU usage on nodes drops
- Bootstrap services appear stuck

### Diagnosis

```bash
# On bootstrap node
ssh core@<bootstrap-ip>
sudo -i
journalctl -u bootkube.service -b --no-pager | tail -50

# Check pod status
export KUBECONFIG=/etc/kubernetes/kubeconfig
kubectl get nodes
kubectl get pods -A | grep -v Running
```

### Common Causes

1. **Missing master nodes** - Verify all expected masters are registered
2. **etcd not forming quorum** - Check etcd pods on masters
3. **Certificate issues** - Check for "secret not found" errors
4. **OpenShift 4.20 bug** - See Known Issues section above

---

## No Network Connectivity After Installation

### Symptoms
- Node is unreachable after reboot
- OVS bridges not configured
- NMState configuration not applied

### Diagnosis

```bash
# Check OVS status
oc debug node/<node> -- chroot /host ovs-vsctl show

# Check if nmstate service ran
oc debug node/<node> -- chroot /host journalctl -u nmstate.service -b

# Check nmstate-configuration service
oc debug node/<node> -- chroot /host journalctl -u nmstate-configuration.service -b

# Check NetworkManager connections
oc debug node/<node> -- chroot /host nmcli con show
```

### Common Causes

1. **NMState file not found**: Filename mismatch with hostname
2. **OVS not ready**: nmstate service started before OVS
3. **Syntax error in YAML**: Validate your NMState YAML
4. **configure-ovs.sh overwrote config**: Check if `/etc/nmstate/openshift/applied` exists

---

## Bond Shows Only One Active Interface

### Symptoms
- `ovs-appctl bond/show` shows only one interface active
- Traffic not balanced across NICs

### Explanation

This is **expected behavior** for balance-slb. Traffic with the same source MAC+VLAN (like pod traffic from OVN-Kubernetes) will use only one interface. Balance-slb distributes traffic only when source MACs differ.

### Verification

```bash
oc debug node/<node> -- chroot /host ovs-appctl bond/show ovs-bond
```

**Expected output:**
```
---- ovs-bond ----
bond_mode: balance-slb

slave ens33: enabled
  may_enable: true
  hash 0-127: 128

slave ens34: enabled
  may_enable: true
  hash 128-255: 128
```

For VM workloads with different MACs, traffic will be distributed across interfaces.

---

## Patch Ports Not Connected

### Symptoms
- br-ex and br-phy exist but no connectivity between them
- Traffic doesn't flow between bridges

### Diagnosis

```bash
oc debug node/<node> -- chroot /host ovs-vsctl show
```

**Expected output:**
```
Bridge br-ex
    Port patch-ex-to-phy
        Interface patch-ex-to-phy
            type: patch
            options: {peer=patch-phy-to-ex}
Bridge br-phy
    Port patch-phy-to-ex
        Interface patch-phy-to-ex
            type: patch
            options: {peer=patch-ex-to-phy}
```

### Solution

Ensure both patch ports are defined with correct peer references:

```yaml
- name: patch-ex-to-phy
  type: ovs-interface
  state: up
  patch:
    peer: patch-phy-to-ex

- name: patch-phy-to-ex
  type: ovs-interface
  state: up
  patch:
    peer: patch-ex-to-phy
```

---

## MTU Issues

### Symptoms
- Large packets dropped
- SSH works but large file transfers fail
- Intermittent connectivity

### Solution

Ensure consistent MTU across all interfaces:

```yaml
- name: ens33
  type: ethernet
  state: up
  mtu: 9000  # Must match on all interfaces

- name: ens34
  type: ethernet
  state: up
  mtu: 9000
```

---

## Network Loops / Broadcast Storms

### Symptoms
- Network becomes unresponsive
- High CPU on switch/host
- Packet loss

### Cause

Balance-slb with two NICs connected to an unmanaged switch can cause loops.

### Solution

Enable STP on br-phy:

```yaml
- name: br-phy
  type: ovs-bridge
  state: up
  bridge:
    options:
      stp: true
    port:
    - name: patch-phy-to-ex
    - name: ovs-bond
      link-aggregation:
        mode: balance-slb
        port:
        - name: ens33
        - name: ens34
```

> **Note:** Do NOT enable STP on br-ex (managed by OVN-Kubernetes).

---

## Live Fix Procedure

If installation is stuck at 53%, you can fix nodes without restarting the entire deployment.

### Step 1: Access the Node

```bash
ssh core@<node-ip>
sudo -i
```

### Step 2: Check Current State

```bash
# Check if nmstate configuration was applied
journalctl -u nmstate.service -b

# Check OVS topology
ovs-vsctl show

# Check if config file exists
ls -la /etc/nmstate/openshift/
cat /etc/nmstate/*.yml
```

### Step 3: Fix the Configuration

```bash
# Edit the nmstate configuration
vi /etc/nmstate/ocp-dualstack-0.yml

# Add the missing fields:
# 1. controller: br-ex (to ovs-interface)
# 2. - name: br-ex (to bridge ports)
```

### Step 4: Reapply Configuration

```bash
# Remove the applied flag
rm -f /etc/nmstate/openshift/applied

# Apply the configuration
nmstatectl apply /etc/nmstate/ocp-dualstack-0.yml
```

### Step 5: Verify

```bash
# Check OVS topology
ovs-vsctl show

# Expected output:
#   Bridge br-phy
#       Port patch-phy-to-ex
#       Port ovs-bond
#           Interface ens33
#           Interface ens34
#   Bridge br-ex
#       Port patch-ex-to-phy
#       Port br-ex
#           Interface br-ex (internal)

# Check IP assignment
ip addr show br-ex

# Test connectivity
ping -c 3 <gateway-ip>
```

### Step 6: Repeat for All Nodes

Apply the same fix on all nodes. The installation should progress automatically once all nodes have correct network configuration.

---

## Reset and Retry

If all else fails, use the **Reset Cluster** option in Assisted Installer:

1. Go to cluster details in Assisted Installer
2. Click **Reset Cluster**
3. Boot nodes with the same discovery ISO
4. Adjust your YAML files
5. Re-upload manifests and retry

This preserves your cluster configuration while allowing you to fix network issues.

---

## Version Compatibility Matrix

| OpenShift | Ignition | nmstate | /run/nodeip-configuration | controller field | Status |
|-----------|----------|---------|---------------------------|------------------|--------|
| 4.17 | 3.2.0 | 2.2.x | Required in MC | Optional | Works |
| 4.18 | 3.2.0 | 2.2.x | Required in MC | Optional | Works |
| 4.19 | 3.4.0 | 2.2.54 | Remove from MC | Required | Works |
| 4.20 | 3.4.0 | 2.2.54 | Remove from MC | Required | Bootstrap issues |

---

## Quick Checklist

### Before Deployment

- [ ] Ignition version matches OpenShift version
- [ ] No `directories` section for `/run/nodeip-configuration` (4.19+)
- [ ] NMState files use **short hostname** (not FQDN)
- [ ] `ovs-interface` has `controller` field
- [ ] `ovs-bridge` lists internal interface as port
- [ ] Base64 encoding is correct
- [ ] Using OpenShift 4.19 (not 4.20) for balance-slb

### During Stuck Deployment

- [ ] Check `journalctl -u nmstate.service -b` for errors
- [ ] Verify `ovs-vsctl show` topology
- [ ] Fix YAML and reapply with `nmstatectl apply`
- [ ] Repeat on all nodes

---

## Useful Commands

### OVS Commands

```bash
# Full OVS status
ovs-vsctl show

# Bond details
ovs-appctl bond/show ovs-bond

# MAC table
ovs-appctl fdb/show br-phy

# Force bond rebalance
ovs-appctl bond/rebalance ovs-bond
```

### NMState Commands

```bash
# Current network state
nmstatectl show

# Apply configuration
nmstatectl apply /etc/nmstate/config.yml
```

### OpenShift Commands

```bash
# Check MachineConfigs
oc get mc | grep -E "(nmstate|br-ex)"

# Check MachineConfigPools
oc get mcp

# Debug node
oc debug node/<node> -- chroot /host bash

# Node network config policies
oc get nncp
oc get nnce
```

### Systemd Services

```bash
# NMState configuration service
journalctl -u nmstate-configuration.service -b

# NMState apply service
journalctl -u nmstate.service -b

# OVS configuration service
journalctl -u ovs-configuration.service -b

# Kubelet
journalctl -u kubelet -b | tail -50
```



<!---
journalctl -u nmstate-configuration.service -b

Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com systemd[1]: Starting Applies per-node NMState network configuration...
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + systemctl -q is-enabled mtu-migration
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com systemctl[3290]: Failed to get unit file state for mtu-migration.service: No such file or directory
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + echo 'Cleaning up left over mtu migration configuration'
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: Cleaning up left over mtu migration configuration
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + rm -rf /etc/cno/mtu-migration
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + '[' -e /etc/nmstate/openshift/applied ']'
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + src_path=/etc/nmstate/openshift
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + dst_path=/etc/nmstate
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com systemd[1]: nmstate-configuration.service: Deactivated successfully.
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3292]: ++ hostname -s
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com systemd[1]: Finished Applies per-node NMState network configuration.
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + hostname=ocp-dualstack-0
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + host_file=ocp-dualstack-0.yml
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + cluster_file=cluster.yml
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + config_file=
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + '[' -s /etc/nmstate/openshift/ocp-dualstack-0.yml ']'
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + '[' -s /etc/nmstate/openshift/cluster.yml ']'
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + echo 'No configuration found at /etc/nmstate/openshift/ocp-dualstack-0.yml or /etc/nmstate/openshift/cluster.yml'
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: No configuration found at /etc/nmstate/openshift/ocp-dualstack-0.yml or /etc/nmstate/openshift/cluster.yml
Jan 11 19:27:35 ocp-dualstack-0.baremetalbr.com nmstate-configuration.sh[3289]: + exit 0
--->