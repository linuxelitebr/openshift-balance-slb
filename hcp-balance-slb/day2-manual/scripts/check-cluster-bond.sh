#!/bin/bash
#===============================================================================
# OVS Balance-SLB Cluster Verification Script
# 
# This script checks all nodes in the cluster to verify if they are
# configured with OVS balance-slb bonding.
#
# Run from: Bastion host with oc CLI access
# Tested on: OpenShift 4.20.8
#===============================================================================

set -uo pipefail

VERSION="1.0.1"

#-------------------------------------------------------------------------------
# Color Output
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[38;5;75m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
OVS Balance-SLB Cluster Verification Script v1.0.0

Usage: check-cluster-bond.sh [OPTIONS]

Options:
  --nodes <list>     Comma-separated list of specific nodes to check
  --label <selector> Node label selector (e.g., node-role.kubernetes.io/worker)
  --verbose          Show detailed output for each node
  --help             Show this help message

Examples:
  check-cluster-bond.sh                           # Check all nodes
  check-cluster-bond.sh --verbose                 # Check all with details
  check-cluster-bond.sh --nodes node1,node2       # Check specific nodes
  check-cluster-bond.sh --label node-role.kubernetes.io/worker

EOF
    exit 0
}

#-------------------------------------------------------------------------------
# Variables
#-------------------------------------------------------------------------------
SPECIFIC_NODES=""
LABEL_SELECTOR=""
VERBOSE=false

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --nodes)
                SPECIFIC_NODES="$2"
                shift 2
                ;;
            --label)
                LABEL_SELECTOR="$2"
                shift 2
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                error "Unknown option: $1"
                show_help
                ;;
        esac
    done
}

#-------------------------------------------------------------------------------
# Check Prerequisites
#-------------------------------------------------------------------------------
check_prerequisites() {
    info "Checking prerequisites..."
    
    # Check oc CLI
    if ! command -v oc &>/dev/null; then
        error "oc CLI not found. Please install OpenShift CLI."
        exit 1
    fi
    
    # Check cluster connection
    if ! oc whoami &>/dev/null; then
        error "Not logged into OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    
    local user=$(oc whoami)
    local server=$(oc whoami --show-server)
    success "Connected to cluster as '${user}'"
    echo "  Server: ${server}"
    echo ""
}

