# How to configure OVS balance-slb bonding on OpenShift HCP worker nodes

## Environment

- Red Hat OpenShift Container Platform 4.19, 4.20
- Hosted Control Planes (HCP)
- Bare metal worker nodes with 2 physical NICs
- OVN-Kubernetes network plugin
- Physical switch ports configured as 802.1Q trunk (LACP/LAG not required)

> **Note:** This procedure was validated on OpenShift 4.19 and 4.20. Future OpenShift versions may introduce changes to nmstate handling or OVS configuration. Verify compatibility before applying to newer versions.

## Issue

Customers deploying OpenShift Hosted Control Planes on bare metal need network redundancy without LACP/LAG switch configuration. The agent-based installer and NMStateConfig CR do not support OVS balance-slb bonding mode.

**Limitations of agent-based installer:**

| Bond Mode | Supported in agent-config? | Switch Requirement |
|-----------|---------------------------|-------------------|
| active-backup | Yes | None |
| 802.3ad (LACP) | Yes | LACP/LAG required |
| balance-xor | Yes | None when using `options: xmit_hash_policy: vlan+srcmac`|
| balance-slb | **No** | None |

OVS balance-slb provides load distribution across links without requiring switch-side configuration, but must be configured post-installation.

## Resolution

Deploy nmstate configuration files via MachineConfig embedded in a ConfigMap, referenced by the NodePool. The `nmstate-configuration.service` (OpenShift component) automatically applies the configuration based on hostname.

**This approach uses only product-provided interfaces:**
- `/etc/nmstate/openshift/<hostname>.yml` - Standard nmstate configuration path
- `nmstate-configuration.service` - OpenShift's nmstate service
- MachineConfig via ConfigMap - Standard HCP configuration method

### Prerequisites

| Requirement | Description |
|-------------|-------------|
| 2 NICs | Each node must have 2 physical NICs for the bond |
| NIC names | All nodes in the NodePool must have NIC names |
| Node inventory | Short hostname, IP, prefix, VLAN, gateway, DNS for each node |
| Switch configuration | Trunk ports allowing required VLANs (no LACP needed) |
| Console access | BMC/IPMI/iLO/iDRAC access for emergency recovery |
| Core user password | Set password for `core` user on nodes for console login |

> **Important:** Before applying this configuration, ensure you have console access to the nodes and have set a password for the `core` user. This is critical for troubleshooting if network connectivity is lost during the configuration process.

### When to Apply the Configuration

| Scenario | Reboot Required? | Behavior |
|----------|------------------|----------|
| ConfigMap in `spec.config` **before** creating nodes | **No** | Ignition delivers nmstate files on first boot; nodes start with balance-slb configured |
| ConfigMap added to **existing** NodePool | **Yes** | HCP triggers rolling reboot (InPlace) or node replacement (Replace) |

**Recommendation:** When possible, add the ConfigMap reference to the NodePool YAML **before** creating the nodes. This avoids any additional reboot and ensures nodes are correctly configured from the first boot.

**Example - NodePool with ConfigMap from the start:**

```yaml
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: my-nodepool
  namespace: clusters-myhcp
spec:
  clusterName: my-hosted-cluster
  replicas: 3
  config:
  - name: balance-slb-config    # <-- Add BEFORE creating the hosted cluster
  management:
    autoRepair: false
    upgradeType: InPlace
  platform:
    agent:
      agentLabelSelector:
        matchLabels:
          cluster-name: my-hosted-cluster
    type: Agent
  release:
    image: quay.io/openshift-release-dev/ocp-release:4.20.10-x86_64
```

With this approach:
1. Ignition delivers `/etc/nmstate/openshift/<hostname>.yml` during node provisioning
2. `nmstate-configuration.service` applies the configuration on first boot
3. Node joins the cluster with balance-slb already configured
4. No additional reboot required

**TIP**: To verify the namespace of your Hosted Cluster: `oc get hc -A`

### Procedure

#### Step 1: Generate nmstate Configuration for Each Node

For each node, create an nmstate YAML file. Example for `ocp-worker-01`:

* Note that in this example, the nodes were originally configured using an NMState configuration that defines a Linux bond with VLAN 100. This configuration is being replaced by an OVS bond.

