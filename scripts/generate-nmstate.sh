#!/bin/bash
#
# generate-nmstate-corrected.sh
#
# Generates nmstate configuration for OVS balance-slb with all fixes applied.
# Compatible with OpenShift 4.18, 4.19, 4.20+
#
# Usage: ./generate-nmstate-corrected.sh <short-hostname> <ip_address> <nic1> <nic2> <gateway> <dns1> <dns2>
#
# Example:
#   ./generate-nmstate-corrected.sh ocp-dualstack-0 10.132.254.11 ens33 ens34 10.132.254.10 10.132.254.103 10.132.254.102
#
# IMPORTANT: Use SHORT hostname (not FQDN)
#

set -e

if [ $# -lt 7 ]; then
    echo "Usage: $0 <short-hostname> <ip_address> <nic1> <nic2> <gateway> <dns1> <dns2>"
    echo ""
    echo "Example:"
    echo "  $0 ocp-dualstack-0 10.132.254.11 ens33 ens34 10.132.254.10 10.132.254.103 10.132.254.102"
    echo ""
    echo "IMPORTANT: Use SHORT hostname (e.g., ocp-dualstack-0, NOT ocp-dualstack-0.domain.com)"
    exit 1
fi

HOSTNAME=$1
IP_ADDRESS=$2
NIC1=$3
NIC2=$4
GATEWAY=$5
DNS1=$6
DNS2=$7

# Validate short hostname
if [[ "$HOSTNAME" == *.* ]]; then
    echo "WARNING: Hostname contains dots. Use SHORT hostname (e.g., ocp-dualstack-0)"
    echo "         The script uses 'hostname -s' which returns short name."
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

OUTPUT_FILE="${HOSTNAME}.yml"

# Generate NMState YAML with all fixes applied
cat > "$OUTPUT_FILE" << EOF
# OVS Balance-SLB Configuration
# Generated for: ${HOSTNAME}
# IP: ${IP_ADDRESS}
interfaces:
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
      - name: patch-ex-to-phy
      - name: br-ex
    ovs-db:
      external_ids:
        bridge-uplink: "patch-ex-to-phy"
  - name: br-ex
    type: ovs-interface
    state: up
    controller: br-ex
    copy-mac-from: ${NIC1}
    ipv4:
      enabled: true
      address:
      - ip: ${IP_ADDRESS}
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
      options:
        stp: true
      allow-extra-patch-ports: true
      port:
      - name: patch-phy-to-ex
      - name: ovs-bond
        link-aggregation:
          mode: balance-slb
          port:
          - name: ${NIC1}
          - name: ${NIC2}
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
  - name: ${NIC1}
    type: ethernet
    state: up
    mtu: 9000
    ipv4:
      enabled: false
    ipv6:
      enabled: false
  - name: ${NIC2}
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
    - ${DNS1}
    - ${DNS2}
routes:
  config:
  - destination: 0.0.0.0/0
    next-hop-address: ${GATEWAY}
    next-hop-interface: br-ex
EOF

echo "Generated: ${OUTPUT_FILE}"
echo ""

# Generate base64
BASE64_CONTENT=$(cat "$OUTPUT_FILE" | base64 -w0)

echo "# MachineConfig entry for ${HOSTNAME}:"
echo "# Add this to your MachineConfig storage.files section"
echo ""
echo "          - contents:"
echo "              source: data:text/plain;charset=utf-8;base64,${BASE64_CONTENT}"
echo "            mode: 0644"
echo "            overwrite: true"
echo "            path: /etc/nmstate/openshift/${HOSTNAME}.yml"
echo ""
echo "# File saved as: ${OUTPUT_FILE}"
