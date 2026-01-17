#!/bin/bash

set -eo pipefail

usage() {
    cat <<EOF
Usage: $0 [-d <nmstate_dir>] [-c <nodes_conf>]

Options:
    -d    Directory containing nmstate .yml files (default: current directory)
    -c    Path to nodes.conf file (default: ./nodes.conf)
    -h    Show this help message

nodes.conf format (one node per line):
    <hostname> <role>

Example nodes.conf:
    ocp-node-0.example.com master
    ocp-node-1.example.com master
    ocp-node-2.example.com master
    ocp-node-3.example.com worker
    ocp-node-4.example.com worker

EOF
    exit 1
}

NMSTATE_DIR="."
NODES_CONF="./nodes.conf"

while getopts ":d:c:h" opt; do
    case ${opt} in
        d) NMSTATE_DIR="$OPTARG" ;;
        c) NODES_CONF="$OPTARG" ;;
        h) usage ;;
        \?) echo "ERROR: Invalid option -$OPTARG" >&2; usage ;;
        :) echo "ERROR: Option -$OPTARG requires an argument" >&2; usage ;;
    esac
done

# NetworkManager server config (base64 encoded)
NM_CONF_B64="IyBUaGlzIGNvbmZpZ3VyYXRpb24gZmlsZSBjaGFuZ2VzIE5ldHdvcmtNYW5hZ2VyJ3MgYmVoYXZpb3IgdG8KIyB3aGF0J3MgZXhwZWN0ZWQgb24gInRyYWRpdGlvbmFsIFVOSVggc2VydmVyIiB0eXBlIGRlcGxveW1lbnRzLgojCiMgU2VlICJtYW4gTmV0d29ya01hbmFnZXIuY29uZiIgZm9yIG1vcmUgaW5mb3JtYXRpb24gYWJvdXQgdGhlc2UKIyBhbmQgb3RoZXIga2V5cy4KClttYWluXQojIERvIG5vdCBkbyBhdXRvbWF0aWMgKERIQ1AvU0xBQUMpIGNvbmZpZ3VyYXRpb24gb24gZXRoZXJuZXQgZGV2aWNlcwojIHdpdGggbm8gb3RoZXIgbWF0Y2hpbmcgY29ubmVjdGlvbnMuCm5vLWF1dG8tZGVmYXVsdD0qCgojIElnbm9yZSB0aGUgY2FycmllciAoY2FibGUgcGx1Z2dlZCBpbikgc3RhdGUgd2hlbiBhdHRlbXB0aW5nIHRvCiMgYWN0aXZhdGUgc3RhdGljLUlQIGNvbm5lY3Rpb25zLgppZ25vcmUtY2Fycmllcj0qCg=="

if [[ ! -f "$NODES_CONF" ]]; then
    echo "ERROR: nodes.conf not found at '$NODES_CONF'" >&2
    echo "Create it with format: <hostname> <role>" >&2
    echo "Example:" >&2
    echo "  ocp-node-0.example.com master" >&2
    exit 1
fi

if [[ ! -d "$NMSTATE_DIR" ]]; then
    echo "ERROR: Directory '$NMSTATE_DIR' does not exist" >&2
    exit 1
fi

declare -a MASTER_NODES=()
declare -a WORKER_NODES=()

line_num=0
while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_num++))
    
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    
    read -r hostname role <<< "$line"
    
    if [[ -z "$hostname" || -z "$role" ]]; then
        echo "ERROR: Invalid format at line $line_num: '$line'" >&2
        echo "Expected: <hostname> <role>" >&2
        exit 1
    fi
    
    case "$role" in
        master) MASTER_NODES+=("$hostname") ;;
        worker) WORKER_NODES+=("$hostname") ;;
        *)
            echo "ERROR: Invalid role '$role' at line $line_num (must be 'master' or 'worker')" >&2
            exit 1
            ;;
    esac
done < "$NODES_CONF"

if [[ ${#MASTER_NODES[@]} -eq 0 && ${#WORKER_NODES[@]} -eq 0 ]]; then
    echo "ERROR: No nodes defined in '$NODES_CONF'" >&2
    exit 1
fi

validate_files() {
    local nodes=("$@")
    local missing=()
    
    for node in "${nodes[@]}"; do
        [[ ! -f "${NMSTATE_DIR}/${node}.yml" ]] && missing+=("${node}.yml")
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing nmstate files in '${NMSTATE_DIR}':" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        return 1
    fi
    return 0
}

generate_files_section() {
    local nodes=("$@")
    
    for node in "${nodes[@]}"; do
        local file="${node}.yml"
        local b64
        b64=$(base64 -w0 < "${NMSTATE_DIR}/${file}")
        
        cat <<ENTRY
      - contents:
          source: data:text/plain;charset=utf-8;base64,${b64}
        mode: 0644
        overwrite: true
        path: /etc/nmstate/openshift/${file}
ENTRY
    done
}

generate_mc() {
    local role=$1
    shift
    local nodes=("$@")
    local output_file="10-br-ex-${role}-mc.yml"
    
    cat <<EOF > "$output_file"
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  name: 10-br-ex-${role}
spec:
  config:
    ignition:
      version: 3.4.0
    storage:
      files:
      - contents:
          source: data:text/plain;charset=utf-8;base64,${NM_CONF_B64}
        mode: 0644
        overwrite: true
        path: /etc/NetworkManager/conf.d/00-server.conf
$(generate_files_section "${nodes[@]}")
EOF

    echo "Generated: $output_file"
}

echo "Using nodes.conf: $NODES_CONF"
echo "Using nmstate dir: $NMSTATE_DIR"
echo ""

ALL_NODES=("${MASTER_NODES[@]}" "${WORKER_NODES[@]}")
if ! validate_files "${ALL_NODES[@]}"; then
    exit 1
fi

echo "Found ${#MASTER_NODES[@]} master(s), ${#WORKER_NODES[@]} worker(s)"
echo ""

[[ ${#MASTER_NODES[@]} -gt 0 ]] && generate_mc "master" "${MASTER_NODES[@]}"
[[ ${#WORKER_NODES[@]} -gt 0 ]] && generate_mc "worker" "${WORKER_NODES[@]}"

echo ""
echo "Done. Upload the generated files to the 'openshift/' folder in Assisted Installer."