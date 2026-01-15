#!/bin/bash
#===============================================================================
# OVS Balance-SLB Migration Script for OpenShift HCP Agent Nodes
# Tested on: OpenShift 4.20.8
#
# This script migrates network configuration from Linux kernel bonding
# to OVS balance-slb bonding with VLAN tagging via patch ports.
#
# Architecture:
#   NIC1/NIC2 → ovs-bond (balance-slb) → br-phy → patch (VLAN tag) → br-ex (IP)
#
# IMPORTANT: Ensure core user has password set for console recovery!
#
# v1.6.0 Changes:
#   - Use /etc/nmstate/openshift/ path (product-provided interface)
#   - Remove manual 'applied' flag creation (handled by nmstate-configuration)
#   - Remove manual br-ex cleanup (handled by nmstate-configuration in recent z-streams)
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# Default Configuration
#-------------------------------------------------------------------------------
VERSION="1.6.0"
TESTED_OCP_VERSION="4.20.8"
LOG_FILE="/var/log/ovs-slb-migration.log"
BACKUP_DIR="/root/backup-migration"
DRY_RUN=false
FORCE_SSH=false
SKIP_BACKUP=false
VALIDATE_ONLY=false
FAILOVER_TEST=false

# Network defaults (can be overridden via parameters)
NODE_IP=""
PREFIX_LENGTH="24"
GATEWAY="10.132.254.10"
DNS1="10.132.254.102"
DNS2="10.132.254.103"
NIC1="ens33"
NIC2="ens34"
VLAN_TAG="100"
MTU="9000"

#-------------------------------------------------------------------------------
# Color Output
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[38;5;75m'
NC='\033[0m' # No Color

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

info()    { log "INFO" "${BLUE}$*${NC}"; }
success() { log "OK" "${GREEN}✓ $*${NC}"; }
warn()    { log "WARN" "${YELLOW}⚠ $*${NC}"; }
error()   { log "ERROR" "${RED}✗ $*${NC}"; }
fatal()   { error "$*"; exit 1; }

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
show_help() {
    cat << 'HELPEOF'
OVS Balance-SLB Migration Script v1.6.0
Tested on OpenShift 4.20.8

Usage: migrate-to-ovs-slb.sh [OPTIONS] --ip <NODE_IP>
       migrate-to-ovs-slb.sh --validate [--gateway <IP>]
       migrate-to-ovs-slb.sh --failover-test [--gateway <IP>]

Modes:
  Migration (default)    Apply configuration (requires manual reboot)
  --validate             Post-reboot validation (non-invasive, can run via SSH)
  --failover-test        Invasive bond failover test (temporarily disables NICs)

Required for migration:
  --ip <IP>              Node IP address (e.g., 10.132.254.25)

Optional:
  --prefix <LENGTH>      Network prefix length (default: 24)
  --gateway <IP>         Gateway IP address (default: 10.132.254.10)
  --dns1 <IP>            Primary DNS server (default: 10.132.254.102)
  --dns2 <IP>            Secondary DNS server (default: 10.132.254.103)
  --nic1 <name>          First network interface (default: ens33)
  --nic2 <name>          Second network interface (default: ens34)
  --vlan <TAG>           VLAN tag for access mode (default: 100)
  --mtu <SIZE>           MTU size (default: 9000)
  --dry-run              Show what would be done without making changes
  --force-ssh            Allow running via SSH (DANGEROUS - not recommended)
  --help                 Show this help message

Workflow:
  1. Cordon node:           oc adm cordon <node-name>
  2. Run migration:         ./migrate-to-ovs-slb.sh --ip 10.132.254.25
  3. Reboot the node:       reboot
  4. After reboot, validate: ./migrate-to-ovs-slb.sh --validate
  5. Uncordon node:         oc adm uncordon <node-name>

Examples:
  migrate-to-ovs-slb.sh --ip 10.132.254.25
  migrate-to-ovs-slb.sh --ip 10.132.254.25 --nic1 eno1 --nic2 eno2 --vlan 200
  migrate-to-ovs-slb.sh --validate
  migrate-to-ovs-slb.sh --failover-test --gateway 10.132.254.10
  migrate-to-ovs-slb.sh --ip 10.132.254.25 --dry-run

Architecture:
  NIC1/NIC2 -> ovs-bond (balance-slb) -> br-phy -> patch-phy-to-ex (VLAN) -> br-ex (IP)

IMPORTANT:
  - Migration MUST be run from a LOCAL CONSOLE (not SSH)
  - Network reconfiguration requires a REBOOT to take full effect
  - Run this script ONE NODE AT A TIME
  - Ensure core user has a password set for console recovery
  - Cordon the node before migration: oc adm cordon <node>

HELPEOF
    exit 0
}

#-------------------------------------------------------------------------------
# Parse Arguments
#-------------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ip)
                NODE_IP="$2"
                shift 2
                ;;
            --prefix)
                PREFIX_LENGTH="$2"
                shift 2
                ;;
            --gateway)
                GATEWAY="$2"
                shift 2
                ;;
            --dns1)
                DNS1="$2"
                shift 2
                ;;
            --dns2)
                DNS2="$2"
                shift 2
                ;;
            --nic1)
                NIC1="$2"
                shift 2
                ;;
            --nic2)
                NIC2="$2"
                shift 2
                ;;
            --vlan)
                VLAN_TAG="$2"
                shift 2
                ;;
            --mtu)
                MTU="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --force-ssh)
                FORCE_SSH=true
                shift
                ;;
            --validate)
                VALIDATE_ONLY=true
                shift
                ;;
            --failover-test)
                FAILOVER_TEST=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                fatal "Unknown option: $1. Use --help for usage information."
                ;;
        esac
    done

    # NODE_IP is only required for migration mode, not for --validate or --failover-test
    if [[ -z "$NODE_IP" ]] && ! $VALIDATE_ONLY && ! $FAILOVER_TEST; then
        error "Node IP is required for migration mode."
        echo ""
        show_help
    fi
}