```yaml
# /etc/nmstate/openshift/ocp-worker-01.yml
interfaces:
  # Remove existing Linux bond and VLAN interface
  - name: bond0
    type: bond
    state: absent

  - name: bond0.100
    type: vlan
    state: absent

  - name: br-ex
    type: ovs-bridge
    state: up
    ipv4:
      enabled: false
      dhcp: false
    ipv6:
      enabled: false
      dhcp: false
    bridge:
      allow-extra-patch-ports: true
      port:
      - name: br-ex
      - name: patch-ex-to-phy
    ovs-db:
      external_ids:
        bridge-uplink: "patch-ex-to-phy"

  - name: br-ex
    type: ovs-interface
    state: up
    mtu: 9000
    copy-mac-from: ens33
    ipv4:
      enabled: true
      address:
      - ip: 10.132.254.21
        prefix-length: 24
    ipv6:
      enabled: false
      dhcp: false

  - name: br-phy
    type: ovs-bridge
    state: up
    ipv4:
      enabled: false
      dhcp: false
    ipv6:
      enabled: false
      dhcp: false
    bridge:
      allow-extra-patch-ports: true
      port:
      - name: patch-phy-to-ex
        vlan:
          mode: access
          tag: 100
      - name: ovs-bond
        link-aggregation:
          mode: balance-slb
          port:
          - name: ens33
          - name: ens34

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

  - name: ens33
    type: ethernet
    state: up
    mtu: 9000
    ipv4:
      enabled: false
    ipv6:
      enabled: false

  - name: ens34
    type: ethernet
    state: up
    mtu: 9000
    ipv4:
      enabled: false
    ipv6:
      enabled: false

dns-resolver:
  config:
    server:
    - 10.132.254.102
    - 10.132.254.103

routes:
  config:
  - destination: 0.0.0.0/0
    next-hop-address: 10.132.254.10
    next-hop-interface: br-ex

ovn:
  bridge-mappings:
    - bridge: br-phy
      localnet: vmnet
      state: present
```

**Customization per node:**

| Field | Location in YAML | Description |
|-------|------------------|-------------|
| bond0.XXX | `interfaces[1].name` | Existing VLAN interface to remove (match your VLAN ID) |
| IP | `interfaces[3].ipv4.address[0].ip` | Node-specific IP address |
| prefix-length | `interfaces[3].ipv4.address[0].prefix-length` | Network prefix (e.g., 24, 25, 26) |
| copy-mac-from | `interfaces[3].copy-mac-from` | First NIC name |
| tag | `interfaces[4].bridge.port[0].vlan.tag` | VLAN ID |
| port names | `interfaces[4].bridge.port[1].link-aggregation.port` | NIC names |
| server | `dns-resolver.config.server` | DNS servers |
| next-hop-address | `routes.config[0].next-hop-address` | Gateway |

> **Note:** The `state: absent` entries for `bond0` and `bond0.XXX` ensure the existing Linux bond configuration is removed before applying the OVS balance-slb configuration.

#### Step 2: Create ConfigMap with MachineConfig

Encode each nmstate file in base64 and create a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: balance-slb-config
  namespace: clusters-<hosted-cluster-name>
data:
  config: |
    apiVersion: machineconfiguration.openshift.io/v1
    kind: MachineConfig
    metadata:
      labels:
        machineconfiguration.openshift.io/role: worker
      name: 99-ovs-balance-slb
    spec:
      config:
        ignition:
          version: 3.2.0
        storage:
          files:
          - path: /etc/nmstate/openshift/ocp-worker-01.yml
            mode: 0644
            overwrite: true
            contents:
              source: data:text/plain;charset=utf-8;base64,<BASE64_ENCODED_NMSTATE_1>
          - path: /etc/nmstate/openshift/ocp-worker-02.yml
            mode: 0644
            overwrite: true
            contents:
              source: data:text/plain;charset=utf-8;base64,<BASE64_ENCODED_NMSTATE_2>
          - path: /etc/nmstate/openshift/ocp-worker-03.yml
            mode: 0644
            overwrite: true
            contents:
              source: data:text/plain;charset=utf-8;base64,<BASE64_ENCODED_NMSTATE_3>
```

To encode nmstate files:

```bash
base64 -w0 ocp-worker-01.yml
```

#### Step 3: Apply ConfigMap

```bash
oc apply -f balance-slb-configmap.yaml
```

#### Step 4: Reference in NodePool

**Option A: New NodePool (recommended)**

Include the ConfigMap reference in the NodePool YAML before creating it:

```yaml
spec:
  config:
  - name: balance-slb-config
```

Nodes will boot with balance-slb already configured. No reboot needed.

**Option B: Existing NodePool**

```bash
oc -n clusters patch nodepool <nodepool-name> --type=merge -p '
spec:
  config:
  - name: balance-slb-config
