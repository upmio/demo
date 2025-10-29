#!/bin/bash

# Deploy MongoDB ReplicaSet Script
# This script deploys a MongoDB ReplicaSet using UPM
# Output style and deployment logic fully mirror the InnoDB Cluster script

set -euo pipefail

# Color definitions for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="$(mktemp -d)"
DRY_RUN="false"
SHOW_HELP="false"

# Command line arguments
STORAGE_CLASS=""
NAMESPACE=""
MONGODB_VERSION=""
NODEPORT_IP=""

# YAML template files list
YAML_FILES=(
    "0-project.yaml"
    "1-gen-secret.yaml"
    "2-mongodb-us.yaml"
    "3-mongodb-replicaset.yaml"
)

# Print functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Cross-platform sed helper
sed_inplace() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# Help information
show_help() {
    cat << EOF
Deploy MongoDB ReplicaSet Script

This script deploys a MongoDB ReplicaSet using UPM.

Usage: $0 [OPTIONS]

Options:
  -s, --storage-class STORAGE_CLASS    Kubernetes StorageClass name
  -n, --namespace NAMESPACE            Kubernetes namespace
  -v, --mongodb-version VERSION        MongoDB version to deploy
  -i, --nodeport-ip IP                 NodePort IP address (auto-detected if not specified)
  -d, --dry-run                        Show what would be deployed without actually deploying
  -h, --help                           Show this help message

Examples:
  # Interactive deployment (recommended)
  $0

  # Non-interactive deployment with all parameters
  $0 -s local-path -n demo -v 7.0.0 -i 192.168.1.100

  # Dry run to see what would be deployed
  $0 -s local-path -n demo -v 7.0.0 --dry-run

Notes:
  - If parameters are not provided, the script will prompt for them interactively
  - NodePort IP will be auto-detected from cluster nodes if not specified
  - The script requires kubectl, helm, curl, jq, and sed to be installed
  - UPM packages will be automatically installed if not present

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--storage-class)
                STORAGE_CLASS="$2"
                shift 2
                ;;
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -v|--mongodb-version)
                MONGODB_VERSION="$2"
                shift 2
                ;;
            -i|--nodeport-ip)
                NODEPORT_IP="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                SHOW_HELP="true"
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Cleanup function
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        print_info "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# Download YAML templates
download_yaml_templates() {
    local temp_dir="$1"
    mkdir -p "$temp_dir"

    local base_url="https://raw.githubusercontent.com/upmio/demo/refs/heads/main/mongodb-replicaset/templates"

    local yaml_files=(
        "0-project.yaml"
        "1-gen-secret.yaml"
        "2-mongodb-us.yaml"
        "3-mongodb-replicaset.yaml"
    )

    print_info "Downloading YAML templates from remote repository..."

    local download_success=true
    for yaml_file in "${yaml_files[@]}"; do
        local file_url="${base_url}/${yaml_file}"
        local target_file="${temp_dir}/${yaml_file}"

        print_info "Downloading ${yaml_file}..."

        if curl -sSL --fail "$file_url" -o "$target_file"; then
            print_success "Successfully downloaded ${yaml_file}"
        else
            print_error "Failed to download ${yaml_file} from ${file_url}"
            download_success=false
            break
        fi

        if [[ ! -s "$target_file" ]]; then
            print_error "Downloaded file ${yaml_file} is empty or corrupted"
            download_success=false
            break
        fi
    done

    if [[ "$download_success" == "true" ]]; then
        print_success "All YAML templates downloaded successfully to $temp_dir"
    else
        print_error "YAML template download failed. Please check:"
        print_error "  1. Network connectivity"
        print_error "  2. Repository URL: $base_url"
        print_error "  3. Template files availability"
        exit 1
    fi
}