#-------------------------------------------------------------------------------
# Get Nodes
#-------------------------------------------------------------------------------
get_nodes() {
    local nodes=""
    
    if [[ -n "$SPECIFIC_NODES" ]]; then
        # Use specific nodes provided
        nodes=$(echo "$SPECIFIC_NODES" | tr ',' '\n')
    elif [[ -n "$LABEL_SELECTOR" ]]; then
        # Use label selector
        nodes=$(oc get nodes -l "$LABEL_SELECTOR" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
    else
        # Get all nodes
        nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
    fi
    
    echo "$nodes"
}

#-------------------------------------------------------------------------------
# Check Single Node
#-------------------------------------------------------------------------------
check_node() {
    local node="$1"
    local result=""
    local bond_mode=""
    local bond_status=""
    local mtu_status=""
    local br_ex_ip=""
    
    # Get bond info via oc debug
    local bond_output=$(oc debug node/"$node" --quiet -- chroot /host ovs-appctl bond/show ovs-bond 2>/dev/null)
    
    if [[ -z "$bond_output" ]]; then
        echo "NO_BOND"
        return
    fi
    
    # Check bond mode
    if echo "$bond_output" | grep -q "bond_mode: balance-slb"; then
        bond_mode="balance-slb"
    elif echo "$bond_output" | grep -q "bond_mode:"; then
        bond_mode=$(echo "$bond_output" | grep "bond_mode:" | awk '{print $2}')
    else
        bond_mode="unknown"
    fi
    
    # Check if members are enabled
    local enabled_count=$(echo "$bond_output" | grep -c "may_enable: true" 2>/dev/null || echo "0")
    enabled_count=$(echo "$enabled_count" | tr -d '\n' | head -c 10)
    enabled_count=${enabled_count:-0}
    if [[ "$enabled_count" =~ ^[0-9]+$ ]] && [[ "$enabled_count" -ge 2 ]]; then
        bond_status="OK"
    else
        bond_status="DEGRADED"
    fi
    
    # Get MTU info
    local mtu_output=$(oc debug node/"$node" --quiet -- chroot /host ip link show br-ex 2>/dev/null | grep -oP 'mtu \K[0-9]+' | head -1 || echo "0")
    mtu_output=$(echo "$mtu_output" | tr -d '\n')
    mtu_output=${mtu_output:-0}
    if [[ "$mtu_output" =~ ^[0-9]+$ ]] && [[ "$mtu_output" -ge 9000 ]]; then
        mtu_status="9000"
    else
        mtu_status="$mtu_output"
    fi
    
    # Get br-ex IP
    br_ex_ip=$(oc debug node/"$node" --quiet -- chroot /host ip -4 addr show br-ex 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1 || echo "none")
    
    echo "${bond_mode}|${bond_status}|${mtu_status}|${br_ex_ip}|${enabled_count}"
    
    if $VERBOSE; then
        echo "---VERBOSE_START---"
        echo "$bond_output"
        echo "---VERBOSE_END---"
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"
    
    echo ""
    echo "==============================================================================="
    echo " OVS Balance-SLB Cluster Verification v${VERSION}"
    echo "==============================================================================="
    echo ""
    
    check_prerequisites
    
    # Get list of nodes
    info "Discovering nodes..."
    local nodes=$(get_nodes)
    local node_count=$(echo "$nodes" | wc -w)
    
    if [[ -z "$nodes" || "$node_count" -eq 0 ]]; then
        error "No nodes found matching criteria"
        exit 1
    fi
    
    echo "  Found ${node_count} node(s) to check"
    echo ""
    
    # Results tracking
    local total=0
    local configured=0
    local not_configured=0
    local degraded=0
    
    # Print header
    printf "${CYAN}%-40s %-15s %-10s %-8s %-15s${NC}\n" "NODE" "BOND MODE" "STATUS" "MTU" "BR-EX IP"
    printf "%-40s %-15s %-10s %-8s %-15s\n" "$(printf '%0.s-' {1..40})" "$(printf '%0.s-' {1..15})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..8})" "$(printf '%0.s-' {1..15})"
    
    for node in $nodes; do
        ((total++))
        
        # Show progress
        echo -ne "\r${BLUE}Checking ${node}...${NC}                    " >&2
        
        local result=$(check_node "$node")
        
        # Clear progress line
        echo -ne "\r                                                  \r" >&2
        
        if [[ "$result" == "NO_BOND" ]]; then
            printf "%-40s ${RED}%-15s${NC} %-10s %-8s %-15s\n" "$node" "NO BOND" "-" "-" "-"
            ((not_configured++))
        else
            # Extract and sanitize values (remove newlines)
            local bond_mode=$(echo "$result" | cut -d'|' -f1 | tr -d '\n')
            local bond_status=$(echo "$result" | cut -d'|' -f2 | tr -d '\n')
            local mtu=$(echo "$result" | cut -d'|' -f3 | tr -d '\n')
            local ip=$(echo "$result" | cut -d'|' -f4 | tr -d '\n')
            local members=$(echo "$result" | cut -d'|' -f5 | tr -d '\n')
            
            # Default values if empty
            mtu=${mtu:-0}
            members=${members:-0}
            
            # Determine color based on bond mode
            local mode_color=""
            if [[ "$bond_mode" == "balance-slb" ]]; then
                mode_color="${GREEN}"
                ((configured++))
            else
                mode_color="${YELLOW}"
                ((not_configured++))
            fi
            
            # Status color
            local status_color=""
            if [[ "$bond_status" == "OK" ]]; then
                status_color="${GREEN}"
            else
                status_color="${YELLOW}"
                ((degraded++))
            fi
            
            # MTU color
            local mtu_color=""
            if [[ "$mtu" =~ ^[0-9]+$ ]] && [[ "$mtu" -ge 9000 ]]; then
                mtu_color="${GREEN}"
            else
                mtu_color="${YELLOW}"
            fi
            
            printf "%-40s ${mode_color}%-15s${NC} ${status_color}%-10s${NC} ${mtu_color}%-8s${NC} %-15s\n" \
                "$node" "$bond_mode" "$bond_status (${members})" "$mtu" "$ip"
            
            # Show verbose output if enabled
            if $VERBOSE && echo "$result" | grep -q "VERBOSE_START"; then
                echo ""
                echo "  --- Bond Details for $node ---"
                echo "$result" | sed -n '/---VERBOSE_START---/,/---VERBOSE_END---/p' | grep -v "VERBOSE"
                echo ""
            fi
        fi
    done
    
    # Summary
    echo ""
    echo "==============================================================================="
    echo " Summary"
    echo "==============================================================================="
    echo ""
    echo "  Total nodes checked:     ${total}"
    echo -e "  Configured (balance-slb): ${GREEN}${configured}${NC}"
    echo -e "  Not configured:          ${YELLOW}${not_configured}${NC}"
    if [[ "$degraded" -gt 0 ]]; then
        echo -e "  Degraded bonds:          ${YELLOW}${degraded}${NC}"
    fi
    echo ""
    
    if [[ "$configured" -eq "$total" ]] && [[ "$degraded" -eq 0 ]]; then
        success "All nodes are configured with OVS balance-slb!"
    elif [[ "$not_configured" -gt 0 ]]; then
        warn "Some nodes need migration to balance-slb"
        echo ""
        echo "To migrate a node, run on the node console:"
        echo "  ./migrate-to-ovs-slb.sh --ip <NODE_IP>"
    fi
    
    echo ""
}

main "$@"