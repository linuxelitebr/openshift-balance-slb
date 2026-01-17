#!/bin/bash
# generate-balance-slb-machineconfig.sh
#
# Generates a MachineConfig containing nmstate files for multiple nodes.
# For use with STANDALONE OpenShift clusters (non-HCP).
#
# Each node gets its own nmstate file identified by short hostname.
# The nmstate-configuration service automatically loads:
#   /etc/nmstate/openshift/$(hostname -s).yml
#
# Usage:
#   ./generate-balance-slb-machineconfig.sh --nodes nodes.conf --role worker
#
# nodes.conf format (tab or space separated):
#   HOSTNAME    IP          PREFIX  VLAN    GATEWAY         NIC1    NIC2    DNS1,DNS2
#   worker-01   10.1.1.10   24      100     10.1.1.1        ens33   ens34   10.1.1.2,10.1.1.3
#   worker-02   10.1.1.11   25      100     10.1.1.1        ens33   ens34   10.1.1.2,10.1.1.3
#
# IMPORTANT: HOSTNAME must be the SHORT hostname (output of 'hostname -s')
#
# V 1.0.0
# Andre Rocha

set -euo pipefail

usage() {
    cat << 'EOF'
Usage: ./generate-balance-slb-machineconfig.sh --nodes <file> [OPTIONS]

REQUIRED:
  --nodes <file>      Node configuration file (see format below)

OPTIONS:
  --role <role>       MachineConfig role: worker, master, or custom pool name (default: worker)
  --mtu <mtu>         MTU size (default: 9000)
  --output <file>     Output filename (default: balance-slb-machineconfig.yaml)
  --name <n>          MachineConfig name (default: 99-ovs-balance-slb)
  --create-mcp        Generate a custom MachineConfigPool for controlled rollout
  -h, --help          Show this help

NODE FILE FORMAT (tab or space separated):
  HOSTNAME    IP            PREFIX  VLAN    GATEWAY       NIC1    NIC2    DNS_SERVERS
  worker-01   10.1.1.10     24      100     10.1.1.1      ens33   ens34   10.1.1.2,10.1.1.3
  worker-02   10.1.1.11     25      100     10.1.1.1      ens33   ens34   10.1.1.2,10.1.1.3

  - HOSTNAME: SHORT hostname (output of 'hostname -s'), NOT FQDN
  - PREFIX: Network prefix length (e.g., 24, 25, 26) without /
  - Lines starting with # are ignored
  - DNS_SERVERS: comma-separated, no spaces

EXAMPLES:
  # Generate MachineConfig for all workers (immediate rolling update)
  ./generate-balance-slb-machineconfig.sh --nodes nodes.conf --role worker

  # Generate MachineConfig with custom MCP for controlled rollout
  ./generate-balance-slb-machineconfig.sh --nodes nodes.conf --role worker-balance-slb --create-mcp

  # Generate MachineConfig for masters
  ./generate-balance-slb-machineconfig.sh --nodes masters.conf --role master --name 99-ovs-balance-slb-master

CONTROLLED ROLLOUT (--create-mcp):
  When using --create-mcp, the script generates:
    1. A MachineConfigPool that inherits from 'worker' pool
    2. A MachineConfig targeting that pool

  Workflow:
    1. Apply the generated YAML (MCP + MC)
    2. Label nodes one at a time to move them into the new pool:
       oc label node <node-name> node-role.kubernetes.io/<role>=""
    3. Node will reboot and apply the configuration
    4. Verify with: oc get mcp <role> && ovs-appctl bond/show ovs-bond
    5. Repeat for next node
EOF
    exit 1
}

# Defaults
NODES_FILE=""
ROLE="worker"
MTU="9000"
OUTPUT="balance-slb-machineconfig.yaml"
MC_NAME="99-ovs-balance-slb"
CREATE_MCP="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --nodes)
            NODES_FILE="$2"
            shift 2
            ;;
        --role)
            ROLE="$2"
            shift 2
            ;;
        --mtu)
            MTU="$2"
            shift 2
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        --name)
            MC_NAME="$2"
            shift 2
            ;;
        --create-mcp)
            CREATE_MCP="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate
if [[ -z "$NODES_FILE" ]]; then
    echo "ERROR: --nodes is required"
    usage
fi

if [[ ! -f "$NODES_FILE" ]]; then
    echo "ERROR: Nodes file not found: $NODES_FILE"
    exit 1
fi

# =============================================================================
# GENERATE NMSTATE CONTENT FOR EACH NODE
# =============================================================================

generate_nmstate() {
    local hostname="$1"
    local ip="$2"
    local prefix="$3"
    local vlan="$4"
    local gateway="$5"
    local nic1="$6"
    local nic2="$7"
    local dns_csv="$8"
    
    # Build DNS YAML
    local dns_yaml=""
    IFS=',' read -ra DNS_ARRAY <<< "$dns_csv"
    for dns in "${DNS_ARRAY[@]}"; do
        dns_yaml="${dns_yaml}    - ${dns}
"
    done
    
    cat << EOF
# OVS Balance-SLB Configuration
# Node: ${hostname}
# Generated: $(date)

interfaces:
  # Remove existing Linux bond configuration
  - name: bond0
    type: bond
    state: absent

  - name: bond0.${vlan}
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
    mtu: ${MTU}
    copy-mac-from: ${nic1}
    ipv4:
      enabled: true
      address:
      - ip: ${ip}
        prefix-length: ${prefix}
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
          tag: ${vlan}
      - name: ovs-bond
        link-aggregation:
          mode: balance-slb
          port:
          - name: ${nic1}
          - name: ${nic2}

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

  - name: ${nic1}
    type: ethernet
    state: up
    mtu: ${MTU}
    ipv4:
      enabled: false
    ipv6:
      enabled: false

  - name: ${nic2}
    type: ethernet
    state: up
    mtu: ${MTU}
    ipv4:
      enabled: false
    ipv6:
      enabled: false

dns-resolver:
  config:
    server:
${dns_yaml}
routes:
  config:
  - destination: 0.0.0.0/0
    next-hop-address: ${gateway}
    next-hop-interface: br-ex

ovn:
  bridge-mappings:
    - bridge: br-phy
      localnet: vmnet
      state: present
EOF
}

# =============================================================================
# BUILD MACHINECONFIG
# =============================================================================

echo "========================================"
echo "OVS Balance-SLB MachineConfig Generator"
echo "========================================"
echo "Nodes file: $NODES_FILE"
echo "Role: $ROLE"
echo "MTU: $MTU"
echo "MachineConfig name: $MC_NAME"
echo "Create MCP: $CREATE_MCP"
echo ""

# Collect node hostnames for later
NODE_HOSTNAMES=()

# Start output file
cat > "$OUTPUT" << EOF
# =============================================================================
# OVS Balance-SLB MachineConfig for Standalone OpenShift Clusters
# =============================================================================
# Generated by: generate-balance-slb-machineconfig.sh
# Generated at: $(date)
#
# Role: ${ROLE}
# MTU: ${MTU}
EOF

# Add MCP if requested
if [[ "$CREATE_MCP" == "true" ]]; then
    cat >> "$OUTPUT" << EOF
#
# CONTROLLED ROLLOUT MODE
# -----------------------
# This file contains:
#   1. MachineConfigPool '${ROLE}' (inherits from worker)
#   2. MachineConfig targeting that pool
#
# Workflow:
#   1. oc apply -f ${OUTPUT}
#   2. Label nodes one at a time:
#      oc label node <node-name> node-role.kubernetes.io/${ROLE}=""
#   3. Wait for node to reboot and verify
#   4. Repeat for next node
#
# To remove a node from this pool (revert to worker):
#   oc label node <node-name> node-role.kubernetes.io/${ROLE}-
#
# =============================================================================