#-------------------------------------------------------------------------------
# Validation Functions
#-------------------------------------------------------------------------------
validate_ip() {
    local ip="$1"
    local name="$2"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        fatal "Invalid IP format for ${name}: ${ip}"
    fi
    
    # Validate each octet
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [[ "$octet" -lt 0 || "$octet" -gt 255 ]]; then
            fatal "Invalid IP octet for ${name}: ${ip}"
        fi
    done
}

validate_number() {
    local value="$1"
    local name="$2"
    local min="$3"
    local max="$4"
    
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        fatal "${name} must be a number: ${value}"
    fi
    
    if [[ "$value" -lt "$min" || "$value" -gt "$max" ]]; then
        fatal "${name} must be between ${min} and ${max}: ${value}"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "This script must be run as root. Use: sudo $0"
    fi
    success "Running as root"
}

check_ssh_session() {
    info "Checking terminal type..."
    
    local is_ssh=false
    local detection_method=""
    
    # Method 1: Check SSH_CONNECTION environment variable
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        is_ssh=true
        detection_method="SSH_CONNECTION environment variable"
    fi
    
    # Method 2: Check SSH_TTY environment variable
    if [[ -n "${SSH_TTY:-}" ]]; then
        is_ssh=true
        detection_method="SSH_TTY environment variable"
    fi
    
    # Method 3: Check if current TTY is a pseudo-terminal (pts)
    local current_tty=$(tty 2>/dev/null || echo "unknown")
    if [[ "$current_tty" == */pts/* ]]; then
        # pts could be SSH or local terminal emulator, but on CoreOS it's usually SSH
        if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]; then
            is_ssh=true
            detection_method="pseudo-terminal with SSH variables"
        fi
    fi
    
    if $is_ssh; then
        error "═══════════════════════════════════════════════════════════════════════"
        error "  CRITICAL: SSH SESSION DETECTED"
        error "═══════════════════════════════════════════════════════════════════════"
        error ""
        error "  This script reconfigures the network and WILL DISCONNECT your SSH"
        error "  session during execution, leaving you with no way to recover or"
        error "  see the results."
        error ""
        error "  Detection method: ${detection_method}"
        error "  Current TTY: ${current_tty}"
        error ""
        error "  YOU MUST RUN THIS SCRIPT FROM A LOCAL CONSOLE:"
        error "    - VMware Console"
        error "    - IPMI/iLO/iDRAC KVM"
        error "    - Physical keyboard/monitor"
        error ""
        error "═══════════════════════════════════════════════════════════════════════"
        
        if $FORCE_SSH; then
            warn ""
            warn "  --force-ssh flag detected. Proceeding despite SSH session."
            warn "  YOU WILL LOSE CONNECTION AND MUST USE CONSOLE TO VERIFY RESULTS."
            warn ""
            read -p "  Type 'I UNDERSTAND' to continue (or anything else to abort): " confirm
            if [[ "$confirm" != "I UNDERSTAND" ]]; then
                fatal "Aborted by user"
            fi
            warn "Continuing via SSH as requested (--force-ssh)"
        else
            error ""
            error "  To override this check (NOT RECOMMENDED), use: --force-ssh"
            error ""
            fatal "Aborting: Cannot run network migration via SSH"
        fi
    else
        success "Running from local console (TTY: ${current_tty})"
    fi
}

check_core_user_password() {
    info "Checking if core user has password set..."
    
    # Check if core user exists
    if ! id "core" &>/dev/null; then
        fatal "User 'core' does not exist on this system"
    fi
    
    # Check password field in /etc/shadow
    local shadow_entry=$(grep "^core:" /etc/shadow 2>/dev/null || true)
    
    if [[ -z "$shadow_entry" ]]; then
        fatal "Cannot read shadow entry for core user"
    fi
    
    # Extract password hash (second field)
    local pass_hash=$(echo "$shadow_entry" | cut -d: -f2)
    
    # Check for locked/no password indicators
    # '!' or '!!' or '*' or empty means no valid password
    if [[ "$pass_hash" == "!" || "$pass_hash" == "!!" || "$pass_hash" == "*" || -z "$pass_hash" ]]; then
        error "SECURITY REQUIREMENT: Core user does NOT have a password set!"
        error ""
        error "Console access is REQUIRED for recovery if network fails."
        error "Set a password for core user before running this script:"
        error ""
        error "    passwd core"
        error ""
        fatal "Aborting: core user password not set"
    fi
    
    success "Core user has password set (console recovery available)"
}

check_interfaces() {
    info "Checking network interfaces..."
    
    if [[ ! -d "/sys/class/net/${NIC1}" ]]; then
        fatal "Interface ${NIC1} does not exist. Available interfaces: $(ls /sys/class/net/ | grep -v lo | tr '\n' ' ')"
    fi
    
    if [[ ! -d "/sys/class/net/${NIC2}" ]]; then
        fatal "Interface ${NIC2} does not exist. Available interfaces: $(ls /sys/class/net/ | grep -v lo | tr '\n' ' ')"
    fi
    
    success "Interfaces ${NIC1} and ${NIC2} exist"
}

check_current_connectivity() {
    info "Checking current network connectivity..."
    
    if ! ping -c 2 -W 3 "$GATEWAY" &>/dev/null; then
        warn "Cannot ping gateway ${GATEWAY} - connectivity may already be impaired"
        read -p "Continue anyway? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            fatal "Aborted by user"
        fi
    else
        success "Gateway ${GATEWAY} is reachable"
    fi
}

check_ocp_version() {
    info "Checking OpenShift version..."
    
    local current_version=""
    
    # Try to get version from node
    if command -v oc &>/dev/null && [[ -f /var/lib/kubelet/kubeconfig ]]; then
        current_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
    fi
    
    # Fallback: check release file
    if [[ -z "$current_version" ]] && [[ -f /etc/os-release ]]; then
        current_version=$(grep -oP 'OPENSHIFT_VERSION="\K[^"]+' /etc/os-release 2>/dev/null || true)
    fi
    
    if [[ -n "$current_version" ]]; then
        if [[ "$current_version" == "$TESTED_OCP_VERSION" ]]; then
            success "OpenShift version: ${current_version} (tested)"
        else
            warn "OpenShift version: ${current_version} (script tested on ${TESTED_OCP_VERSION})"
        fi
    else
        warn "Could not determine OpenShift version (script tested on ${TESTED_OCP_VERSION})"
    fi
}

check_existing_backup() {
    SKIP_BACKUP=false
    if [[ -d "$BACKUP_DIR" ]]; then
        warn "Backup directory already exists: ${BACKUP_DIR}"
        local backup_date=$(stat -c %y "$BACKUP_DIR" 2>/dev/null | cut -d' ' -f1)
        warn "Created on: ${backup_date}"
        echo ""
        echo "Options:"
        echo "  [o] Overwrite - Create new backup (deletes existing)"
        echo "  [k] Keep      - Continue using existing backup"
        echo "  [a] Abort     - Exit script"
        echo ""
        read -p "Choose option [o/k/a]: " choice
        case "${choice,,}" in  # ${choice,,} converts to lowercase
            o|overwrite)
                info "Will overwrite existing backup"
                rm -rf "$BACKUP_DIR"
                ;;
            k|keep)
                info "Keeping existing backup, skipping backup phase"
                SKIP_BACKUP=true
                ;;
            a|abort|*)
                fatal "Aborted by user"
                ;;
        esac
    fi
    success "Backup directory check passed"
}

#-------------------------------------------------------------------------------
# Migration Functions
#-------------------------------------------------------------------------------
create_backup() {
    info "PHASE 1: Creating backup..."
    
    if $SKIP_BACKUP; then
        info "Skipping backup (using existing backup in ${BACKUP_DIR})"
        return
    fi
    
    if $DRY_RUN; then
        info "[DRY-RUN] Would create backup in ${BACKUP_DIR}"
        return
    fi
    
    mkdir -p "${BACKUP_DIR}/cni"
    
    # Backup NetworkManager connections
    cp -a /etc/NetworkManager/system-connections/* "${BACKUP_DIR}/" 2>/dev/null || true
    
    # Backup CNI configuration
    cp -a /etc/kubernetes/cni/net.d/* "${BACKUP_DIR}/cni/" 2>/dev/null || true
    cp /run/multus/cni/net.d/10-ovn-kubernetes.conf "${BACKUP_DIR}/cni/" 2>/dev/null || true
    
    # Backup current nmstate if exists (both paths)
    cp -a /etc/nmstate/*.yml "${BACKUP_DIR}/" 2>/dev/null || true
    cp -a /etc/nmstate/openshift/*.yml "${BACKUP_DIR}/" 2>/dev/null || true
    
    success "Backup created in ${BACKUP_DIR}"
}

prepare_environment() {
    info "PHASE 2: Preparing environment..."
    
    if $DRY_RUN; then
        info "[DRY-RUN] Would remove NM connections and create nmstate directory"
        return
    fi
    
    # Remove NetworkManager connections
    rm -f /etc/NetworkManager/system-connections/*
    
    # Create openshift nmstate directory
    # Using /etc/nmstate/openshift/ is the product-provided interface
    # The nmstate-configuration service will handle the 'applied' flag automatically
    mkdir -p /etc/nmstate/openshift
    
    success "Environment prepared"
}

create_nmstate_config() {
    local hostname=$(hostname -s)
    # Use the product-provided path: /etc/nmstate/openshift/
    local nmstate_file="/etc/nmstate/openshift/${hostname}.yml"
    
    info "PHASE 3: Creating nmstate configuration..."
    info "Hostname: ${hostname}"
    info "File: ${nmstate_file}"
    
    local config="interfaces:
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
        bridge-uplink: \"patch-ex-to-phy\"

  - name: br-ex
    type: ovs-interface
    state: up
    mtu: ${MTU}
    copy-mac-from: ${NIC1}
    ipv4:
      enabled: true
      address:
      - ip: ${NODE_IP}
        prefix-length: ${PREFIX_LENGTH}
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
          tag: ${VLAN_TAG}
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
    mtu: ${MTU}
    controller: br-phy
    ipv4:
      enabled: false
    ipv6:
      enabled: false

  - name: ${NIC2}
    type: ethernet
    state: up
    mtu: ${MTU}
    controller: br-phy
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
    next-hop-interface: br-ex"

    if $DRY_RUN; then
        info "[DRY-RUN] Would create ${nmstate_file} with content:"
        echo "---"
        echo "$config"
        echo "---"
        return
    fi
    
    mkdir -p /etc/nmstate/openshift
    echo "$config" > "$nmstate_file"
    success "nmstate configuration created: ${nmstate_file}"
}

apply_network_config() {
    local hostname=$(hostname -s)
    local nmstate_file="/etc/nmstate/openshift/${hostname}.yml"
    
    info "PHASE 4: Applying nmstate configuration..."
    
    if $DRY_RUN; then
        info "[DRY-RUN] Would apply nmstate configuration"
        return
    fi
    
    # NOTE: No need to manually delete br-ex/br-phy
    # The nmstate-configuration service handles cleanup in recent z-streams
    # when using the /etc/nmstate/openshift/ path
    
    warn ">>> NETWORK WILL BE RECONFIGURED - Have console access ready! <<<"
    
    sleep 2
    
    nmstatectl apply "$nmstate_file"
    
    success "nmstate configuration applied"
}

verify_connectivity() {
    info "PHASE 5: Verifying connectivity..."
    
    if $DRY_RUN; then
        info "[DRY-RUN] Would verify connectivity to ${GATEWAY}"
        return
    fi
    
    info "Waiting for network stack to stabilize..."
    sleep 5
    
    if ping -c 3 -W 5 "$GATEWAY" &>/dev/null; then
        success "Gateway ${GATEWAY} is reachable"
    else
        error "Cannot reach gateway ${GATEWAY}!"
        error "Use console access to troubleshoot."
        error "Rollback: rm /etc/nmstate/openshift/$(hostname -s).yml && reboot"
        exit 1
    fi
}

verify_mtu() {
    info "PHASE 5.1: Verifying MTU configuration..."
    
    if $DRY_RUN; then
        info "[DRY-RUN] Would verify MTU is ${MTU} on all interfaces"
        return
    fi
    
    # Wait for OVS interfaces to be fully registered in kernel
    # After nmstatectl apply, there can be a delay before ip link sees them
    info "Waiting for OVS interfaces to be fully available..."
    
    local max_attempts=10
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        if ip link show br-ex &>/dev/null && ip link show br-phy &>/dev/null; then
            success "OVS interfaces are available (attempt ${attempt}/${max_attempts})"
            break
        fi
        
        if [[ $attempt -eq $max_attempts ]]; then
            warn "Interfaces not visible via 'ip link' after ${max_attempts} attempts"
            warn "This may be a timing issue. Checking via ovs-vsctl..."
            
            # Fallback: verify via OVS directly
            if ovs-vsctl br-exists br-ex && ovs-vsctl br-exists br-phy; then
                warn "Bridges exist in OVS but not yet in kernel. Waiting 5 more seconds..."
                sleep 5
            else
                error "Bridges not found in OVS either!"
                return 1
            fi
        fi
        
        sleep 1
        ((attempt++))
    done
    
    # Now check and fix MTU
    local br_ex_mtu=$(ip link show br-ex 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "0")
    local br_phy_mtu=$(ip link show br-phy 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "0")
    
    local mtu_ok=true
    
    if [[ "$br_ex_mtu" != "$MTU" ]]; then
        warn "br-ex MTU is ${br_ex_mtu}, expected ${MTU}. Correcting..."
        ip link set br-ex mtu "$MTU" 2>/dev/null || warn "Could not set br-ex MTU (may need retry after services restart)"
        mtu_ok=false
    fi
    
    if [[ "$br_phy_mtu" != "$MTU" ]]; then
        warn "br-phy MTU is ${br_phy_mtu}, expected ${MTU}. Correcting..."
        ip link set br-phy mtu "$MTU" 2>/dev/null || warn "Could not set br-phy MTU (may need retry after services restart)"
        mtu_ok=false
    fi
    
    if $mtu_ok; then
        success "MTU is correctly set to ${MTU}"
    else
        success "MTU correction attempted"
    fi
}

restore_cni() {
    info "PHASE 6: Ensuring CNI configuration..."
    
    if $DRY_RUN; then
        info "[DRY-RUN] Would ensure CNI files exist"
        return
    fi
    
    # Check for 00-multus.conf FIRST (critical)
    local multus_cni="/etc/kubernetes/cni/net.d/00-multus.conf"
    if [[ ! -f "$multus_cni" ]]; then
        warn "Missing ${multus_cni}"
        if [[ -f "${BACKUP_DIR}/cni/00-multus.conf" ]]; then
            info "Restoring from backup..."
            cp "${BACKUP_DIR}/cni/00-multus.conf" "$multus_cni"
            success "Restored 00-multus.conf from backup"
        else
            error "00-multus.conf not found in backup!"
            error "Copy from a working node: scp <working-node>:/etc/kubernetes/cni/net.d/00-multus.conf ${multus_cni}"
            fatal "Cannot continue without 00-multus.conf"
        fi
    else
        success "CNI file exists: ${multus_cni}"
    fi
    
    # 10-ovn-kubernetes.conf is generated by ovnkube-node pod
    # Only create if missing AND we have it in backup
    local ovn_cni="/etc/kubernetes/cni/net.d/10-ovn-kubernetes.conf"
    if [[ ! -f "$ovn_cni" ]]; then
        info "Note: ${ovn_cni} will be created by ovnkube-node pod on startup"
    else
        success "CNI file exists: ${ovn_cni}"
    fi
}

restart_services() {
    info "PHASE 7: Restarting container runtime and kubelet..."
    
    if $DRY_RUN; then
        info "[DRY-RUN] Would restart crio and kubelet"
        return
    fi
    
    systemctl restart crio
    sleep 3
    systemctl restart kubelet
    
    sleep 10
    
    if systemctl is-active --quiet kubelet; then
        success "kubelet is running"
    else
        warn "kubelet may still be starting..."
    fi
}

show_validation() {
    info "PHASE 8: Validation summary..."
    
    if $DRY_RUN; then
        info "[DRY-RUN] Would show validation output"
        return
    fi
    
    echo ""
    echo "=== OVS Bond Status ==="
    ovs-appctl bond/show ovs-bond 2>/dev/null || echo "Bond not found (may need time to initialize)"
    
    echo ""
    echo "=== OVS Bridge Configuration ==="
    ovs-vsctl show
    
    echo ""
    echo "=== br-ex IP Address ==="
    ip addr show br-ex | grep -E "inet|mtu"
    
    echo ""
    echo "=== CNI Files ==="
    ls -la /etc/kubernetes/cni/net.d/
    
    echo ""
    echo "=== Service Status ==="
    echo "crio:    $(systemctl is-active crio)"
    echo "kubelet: $(systemctl is-active kubelet)"
}

show_completion() {
    echo ""
    echo "==============================================================================="
    if $DRY_RUN; then
        success "DRY-RUN COMPLETE - No changes were made"
        echo ""
        echo "To perform the actual migration, run without --dry-run"
    else
        success "CONFIGURATION APPLIED SUCCESSFULLY"
        echo ""
        warn "A REBOOT IS REQUIRED for changes to take effect!"
        echo ""
        echo "Next steps:"
        echo "  1. Reboot the node:           reboot"
        echo "  2. After reboot, validate:    ./migrate-to-ovs-slb.sh --validate"
        echo "  3. Verify node is Ready:      oc get nodes"
        echo "  4. Uncordon the node:         oc adm uncordon <node-name>"
        echo ""
        echo "Rollback (if needed):"
        echo "  rm -f /etc/nmstate/openshift/\$(hostname -s).yml"
        echo "  cp ${BACKUP_DIR}/*.nmconnection /etc/NetworkManager/system-connections/"
        echo "  reboot"
    fi
    echo "==============================================================================="
    echo ""
    echo "Log file: ${LOG_FILE}"
}

#-------------------------------------------------------------------------------
# Validation Mode Functions
#-------------------------------------------------------------------------------
run_full_validation() {
    echo ""
    echo "==============================================================================="
    echo " OVS Balance-SLB Validation"
    echo " Running post-reboot validation and bond testing"
    echo "==============================================================================="
    echo ""
    
    local all_passed=true
    
    # Test 1: Check OVS bridges exist
    info "TEST 1: Checking OVS bridges..."
    if ovs-vsctl br-exists br-ex && ovs-vsctl br-exists br-phy; then
        success "br-ex and br-phy bridges exist"
    else
        error "OVS bridges missing!"
        all_passed=false
    fi
    
    # Test 2: Check bond status
    info "TEST 2: Checking OVS bond status..."
    local bond_output=$(ovs-appctl bond/show ovs-bond 2>/dev/null)
    if [[ -n "$bond_output" ]]; then
        echo "$bond_output"
        if echo "$bond_output" | grep -q "bond_mode: balance-slb"; then
            success "Bond mode is balance-slb"
        else
            error "Bond mode is NOT balance-slb!"
            all_passed=false
        fi
        
        # Check if both slaves are enabled
        local enabled_count=$(echo "$bond_output" | grep -c "may_enable: true" || echo "0")
        if [[ "$enabled_count" -ge 2 ]]; then
            success "Both bond members are enabled"
        else
            warn "Not all bond members are enabled (found ${enabled_count})"
        fi
    else
        error "Bond 'ovs-bond' not found!"
        all_passed=false
    fi
    
    # Test 3: Check MTU
    info "TEST 3: Checking MTU configuration..."
    local br_ex_mtu=$(ip link show br-ex 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "0")
    
    # For physical interfaces, get from bond members
    local nic1_mtu=$(ip link show "${NIC1}" 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "0")
    local nic2_mtu=$(ip link show "${NIC2}" 2>/dev/null | grep -oP 'mtu \K[0-9]+' || echo "0")
    
    echo "  br-ex MTU: ${br_ex_mtu}"
    echo "  ${NIC1} MTU: ${nic1_mtu}"
    echo "  ${NIC2} MTU: ${nic2_mtu}"
    
    if [[ "$br_ex_mtu" -ge 9000 ]] && [[ "$nic1_mtu" -ge 9000 ]] && [[ "$nic2_mtu" -ge 9000 ]]; then
        success "MTU is correctly set to jumbo frames"
    else
        error "MTU is not correctly configured (expected >= 9000)"
        all_passed=false
    fi
    
    # Test 4: Check IP address
    info "TEST 4: Checking br-ex IP address..."
    local br_ex_ip=$(ip -4 addr show br-ex 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "none")
    echo "  br-ex IP: ${br_ex_ip}"
    if [[ "$br_ex_ip" != "none" ]]; then
        success "br-ex has IP address configured"
    else
        error "br-ex has no IP address!"
        all_passed=false
    fi
    
    # Test 5: Check gateway connectivity
    info "TEST 5: Checking gateway connectivity..."
    if ping -c 3 -W 3 "$GATEWAY" &>/dev/null; then
        success "Gateway ${GATEWAY} is reachable"
    else
        error "Cannot reach gateway ${GATEWAY}!"
        all_passed=false
    fi
    
    # Test 6: Check CNI files
    info "TEST 6: Checking CNI configuration..."
    if [[ -f /etc/kubernetes/cni/net.d/00-multus.conf ]]; then
        success "00-multus.conf exists"
    else
        error "00-multus.conf is missing!"
        all_passed=false
    fi
    
    if [[ -f /run/multus/cni/net.d/10-ovn-kubernetes.conf ]]; then
        success "10-ovn-kubernetes.conf exists (generated by ovnkube-node)"
    else
        warn "10-ovn-kubernetes.conf not yet created (ovnkube-node may still be starting)"
    fi
    
    # Test 7: Check services
    info "TEST 7: Checking system services..."
    if systemctl is-active --quiet crio; then
        success "crio is running"
    else
        error "crio is not running!"
        all_passed=false
    fi
    
    if systemctl is-active --quiet kubelet; then
        success "kubelet is running"
    else
        error "kubelet is not running!"
        all_passed=false
    fi
    
    # Test 8: Bond health check (non-invasive)
    info "TEST 8: Checking bond member health..."
    
    # Get member interfaces
    local members=$(ovs-appctl bond/show ovs-bond 2>/dev/null | grep -E "^member " | awk '{print $2}' | tr -d ':')
    local first_member=$(echo "$members" | head -1)
    local second_member=$(echo "$members" | tail -1)
    
    if [[ -n "$first_member" ]] && [[ -n "$second_member" ]]; then
        echo ""
        # Check carrier/link state
        local nic1_carrier=$(cat /sys/class/net/${first_member}/carrier 2>/dev/null || echo "0")
        local nic2_carrier=$(cat /sys/class/net/${second_member}/carrier 2>/dev/null || echo "0")
        
        # Check operstate
        local nic1_state=$(cat /sys/class/net/${first_member}/operstate 2>/dev/null || echo "unknown")
        local nic2_state=$(cat /sys/class/net/${second_member}/operstate 2>/dev/null || echo "unknown")
        
        # Get TX/RX stats
        local nic1_tx=$(cat /sys/class/net/${first_member}/statistics/tx_bytes 2>/dev/null || echo "0")
        local nic1_rx=$(cat /sys/class/net/${first_member}/statistics/rx_bytes 2>/dev/null || echo "0")
        local nic2_tx=$(cat /sys/class/net/${second_member}/statistics/tx_bytes 2>/dev/null || echo "0")
        local nic2_rx=$(cat /sys/class/net/${second_member}/statistics/rx_bytes 2>/dev/null || echo "0")
        
        echo "  ${first_member}: carrier=${nic1_carrier} state=${nic1_state} TX=$(numfmt --to=iec ${nic1_tx})B RX=$(numfmt --to=iec ${nic1_rx})B"
        echo "  ${second_member}: carrier=${nic2_carrier} state=${nic2_state} TX=$(numfmt --to=iec ${nic2_tx})B RX=$(numfmt --to=iec ${nic2_rx})B"
        echo ""
        
        if [[ "$nic1_carrier" == "1" ]] && [[ "$nic2_carrier" == "1" ]]; then
            success "Both bond members have active links"
        else
            error "One or more bond members have no carrier!"
            all_passed=false
        fi
        
        if [[ "$nic1_state" == "up" ]] && [[ "$nic2_state" == "up" ]]; then
            success "Both bond members are in 'up' state"
        else
            warn "One or more bond members not in 'up' state"
        fi
        
        # Check if both have traffic (indicates active participation)
        if [[ "$nic1_tx" -gt 0 ]] && [[ "$nic2_tx" -gt 0 ]]; then
            success "Both bond members have transmitted traffic"
        else
            warn "Not all bond members show TX traffic (may be normal for balance-slb)"
        fi
    else
        error "Could not determine bond member interfaces"
        all_passed=false
    fi
    
    # Summary
    echo ""
    echo "==============================================================================="
    if $all_passed; then
        success "ALL VALIDATION TESTS PASSED"
        echo ""
        echo "Next steps:"
        echo "  1. Verify node is Ready:   oc get nodes"
        echo "  2. Uncordon the node:      oc adm uncordon <node-name>"
        echo ""
        echo "Optional: Run invasive failover test with: --failover-test"
    else
        error "SOME VALIDATION TESTS FAILED"
        echo ""
        echo "Check the errors above and troubleshoot before proceeding."
        echo "See the procedure document for troubleshooting guidance."
    fi
    echo "==============================================================================="
}

run_bond_failover_test() {
    info "Starting bond failover test..."
    
    # Get the member interfaces (OVS uses "member" not "slave" in newer versions)
    local members=$(ovs-appctl bond/show ovs-bond 2>/dev/null | grep -E "^member " | awk '{print $2}' | tr -d ':')
    local first_member=$(echo "$members" | head -1)
    local second_member=$(echo "$members" | tail -1)
    
    if [[ -z "$first_member" ]]; then
        error "Could not determine bond member interfaces"
        return 1
    fi
    
    echo ""
    echo "  Bond members detected: ${first_member}, ${second_member}"
    echo ""
    
    # Test 1: Disable first member
    info "  Disabling ${first_member}..."
    ip link set "$first_member" down
    info "  Waiting 5 seconds for bond to rebalance..."
    sleep 5
    
    echo "  Testing connectivity with ${first_member} down..."
    if ping -c 5 -W 3 "$GATEWAY" &>/dev/null; then
        success "  Network still operational with ${first_member} down"
    else
        warn "  Network disruption when ${first_member} was disabled"
    fi
    
    # Re-enable first member
    info "  Re-enabling ${first_member}..."
    ip link set "$first_member" up
    sleep 3
    
    # Test 2: Disable second member
    info "  Disabling ${second_member}..."
    ip link set "$second_member" down
    info "  Waiting 5 seconds for bond to rebalance..."
    sleep 5
    
    echo "  Testing connectivity with ${second_member} down..."
    if ping -c 5 -W 3 "$GATEWAY" &>/dev/null; then
        success "  Network still operational with ${second_member} down"
    else
        warn "  Network disruption when ${second_member} was disabled"
    fi
    
    # Re-enable second member
    info "  Re-enabling ${second_member}..."
    ip link set "$second_member" up
    sleep 3
    
    # Verify both are back up
    echo ""
    info "  Verifying bond status after test..."
    ovs-appctl bond/show ovs-bond | grep -E "member|may_enable"
    
    # Final connectivity check
    if ping -c 3 -W 3 "$GATEWAY" &>/dev/null; then
        success "Bond failover test completed - both members restored"
    else
        error "Network connectivity issue after failover test!"
    fi
}

#-------------------------------------------------------------------------------
# Main
#-------------------------------------------------------------------------------
main() {
    # Initialize log
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "" >> "$LOG_FILE"
    
    parse_args "$@"
    
    # Handle validation mode separately
    if $VALIDATE_ONLY; then
        log "INFO" "========== Validation started: $(date) =========="
        check_root
        run_full_validation
        log "INFO" "========== Validation completed: $(date) =========="
        exit 0
    fi
    
    # Handle failover test mode separately
    if $FAILOVER_TEST; then
        log "INFO" "========== Failover Test started: $(date) =========="
        check_root
        check_ssh_session
        echo ""
        echo "==============================================================================="
        echo " OVS Balance-SLB Bond Failover Test"
        echo " WARNING: This test will temporarily disable network interfaces!"
        echo "==============================================================================="
        echo ""
        warn "This is an INVASIVE test that will:"
        echo "  - Disable each bond member interface one at a time"
        echo "  - Test network connectivity with each interface down"
        echo "  - Re-enable interfaces after testing"
        echo ""
        read -p "Proceed with failover test? (y/N): " confirm
        if [[ "${confirm,,}" == "y" ]]; then
            run_bond_failover_test
        else
            info "Failover test cancelled"
        fi
        log "INFO" "========== Failover Test completed: $(date) =========="
        exit 0
    fi
    
    # Migration mode
    log "INFO" "========== Migration started: $(date) =========="
    
    echo ""
    echo "==============================================================================="
    echo " OVS Balance-SLB Migration Script v${VERSION}"
    echo " Tested on OpenShift ${TESTED_OCP_VERSION}"
    echo "==============================================================================="
    echo ""
    
    if $DRY_RUN; then
        warn "DRY-RUN MODE - No changes will be made"
        echo ""
    fi
    
    info "Configuration:"
    echo "  Node IP:     ${NODE_IP}/${PREFIX_LENGTH}"
    echo "  Gateway:     ${GATEWAY}"
    echo "  DNS:         ${DNS1}, ${DNS2}"
    echo "  Interfaces:  ${NIC1}, ${NIC2}"
    echo "  VLAN Tag:    ${VLAN_TAG}"
    echo "  MTU:         ${MTU}"
    echo ""
    
    # Validations
    info "Running pre-flight checks..."
    echo ""
    
    check_root
    check_ssh_session
    validate_ip "$NODE_IP" "Node IP"
    validate_ip "$GATEWAY" "Gateway"
    validate_ip "$DNS1" "DNS1"
    validate_ip "$DNS2" "DNS2"
    validate_number "$PREFIX_LENGTH" "Prefix length" 1 32
    validate_number "$VLAN_TAG" "VLAN tag" 1 4094
    validate_number "$MTU" "MTU" 1280 9216
    
    check_core_user_password
    check_interfaces
    check_current_connectivity
    check_ocp_version
    check_existing_backup
    
    echo ""
    success "All pre-flight checks passed"
    echo ""
    
    if ! $DRY_RUN; then
        warn "This will reconfigure the node's network!"
        warn "A REBOOT will be required after configuration is applied."
        warn "Ensure you have console access for recovery."
        echo ""
        read -p "Proceed with migration? (y/N): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            fatal "Aborted by user"
        fi
        echo ""
    fi
    
    # Execute migration phases
    create_backup
    prepare_environment
    create_nmstate_config
    apply_network_config
    
    # Skip connectivity test - it requires reboot to work properly
    info "PHASE 5: Skipping connectivity test (requires reboot)..."
    info "Network configuration has been applied."
    
    restore_cni
    show_completion
    
    log "INFO" "========== Migration completed: $(date) =========="
}

main "$@"