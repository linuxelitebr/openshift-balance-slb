# Runbook: OVS Balance-SLB Migration
## Clusters with br-vmdata via NNCP

| Field | Value |
|-------|-------|
| Version | 1.2 |
| Tested on | OpenShift 4.20.8 |
| Estimated time | 30-45 min per node |

---

## Prerequisites

- [ ] SSH access to bastion
- [ ] Console access to nodes (iLO/iDRAC/BMC) - **SSH won't work during migration**
- [ ] `oc` CLI configured as cluster-admin
- [ ] Script `migrate-to-ovs-slb.sh` available
- [ ] Backup of current br-vmdata NNCP

---

## Phase 0: Prepare Labels (One Time Only)

> **⚠️ CRITICAL**: This must be done BEFORE any migration to avoid NNCP conflicts.

### 0.1 Add Label to ALL Workers

```bash
# Add label to all workers as "not migrated"
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  oc label $node balance-slb-migrated=false --overwrite
done

# Verify
oc get nodes -l node-role.kubernetes.io/worker --show-labels | grep balance-slb
```

### 0.2 Modify Original NNCP

Add selector to exclude migrated nodes from the original br-vmdata NNCP:

```bash
oc patch nncp br-vmdata --type=merge -p '
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
    balance-slb-migrated: "false"
'
```

Verify:

```bash
oc get nncp br-vmdata -o yaml | grep -A3 nodeSelector
# Should show:
#   nodeSelector:
#     node-role.kubernetes.io/worker: ""
#     balance-slb-migrated: "false"
```

---

## Phase 1: Create Migration NNCP (One Time Only)

### 1.1 Create Migration NNCP

```bash
cat <<'EOF' | oc apply -f -
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: br-vmdata-migrated
spec:
  nodeSelector:
    balance-slb-migrated: 'true'
  desiredState:
    interfaces:
    - name: br-vmdata
      type: ovs-bridge
      state: absent
    ovn:
      bridge-mappings:
      - bridge: br-phy
        localnet: vmnet
        state: present
EOF
```

### 1.2 Verify

```bash
oc get nncp br-vmdata-migrated
# Should exist, but no NNCE yet (no node has label = true)

oc get nnce | grep br-vmdata-migrated
# (empty - expected)
```

---

## Phase 2: Per-Node Migration

> **⚠️ IMPORTANT**: Execute one node at a time. Only proceed to the next after validation.

### 2.1 Select Node

```bash
# List workers
oc get nodes -l node-role.kubernetes.io/worker

# Set variables
export NODE="ocp-worker-01.example.com"
export NODE_IP="10.x.x.x"
```

### 2.2 Prepare Node

```bash
# Cordon
oc adm cordon $NODE

# Check VMs on node
oc get vmi -A -o wide | grep $NODE


## You have two options here: ##

# Drain the node
oc adm drain $NODE --ignore-daemonsets --delete-emptydir-data --force

# Or just migrate the VMs (if VMs exist) to other nodes (optional but recommended)
for vm in $(oc get vmi -A -o jsonpath="{.items[?(@.status.nodeName=='${NODE}')].metadata.name}"); do
  ns=$(oc get vmi -A -o jsonpath="{.items[?(@.metadata.name=='${vm}')].metadata.namespace}")
  virtctl migrate -n $ns $vm
done


# Wait for VM migrations
watch "oc get vmi -A -o wide | grep $NODE"
# (should be empty)
```

### 2.3 Execute Balance-SLB Migration

> **⚠️ Use CONSOLE (iLO/iDRAC), NOT SSH!**

```bash
# On node console:
sudo -i
cd /tmp

# Transfer script (if not already on node)
# Option: curl, scp before cordon, or copy manually

# Execute migration
./migrate-to-ovs-slb.sh \
--ip $NODE_IP \
--prefix <PREFIX> \
--gateway <GW> \
--dns1 <DNS1> \
--dns2 <DNS2> \
--nic1 <NIC1> \
--nic2 <NIC2> \
--vlan <VLAN>

# Real example:
./migrate-to-ovs-slb.sh \
--ip 10.132.254.25 \
--prefix 24 \
--gateway 10.132.254.10 \
--dns1 10.132.254.103 \
--dns2 10.132.254.104 \
--nic1 eno1 \
--nic2 eno2 \
--vlan 100

# Mandatory reboot
reboot
```

### 2.4 Post-Reboot: Apply Label

```bash
# Wait for node to come back (from bastion)
oc get node $NODE -w
# Wait for Ready status

# Change label to trigger migration NNCP
oc label node $NODE balance-slb-migrated=true --overwrite

# Wait for NNCE
oc get nnce -w | grep $NODE
# Wait for: Available
```

### 2.5 Validate

```bash
# Check bridges
oc debug node/$NODE -- chroot /host ovs-vsctl list-br
# Expected: br-ex, br-int, br-phy (NO br-vmdata)

# Check bridge-mapping
oc debug node/$NODE -- chroot /host ovs-vsctl get Open_vSwitch . external_ids:ovn-bridge-mappings
# Expected: "vmnet:br-phy,physnet:br-ex"

# Check bond
oc debug node/$NODE -- chroot /host ovs-appctl bond/show ovs-bond
# Expected: bond_mode: balance-slb, 2 members enabled

# Uncordon
oc adm uncordon $NODE
```

### 2.6 Test VMs

```bash
# Check VMs on migrated node
oc get vmi -A -o wide

# Test connectivity (from inside VM)
virtctl console <vm-name>
# ping gateway
```

---

## Phase 3: Repeat for Each Node

Repeat **Phase 2** (steps 2.1 to 2.6) for each worker.

### Track Progress

