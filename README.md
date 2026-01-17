# OpenShift OVS Balance-SLB

Deploy OpenShift on bare metal with OVS bond in `balance-slb` mode - no switch configuration required.

## Overview

This repository provides manifests and documentation for deploying OpenShift clusters using Open vSwitch (OVS) with `balance-slb` bonding mode. This approach enables NIC redundancy and load balancing without requiring LACP or any physical switch configuration.

**Ideal for:**

- Bare metal clusters
- OpenShift Virtualization (CNV) workloads
- Disconnected or constrained environments
- Labs and PoCs

## Visual Guide

For convenience, there’s also a more detailed guide **[here](assisted-installer/detailed-guide.md)**, and a rendered version with diagrams and screenshots available **[here](https://linuxelite.com.br/blog/openshift-balance-slb/)**. The Git repo remains the canonical source.

## Architecture

![Balance SLB](pictures/balance-slb.avif "Title")

## Tested Versions

| OpenShift | Ignition | Status |
|-----------|----------|--------|
| 4.18.x    | 3.2.0    | Working (requires adjustments) |
| 4.19.x    | 3.4.0    | Working |
| 4.20.x    | 3.4.0    | Working |

## Quick Start

### Prerequisites

- 2+ physical NICs per node
- Assisted Installer access
- Static IP planning

### Steps

1. **Create cluster in Assisted Installer** with:
   - Include custom manifests
   - Static network configuration

2. **Configure temporary bootstrap network** using a simple static IP (single NIC or active-backup bond)

3. **Note discovered hostnames** - filenames must match exactly

4. **Upload MachineConfigs** to `openshift/` folder:

   ```
   openshift/05-nmstate-configuration-master.yml
   openshift/05-nmstate-configuration-worker.yml
   openshift/10-br-ex-master-mc.yml
   openshift/10-br-ex-worker-mc.yml
   ```

5. **Install cluster**

> **Critical**: NMState filenames must match hostnames exactly, or installation fails silently at ~53%.

## Repository Structure

```
.
├── README.md
├── docs/
│   └── detailed-guide.md        # Full step-by-step guide
├── manifests/
│   ├── 05-nmstate-configuration-master.yml
│   ├── 05-nmstate-configuration-worker.yml
│   └── examples/
│       ├── nmstate-node-example.yml
│       ├── 10-br-ex-master-mc.yml
│       └── 10-br-ex-worker-mc.yml
└── scripts/
    └── generate-machineconfig.sh
```

## Key Concepts

| Concept | Description |
|---------|-------------|
| **balance-slb** | OVS bonding mode using MAC+VLAN hash. No switch support needed. |
| **br-ex** | External bridge where the node IP is configured (ovs-interface). |
| **br-phy** | Physical uplink bridge containing the OVS bond. |
| **Patch ports** | Connect br-ex ↔ br-phy internally. |

### Limitations

- Pod traffic (OVN-Kubernetes) uses same MAC/VLAN - **not load balanced**
- Best suited for VM workloads with diverse MAC addresses
- Linux kernel does not support balance-slb natively - OVS handles it

## Validation

```bash
# Check OVS topology
oc debug node/<node> -- chroot /host ovs-vsctl show

# Check NMState
oc debug node/<node> -- chroot /host nmstatectl show

# Check NetworkManager connections
oc debug node/<node> -- chroot /host nmcli con show
```

## Where configuration takes place in coreOS

```
sh-5.1# systemctl status nmstate-configuration.service
○ nmstate-configuration.service - Applies per-node NMState network configuration
     Loaded: loaded (/etc/systemd/system/nmstate-configuration.service; enabled; preset: disabled)
     Active: inactive (dead) since Sat 2026-01-10 21:15:53 UTC; 14min ago
   Main PID: 2145 (code=exited, status=0/SUCCESS)
        CPU: 15ms

Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com systemd[1]: Finished Applies per-node NMState network configuration.
Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com nmstate-configuration.sh[2145]: + hostname=ocp-dualstack-1
Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com nmstate-configuration.sh[2145]: + host_file=ocp-dualstack-1.yml
Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com nmstate-configuration.sh[2145]: + cluster_file=cluster.yml
Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com nmstate-configuration.sh[2145]: + config_file=
Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com nmstate-configuration.sh[2145]: + '[' -s /etc/nmstate/openshift/ocp-dualstack-1.yml ']'
Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com nmstate-configuration.sh[2145]: + '[' -s /etc/nmstate/openshift/cluster.yml ']'
Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com nmstate-configuration.sh[2145]: + echo 'No configuration found at /etc/nmstate/openshift/ocp-dualstack-1.yml or /etc/nmstate/openshift/cluster.yml'
Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com nmstate-configuration.sh[2145]: No configuration found at /etc/nmstate/openshift/ocp-dualstack-1.yml or /etc/nmstate/openshift/cluster.yml
Jan 10 21:15:53 ocp-dualstack-1.baremetalbr.com nmstate-configuration.sh[2145]: + exit 0
```

## Documentation

- [Detailed Deployment Guide](assisted-installer/detailed-guide.md)
- [Troubleshooting](docs/troubleshooting.md)

## References

- [OVS Bonding Documentation](https://docs.openvswitch.org/en/stable/topics/bonding/)
- [OKD - Enabling OVS balance-slb mode](https://docs.okd.io/4.19/installing/installing_bare_metal/upi/installing-bare-metal.html#enabling-OVS-balance-slb-mode_installing-bare-metal)
- [OpenShift NMState Operator](https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/networking/kubernetes-nmstate)
