#!/bin/bash

# UPM (Unified Platform Management) Operator Installation Script
# Used to install unit-operator and compose-operator in Kubernetes cluster
# Author: UPM Team
# Version: 1.0.0

# Set strict mode
set -euo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/install-operator.log"
TARGET_NODE="${1:-}"

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 日志文件
LOG_FILE="install-operator-$(date +%Y%m%d-%H%M%S).log"

# Logging functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

print_separator() {
    echo -e "${CYAN}================================================${NC}" | tee -a "$LOG_FILE"
}

# Error handling function
handle_error() {
    local exit_code=$?
    print_error "Script execution failed with exit code: $exit_code"
    print_error "Check detailed logs at: $LOG_FILE"
    exit $exit_code
}

# Set error handling
trap handle_error ERR

# Check if command exists
check_command() {
    if ! command -v "$1" &>/dev/null; then
        print_error "Command '$1' not found, please install it first"
        return 1
    fi
    return 0
}

# Confirmation function
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    while true; do
        if [[ "$default" == "y" ]]; then
            read -r -p "$prompt [Y/n]: " response
            response=${response:-y}
        else
            read -r -p "$prompt [y/N]: " response
            response=${response:-n}
        fi

        case "$response" in
            [Yy] | [Yy][Ee][Ss]) return 0 ;;
            [Nn] | [Nn][Oo]) return 1 ;;
            *) echo "Please enter y/yes or n/no" ;;
        esac
    done
}

# Precheck function
precheck() {
    print_separator
    print_info "Starting installation precheck..."

    # Check required commands
    print_info "Checking required command tools..."
    check_command "kubectl" || exit 1
    check_command "helm" || exit 1
    check_command "curl" || exit 1
    print_success "All required command tools check passed"

    # Check kubectl connection
    print_info "Checking kubectl cluster connection..."
    if ! kubectl cluster-info &>/dev/null; then
        print_error "Cannot connect to Kubernetes cluster, please check kubectl configuration"
        exit 1
    fi

    local cluster_info
    cluster_info=$(kubectl cluster-info | head -1)
    print_success "kubectl cluster connection is healthy"
    print_info "Current cluster info: $cluster_info"

    # Check cert-manager dependency
    print_info "Checking cert-manager dependency..."

    # Use kubectl wait to verify cert-manager components readiness
    if ! kubectl wait --for=condition=available --timeout=300s deployment cert-manager cert-manager-cainjector cert-manager-webhook -n cert-manager 2>/dev/null; then
        print_error "cert-manager is not installed or components are not ready, this is a required dependency for UPM operator"
        print_error "Please install cert-manager first, then re-run this script"
        print_separator
        print_info "cert-manager installation methods:"
        print_info "Method 1 - Using kubectl (recommended):"
        print_info "  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml"
        print_info "Method 2 - Using helm:"
        print_info "  helm repo add jetstack https://charts.jetstack.io"
        print_info "  helm repo update"
        print_info "  helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true"
        print_separator
        print_info "After installation, please wait for all cert-manager components to be ready, then re-run this script"
        print_info "Check installation status: kubectl get pods -n cert-manager"
        exit 1
    fi

    print_success "cert-manager dependency check passed"

    if ! confirm "Confirm to install unit-operator and compose-operator on this cluster?"; then
        print_info "User cancelled installation"
        exit 0
    fi

    # Get node list
    print_info "Getting cluster node list..."
    local nodes
    nodes=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name")
    if [[ -z "$nodes" ]]; then
        print_error "No available nodes found"
        exit 1
    fi

    # Convert node list to array
    local nodes_array=()
    while IFS= read -r node; do
        nodes_array+=("$node")
    done <<<"$nodes"

    print_info "Available node list:"
    for i in "${!nodes_array[@]}"; do
        echo "$((i + 1)). ${nodes_array[i]}"
    done

    # Select target node
    while true; do
        read -r -p "Please enter node number (for labeling upm.operator=true): " node_choice
        if [[ -z "$node_choice" ]]; then
            print_warning "Node number cannot be empty"
            continue
        fi

        # Validate input is a number
        if ! [[ "$node_choice" =~ ^[0-9]+$ ]]; then
            print_warning "Please enter a valid number"
            continue
        fi

        # Validate number is in valid range
        if [[ "$node_choice" -lt 1 || "$node_choice" -gt "${#nodes_array[@]}" ]]; then
            print_warning "Number out of range, please enter a number between 1-${#nodes_array[@]}"
            continue
        fi

        # Get corresponding node name
        TARGET_NODE="${nodes_array[$((node_choice - 1))]}"
        break
    done

    print_success "Selected target node: $TARGET_NODE"

    # Final confirmation
    print_separator
    print_info "Installation configuration confirmation:"
    print_info "Target cluster: $cluster_info"
    print_info "Target node: $TARGET_NODE"
    print_separator

    if ! confirm "Confirm to start unit-operator and compose-operator installation?" "y"; then
        print_info "User cancelled installation"
        exit 0
    fi
}

