#!/bin/bash
# generate-balance-slb-configmap-multi.sh
#
# Generates a ConfigMap containing nmstate files for multiple nodes.
# Each node gets its own nmstate file identified by short hostname.
#
# The nmstate-configuration service automatically loads:
#   /etc/nmstate/openshift/$(hostname -s).yml
#
# Usage:
#   ./generate-balance-slb-configmap-multi.sh --nodes nodes.conf --namespace clusters-mycluster
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
Usage: ./generate-balance-slb-configmap-multi.sh --nodes <file> [OPTIONS]

REQUIRED:
  --nodes <file>      Node configuration file (see format below)

OPTIONS:
  --namespace <ns>    Kubernetes namespace (default: clusters)
  --mtu <mtu>         MTU size (default: 9000)
  --output <file>     Output filename (default: balance-slb-configmap.yaml)
  -h, --help          Show this help

NODE FILE FORMAT (tab or space separated):
  HOSTNAME    IP            PREFIX  VLAN    GATEWAY       NIC1    NIC2    DNS_SERVERS
  worker-01   10.1.1.10     24      100     10.1.1.1      ens33   ens34   10.1.1.2,10.1.1.3
  worker-02   10.1.1.11     25      100     10.1.1.1      ens33   ens34   10.1.1.2,10.1.1.3

  - HOSTNAME: SHORT hostname (output of 'hostname -s'), NOT FQDN
  - PREFIX: Network prefix length (e.g., 24, 25, 26) without /
  - Lines starting with # are ignored
  - DNS_SERVERS: comma-separated, no spaces

EXAMPLE:
  # Create nodes.conf
  cat > nodes.conf << 'END'
  # HOSTNAME         IP              PREFIX  VLAN  GATEWAY        NIC1   NIC2   DNS
  ocp-worker-01      10.132.254.21   24      100   10.132.254.10  ens33  ens34  10.132.254.102,10.132.254.103
  ocp-worker-02      10.132.254.22   24      100   10.132.254.10  ens33  ens34  10.132.254.102,10.132.254.103
  ocp-worker-03      10.132.254.23   25      200   10.132.254.10  ens33  ens34  10.132.254.102,10.132.254.103
  END

  # Generate ConfigMap
  ./generate-balance-slb-configmap-multi.sh --nodes nodes.conf --namespace clusters-myhcp
EOF
    exit 1
}

# Defaults
NODES_FILE=""
NAMESPACE="clusters"
MTU="9000"
OUTPUT="balance-slb-configmap.yaml"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --nodes)
            NODES_FILE="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
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
# BUILD CONFIGMAP
# =============================================================================

echo "Reading nodes from: $NODES_FILE"
echo "Namespace: $NAMESPACE"
echo "MTU: $MTU"
echo ""

# Start ConfigMap
cat > "$OUTPUT" << 'HEADER'
# =============================================================================
# OVS Balance-SLB Configuration for HCP NodePools
# =============================================================================
# Generated by: generate-balance-slb-configmap-multi.sh
HEADER

echo "# Generated at: $(date)" >> "$OUTPUT"
cat >> "$OUTPUT" << 'HEADER2'
#
# This ConfigMap contains nmstate files for each node.
# The nmstate-configuration service automatically loads the correct file
# based on hostname: /etc/nmstate/openshift/$(hostname -s).yml
#
# NO systemd unit required - just static configuration files.
#
# =============================================================================

HEADER2

# Add namespace
cat >> "$OUTPUT" << EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: balance-slb-config
  namespace: ${NAMESPACE}
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
    
    # Generate nmstate content and encode
    NMSTATE_CONTENT=$(generate_nmstate "$hostname" "$ip" "$prefix" "$vlan" "$gateway" "$nic1" "$nic2" "$dns_servers")
    NMSTATE_B64=$(echo "$NMSTATE_CONTENT" | base64 -w0)
    
    # Add file entry to ConfigMap
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
echo "============================================"
echo "Generated: $OUTPUT"
echo "Nodes: $NODE_COUNT"
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Review: cat $OUTPUT"
echo "  2. Apply:  oc apply -f $OUTPUT"
echo "  3. Add to NodePool:"
echo "     oc -n clusters patch nodepool <name> --type=merge -p 'spec: {config: [{name: balance-slb-config}]}'"