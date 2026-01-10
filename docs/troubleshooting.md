# Troubleshooting Guide

Common issues and solutions when deploying OVS balance-slb with OpenShift.

## Installation Fails at ~53%

### Symptoms
- Installation hangs around 53%
- No clear error in Assisted Installer UI
- Nodes appear to be stuck

### Root Cause
NMState filename does not match the discovered hostname.

### Solution
1. Check the exact hostname in Assisted Installer UI
2. Verify with `hostname` command on the node
3. Ensure your NMState YAML filename matches **exactly** (including FQDN if applicable)

```bash
# Example: if hostname is "ocp-node-0.example.com"
# Your file must be named: ocp-node-0.example.com.yml
```

---

## Ignition Version Mismatch

### Symptoms
- MachineConfig not applied
- Node boots with wrong network configuration

### Solution
Check your OpenShift version and use the correct Ignition spec:

| OpenShift | Ignition Spec |
|-----------|---------------|
| 4.17, 4.18 | 3.2.0 |
| 4.19+ | 3.4.0 |

For 4.17/4.18, also uncomment the `directories` section in MachineConfig:

```yaml
storage:
  directories:
  - path: /run/nodeip-configuration
    mode: 0755
    overwrite: true
```

---

## No Network Connectivity After Installation

### Symptoms
- Node is unreachable after reboot
- OVS bridges not configured

### Diagnosis

```bash
# Check OVS status
oc debug node/<node> -- chroot /host ovs-vsctl show

# Check if nmstate service ran
oc debug node/<node> -- chroot /host journalctl -u nmstate-configuration

# Check NetworkManager connections
oc debug node/<node> -- chroot /host nmcli con show
```

### Common Causes

1. **NMState file not found**: Filename mismatch with hostname
2. **OVS not ready**: nmstate service started before OVS
3. **Syntax error in YAML**: Validate your NMState YAML

---

## Bond Shows Only One Active Interface

### Symptoms
- `ovs-appctl bond/show` shows only one interface active
- Traffic not balanced

### Explanation
This is **expected behavior** for traffic with the same source MAC+VLAN (like pod traffic). Balance-slb only distributes traffic across interfaces when source MACs differ.

### Verification

```bash
oc debug node/<node> -- chroot /host ovs-appctl bond/show ovs-bond
```

For VM workloads with different MACs, you should see traffic distributed.

---

## Patch Ports Not Connected

### Symptoms
- br-ex and br-phy exist but no connectivity between them
- Traffic doesn't flow

### Diagnosis

```bash
oc debug node/<node> -- chroot /host ovs-vsctl show
```

Look for:
```
Bridge br-ex
    Port patch-ex-to-phy
        Interface patch-ex-to-phy
            type: patch
            options: {peer=patch-phy-to-ex}
```

### Solution
Ensure both patch ports are defined with correct peer references in your NMState YAML.

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
  mtu: 9000  # Must match on all interfaces and bridges
```

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

## Useful Commands

```bash
# Full OVS status
oc debug node/<node> -- chroot /host ovs-vsctl show

# Bond details
oc debug node/<node> -- chroot /host ovs-appctl bond/show ovs-bond

# NMState current config
oc debug node/<node> -- chroot /host nmstatectl show

# Check applied MachineConfigs
oc get mcp
oc get mc | grep br-ex

# Node network status
oc get nncp
oc get nnce
```