'
```

With `upgradeType: InPlace`, HCP will trigger a rolling reboot of the nodes to apply the configuration.

#### Step 5: Monitor Node Status

**For new NodePools:**

Watch nodes join the cluster:

```bash
oc get nodes -w
```

Nodes should reach `Ready` state with balance-slb already configured.

**For existing NodePools:**

Monitor the rolling reboot:

```bash
oc get nodes -w
```

Nodes will go `NotReady` > `Ready` one at a time as they reboot and apply the new configuration.

#### Step 6: Verify Configuration

After nodes return to `Ready` state:

```bash
# Check bond mode
oc debug node/<node-name> -- chroot /host ovs-appctl bond/show ovs-bond

# Expected output includes:
# bond_mode: balance-slb
# may_enable: true (for both members)
```

Verify on all nodes:

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  echo "=== $node ==="
  oc debug $node -- chroot /host ovs-appctl bond/show ovs-bond 2>/dev/null | grep -E "bond_mode|may_enable"
done
```

##### Post-Configuration State

After successful configuration, the network state should be:

**Interface status (`ip link show`):**

| Interface | State | Master | Notes |
|-----------|-------|--------|-------|
| ens33 | UP | ovs-system | Physical NIC, now OVS slave |
| ens34 | UP | ovs-system | Physical NIC, now OVS slave |
| bond0 | REMOVED | - | Linux bond disabled, no slaves |
| bond0.XXX | REMOVED | - | VLAN interface disabled |
| br-ex | UP | - | OVS bridge with node IP |

**Expected `ip link show` output:**

```
2: ens33: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 ... master ovs-system state UP
3: ens34: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 ... master ovs-system state UP
10: br-ex: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 9000 ... state UNKNOWN
    inet 10.132.254.x/24 ...
```

**NetworkManager connections (`/etc/NetworkManager/system-connections/`):**

New files are created automatically for the OVS configuration:
- `br-ex-br.nmconnection`, `br-ex-if.nmconnection`, `br-ex-port.nmconnection`
- `br-phy-br.nmconnection`
- `ovs-bond-port.nmconnection`
- `ens33.nmconnection`, `ens34.nmconnection`
- `patch-ex-to-phy-*.nmconnection`, `patch-phy-to-ex-*.nmconnection`

### Key Benefits

| Benefit | Description |
|---------|-------------|
| **No custom scripts** | Uses only product-provided interfaces |
| **No custom systemd units** | Relies on `nmstate-configuration.service` from OpenShift |
| **Zero reboot for new nodes** | When ConfigMap is applied before node creation |
| **Declarative** | Configuration is auditable YAML, no runtime logic |
| **Support-friendly** | Standard nmstate files that Red Hat support can analyze |

### Architecture

---

![Before Migration (Linux Bond – agent-config default)](linux-bond.avif)

---

![After Migration (OVS Bond – balance-slb)](ovs-bond.avif)

---

**Key differences:**

| Aspect | Linux Bond | OVS Balance-SLB |
|--------|------------|-----------------|
| Bond type | Kernel bond (bond0) | OVS bond (ovs-bond) |
| NIC master | `master bond0` | `master ovs-system` |
| VLAN handling | bond0.XXX interface | Patch port with access tag |
| Node IP location | bond0.XXX | br-ex |
| Switch requirement | LACP for 802.3ad | None |

**Key components:**
- **br-phy**: Physical bridge with OVS bond and VLAN tagging
- **br-ex**: External bridge for OVN (holds node IP)
- **patch ports**: Connect br-phy to br-ex with VLAN access mode
- **ovs-bond**: Balance-SLB bond with both NICs

## Root Cause

The agent-based installer validates network configuration against a schema that does not include OVS-native bond modes. Balance-slb is an OVS-specific mode, not a Linux kernel bond mode.