```bash
# Nodes already migrated
oc get nodes -l balance-slb-migrated=true

# Nodes pending
oc get nodes -l balance-slb-migrated=false

# NNCE status
oc get nnce | grep br-vmdata-migrated
```

---

## Phase 4: Finalization (After All Nodes)

### 4.1 Change Migration NNCP Selector to All Workers

```bash
oc patch nncp br-vmdata-migrated --type=merge -p '
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
'
```

### 4.2 Delete Original NNCP

```bash
# Check original NNCP name
oc get nncp | grep vmdata

# Delete
oc delete nncp br-vmdata
```

### 4.3 Final Validation

```bash
# All workers with correct bridge-mapping
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name | cut -d/ -f2); do
  echo "=== $node ==="
  oc debug node/$node -- chroot /host ovs-vsctl get Open_vSwitch . external_ids:ovn-bridge-mappings 2>/dev/null
done

# All VMs with connectivity
oc get vmi -A
```

---

## Phase 5: Bond Tuning (Optional)

> **INFO**: This phase is optional. The default `bond-rebalance-interval` of 10 seconds works well for most environments.

OVS balance-slb periodically rebalances traffic across links based on utilization. The default interval is 10 seconds. For environments with stable, long-running VMs, increasing to 30 seconds reduces rebalancing overhead.

> **Note**: This tuning does not affect failover time. Link failure detection remains under 100ms regardless of rebalance interval.

### 5.1 Why Tune the Rebalance Interval?

| Interval | Use Case |
|----------|----------|
| **10s** (default) | Dynamic environments, frequent VM creation/deletion |
| **30s** (tuned) | Stable VMs, large environments, bursty traffic patterns |

### 5.2 Create ConfigMap with MachineConfig

For HCP clusters, use ConfigMap to inject a systemd unit:

```bash
# Set your hosted cluster namespace
export HC_NAMESPACE="<hosted-cluster-namespace>"

# Create ConfigMap
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ovs-bond-tuning
  namespace: ${HC_NAMESPACE}
data:
  config: |
    apiVersion: machineconfiguration.openshift.io/v1
    kind: MachineConfig
    metadata:
      labels:
        machineconfiguration.openshift.io/role: worker
      name: 99-ovs-bond-tuning
    spec:
      config:
        ignition:
          version: 3.2.0
        systemd:
          units:
          - name: ovs-bond-tuning.service
            enabled: true
            contents: |
              [Unit]
              Description=OVS Bond Rebalance Interval Tuning
              After=openvswitch.service ovs-vswitchd.service
              Requires=openvswitch.service

              [Service]
              Type=oneshot
              ExecStartPre=/usr/bin/sleep 5
              ExecStart=/usr/bin/ovs-vsctl set port ovs-bond other_config:bond-rebalance-interval=30000
              RemainAfterExit=yes

              [Install]
              WantedBy=multi-user.target
EOF
```

### 5.3 Reference ConfigMap in NodePool

```bash
# Get NodePool name
oc get nodepool -n $HC_NAMESPACE

# Edit NodePool to add config reference
oc edit nodepool <nodepool-name> -n $HC_NAMESPACE
```

Add under `spec`:

```yaml
spec:
  config:
  - name: ovs-bond-tuning
```

### 5.4 Wait for Rollout

The NodePool will trigger a rolling update of worker nodes:

> The nodes will reboot.

```bash
# Watch node updates
oc get nodes -w

# Check NodePool status
oc get nodepool -n $HC_NAMESPACE
```

### 5.5 Verify Tuning

After nodes are updated:

```bash
# Check on each node
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name | cut -d/ -f2); do
  echo "=== $node ==="
  oc debug node/$node -- chroot /host ovs-vsctl get port ovs-bond other_config 2>/dev/null
done

# Expected output includes: bond-rebalance-interval="30000"
```

---

## Quick Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| SSH won't connect during migration | Network reconfiguration | Use console (iLO/iDRAC) |
| NNCE doesn't appear after label | Slow operator | `oc get nnce -w`, wait |
| br-vmdata keeps coming back | NNCP conflict | Verify original NNCP has `balance-slb-migrated: "false"` selector |
| VM has no network | Incorrect bridge-mapping | Verify `ovn-bridge-mappings` |
| Node NotReady after reboot | Incorrect MTU, Incorrect VLAN, incorrect GW, etc. | Verify MTU 9000 on br-ex, etc |

### Useful Logs

```bash
# nmstate logs
oc logs -n openshift-nmstate -l app=kubernetes-nmstate --tail=50

# Detailed NNCE status
oc get nnce $NODE.br-vmdata-migrated -o yaml
```

---

## Quick Checklist

Before starting (one time):

- [ ] Label all workers: `balance-slb-migrated=false`
- [ ] Patch original NNCP with `balance-slb-migrated: "false"` selector
- [ ] Create migration NNCP `br-vmdata-migrated`

Per node:

- [ ] `oc adm cordon $NODE`
- [ ] Migrate VMs (optional)
- [ ] Console: `./migrate-to-ovs-slb.sh` + `reboot`
- [ ] `oc label node $NODE balance-slb-migrated=true --overwrite`
- [ ] Wait for NNCE Available
- [ ] Validate: bridges, bond, mapping
- [ ] `oc adm uncordon $NODE`
- [ ] Test VM

After all nodes:

- [ ] Patch migration NNCP to `node-role.kubernetes.io/worker`
- [ ] Delete original NNCP `br-vmdata`
- [ ] Final validation

---

## References

- Full documentation: `OPENSHIFT-VIRTUALIZATION-VMNET-BALANCE-SLB.md`
- Migration script: `migrate-to-ovs-slb.sh`
- Verification script: `check-cluster-bond.sh`