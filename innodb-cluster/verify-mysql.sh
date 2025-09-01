#!/bin/bash

# MySQL InnoDB Cluster Verification Script
# Comprehensive verification of MySQL InnoDB Cluster deployment status from database usage perspective

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
NAMESPACE="default"
CLUSTER_NAME="mysql"
ROOT_PASSWORD=""
VERBOSE=false

# Help information
show_help() {
    cat <<EOF
MySQL InnoDB Cluster Verification Script

Usage: $0 [options]

Options:
    -n, --namespace NAMESPACE    Specify Kubernetes namespace (default: default)
    -c, --cluster-name NAME      Specify cluster name (default: mysql)
    -p, --password PASSWORD      Specify MySQL root password
    -v, --verbose               Enable verbose output mode
    -h, --help                  Show this help information

Examples:
    $0                                    # Verify with default configuration
    $0 -n production -c my-cluster       # Specify namespace and cluster name
    $0 -p mypassword -v                  # Specify password and enable verbose output

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n | --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        -c | --cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -p | --password)
            ROOT_PASSWORD="$2"
            shift 2
            ;;
        -v | --verbose)
            VERBOSE=true
            shift
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $1"
    fi
}

# Check required tools
check_prerequisites() {
    log_info "Checking required tools..."

    local missing_tools=()

    if ! command -v kubectl &>/dev/null; then
        missing_tools+=("kubectl")
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install the missing tools and try again"
        exit 1
    fi

    log_success "All required tools are installed"
}

# Check Kubernetes connection
check_k8s_connection() {
    log_info "Checking Kubernetes cluster connection..."

    if ! kubectl cluster-info &>/dev/null; then
        log_error "Unable to connect to Kubernetes cluster"
        log_error "Please check kubeconfig configuration"
        exit 1
    fi

    log_success "Kubernetes cluster connection is healthy"
}

# Check namespace
check_namespace() {
    log_info "Checking namespace '$NAMESPACE'..."

    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist"
        exit 1
    fi

    log_success "Namespace '$NAMESPACE' exists"
}