| Configuration Method | Supports balance-slb | Reason |
|---------------------|---------------------|--------|
| agent-config.yaml | No | Schema validation |
| NMStateConfig CR | No | Assisted Service validation |
| /etc/nmstate/openshift/*.yml | **Yes** | Direct nmstate, post-install |

The path `/etc/nmstate/openshift/` is the product-provided interface for custom nmstate configurations. The `nmstate-configuration.service` automatically loads `$(hostname -s).yml` during boot.

## Diagnostic Steps

**Verify nmstate file exists:**

```bash
oc debug node/<node> -- chroot /host ls -la /etc/nmstate/openshift/
```

**Check nmstate file content:**

```bash
oc debug node/<node> -- chroot /host cat /etc/nmstate/openshift/<hostname>.yml
```

**Check bond status:**

```bash
oc debug node/<node> -- chroot /host ovs-appctl bond/show ovs-bond
```

**Check OVS bridge structure:**

```bash
oc debug node/<node> -- chroot /host ovs-vsctl show
```

**Check bridge-mappings:**

```bash
oc debug node/<node> -- chroot /host ovs-vsctl get Open_vSwitch . external_ids:ovn-bridge-mappings
```

**Check nmstate-configuration service:**

```bash
oc debug node/<node> -- chroot /host systemctl status nmstate-configuration.service
```

**Verify old bond0 was removed:**

```bash
oc debug node/<node> -- chroot /host ip link show bond0

oc debug node/<node> -- chroot /host cat /proc/net/bonding/bond0
```

**Verify NICs are now OVS slaves:**

```bash
oc debug node/<node> -- chroot /host ip link show ens33
# Expected: master ovs-system state UP

oc debug node/<node> -- chroot /host ip link show ens34  
# Expected: master ovs-system state UP
```

> **Note:** The NICs should show `master ovs-system` (OVS control), not `master bond0` (Linux bond). This confirms they are now part of the OVS bond.

### Emergency Recovery via Console

If a node loses network connectivity during configuration:

1. **Access the node via BMC/IPMI/iLO/iDRAC console**

2. **Login as core user:**
   ```
   login: core
   Password: <password set earlier>
   ```

3. **Check network status:**
   ```bash
   sudo -i
   ip addr show
   ovs-vsctl show
   journalctl -u nmstate-configuration.service
   ```

4. **Check nmstate file:**
   ```bash
   cat /etc/nmstate/openshift/$(hostname -s).yml
   ```

5. **If needed, manually reapply nmstate:**
   ```bash
   nmstatectl apply /etc/nmstate/openshift/$(hostname -s).yml
   ```

6. **Verify connectivity:**
   ```bash
   ping <gateway>
   ```

## Additional Information

### Tested Versions

| OpenShift Version | Status | Notes |
|-------------------|--------|-------|
| 4.19.x | Validated | Tested with 4.19.20 |
| 4.20.x | Validated | Tested with 4.20.10 |
| 4.21+ | Not tested | Verify before use |

### Upgrade Behavior

The balance-slb configuration persists through HCP upgrades:
- Tested upgrade path: 4.19.20 > 4.20.10
- nmstate files in `/etc/nmstate/openshift/` are preserved
- No manual intervention required after upgrade

### Helper Script

A [helper script](./generate-balance-slb-configmap-multi.sh) is available to generate the ConfigMap from a node inventory file:

```bash
# Create nodes.conf with your node inventory
cat > nodes.conf << 'EOF'
# HOSTNAME         IP              PREFIX  VLAN  GATEWAY        NIC1   NIC2   DNS
ocp-worker-01      10.132.254.21   24      100   10.132.254.10  ens33  ens34  10.132.254.102,10.132.254.103
ocp-worker-02      10.132.254.22   24      100   10.132.254.10  ens33  ens34  10.132.254.102,10.132.254.103
ocp-worker-03      10.132.254.23   25      200   10.132.254.10  ens33  ens34  10.132.254.102,10.132.254.103
EOF

# Generate ConfigMap
./generate-balance-slb-configmap-multi.sh \
  --nodes nodes.conf \
  --namespace clusters-myhcp \
  --output balance-slb-configmap.yaml
```

The script automatically:
- Generates nmstate configuration for each node
- Includes removal of existing bond0 and bond0.XXX interfaces
- Encodes files in base64 for the MachineConfig
- Creates a ready-to-apply ConfigMap

**Field descriptions:**

| Field | Description | Example |
|-------|-------------|---------|
| HOSTNAME | **Short hostname** - output of `hostname -s` on the node | ocp-worker-01 |
| IP | Node IP address | 10.132.254.21 |
| PREFIX | Network prefix length (CIDR notation without /) | 24 |
| VLAN | 802.1Q VLAN ID for node network | 100 |
| GATEWAY | Default gateway | 10.132.254.10 |
| NIC1 | First physical NIC | ens33 |
| NIC2 | Second physical NIC | ens34 |
| DNS_SERVERS | Comma-separated DNS servers | 10.132.254.102,10.132.254.103 |

> **Important:** HOSTNAME must be the **short hostname** (without domain). Verify with `hostname -s` on the node. The nmstate file will be named `<short-hostname>.yml`.

### Future Compatibility

This procedure relies on:
1. `MachineConfig` support in HCP `ConfigMaps`
2. `nmstate-configuration.service` loading from `/etc/nmstate/openshift/`
3. OVS `balance-slb` bond mode support in nmstate

Future OpenShift versions may change these interfaces. Consult OpenShift documentation for your version before applying this procedure.

## Related Solutions

- How to migrate br-vmdata to br-phy after OVS balance-slb configuration
- How to configure VM localnet networks with OVS balance-slb
