# Detailed Deployment Guide: OVS Balance-SLB with Assisted Installer

This guide provides a complete walkthrough for deploying OpenShift on bare metal using OVS `balance-slb` bonding mode with the Assisted Installer.

## Table of Contents

- [Introduction](#introduction)
- [Understanding Balance-SLB](#understanding-balance-slb)
- [Architecture Overview](#architecture-overview)
- [The Real Problem](#the-real-problem)
- [Step-by-Step Deployment](#step-by-step-deployment)
- [Validation](#validation)
- [Lessons Learned](#lessons-learned)
- [Additional Considerations](#additional-considerations)
- [References](#references)

---

## Introduction

Deploying OpenShift on bare metal often requires network designs that are **not always compatible with existing physical switch configurations**. This is especially true in environments such as **CNV (OpenShift Virtualization)**, **Telco**, or **lab / edge deployments**, where reconfiguring switches (LACP, MLAG, port-channels) is either undesirable or simply impossible.

This guide documents a **practical and realistic approach** to deploying OpenShift using:

- Open vSwitch (OVS)
- An OVS bond in `balance-slb` mode
- **No physical switch configuration**
- Assisted Installer
- Static IPs (DHCP is possible and supported)

Although Balance SLB is in the GA (general availability) stage, there is no **complete or official documentation** covering this scenario from end to end. What follows is the result of trial, error, and reverse engineering of how Assisted Installer, Ignition, NMState, and OVS interact during **day-0 cluster installation**.

---

## Understanding Balance-SLB

### What is Open vSwitch (OVS)?

Open vSwitch is an open source virtual switch that enables programmatic network management. It is widely used in virtualization and cloud environments, including OpenShift, to create and manage network bridges, bonds, and other advanced network configurations.

### Balance-SLB Mode (Source Load Balancing)

The `balance-slb` mode is a type of link aggregation (bonding) supported by OVS that distributes network traffic between physical interfaces based on a hash of the source MAC address and VLAN tag. Unlike other bonding modes that require physical switch support (such as LACP), `balance-slb` operates independently of the switch, making it a flexible option for environments where switch configuration is limited or undesirable.

### Important Limitation

It is crucial to understand that although `balance-slb` provides load balancing, it does so by hashing the source MAC address and VLAN tag. This means that all traffic from OVN-Kubernetes pods, which use the same MAC address and VLAN, will not be balanced across physical interfaces. Instead, it will use only one of the bond interfaces.

`balance-slb` is most effective for virtualization workloads (VMs) that generate traffic with different source MAC addresses, allowing different VMs to use different physical interfaces for outgoing traffic.

### Why Use balance-slb Without Switch Configuration?

The goal is to optimize the use of network interfaces, providing redundancy and a certain level of load balancing for network traffic, especially in virtualization scenarios with KubeVirt.

Key characteristics:
- `balance-slb` operates at Layer 2 (MAC-based hashing)
- No switch-side LACP required
- Ideal for:
  - Bare metal clusters
  - Disconnected or constrained environments
  - PoCs and labs
  - CNV workloads where NIC redundancy matters

> **Note**: `balance-slb` is **not LACP**. It provides load spreading and failover without any switch awareness.

---

## Architecture Overview

This procedure deploys OpenShift with the following topology:

- Two OVS bridges:
  - `br-ex`: external / routable
  - `br-phy`: physical uplink bridge
- Patch ports connecting both bridges
- OVS bond using `balance-slb`
- IP configured **only on an OVS internal interface**

### Key Design Rules

- No IP on physical NICs
- No IP on the bond
- No VLANs in the final OVS topology
- Layer 3 lives only on `ovs-interface br-ex`

---

## The Real Problem

You are trying and failing miserably to successfully deploy an OpenShift cluster using OVS bridge with SLB Balance.

### Symptoms

- Installation consistently fails around **53%**
- No clear error in Assisted Installer UI
- No obvious failure in bootstrap logs
- Repeated retries with different manifests show no progress

### Root Cause (Not Obvious)

- Assisted Installer applies static network configuration **before the cluster exists**
- NMState manifests are matched **by filename**, not by MAC, IP, or role
- A mismatch between:
  - Node hostname
  - Assisted Installer UI
  - NMState filename

  **causes Ignition to silently skip the configuration**

> This failure mode produces **no explicit error**.

---

## Step-by-Step Deployment

### Tested Versions

| OpenShift | Ignition | Status |
|-----------|----------|--------|
| 4.18.30   | 3.2.0    | Working (requires ignition adjustments) |
| 4.19.21   | 3.4.0    | Working |
| 4.20.8    | 3.4.0    | Working |

> Make a note of your OpenShift version and the Ignition version used in it. This is a subtle detail, but one that causes problems when overlooked.

If you already have OCP 4.18 running and upgrade to 4.19 and 4.20, balance-slb will continue to work.

### Step 1: Assisted Installer Options

Create the cluster as usual, but enable:

- **Include custom manifests**
- **Static network configuration**

### Step 2: Temporary Bootstrap Network (Important)

At this stage, **do not start with OVS or bonds**.

Use a **simple, working static configuration** to allow Assisted Installer to progress.

This example uses:
- A single NIC
- A VLAN
- Static IP

> **Note**: VLANs are used **only for bootstrap**. They are **not used** in the final OVS / SLB topology.

Use the file `manifests/examples/bootstrap-simple-net.yml` as an example to create a simple configuration for the node network. Since this is a temporary configuration, use a minimalist approach, just to establish a connection with the node.

Generate the ISO, boot your nodes with it, and take note of the node names that appear in the console. You will need these names to correctly generate the custom manifests.

Proceed with the installation until the **Custom Manifests** step.

> Although the initial validation was done using a single NIC, the same procedure works with an active-backup bond during the Assisted Installer bootstrap phase. The custom manifests and OVS topology remain unchanged.

### Step 3: NMState Injection via MachineConfig

Be sure to select the `openshift` folder to upload the manifests.

#### Step 3.1: NMState Loader Service

Add the following MachineConfigs (always both):

- `05-nmstate-configuration-master.yml`
- `05-nmstate-configuration-worker.yml`

These install a systemd service that:
- Selects the correct NMState file
- Applies it during early boot
- Ensures OVS is available first

> **Tip**: In the Assisted Installer, there is a **Reset Cluster** option, which you can use to restart a failed cluster deployment without having to start from scratch.

### Step 4: Critical Filename Matching

When using **static IPs + custom NMState manifests**:

- Assisted Installer matches configuration **by filename**
- Not by MAC
- Not by IP
- Not by role

#### The Filename Must Exactly Match

- The hostname shown in the Assisted Installer UI
- The output of `hostname` on the node

In some environments, this means **FQDN**, not short hostname. For others, it's the short hostname.

```sh
$ hostname
node.example.com
```

> If the filename does not match exactly, Ignition will **silently skip** the configuration and the install will fail around ~53%.

Each node **requires its own YAML file**.

### Step 5: Final NMState (OVS + balance-slb)

This is where the **real topology** is created.

**Important**: The Linux kernel does not support balance-slb. In OpenShift 4.[18|19|20], Linux CoreOS **cannot perform balance-SLB** at the kernel level. Instead, **Open vSwitch (OVS) handles all load balancing** across multiple physical interfaces.

The IP address does **not** belong to the bond; it is assigned to an **OVS internal interface** (`ovs-interface`), which acts as the L3 endpoint. This internal interface is part of the `br-ex` bridge, which transparently forwards traffic while OVS performs load balancing on `br-phy`.

#### Recommended Object Sequence

To avoid nmstate issues, follow this order:

1. OVS Bridges (`br-ex`, `br-phy`)
2. OVS internal interface (with IP, on `br-ex`)
3. OVS bond with `balance-slb` (on `br-phy`)
4. Patch ports (connecting `br-ex` ↔ `br-phy`)
5. Physical interfaces (as bond members)

This approach ensures **IP stability** and allows OVS to manage traffic efficiently, keeping the kernel unaware of SLB operations.

After deploying the cluster, OVS will manage the network datapath. NetworkManager remains active but OVS controls traffic forwarding.

#### Design Choices Explained

- No VLANs
- No IP on the bond
- No IP on physical NICs
- IP only on `ovs-interface br-ex`
- `balance-slb` on an OVS bond
- Patch ports connecting `br-ex` and `br-phy`

This configuration is **deterministic** and reproducible.

### Step 6: Generate MachineConfigs

Each node's NMState file is Base64-encoded and injected into the MachineConfig. A script is provided to automate this process.

> The filenames **must match exactly** the Assisted Installer UI.

#### 6.1: Create NMState files for each node

Use the file `manifests/examples/nmstate-node-example.yml` as a template. For each node, create a file named `<hostname>.yml`, changing only:

- IP address
- NIC names
- DNS servers
- Default route

Example structure:
```
nmstate/
├── ocp-node-0.example.com.yml
├── ocp-node-1.example.com.yml
└── ocp-node-2.example.com.yml
```

#### 6.2: Configure nodes.conf

Create a `nodes.conf` file listing all nodes and their roles:

```bash
cp scripts/nodes.conf.example nodes.conf
```

Edit `nodes.conf`:
```
# Format: <hostname> <role>
ocp-node-0.example.com master
ocp-node-1.example.com master
ocp-node-2.example.com master
ocp-node-3.example.com worker
ocp-node-4.example.com worker
```

> The hostname must match exactly what Assisted Installer discovered.

#### 6.3: Generate MachineConfigs

Run the script:

```bash
./scripts/generate-machineconfig.sh -d ./nmstate -c ./nodes.conf
```

Options:
- `-d <dir>` — Directory containing nmstate `.yml` files (default: current directory)
- `-c <file>` — Path to nodes.conf (default: `./nodes.conf`)

Output:
```
Using nodes.conf: ./nodes.conf
Using nmstate dir: ./nmstate

Found 3 master(s), 2 worker(s)

Generated: 10-br-ex-master-mc.yml
Generated: 10-br-ex-worker-mc.yml

Done. Upload the generated files to the 'openshift/' folder in Assisted Installer.
```

#### 6.4: Upload to Assisted Installer

Upload all MachineConfigs to the `openshift/` folder:

```
openshift/05-nmstate-configuration-master.yml
openshift/05-nmstate-configuration-worker.yml
openshift/10-br-ex-master-mc.yml
openshift/10-br-ex-worker-mc.yml   # if you have workers
```

### Step 7: Deploy

1. Click **Install cluster**
2. Wait for the installation to complete

---

## Validation

### OVS Topology

```sh
oc debug node/<node> -- chroot /host ovs-vsctl show
```

Expected:
- `br-ex`
- patch ports
- OVS bond
- internal interface

### NMState

```sh
oc debug node/<node> -- chroot /host nmstatectl show
```

### NetworkManager

```sh
oc debug node/<node> -- chroot /host nmcli con show
```

---

## Lessons Learned

- Context matters more than copying examples
- Assisted Installer ≠ cluster runtime
- NMState is deterministic, but not verbose
- Functional does not always mean correct
- Filename mismatches cause silent failures

---

## Additional Considerations

- **Pod Traffic**: Keep in mind the limitation of `balance-slb` for OVN-Kubernetes pod traffic. If load balancing for pods is a priority, other bonding modes (such as LACP with switch support) or more advanced networking solutions may be required.

- **MTU**: Ensure that the MTU (Maximum Transmission Unit) is configured correctly on all interfaces and on the OVS bridge to avoid packet fragmentation issues.

- **Traffic Isolation**: To isolate different types of traffic (e.g., management traffic, VM traffic, storage traffic), consider creating dedicated VLANs and OVS bridges for each type of traffic, using the same `balance-slb` bond as the uplink.

---

## References

### Official Documentation

1. Red Hat. *Network bonding considerations - Advanced networking*. OKD Documentation.
   https://docs.okd.io/latest/networking/advanced_networking/network-bonding-considerations.html

2. Open vSwitch Project. *Bonding*. Open vSwitch Documentation.
   https://docs.openvswitch.org/en/stable/topics/bonding/

3. Red Hat. *Kubernetes NMState - Networking*. OpenShift Container Platform 4.19 Documentation.
   https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/networking/kubernetes-nmstate

4. OpenShift Examples. *Networking - KubeVirt*.
   https://examples.openshift.pub/kubevirt/networking/

### Additional Resources

5. Red Hat. *Installing an on-premise cluster with the Agent-based Installer*. OpenShift Container Platform 4.19.
   https://docs.redhat.com/en/documentation/openshift_container_platform/4.19/html/installing_an_on-premise_cluster_with_the_agent-based_installer/preparing-to-install-with-agent-based-installer

6. Red Hat. *Enabling OVS balance-slb mode - Installing on bare metal*. OKD 4.19.
   https://docs.okd.io/4.19/installing/installing_bare_metal/upi/installing-bare-metal.html#enabling-OVS-balance-slb-mode_installing-bare-metal

7. Red Hat. *Bonding considerations for OVS*. Red Hat Knowledgebase (requires subscription).
   https://access.redhat.com/solutions/67546

### Community Resources

8. RHsyseng. *RHCOS SLB Configuration*. GitHub.
   https://github.com/RHsyseng/rhcos-slb/tree/simplify-networking

9. Fontana, G. *OVS Bond Balance-SLB Cheatsheet*. GitHub.
   https://github.com/giofontana/cheatsheet/tree/main/OCP/CNV/Network/ovs-bond-balance-slb

10. Bratta, R. *NMState OVS Balance-SLB Example*. GitHub Gist.
    https://gist.github.com/rbbratta/f4ffbfc2cd5f1af84badcd91b128da93