---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfigPool
metadata:
  name: ${ROLE}
spec:
  machineConfigSelector:
    matchExpressions:
    - key: machineconfiguration.openshift.io/role
      operator: In
      values:
      - worker
      - ${ROLE}
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/${ROLE}: ""
  paused: false
EOF
else
    cat >> "$OUTPUT" << EOF
#
# USAGE:
#   oc apply -f ${OUTPUT}
#
# The Machine Config Operator (MCO) will trigger a rolling reboot
# of all nodes with the matching role.
#
# =============================================================================
EOF
fi

# Add MachineConfig
cat >> "$OUTPUT" << EOF

---
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${ROLE}
  name: ${MC_NAME}
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
EOF

# Process each node
NODE_COUNT=0
while IFS=$' \t' read -r hostname ip prefix vlan gateway nic1 nic2 dns_servers rest; do
    # Skip empty lines and comments
    [[ -z "$hostname" ]] && continue
    [[ "$hostname" =~ ^# ]] && continue
    
    # Validate fields
    if [[ -z "$dns_servers" ]]; then
        echo "ERROR: Invalid line (missing fields): $hostname"
        echo "Expected: HOSTNAME IP PREFIX VLAN GATEWAY NIC1 NIC2 DNS_SERVERS"
        exit 1
    fi
    
    echo "Processing: $hostname ($ip/$prefix, VLAN $vlan, NICs: $nic1/$nic2)"
    
    # Collect hostname
    NODE_HOSTNAMES+=("$hostname")
    
    # Generate nmstate content and encode
    NMSTATE_CONTENT=$(generate_nmstate "$hostname" "$ip" "$prefix" "$vlan" "$gateway" "$nic1" "$nic2" "$dns_servers")
    NMSTATE_B64=$(echo "$NMSTATE_CONTENT" | base64 -w0)
    
    # Add file entry to MachineConfig
    cat >> "$OUTPUT" << EOF
      - path: /etc/nmstate/openshift/${hostname}.yml
        mode: 0644
        overwrite: true
        contents:
          source: data:text/plain;charset=utf-8;base64,${NMSTATE_B64}
EOF
    
    NODE_COUNT=$((NODE_COUNT + 1))
done < "$NODES_FILE"

if [[ $NODE_COUNT -eq 0 ]]; then
    echo "ERROR: No valid nodes found in $NODES_FILE"
    exit 1
fi

echo ""
echo "========================================"
echo "Generated: $OUTPUT"
echo "Nodes: $NODE_COUNT"
echo "Role: $ROLE"
echo "========================================"
echo ""

if [[ "$CREATE_MCP" == "true" ]]; then
    echo "CONTROLLED ROLLOUT MODE"
    echo ""
    echo "Step 1: Apply MCP and MachineConfig"
    echo "  oc apply -f $OUTPUT"
    echo ""
    echo "Step 2: Label nodes one at a time"
    for h in "${NODE_HOSTNAMES[@]}"; do
        echo "  oc label node ${h} node-role.kubernetes.io/${ROLE}=\"\""
    done
    echo ""
    echo "Step 3: Monitor each node"
    echo "  oc get mcp ${ROLE} -w"
    echo "  oc get nodes -l node-role.kubernetes.io/${ROLE} -w"
    echo ""
    echo "Step 4: Verify balance-slb after each node"
    echo "  oc debug node/<node> -- chroot /host ovs-appctl bond/show ovs-bond"
    echo ""
    echo "To revert a node to standard worker pool:"
    echo "  oc label node <node-name> node-role.kubernetes.io/${ROLE}-"
else
    echo "Next steps:"
    echo "  1. Review:  cat $OUTPUT"
    echo "  2. Apply:   oc apply -f $OUTPUT"
    echo "  3. Monitor: oc get mcp $ROLE -w"
    echo ""
    echo "WARNING: Applying this MachineConfig will trigger a rolling reboot"
    echo "         of all nodes in the '$ROLE' MachineConfigPool."
fi