# Label node function
label_node() {
    print_separator
    print_info "Adding label to node '$TARGET_NODE'..."

    # Check if node already has the label
    local existing_label
    existing_label=$(kubectl get node "$TARGET_NODE" --show-labels | grep "upm.operator=true" || true)

    if [[ -n "$existing_label" ]]; then
        print_success "Node '$TARGET_NODE' already has upm.operator=true label"
        return 0
    fi

    # Add label
    if kubectl label node "$TARGET_NODE" upm.operator=true; then
        print_success "Node '$TARGET_NODE' label added successfully"
    else
        print_error "Failed to add label to node '$TARGET_NODE'"
        return 1
    fi

    # Verify label
    print_info "Verifying node label..."
    if kubectl get node "$TARGET_NODE" --show-labels | grep -q "upm.operator=true"; then
        print_success "Node label verification successful"
    else
        print_error "Node label verification failed"
        return 1
    fi
}

# Check Operator health status
check_operator_health() {
    local operator_name="$1"
    local timeout_seconds="${2:-300}" # Default 5 minutes timeout
    local namespace="upm-system"

    print_info "Checking $operator_name health status..."

    # Check if deployment exists
    if ! kubectl get deployment -l "app.kubernetes.io/name=$operator_name" -n "$namespace" &>/dev/null; then
        print_error "$operator_name deployment not found"
        return 1
    fi

    # Wait for deployment to be available
    print_info "Waiting for $operator_name deployment to be ready (timeout: ${timeout_seconds}s)..."
    if kubectl wait --for=condition=available --timeout="${timeout_seconds}s" deployment -l "app.kubernetes.io/name=$operator_name" -n "$namespace"; then
        print_success "$operator_name deployment is ready"
    else
        print_error "$operator_name deployment timeout"
        return 1
    fi

    # Check pod status
    print_info "Checking $operator_name pod status..."
    local pod_name
    pod_name=$(kubectl get pods -l "app.kubernetes.io/name=$operator_name" -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$pod_name" ]]; then
        print_error "$operator_name pod not found"
        return 1
    fi

    # Wait for pod to run
    local max_attempts=60 # Max wait 5 minutes (60 * 5 seconds)
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        local pod_status
        pod_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)

        case "$pod_status" in
            "Running")
                # Check if container is ready
                local ready_status
                ready_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
                if [[ "$ready_status" == "True" ]]; then
                    print_success "$operator_name pod ($pod_name) is running normally"

                    # Show pod details
                    print_info "Pod details:"
                    kubectl get pod "$pod_name" -n "$namespace" -o wide | tee -a "$LOG_FILE"
                    return 0
                else
                    print_info "$operator_name pod is starting... (attempt $attempt/$max_attempts)"
                fi
                ;;
            "Pending")
                print_info "$operator_name pod is pending... (attempt $attempt/$max_attempts)"
                ;;
            "Failed" | "CrashLoopBackOff")
                print_error "$operator_name pod failed to start, status: $pod_status"
                print_info "Pod details:"
                kubectl describe pod "$pod_name" -n "$namespace" | tee -a "$LOG_FILE"
                return 1
                ;;
            *)
                print_info "$operator_name pod status: $pod_status (attempt $attempt/$max_attempts)"
                ;;
        esac

        sleep 5
        ((attempt++))
    done

    print_error "$operator_name pod health check timeout"
    print_info "Current pod status:"
    kubectl get pod "$pod_name" -n "$namespace" -o wide | tee -a "$LOG_FILE"
    kubectl describe pod "$pod_name" -n "$namespace" | tee -a "$LOG_FILE"
    return 1
}