# Check UnitSet resources
check_unitset() {
    log_info "Checking UnitSet resources..."

    local unitset_output
    unitset_output=$(kubectl get unitset -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" -o wide 2>/dev/null || true)

    if [[ -z "$unitset_output" ]] || [[ "$unitset_output" == *"No resources found"* ]]; then
        log_error "UnitSet resources not found (label: app.kubernetes.io/name=$CLUSTER_NAME)"
        return 1
    fi

    log_success "Found UnitSet resources:"
    echo "${unitset_output//$'\n'/$'\n'    }"

    log_verbose "UnitSet detailed information:"
    if [[ "$VERBOSE" == "true" ]]; then
        kubectl describe unitset -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" | sed 's/^/    /'
    fi
}

# Check Pod status
check_pods() {
    log_info "Checking MySQL Pod status..."

    local pods_output
    pods_output=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" -o wide 2>/dev/null || true)

    if [[ -z "$pods_output" ]] || [[ "$pods_output" == *"No resources found"* ]]; then
        log_error "MySQL Pods not found (label: app.kubernetes.io/name=$CLUSTER_NAME)"
        return 1
    fi

    log_success "Found MySQL Pods:"
    echo "${pods_output//$'\n'/$'\n'    }"

    # Check if all Pods are running
    local not_running_pods
    not_running_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" --no-headers | grep -v "Running" || true)

    if [[ -n "$not_running_pods" ]]; then
        log_warning "Found Pods not in running state:"
        echo "${not_running_pods//$'\n'/$'\n'    }"
    else
        log_success "All MySQL Pods are in running state"
    fi

    # Check Pod readiness status
    local not_ready_pods
    not_ready_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" --no-headers | awk '$2 !~ /^[0-9]+\/[0-9]+$/ || $2 ~ /0\//' || true)

    if [[ -n "$not_ready_pods" ]]; then
        log_warning "Found Pods not ready:"
        echo "${not_ready_pods//$'\n'/$'\n'    }"
    else
        log_success "All MySQL Pods are ready"
    fi
}

# Check services
check_services() {
    log_info "Checking MySQL services..."

    local services_output
    services_output=$(kubectl get svc -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" -o wide 2>/dev/null || true)

    if [[ -z "$services_output" ]] || [[ "$services_output" == *"No resources found"* ]]; then
        log_warning "MySQL services not found (label: app.kubernetes.io/name=$CLUSTER_NAME)"
        return 1
    fi

    log_success "Found MySQL services:"
    echo "${services_output//$'\n'/$'\n'    }"
}

# Get MySQL root password
get_mysql_password() {
    if [[ -n "$ROOT_PASSWORD" ]]; then
        log_verbose "Using password provided via command line"
        return 0
    fi

    log_info "Attempting to retrieve MySQL root password from Secret..."

    # Try common Secret names
    local secret_names=("${CLUSTER_NAME}-secret" "${CLUSTER_NAME}-root-secret" "mysql-secret" "mysql-root-secret")

    for secret_name in "${secret_names[@]}"; do
        if kubectl get secret "$secret_name" -n "$NAMESPACE" &>/dev/null; then
            ROOT_PASSWORD=$(kubectl get secret "$secret_name" -n "$NAMESPACE" -o jsonpath='{.data.root-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
            if [[ -n "$ROOT_PASSWORD" ]]; then
                log_success "Password retrieved from Secret '$secret_name'"
                return 0
            fi
        fi
    done

    log_warning "Unable to automatically retrieve MySQL root password"
    log_warning "Please specify password manually using -p parameter"
    return 1
}

# Test MySQL connection
test_mysql_connection() {
    log_info "Testing MySQL connection..."

    if [[ -z "$ROOT_PASSWORD" ]]; then
        log_warning "Skipping connection test - no password provided"
        return 1
    fi

    # Get the first MySQL Pod
    local mysql_pod
    mysql_pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" --no-headers | head -1 | awk '{print $1}')

    if [[ -z "$mysql_pod" ]]; then
        log_error "MySQL Pod not found"
        return 1
    fi

    log_verbose "Using Pod: $mysql_pod"

    # Test connection
    if kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -uroot -p"$ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
        log_success "MySQL connection test successful"
        return 0
    else
        log_error "MySQL connection test failed"
        return 1
    fi
}

# Check InnoDB Cluster status
check_cluster_status() {
    log_info "Checking InnoDB Cluster status..."

    if [[ -z "$ROOT_PASSWORD" ]]; then
        log_warning "Skipping cluster status check - no password provided"
        return 1
    fi

    # Get the first MySQL Pod
    local mysql_pod
    mysql_pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" --no-headers | head -1 | awk '{print $1}')

    if [[ -z "$mysql_pod" ]]; then
        log_error "MySQL Pod not found"
        return 1
    fi

    log_verbose "Using Pod: $mysql_pod"

    # Check cluster members
    log_info "Checking cluster members..."
    local cluster_members
    cluster_members=$(kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -uroot -p"$ROOT_PASSWORD" -e "SELECT MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;" 2>/dev/null || true)

    if [[ -n "$cluster_members" ]]; then
        log_success "InnoDB Cluster member status:"
        echo "${cluster_members//$'\n'/$'\n'    }"
    else
        log_warning "Unable to retrieve cluster member information"
    fi

    # Check cluster status
    log_info "Checking overall cluster status..."
    local cluster_status
    cluster_status=$(kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -uroot -p"$ROOT_PASSWORD" -e "SELECT * FROM performance_schema.replication_group_member_stats;" 2>/dev/null || true)

    if [[ -n "$cluster_status" ]]; then
        log_success "Cluster statistics:"
        echo "${cluster_status//$'\n'/$'\n'    }"
    else
        log_warning "Unable to retrieve cluster statistics"
    fi
}

# Test database read/write operations
test_database_operations() {
    log_info "Testing database read/write operations..."

    if [[ -z "$ROOT_PASSWORD" ]]; then
        log_warning "Skipping database read/write test - no password provided"
        return 1
    fi

    # Get the first MySQL Pod
    local mysql_pod
    mysql_pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" --no-headers | head -1 | awk '{print $1}')

    if [[ -z "$mysql_pod" ]]; then
        log_error "MySQL Pod not found"
        return 1
    fi

    log_verbose "Using Pod: $mysql_pod"

    local test_db
    test_db="test_verification_$(date +%s)"
    local test_table="test_table"

    # Create test database
    log_info "Creating test database '$test_db'..."
    if kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -uroot -p"$ROOT_PASSWORD" -e "CREATE DATABASE $test_db;" &>/dev/null; then
        log_success "Test database created successfully"
    else
        log_error "Test database creation failed"
        return 1
    fi

    # Create test table and insert data
    log_info "Testing data write operations..."
    local write_sql="
        USE $test_db;
        CREATE TABLE $test_table (id INT PRIMARY KEY, name VARCHAR(50), created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);
        INSERT INTO $test_table (id, name) VALUES (1, 'test_record_1'), (2, 'test_record_2'), (3, 'test_record_3');
    "

    if kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -uroot -p"$ROOT_PASSWORD" -e "$write_sql" &>/dev/null; then
        log_success "Data write test successful"
    else
        log_error "Data write test failed"
        kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -uroot -p"$ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS $test_db;" &>/dev/null || true
        return 1
    fi

    # Test data read operations
    log_info "Testing data read operations..."
    local read_result
    read_result=$(kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -uroot -p"$ROOT_PASSWORD" -e "USE $test_db; SELECT COUNT(*) as record_count FROM $test_table;" 2>/dev/null || true)

    if [[ "$read_result" == *"3"* ]]; then
        log_success "Data read test successful - found 3 records"
    else
        log_error "Data read test failed"
        kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -uroot -p"$ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS $test_db;" &>/dev/null || true
        return 1
    fi

    # Clean up test data
    log_info "Cleaning up test data..."
    if kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -uroot -p"$ROOT_PASSWORD" -e "DROP DATABASE $test_db;" &>/dev/null; then
        log_success "Test data cleanup completed"
    else
        log_warning "Test data cleanup failed, please manually clean up database '$test_db'"
    fi
}

# Check storage status
check_storage() {
    log_info "Checking storage status..."

    # Check PVC status
    log_info "Checking PVC status..."
    local pvcs
    pvcs=$(kubectl get pvc -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" --no-headers 2>/dev/null || true)

    if [[ -z "$pvcs" ]]; then
        log_warning "No related PVCs found"
        return 1
    fi

    local pvc_count=0
    local bound_count=0

    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            pvc_count=$((pvc_count + 1))
            local status
            local pvc_name
            status=$(echo "$line" | awk '{print $2}')
            pvc_name=$(echo "$line" | awk '{print $1}')

            if [[ "$status" == "Bound" ]]; then
                bound_count=$((bound_count + 1))
                log_success "PVC $pvc_name: $status"
            else
                log_error "PVC $pvc_name: $status"
            fi
        fi
    done <<<"$pvcs"

    log_info "PVC statistics: $bound_count/$pvc_count bound"
}

# Performance benchmark testing
performance_benchmark() {
    log_info "Executing performance benchmark tests..."

    if [[ -z "$ROOT_PASSWORD" ]]; then
        log_warning "Skipping performance test - no password provided"
        return 1
    fi

    # Get the first MySQL Pod
    local mysql_pod
    mysql_pod=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name="$CLUSTER_NAME" --no-headers | head -1 | awk '{print $1}')

    if [[ -z "$mysql_pod" ]]; then
        log_error "MySQL Pod not found"
        return 1
    fi

    log_verbose "Using Pod: $mysql_pod"

    # Simple connection performance test
    log_info "Testing connection performance..."
    local start_time
    start_time=$(date +%s%N)

    for i in {1..5}; do
        if ! kubectl exec -n "$NAMESPACE" "$mysql_pod" -- mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
            log_error "Connection test failed (attempt $i)"
            return 1
        fi
    done

    local end_time
    end_time=$(date +%s%N)
    local duration=$(((end_time - start_time) / 1000000))

    log_success "Connection performance test completed - 5 connections took: ${duration}ms (average: $((duration / 5))ms)"
}

# Generate verification report
generate_report() {
    log_info "Generating verification report..."

    local report_file
    report_file="mysql-verification-report-$(date +%Y%m%d-%H%M%S).txt"

    {
        echo "MySQL InnoDB Cluster Verification Report"
        echo "======================================="
        echo "Generated at: $(date)"
        echo "Cluster name: $CLUSTER_NAME"
        echo "Namespace: $NAMESPACE"
        echo ""

        echo "Verification items:"
        echo "- Prerequisites check: ${CHECK_PREREQUISITES:-Not executed}"
        echo "- Kubernetes connection: ${CHECK_K8S:-Not executed}"
        echo "- Namespace check: ${CHECK_NAMESPACE:-Not executed}"
        echo "- UnitSet check: ${CHECK_UNITSET:-Not executed}"
        echo "- Pod status check: ${CHECK_PODS:-Not executed}"
        echo "- Service check: ${CHECK_SERVICES:-Not executed}"
        echo "- MySQL connection test: ${CHECK_CONNECTION:-Not executed}"
        echo "- Cluster status check: ${CHECK_CLUSTER:-Not executed}"
        echo "- Database operations test: ${CHECK_DATABASE:-Not executed}"
        echo "- Storage check: ${CHECK_STORAGE:-Not executed}"
        echo "- Performance test: ${CHECK_PERFORMANCE:-Not executed}"
        echo ""

        echo "For detailed information, please refer to the log output above."
    } >"$report_file"

    log_success "Verification report generated: $report_file"
}

# Main function
main() {
    echo "==========================================="
    echo "    MySQL InnoDB Cluster Verification Script"
    echo "==========================================="
    echo

    # Execute various checks
    check_prerequisites
    check_k8s_connection
    check_namespace

    echo
    log_info "Starting MySQL InnoDB Cluster verification..."
    echo

    # Kubernetes resource checks
    check_unitset || true
    check_pods || true
    check_services || true
    check_storage || true

    echo

    # MySQL functionality checks
    get_mysql_password || true
    test_mysql_connection || true
    check_cluster_status || true
    test_database_operations || true

    if [[ "$VERBOSE" == "true" ]]; then
        echo
        performance_benchmark || true
    fi

    echo

    # Generate report
    generate_report
}

# Execute main function
main "$@"