# Generate random identifier
generate_random_identifier() {
    local length="${1:-5}"
    local chars="abcdefghijklmnopqrstuvwxyz0123456789"
    local result=""
    for ((i=0; i<length; i++)); do
        local random_index=$((RANDOM % ${#chars}))
        result+="${chars:$random_index:1}"
    done
    echo "$result"
}

# Escape for sed replacement
escape_sed_replacement() {
    local input="$1"
    printf '%s\n' "$input" | sed 's/[\\&\/]/\\&/g'
}

# Prepare YAML files
prepare_yaml_files() {
    print_info "Preparing YAML configuration files..."
    download_yaml_templates "$TEMP_DIR"
    print_success "YAML files prepared in temporary directory: $TEMP_DIR"
}

# Check StorageClass
check_storageclass() {
    print_info "Checking StorageClass availability..."
    local available_sc
    available_sc=$(kubectl get storageclass --no-headers -o custom-columns=":metadata.name" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$available_sc" -eq 0 ]]; then
        print_error "No available StorageClass found in the cluster"
        print_error "Please install StorageClass first, for example:"
        echo "  - Local storage: kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"
        echo "  - Or other storage solutions"
        exit 1
    fi
    print_success "Found $available_sc available StorageClass(es)"
}

# Check and add helm repository if needed
check_helm_repo() {
    print_info "Checking helm repository..."
    if helm repo list 2>/dev/null | grep -q "upm-packages"; then
        print_success "Helm repository 'upm-packages' already exists"
    else
        print_info "Adding helm repository 'upm-packages'..."
        if helm repo add upm-packages https://upmio.github.io/upm-packages; then
            print_success "Successfully added helm repository 'upm-packages'"
            if helm repo update; then
                print_success "Helm repositories updated successfully"
            else
                print_warning "Failed to update helm repositories, but repo was added"
            fi
        else
            print_error "Failed to add helm repository 'upm-packages'"
            print_error "Please check your network connection and try again"
            exit 1
        fi
    fi
}

# Dependency checks
check_dependencies() {
    print_info "Checking dependencies..."
    local deps=("kubectl" "sed" "helm" "curl" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            print_error "Missing dependency: $dep"
            if [[ "$dep" == "helm" ]]; then
                print_error "Please install Helm first: https://helm.sh/docs/intro/install/"
            fi
            if [[ "$dep" == "curl" ]]; then
                print_error "Please install curl first or ensure it's available in PATH"
            fi
            if [[ "$dep" == "jq" ]]; then
                print_error "Please install jq first: https://stedolan.github.io/jq/"
            fi
            exit 1
        fi
    done

    if ! kubectl cluster-info &>/dev/null; then
        print_error "Unable to connect to Kubernetes cluster"
        exit 1
    fi

    print_success "Basic dependency check passed"

    check_helm_repo
    check_storageclass
    print_success "All dependency checks completed"
}

# IP format validation
validate_ip_address() {
    local ip="$1"
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    IFS='.' read -ra ADDR <<<"$ip"
    for i in "${ADDR[@]}"; do
        if [[ "$i" -lt 0 || "$i" -gt 255 ]]; then
            return 1
        fi
        if [[ "${#i}" -gt 1 && "${i:0:1}" == "0" ]]; then
            return 1
        fi
    done
    return 0
}

get_node_ips() {
    local node_ips
    node_ips=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -v '^$' || echo "")
    if [[ -z "$node_ips" ]]; then
        node_ips=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -v '^$' || echo "")
    fi
    echo "$node_ips"
}

auto_detect_nodeport_ip() {
    print_info "Auto-detecting NodePort IP from Kubernetes cluster..."
    local node_ips_str
    node_ips_str=$(get_node_ips)
    if [[ -n "$node_ips_str" ]]; then
        local first_ip
        first_ip=$(echo "$node_ips_str" | head -n 1)
        if validate_ip_address "$first_ip"; then
            NODEPORT_IP="$first_ip"
            print_success "NodePort IP auto-detected: $NODEPORT_IP"
            return 0
        fi
    fi
    print_warning "Unable to detect valid node IP, using localhost as fallback"
    NODEPORT_IP="127.0.0.1"
    print_info "NodePort IP set to: $NODEPORT_IP"
}

# Selection menu
select_from_list() {
    local title="$1"
    shift
    local options=("$@")
    local allow_custom="false"
    local custom_prompt="Please enter custom value"
    local validation_func=""

    local last_idx=$((${#options[@]} - 1))
    if [[ ${#options[@]} -gt 0 && "${options[$last_idx]}" == "validate_ip_address" ]]; then
        validation_func="${options[$last_idx]}"
        unset options[$last_idx]
        last_idx=$((last_idx - 1))
    fi
    if [[ ${#options[@]} -gt 0 && ( "${options[$last_idx]}" == "true" || "${options[$last_idx]}" == "false" ) ]]; then
        allow_custom="${options[$last_idx]}"
        unset options[$last_idx]
        last_idx=$((last_idx - 1))
    fi
    if [[ "$allow_custom" == "true" && ${#options[@]} -gt 0 ]]; then
        custom_prompt="${options[$last_idx]}"
        unset options[$last_idx]
    fi

    local options_count=${#options[@]}
    if [[ ! -t 0 ]]; then
        print_warning "Non-interactive input detected, using first option as default: ${options[0]}" >&2
        echo "${options[0]}"
        return 0
    fi

    while true; do
        echo >&2
        print_info "$title" >&2
        local i=1
        for option in "${options[@]}"; do
            echo "  $i) $option" >&2
            ((i++))
        done
        if [[ "$allow_custom" == "true" ]]; then
            echo "  $i) Custom input" >&2
        fi
        echo >&2
        local max_choice=$options_count
        if [[ "$allow_custom" == "true" ]]; then
            max_choice=$((options_count + 1))
        fi
        local choice
        if ! read -t 30 -p "Please select (1-$max_choice): " choice; then
            print_warning "Input timeout or EOF detected, using first option as default: ${options[0]}" >&2
            echo "${options[0]}"
            return 0
        fi
        if [[ -z "$choice" ]]; then
            print_warning "Empty input detected, using first option as default: ${options[0]}" >&2
            echo "${options[0]}"
            return 0
        fi
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            print_warning "Please enter a valid numeric option" >&2
            continue
        fi
        if [[ "$choice" -lt 1 || "$choice" -gt "$max_choice" ]]; then
            print_warning "Please enter a number between 1 and $max_choice" >&2
            continue
        fi
        if [[ "$choice" -le "$options_count" ]]; then
            echo "${options[$((choice - 1))]}"
            return 0
        elif [[ "$allow_custom" == "true" ]]; then
            while true; do
                local custom_value
                if ! read -t 30 -p "$custom_prompt: " custom_value; then
                    print_warning "Input timeout or EOF detected, using first option as default: ${options[0]}" >&2
                    echo "${options[0]}"
                    return 0
                fi
                if [[ -z "$custom_value" ]]; then
                    print_warning "Input cannot be empty" >&2
                    continue
                fi
                if [[ -n "$validation_func" ]]; then
                    if $validation_func "$custom_value"; then
                        echo "$custom_value"
                        return 0
                    else
                        print_warning "Input format is incorrect, please re-enter" >&2
                        continue
                    fi
                else
                    echo "$custom_value"
                    return 0
                fi
            done
        fi
    done
}

# Get available MongoDB versions
get_mongodb_versions() {
    local mongodb_versions
    mongodb_versions=$(helm search repo upm-packages | grep -i "mongodb" | awk '{print $3}' | sort -V -r || echo "")
    if [[ -z "$mongodb_versions" ]]; then
        print_error "Unable to get MongoDB version list" >&2
        return 1
    else
        echo "$mongodb_versions"
        return 0
    fi
}

# Validate MongoDB version
validate_mongodb_version() {
    local version="$1"
    if [[ -z "$version" ]]; then
        return 1
    fi
    local available_versions
    if ! available_versions=$(get_mongodb_versions); then
        return 1
    fi
    while IFS= read -r available_version; do
        if [[ "$version" == "$available_version" ]]; then
            return 0
        fi
    done <<< "$available_versions"
    return 1
}

# Install UPM package components for specific MongoDB version
install_upm_packages() {
    local mongodb_version="$1"
    if [[ -z "$mongodb_version" ]]; then
        print_error "MongoDB version parameter is required for UPM package installation"
        exit 1
    fi
    print_info "Installing UPM package components for MongoDB version $mongodb_version..."
    local upm_script="/tmp/upm-pkg-mgm.sh"
    if [[ ! -f "$upm_script" ]]; then
        print_info "UPM package management script not found, downloading..."
        local download_dir="/tmp"
        mkdir -p "$download_dir"
        if curl -sSL https://raw.githubusercontent.com/upmio/upm-packages/main/upm-pkg-mgm.sh -o "$upm_script"; then
            print_success "UPM package management script downloaded successfully"
        else
            print_error "UPM package management script download failed"
            print_error "Please check network connection or manually download script to: $upm_script"
            exit 1
        fi
    fi
    if [[ ! -f "$upm_script" ]]; then
        print_error "UPM package management script still not found: $upm_script"
        exit 1
    fi
    if [[ ! -x "$upm_script" ]]; then
        print_info "Setting upm-pkg-mgm.sh script as executable..."
        chmod +x "$upm_script"
    fi
    print_info "Installing mongodb-community-$mongodb_version package..."
    if "$upm_script" install "mongodb-community-$mongodb_version"; then
        print_success "UPM package components for version $mongodb_version installed successfully"
    else
        print_error "UPM package components installation failed for version $mongodb_version"
        exit 1
    fi
}

# Check if all required parameters are provided
check_required_parameters() {
    local missing_params=()
    if [[ -z "$STORAGE_CLASS" ]]; then
        missing_params+=("StorageClass")
    fi
    if [[ -z "$NAMESPACE" ]]; then
        missing_params+=("Namespace")
    fi
    if [[ -z "$MONGODB_VERSION" ]]; then
        missing_params+=("MongoDB Version")
    fi
    if [[ ${#missing_params[@]} -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}

# Validate provided parameters
validate_parameters() {
    if [[ -n "$STORAGE_CLASS" ]]; then
        if ! kubectl get storageclass "$STORAGE_CLASS" &>/dev/null; then
            print_error "StorageClass does not exist: $STORAGE_CLASS"
            print_info "Available StorageClass list:"
            kubectl get storageclass -o name 2>/dev/null | sed 's/storageclass.storage.k8s.io\///g' | while read -r sc; do
                echo "  - $sc"
            done
            exit 1
        fi
    fi
    if [[ -n "$MONGODB_VERSION" ]]; then
        if ! validate_mongodb_version "$MONGODB_VERSION"; then
            print_error "Invalid MongoDB version specified: $MONGODB_VERSION"
            print_info "Available MongoDB versions:"
            if get_mongodb_versions | while IFS= read -r version; do
                echo "  - $version"
            done; then
                :
            else
                print_warning "Unable to retrieve available MongoDB versions"
            fi
            exit 1
        fi
    fi
    print_success "Parameter validation passed"
}

# Interactive parameter input
get_user_input() {
    if [[ -z "$MONGODB_VERSION" ]]; then
        local mongodb_versions
        if mongodb_versions=$(get_mongodb_versions); then
            if [[ -n "$mongodb_versions" ]]; then
                local mongodb_version_array=()
                while IFS= read -r line; do
                    [[ -n "$line" ]] && mongodb_version_array+=("$line")
                done <<<"$mongodb_versions"
                if [[ ${#mongodb_version_array[@]} -gt 0 ]]; then
                    MONGODB_VERSION=$(select_from_list "Select MongoDB version:" "${mongodb_version_array[@]}" "false")
                else
                    print_error "Unable to get MongoDB version list"
                    exit 1
                fi
            else
                print_error "Unable to get MongoDB version list"
                exit 1
            fi
        else
            print_error "Failed to retrieve MongoDB versions"
            exit 1
        fi
    else
        print_info "MongoDB Version already specified: $MONGODB_VERSION"
        if ! validate_mongodb_version "$MONGODB_VERSION"; then
            print_error "Invalid MongoDB version specified: $MONGODB_VERSION"
            print_info "Available MongoDB versions:"
            if get_mongodb_versions | while IFS= read -r version; do
                echo "  - $version"
            done; then
                :
            else
                print_warning "Unable to retrieve available MongoDB versions"
            fi
            exit 1
        fi
    fi

    print_info "Current parameter configuration:"
    if [[ -n "$STORAGE_CLASS" ]]; then
        print_success "  StorageClass: $STORAGE_CLASS (provided via command line)"
    else
        print_info "  StorageClass: Not specified, will be configured interactively"
    fi
    if [[ -n "$NAMESPACE" ]]; then
        print_success "  Namespace: $NAMESPACE (provided via command line)"
    else
        print_info "  Namespace: Not specified, will be configured interactively"
    fi
    if [[ -n "$MONGODB_VERSION" ]]; then
        print_success "  MongoDB Version: $MONGODB_VERSION (provided via command line)"
    else
        print_info "  MongoDB Version: Not specified, will be configured interactively"
    fi
    print_success "  NodePort IP: $NODEPORT_IP (auto-detected)"
    echo

    local need_interaction=false
    if [[ -z "$STORAGE_CLASS" ]] || [[ -z "$NAMESPACE" ]] || [[ -z "$MONGODB_VERSION" ]]; then
        need_interaction=true
    fi

    if [[ "$need_interaction" == "false" ]]; then
        print_info "All required parameters provided via command line, skipping interactive configuration"
        validate_parameters
        print_success "Parameter configuration completed:"
        print_success "  StorageClass: $STORAGE_CLASS"
        print_success "  Namespace: $NAMESPACE"
        print_success "  NodePort IP: $NODEPORT_IP"
        print_success "  MongoDB Version: $MONGODB_VERSION"
        echo
        return 0
    fi

    print_info "Starting interactive configuration for missing parameters..."

    if [[ -z "$STORAGE_CLASS" ]]; then
        local available_sc
        available_sc=$(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort)
        if [[ -z "$available_sc" ]]; then
            print_error "No available StorageClass found in cluster"
            print_info "Please install StorageClass first, for example:"
            print_info "kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"
            exit 1
        fi
        local sc_array=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && sc_array+=("$line")
        done <<<"$available_sc"
        STORAGE_CLASS=$(select_from_list "Select StorageClass:" "${sc_array[@]}")
    else
        print_info "StorageClass already specified: $STORAGE_CLASS"
    fi

    if [[ -z "$NAMESPACE" ]]; then
        local available_ns
        available_ns=$(kubectl get namespace -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort)
        if [[ -z "$available_ns" ]]; then
            print_error "Unable to get Namespace list"
            exit 1
        fi
        local ns_array=()
        while IFS=' ' read -r -a temp_array; do
            for item in "${temp_array[@]}"; do
                [[ -n "$item" ]] && ns_array+=("$item")
            done
        done <<<"$available_ns"
        NAMESPACE=$(select_from_list "Select Namespace:" "${ns_array[@]}" "Please enter custom Namespace name" "true")
    else
        print_info "Namespace already specified: $NAMESPACE"
    fi

    echo
    print_success "Parameter configuration completed:"
    print_success "  MongoDB Version: $MONGODB_VERSION"
    print_success "  StorageClass: $STORAGE_CLASS"
    print_success "  Namespace: $NAMESPACE"
    print_success "  NodePort IP: $NODEPORT_IP (auto-detected)"
    echo
}

# Validate YAML files
validate_yaml_files() {
    print_info "Validating YAML configuration files..."
    for yaml_file in "${YAML_FILES[@]}"; do
        local file_path="$TEMP_DIR/$yaml_file"
        if [[ -f "$file_path" ]]; then
            print_success "✓ $yaml_file found"
        else
            print_error "✗ $yaml_file not found in $TEMP_DIR"
            return 1
        fi
    done
    print_success "All YAML files validated successfully"
}

# Replace placeholders in YAML files
replace_placeholders() {
    print_info "Replacing placeholders in YAML files..."
    local mongodb_name_suffix
    mongodb_name_suffix=$(generate_random_identifier 5)

    local escaped_namespace escaped_nodeport_ip escaped_storage_class escaped_version
    escaped_namespace=$(escape_sed_replacement "$NAMESPACE")
    escaped_nodeport_ip=$(escape_sed_replacement "$NODEPORT_IP")
    escaped_storage_class=$(escape_sed_replacement "$STORAGE_CLASS")
    escaped_version=$(escape_sed_replacement "$MONGODB_VERSION")
    local escaped_mongodb_suffix
    escaped_mongodb_suffix=$(escape_sed_replacement "$mongodb_name_suffix")

    for yaml_file in "${YAML_FILES[@]}"; do
        local file_path="$TEMP_DIR/$yaml_file"
        if [[ -f "$file_path" ]]; then
            print_info "Processing $yaml_file..."
            sed_inplace "s/<namespace>/$escaped_namespace/g" "$file_path"
            sed_inplace "s/<nodeport-ip>/$escaped_nodeport_ip/g" "$file_path"
            sed_inplace "s/<storageClass-name>/$escaped_storage_class/g" "$file_path"
            sed_inplace "s/<version>/$escaped_version/g" "$file_path"
            sed_inplace "s/<mongodb-name-suffix>/$escaped_mongodb_suffix/g" "$file_path"
            print_success "✓ $yaml_file processed"
        fi
    done

    MONGODB_NAME_SUFFIX="$mongodb_name_suffix"
    print_success "Placeholder replacement completed"
    print_info "MongoDB name suffix: $MONGODB_NAME_SUFFIX"
}

# Apply YAML file
apply_yaml_file() {
    local yaml_file="$1"
    local file_path="$TEMP_DIR/$yaml_file"
    if [[ ! -f "$file_path" ]]; then
        print_error "YAML file not found: $file_path"
        return 1
    fi
    print_info "Applying $yaml_file..."
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "=== DRY RUN: Content of $yaml_file ==="
        cat "$file_path"
        print_info "=== END OF $yaml_file ==="
        return 0
    fi
    if kubectl apply -f "$file_path"; then
        print_success "✓ $yaml_file applied successfully"
        return 0
    else
        print_error "✗ Failed to apply $yaml_file"
        return 1
    fi
}

# Wait for resource to be ready
wait_for_resource() {
    local resource_type="$1"
    local resource_name="$2"
    local namespace="$3"
    local timeout="${4:-300}"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: Would wait for $resource_type/$resource_name to be ready"
        return 0
    fi
    print_info "Waiting for $resource_type/$resource_name to be ready (timeout: ${timeout}s)..."
    local start_time
    start_time=$(date +%s)
    while true; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        if [[ $elapsed -ge $timeout ]]; then
            print_error "Timeout waiting for $resource_type/$resource_name to be ready"
            return 1
        fi
        case "$resource_type" in
            "job")
                local status
                status=$(kubectl get job "$resource_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || echo "")
                if [[ "$status" == "True" ]]; then
                    print_success "Job $resource_name completed successfully"
                    return 0
                fi
                local failed_status
                failed_status=$(kubectl get job "$resource_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
                if [[ "$failed_status" == "True" ]]; then
                    print_error "Job $resource_name failed"
                    return 1
                fi
                ;;
            "unitset")
                if ! kubectl get unitset "$resource_name" -n "$namespace" >/dev/null 2>&1; then
                    print_info "UnitSet $resource_name does not exist yet, waiting..." >&2
                    continue
                fi
                local ready_units total_units
                ready_units=$(kubectl get unitset "$resource_name" -n "$namespace" -o json 2>/dev/null | jq -r '.status.readyUnits // 0')
                total_units=$(kubectl get unitset "$resource_name" -n "$namespace" -o json 2>/dev/null | jq -r '.spec.units // 0')
                if [[ -z "$ready_units" ]]; then
                    ready_units=0
                fi
                if [[ -z "$total_units" ]]; then
                    total_units=0
                fi
                print_info "UnitSet $resource_name status: ready=$ready_units, desired=$total_units" >&2
                if [[ "$ready_units" -gt 0 && "$total_units" -gt 0 && "$ready_units" -eq "$total_units" ]]; then
                    print_success "UnitSet $resource_name is ready"
                    return 0
                fi
                ;;
            "mongodbreplicaset")
                local ready
                ready=$(kubectl get mongodbreplicaset "$resource_name" -n "$namespace" -o jsonpath='{.status.ready}' 2>/dev/null || echo "")
                if [[ "$ready" == "true" ]]; then
                    print_success "MongoDBReplicaSet $resource_name is ready"
                    return 0
                fi
                ;;
            *)
                print_error "Unknown resource type: $resource_type"
                return 1
                ;;
        esac
        print_info "Still waiting... (${elapsed}s elapsed)"
        sleep 10
    done
}

# Deploy individual step with detailed logging
deploy_step() {
    local step_num="$1"
    local step_name="$2"
    local yaml_file="$3"
    local resource_type="$4"
    local resource_name="$5"
    local timeout="$6"
    local show_replacements="${7:-false}"

    print_info "========================================"
    print_info "Step $step_num: $step_name"
    print_info "========================================"

    if [[ "$show_replacements" == "true" ]]; then
        print_info "Placeholder replacement content:"
        print_info "  <namespace> → $NAMESPACE"
        print_info "  <nodeport-ip> → $NODEPORT_IP"
        print_info "  <storageClass-name> → $STORAGE_CLASS"
        print_info "  <version> → $MONGODB_VERSION"
        print_info "  <mongodb-name-suffix> → $MONGODB_NAME_SUFFIX"
    fi

    print_info "Applying $yaml_file..."
    if ! apply_yaml_file "$yaml_file"; then
        print_error "Step $step_num failed: Unable to apply $yaml_file"
        return 1
    fi

    if [[ -n "$resource_type" && -n "$resource_name" ]]; then
        print_info "Waiting for resource to be ready: $resource_type/$resource_name"
        if ! wait_for_resource "$resource_type" "$resource_name" "$NAMESPACE" "$timeout"; then
            print_error "Step $step_num failed: Resource $resource_type/$resource_name not ready"
            return 1
        fi
    fi

    print_success "Step $step_num completed successfully: $step_name"
    echo
}

# Deploy MongoDB ReplicaSet
deploy_mongodb_replicaset() {
    print_info "Starting MongoDB ReplicaSet deployment..."
    print_info "Deployment order: Project → Secret → MongoDB UnitSet → MongoDB ReplicaSet"
    echo

    if ! deploy_step "0" "Create Project" "0-project.yaml" "" "" "" "true"; then
        return 1
    fi

    if ! deploy_step "1" "Generate Secret" "1-gen-secret.yaml" "job" "generate-mongodb-replicaset-secret-job" "120" "true"; then
        return 1
    fi

    if ! deploy_step "2" "Deploy MongoDB UnitSet" "2-mongodb-us.yaml" "unitset" "demo-mongodb-$MONGODB_NAME_SUFFIX" "300" "true"; then
        return 1
    fi

    if ! deploy_step "3" "Create MongoDB ReplicaSet" "3-mongodb-replicaset.yaml" "mongodbreplicaset" "demo-mongodb-$MONGODB_NAME_SUFFIX-replicaset" "180" "true"; then
        return 1
    fi

    print_info "========================================"
    print_success "MongoDB ReplicaSet deployment completed!"
    print_info "========================================"
    print_info "Deployment summary:"
    print_info "  - Namespace: $NAMESPACE"
    print_info "  - MongoDB UnitSet: demo-mongodb-$MONGODB_NAME_SUFFIX"
    print_info "  - Storage class: $STORAGE_CLASS"
    print_info "  - MongoDB version: $MONGODB_VERSION"
    print_info "  - NodePort IP: $NODEPORT_IP"
    echo

    display_connection_info
}

# Display connection information after deployment
display_connection_info() {
    print_info "========================================"
    print_success "Connection Information"
    print_info "========================================"

    print_info "MongoDB ReplicaSet Access Information:"
    echo
    print_info "📋 Database Connection Details:"
    print_info "  • Host: $NODEPORT_IP"
    print_info "  • Username: admin"
    print_info "  • Password: mypassword123"
    echo

    print_info "🔌 Services:"
    print_info "  This deployment does not expose NodePort by default."
    print_info "  Use in-cluster Service or port-forward to access MongoDB."
    echo

    print_info "💻 Port-Forward Examples:"
    print_info "  # Forward local 27017 to one MongoDB pod"
    print_info "  kubectl -n $NAMESPACE port-forward pod/demo-mongodb-$MONGODB_NAME_SUFFIX-0 27017:27017"
    echo

    print_info "📚 Additional Commands:"
    print_info "  # Check cluster status"
    print_info "  kubectl get pods,svc,pvc -n $NAMESPACE -l upm.api/service-group.name=demo"
    echo
    print_info "  # View MongoDB pod logs"
    print_info "  kubectl logs -n $NAMESPACE -l upm.api/service.type=mongodb"
    echo
    print_success "🎉 Your MongoDB ReplicaSet is ready for use!"
    print_info "========================================"
}

# Main function
main() {
    parse_arguments "$@"

    if [[ "$SHOW_HELP" == "true" ]]; then
        show_help
        exit 0
    fi

    check_dependencies
    auto_detect_nodeport_ip
    get_user_input

    if [[ "$DRY_RUN" != "true" ]]; then
        install_upm_packages "$MONGODB_VERSION"
    fi

    prepare_yaml_files
    validate_yaml_files
    replace_placeholders
    deploy_mongodb_replicaset
    print_success "MongoDB ReplicaSet deployment script completed!"
}

# Global variables for generated identifiers
MONGODB_NAME_SUFFIX=""

main "$@"