# Install unit-operator
install_unit_operator() {
    print_separator
    print_info "Step 2/3: Installing unit-operator..."

    # Check if Helm release already exists
    print_info "Checking if unit-operator is already installed..."
    local release_status
    release_status=$(helm list -n upm-system -f "^unit-operator$" -o json 2>/dev/null | jq -r '.[0].status // "not_found"' 2>/dev/null || echo "not_found")

    if [[ "$release_status" == "deployed" ]]; then
        print_success "unit-operator already installed, skipping installation step"
    else
        if [[ "$release_status" != "not_found" ]]; then
            print_warning "unit-operator exists but status is abnormal: $release_status, will reinstall"
            # If status is abnormal, uninstall first
            helm uninstall unit-operator -n upm-system 2>/dev/null || true
        fi

        print_info "Adding unit-operator Helm repository..."
        if helm repo add unit-operator https://upmio.github.io/unit-operator; then
            print_success "unit-operator repository added successfully"
        else
            print_error "Failed to add unit-operator repository"
            return 1
        fi

        print_info "Updating unit-operator Helm repository..."
        if helm repo update unit-operator; then
            print_success "unit-operator repository updated successfully"
        else
            print_error "Failed to update unit-operator repository"
            return 1
        fi

        print_info "Installing unit-operator..."
        if helm install unit-operator unit-operator/unit-operator \
            --namespace upm-system \
            --create-namespace \
            --set-string nodeAffinityPreset.type="hard" \
            --set-string nodeAffinityPreset.key="upm\\.operator" \
            --set-string nodeAffinityPreset.values='{true}'; then
            print_success "unit-operator installed successfully"
        else
            print_error "Failed to install unit-operator"
            return 1
        fi
    fi

    # Execute health check
    if ! check_operator_health "unit-operator" 300; then
        print_error "unit-operator health check failed, installation may have issues"
        return 1
    fi
}

# Install compose-operator
install_compose_operator() {
    print_separator
    print_info "Step 3/3: Installing compose-operator..."

    # Check if Helm release already exists
    print_info "Checking if compose-operator is already installed..."
    local release_status
    release_status=$(helm list -n upm-system -f "^compose-operator$" -o json 2>/dev/null | jq -r '.[0].status // "not_found"' 2>/dev/null || echo "not_found")

    if [[ "$release_status" == "deployed" ]]; then
        print_success "compose-operator already installed, skipping installation step"
    else
        if [[ "$release_status" != "not_found" ]]; then
            print_warning "compose-operator exists but status is abnormal: $release_status, will reinstall"
            # If status is abnormal, uninstall first
            helm uninstall compose-operator -n upm-system 2>/dev/null || true
        fi

        print_info "Adding compose-operator Helm repository..."
        if helm repo add compose-operator https://upmio.github.io/compose-operator; then
            print_success "compose-operator repository added successfully"
        else
            print_error "Failed to add compose-operator repository"
            return 1
        fi

        print_info "Updating compose-operator Helm repository..."
        if helm repo update compose-operator; then
            print_success "compose-operator repository updated successfully"
        else
            print_error "Failed to update compose-operator repository"
            return 1
        fi

        print_info "Installing compose-operator..."
        if helm install compose-operator compose-operator/compose-operator \
            --namespace upm-system \
            --create-namespace \
            --set-string nodeAffinityPreset.type="hard" \
            --set-string nodeAffinityPreset.key="upm\\.operator" \
            --set-string nodeAffinityPreset.values='{true}'; then
            print_success "compose-operator installed successfully"
        else
            print_error "Failed to install compose-operator"
            return 1
        fi
    fi

    # Execute health check
    if ! check_operator_health "compose-operator" 300; then
        print_error "compose-operator health check failed, installation may have issues"
        return 1
    fi
}

# Verify installation results
verify_installation() {
    print_separator
    print_info "Verifying installation results..."

    # Check namespace
    print_info "Checking upm-system namespace..."
    if kubectl get namespace upm-system &>/dev/null; then
        print_success "upm-system namespace exists"
    else
        print_error "upm-system namespace does not exist"
    fi

    # Check Helm releases
    print_info "Checking Helm deployment status..."
    local helm_releases
    helm_releases=$(helm list -n upm-system --short 2>/dev/null || true)
    if echo "$helm_releases" | grep -q "unit-operator"; then
        print_success "unit-operator Helm release deployed"
    else
        print_warning "unit-operator Helm release not found"
    fi

    if echo "$helm_releases" | grep -q "compose-operator"; then
        print_success "compose-operator Helm release deployed"
    else
        print_warning "compose-operator Helm release not found"
    fi

    # Check Pod status
    print_info "Checking Pod running status..."
    local pods
    pods=$(kubectl get pods -n upm-system --no-headers 2>/dev/null || true)
    if [[ -n "$pods" ]]; then
        print_info "Pods in upm-system namespace:"
        kubectl get pods -n upm-system | tee -a "$LOG_FILE"
    else
        print_warning "No Pods found in upm-system namespace"
    fi

    # Check node labels
    print_info "Verifying node labels..."
    local node_labels
    node_labels=$(kubectl get node "$TARGET_NODE" --show-labels | grep "upm.operator=true" || true)
    if [[ -n "$node_labels" ]]; then
        print_success "Node '$TARGET_NODE' label verification passed"
    else
        print_warning "Node '$TARGET_NODE' label verification failed"
    fi
}

# Show installation summary
show_summary() {
    print_separator
    print_success "UPM installation completed!"
    print_separator

    print_info "Installation summary:"
    print_info "• Target node: $TARGET_NODE (labeled with upm.operator=true)"
    print_info "• unit-operator: Installed in upm-system namespace"
    print_info "• compose-operator: Installed in upm-system namespace"
    print_info "• Installation log: $LOG_FILE"

    print_separator
    print_info "Next steps:"
    print_info "1. Check all component status: kubectl get all -n upm-system"
    print_info "2. Install upm-packages: Refer to README documentation"
    print_info "3. Start deploying services: Refer to UPM documentation for service deployment"
    print_separator
}

# Post-installation environment checks
post_install_checks() {
    print_separator
    print_info "Performing post-installation environment checks..."

    local checks_passed=true

    # Check StorageClass
    print_info "Checking StorageClass availability..."
    local storage_classes
    storage_classes=$(kubectl get storageclass --no-headers 2>/dev/null | wc -l)

    if [[ "$storage_classes" -eq 0 ]]; then
        print_error "No available StorageClass found!"
        print_error "UPM requires StorageClass to create persistent storage volumes"
        print_info "Solutions:"
        print_info "1. If using cloud providers, ensure corresponding CSI drivers are installed"
        print_info "2. For local environments, install local-path-provisioner:"
        print_info "   kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml"
        print_info "3. Or install NFS provisioner and other storage solutions"
        checks_passed=false
    else
        print_success "Found $storage_classes available StorageClass(es)"
        print_info "Available StorageClass list:"
        kubectl get storageclass | tee -a "$LOG_FILE"
    fi

    # Check Prometheus (via PodMonitor CRD)
    print_info "Checking Prometheus installation status..."
    if kubectl get crd podmonitors.monitoring.coreos.com &>/dev/null; then
        print_success "Prometheus is installed (PodMonitor CRD detected)"

        # Get prometheus related information
        local prometheus_namespaces
        prometheus_namespaces=$(kubectl get pods --all-namespaces -l "app.kubernetes.io/name=prometheus" --no-headers 2>/dev/null | awk '{print $1}' | sort -u)

        if [[ -n "$prometheus_namespaces" ]]; then
            print_info "Prometheus is running in the following namespaces:"
            echo "$prometheus_namespaces" | while read -r ns; do
                print_info "  • $ns"
            done
        fi
    else
        print_error "Prometheus installation not detected!"
        print_error "UPM recommends installing Prometheus for application monitoring"
        print_info "Solutions:"
        print_info "1. Use kube-prometheus-stack to install complete monitoring stack:"
        print_info "   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
        print_info "   helm repo update"
        print_info "   helm install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace"
        print_info "2. Or use Prometheus Operator:"
        print_info "   kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/bundle.yaml"
        checks_passed=false
    fi

    print_separator

    if [[ "$checks_passed" == "true" ]]; then
        print_success "All post-installation checks passed! Environment is ready"
        print_separator
        print_info "You can now:"
        print_info "1. Deploy UPM application packages: Use kubectl apply to deploy your application configurations"
        print_info "2. Access Prometheus monitoring: Check application status and performance metrics"
        print_info "3. Use persistent storage: Applications can create and use PVCs normally"
        print_separator
    else
        print_warning "Some checks failed, recommend resolving the above issues before application deployment"
        print_info "You can still continue using UPM, but may encounter storage or monitoring related issues"
        print_separator
    fi
}

# Main function
main() {
    print_separator
    print_info "UPM (Universal Package Manager) Installation Script"
    print_info "Version: 1.0.0"
    print_info "Description: Install UPM operators in Kubernetes cluster"
    print_separator

    # Pre-checks
    precheck "$@"

    # Label target node
    label_node "$TARGET_NODE"

    # Install operators
    install_unit_operator
    install_compose_operator

    # Verify installation
    verify_installation

    # Post-installation environment checks
    post_install_checks

    # Show summary
    show_summary

    print_success "Installation completed! Please review the above information to confirm all components are running properly."
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
