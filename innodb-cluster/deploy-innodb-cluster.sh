#!/bin/bash

# InnoDB Cluster Automated Deployment Script
# Deploy InnoDB Cluster services after installing core Operator components

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_DIR="${SCRIPT_DIR}/example"
TEMP_DIR="${SCRIPT_DIR}/temp-innodb-cluster"

# Command line arguments
DRY_RUN=false
SHOW_HELP=false

# YAML file deployment order
YAML_FILES=(
	"gen-secret.yaml"
	"mysql-us.yaml"
	"mysql-group-replication.yaml"
	"mysql-router-us.yaml"
)

# Global variables - set via command line arguments, fallback to interactive input
STORAGE_CLASS=""
NAMESPACE=""
MYSQL_VERSION=""

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
	echo -e "${RED}[ERROR]${NC} $1"
}

# Cross-platform in-place sed helper (GNU vs BSD)
sed_inplace() {
	local script="$1"
	local file="$2"
	# Detect OS type for sed compatibility
	if [[ "$(uname)" == "Darwin" ]]; then
		# macOS uses BSD sed
		sed -i "" "$script" "$file"
	else
		# Linux uses GNU sed
		sed -i "$script" "$file"
	fi
}


# Display help information
show_help() {
	cat <<EOF
InnoDB Cluster Automated Deployment Script

Usage:
    $0 [options]

Options:
    --dry-run                        Display generated YAML content without actual deployment
    --help                          Show this help information
    --namespace <namespace>         Specify deployment namespace
    --storage-class <class>         Specify StorageClass
    --mysql-version <version>       Specify MySQL version (MySQL Router version will automatically match MySQL version)

Examples:
    $0                                                    # Interactive deployment mode
    $0 --dry-run                                          # Preview mode, display YAML content
    $0 --namespace cert-manager --storage-class local-path  # Non-interactive mode
    $0 --mysql-version 8.0.41                            # Specify version
    $0 --help                                             # Show help information

Note:
    NodePort IP will be automatically detected from the first available Kubernetes node.

EOF
}

# Parse command line arguments
parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--help | -h)
			SHOW_HELP=true
			shift
			;;
		--namespace)
			if [[ -n "${2:-}" ]]; then
				NAMESPACE="$2"
				shift 2
			else
				print_error "--namespace requires a value"
				exit 1
			fi
			;;
		--storage-class)
			if [[ -n "${2:-}" ]]; then
				STORAGE_CLASS="$2"
				shift 2
			else
				print_error "--storage-class requires a value"
				exit 1
			fi
			;;

		--mysql-version)
			if [[ -n "${2:-}" ]]; then
				MYSQL_VERSION="$2"
				shift 2
			else
				print_error "--mysql-version requires a value"
				exit 1
			fi
			;;
		*)
			print_error "Unknown parameter: $1"
			print_error "Use --help to view help information"
			exit 1
			;;
		esac
	done
}

# Error handling function
cleanup() {
	if [[ -d "$TEMP_DIR" ]]; then
		print_info "Cleaning up temporary files..."
		rm -rf "$TEMP_DIR"
	fi
}

trap cleanup EXIT

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

# Check PodMonitor CRD
check_podmonitor_crd() {
	print_info "Checking Prometheus PodMonitor CRD..."

	if kubectl get crd podmonitors.monitoring.coreos.com &>/dev/null; then
		print_success "Prometheus detected (PodMonitor CRD exists)"
	else
		print_warning "Prometheus not detected (PodMonitor CRD does not exist)"
		print_warning "This may affect monitoring functionality, recommend installing Prometheus Operator"
		print_warning "Installation example:"
		echo "  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
		echo "  helm install prometheus prometheus-community/kube-prometheus-stack"
		echo
	fi
}

# Get available MySQL version list
get_mysql_versions() {
	# Get MySQL related versions from UPM packages
	local mysql_versions
	mysql_versions=$(helm search repo upm-packages | grep "mysql-community-" | awk '{print $3}' | sort -V -r || echo "")

	if [[ -z "$mysql_versions" ]]; then
		# Provide default version based on available packages
		echo "8.0.41"
	else
		echo "$mysql_versions"
	fi
}

# Validate MySQL version
validate_mysql_version() {
	local version="$1"
	
	if [[ -z "$version" ]]; then
		return 1
	fi
	
	# Get available MySQL versions
	local available_versions
	available_versions=$(get_mysql_versions)
	
	# Check if the provided version is in the available versions list
	while IFS= read -r available_version; do
		if [[ "$version" == "$available_version" ]]; then
			return 0
		fi
	done <<< "$available_versions"
	
	return 1
}

# Get available MySQL Router version list

# Check dependencies
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

	# Check kubectl connection
	if ! kubectl cluster-info &>/dev/null; then
		print_error "Unable to connect to Kubernetes cluster"
		exit 1
	fi

	print_success "Basic dependency check passed"

	# Check StorageClass
	check_storageclass

	# Check PodMonitor CRD
	check_podmonitor_crd

	print_success "All dependency checks completed"
}

# Install UPM package components for specific MySQL version
install_upm_packages() {
	local mysql_version="$1"
	
	if [[ -z "$mysql_version" ]]; then
		print_error "MySQL version parameter is required for UPM package installation"
		exit 1
	fi
	
	print_info "Installing UPM package components for MySQL version $mysql_version..."

	local upm_script="${SCRIPT_DIR}/upm-pkg-mgm.sh"

	# If script doesn't exist, try to download
	if [[ ! -f "$upm_script" ]]; then
		print_info "UPM package management script not found, downloading..."
		local download_dir="${SCRIPT_DIR}/.."

		# Ensure download directory exists
		mkdir -p "$download_dir"

		# Download upm-pkg-mgm.sh script
		if curl -sSL https://raw.githubusercontent.com/upmio/upm-packages/main/upm-pkg-mgm.sh -o "$upm_script"; then
			print_success "UPM package management script downloaded successfully"
		else
			print_error "UPM package management script download failed"
			print_error "Please check network connection or manually download script to: $upm_script"
			exit 1
		fi
	fi

	# Check again if script exists
	if [[ ! -f "$upm_script" ]]; then
		print_error "UPM package management script still not found: $upm_script"
		exit 1
	fi

	# Check if script is executable
	if [[ ! -x "$upm_script" ]]; then
		print_info "Setting upm-pkg-mgm.sh script as executable..."
		chmod +x "$upm_script"
	fi

	# Install specific version of mysql and mysql-router packages
	print_info "Installing mysql-community-$mysql_version and mysql-router-community-$mysql_version packages..."
	if "$upm_script" install "mysql-community-$mysql_version" "mysql-router-community-$mysql_version"; then
		print_success "UPM package components for version $mysql_version installed successfully"
	else
		print_error "UPM package components installation failed for version $mysql_version"
		exit 1
	fi
}

# Check YAML files
check_yaml_files() {
	print_info "Checking YAML configuration files..."

	local missing_files=()

	if [[ ! -d "$YAML_DIR" ]]; then
		print_warning "YAML directory not found: $YAML_DIR"
	else
		for yaml_file in "${YAML_FILES[@]}"; do
			if [[ ! -f "$YAML_DIR/$yaml_file" ]]; then
				missing_files+=("$yaml_file")
			fi
		done
	fi

	if [[ ${#missing_files[@]} -gt 0 || ! -d "$YAML_DIR" ]]; then
		print_warning "Local YAML templates missing. They will be downloaded automatically during preparation."
	else
		print_success "Local YAML templates found"
	fi
}

# IP address format validation
validate_ip_address() {
	local ip="$1"

	# Check basic format
	if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		return 1
	fi

	# Check if each number segment is within 0-255 range
	IFS='.' read -ra ADDR <<<"$ip"
	for i in "${ADDR[@]}"; do
		if [[ "$i" -lt 0 || "$i" -gt 255 ]]; then
			return 1
		fi
		# Check for leading zeros (except single 0)
		if [[ "${#i}" -gt 1 && "${i:0:1}" == "0" ]]; then
			return 1
		fi
	done

	return 0
}

# Get cluster node IP addresses
get_node_ips() {
	local node_ips
	node_ips=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -v '^$' || echo "")

	if [[ -z "$node_ips" ]]; then
		# If InternalIP is not available, try to get ExternalIP
		node_ips=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null | tr ' ' '\n' | sort -u | grep -v '^$' || echo "")
	fi

	echo "$node_ips"
}

# Auto-detect and set NodePort IP from first available node
auto_detect_nodeport_ip() {
	print_info "Auto-detecting NodePort IP from Kubernetes cluster..."
	
	local node_ips_str
	node_ips_str=$(get_node_ips)
	
	if [[ -n "$node_ips_str" ]]; then
		# Get the first available IP
		local first_ip
		first_ip=$(echo "$node_ips_str" | head -n 1)
		
		if validate_ip_address "$first_ip"; then
			NODEPORT_IP="$first_ip"
			print_success "NodePort IP auto-detected: $NODEPORT_IP"
			return 0
		fi
	fi
	
	# Fallback to localhost if no valid node IP found
	print_warning "Unable to detect valid node IP, using localhost as fallback"
	NODEPORT_IP="127.0.0.1"
	print_info "NodePort IP set to: $NODEPORT_IP"
}

# Global variable for NodePort IP
NODEPORT_IP=""

# Numeric selection menu
select_from_list() {
	local title="$1"
	shift
	local options=("$@")
	local allow_custom="false"
	local custom_prompt="Please enter custom value"
	local validation_func=""

	# Parse trailing special parameters in strict order:
	# 1) validation function (rightmost), 2) allow_custom flag, 3) custom prompt
	local last_idx=$((${#options[@]} - 1))

	# 1) validation function
	if [[ ${#options[@]} -gt 0 && "${options[$last_idx]}" == "validate_ip_address" ]]; then
		validation_func="${options[$last_idx]}"
		unset options[$last_idx]
		last_idx=$((last_idx - 1))
	fi

	# 2) allow_custom flag (true/false)
	if [[ ${#options[@]} -gt 0 && ( "${options[$last_idx]}" == "true" || "${options[$last_idx]}" == "false" ) ]]; then
		allow_custom="${options[$last_idx]}"
		unset options[$last_idx]
		last_idx=$((last_idx - 1))
	fi

	# 3) custom prompt (only when allow_custom is true)
	if [[ "$allow_custom" == "true" && ${#options[@]} -gt 0 ]]; then
		custom_prompt="${options[$last_idx]}"
		unset options[$last_idx]
	fi

	local options_count=${#options[@]}

	# Check if stdin is a pipe/redirect (non-interactive)
	if [[ ! -t 0 ]]; then
		# Non-interactive mode: return first option as default
		print_warning "Non-interactive input detected, using first option as default: ${options[0]}" >&2
		echo "${options[0]}"
		return 0
	fi

	while true; do
		echo >&2
		print_info "$title" >&2

		# Display option list
		local i=1
		for option in "${options[@]}"; do
			echo "  $i) $option" >&2
			((i++))
		done

		# If custom input is allowed, add custom option
		if [[ "$allow_custom" == "true" ]]; then
			echo "  $i) Custom input" >&2
		fi

		echo >&2
		local max_choice=$options_count
		if [[ "$allow_custom" == "true" ]]; then
			max_choice=$((options_count + 1))
		fi
		
		# Use timeout for read to prevent infinite loops
		local choice
		if ! read -t 30 -p "Please select (1-$max_choice): " choice; then
			print_warning "Input timeout or EOF detected, using first option as default: ${options[0]}" >&2
			echo "${options[0]}"
			return 0
		fi

		# Handle empty input
		if [[ -z "$choice" ]]; then
			print_warning "Empty input detected, using first option as default: ${options[0]}" >&2
			echo "${options[0]}"
			return 0
		fi

		# Validate if input is a number
		if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
			print_warning "Please enter a valid numeric option" >&2
			continue
		fi

		# Check selection range
		if [[ "$choice" -lt 1 || "$choice" -gt "$max_choice" ]]; then
			print_warning "Please enter a number between 1 and $max_choice" >&2
			continue
		fi

		# Process selection
		if [[ "$choice" -le "$options_count" ]]; then
			# Selected an option from the list
			echo "${options[$((choice - 1))]}"
			return 0
		elif [[ "$allow_custom" == "true" ]]; then
			# Selected custom input
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

				# If validation function is provided, validate
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

# Check if all required parameters are provided
check_required_parameters() {
	local missing_params=()

	if [[ -z "$STORAGE_CLASS" ]]; then
		missing_params+=("StorageClass")
	fi

	if [[ -z "$NAMESPACE" ]]; then
		missing_params+=("Namespace")
	fi

	# NodePort IP will be auto-detected, no need to check

	if [[ ${#missing_params[@]} -eq 0 ]]; then
		return 0 # All parameters provided
	else
		return 1 # Some parameters missing
	fi
}

# Validate provided parameters
validate_parameters() {
	# NodePort IP will be auto-detected, no need to validate here

	# In non-interactive mode, validate StorageClass existence
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

	# Namespace validation removed - Project object will automatically create namespace if it doesn't exist

	print_success "Parameter validation passed"
}

# Interactive parameter input
get_user_input() {
	# In dry-run mode, use default values and skip interactive input
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "Dry-run mode: using default values for missing parameters"
		
		# Set default StorageClass if not provided
		if [[ -z "$STORAGE_CLASS" ]]; then
			local available_sc
			available_sc=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
			if [[ -n "$available_sc" ]]; then
				STORAGE_CLASS="$available_sc"
				print_info "Using default StorageClass: $STORAGE_CLASS"
			else
				STORAGE_CLASS="local-path"
				print_info "Using fallback StorageClass: $STORAGE_CLASS"
			fi
		fi
		
		# Set default Namespace if not provided
		if [[ -z "$NAMESPACE" ]]; then
			NAMESPACE="default"
			print_info "Using default Namespace: $NAMESPACE"
		fi
		
		# Set default MySQL version if not provided
		if [[ -z "$MYSQL_VERSION" ]]; then
			MYSQL_VERSION="8.0.41"
			print_info "Using default MySQL Version: $MYSQL_VERSION"
		else
			# In dry-run mode, validate provided MySQL version
			if ! validate_mysql_version "$MYSQL_VERSION"; then
				print_error "Invalid MySQL version specified: $MYSQL_VERSION"
				print_info "Available MySQL versions:"
				get_mysql_versions | while IFS= read -r version; do
					echo "  - $version"
				done
				exit 1
			fi
			print_info "Using specified MySQL Version: $MYSQL_VERSION"
		fi
		
		print_success "Dry-run mode parameter configuration:"
		print_success "  StorageClass: $STORAGE_CLASS"
		print_success "  Namespace: $NAMESPACE"
		print_success "  NodePort IP: $NODEPORT_IP"
		print_success "  MySQL Version: $MYSQL_VERSION"
		print_success "  Router Version: $MYSQL_VERSION (automatically matches MySQL version)"
		echo
		return 0
	fi
	
	# Check if interactive input is needed
	if check_required_parameters; then
		print_info "All required parameters provided via command line, skipping interactive configuration"

		# Set default version if not specified
		if [[ -z "$MYSQL_VERSION" ]]; then
			MYSQL_VERSION="8.0.41"
		fi

		validate_parameters
		print_success "Non-interactive mode parameter configuration:"
		print_success "  StorageClass: $STORAGE_CLASS"
		print_success "  Namespace: $NAMESPACE"
		print_success "  NodePort IP: $NODEPORT_IP"
		print_success "  MySQL Version: $MYSQL_VERSION"
		print_success "  Router Version: $MYSQL_VERSION (automatically matches MySQL version)"
		echo
		return 0
	fi

	print_info "Starting interactive configuration..."

	# Get StorageClass
	local available_sc
	available_sc=$(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort)

	if [[ -z "$available_sc" ]]; then
		print_error "No available StorageClass found in cluster"
		print_info "Please install StorageClass first, for example:"
		print_info "kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml"
		exit 1
	fi

	# Convert StorageClass to array
	local sc_array=()
	while IFS= read -r line; do
		[[ -n "$line" ]] && sc_array+=("$line")
	done <<<"$available_sc"

	STORAGE_CLASS=$(select_from_list "Select StorageClass:" "${sc_array[@]}")

	# Get Namespace
	local available_ns
	available_ns=$(kubectl get namespace -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort)

	if [[ -z "$available_ns" ]]; then
		print_error "Unable to get Namespace list"
		exit 1
	fi

	# Convert Namespace to array and add custom input option
	local ns_array=()
	while IFS=' ' read -r -a temp_array; do
		for item in "${temp_array[@]}"; do
			[[ -n "$item" ]] && ns_array+=("$item")
		done
	done <<<"$available_ns"

	NAMESPACE=$(select_from_list "Select Namespace:" "${ns_array[@]}" "Please enter custom Namespace name" "true")

	# NodePort IP will be auto-detected, no interactive input needed

	# Select MySQL version
	if [[ -z "$MYSQL_VERSION" ]]; then
		local mysql_versions
		mysql_versions=$(get_mysql_versions)
		if [[ -n "$mysql_versions" ]]; then
			local mysql_version_array=()
			while IFS= read -r line; do
				[[ -n "$line" ]] && mysql_version_array+=("$line")
			done <<<"$mysql_versions"

			if [[ ${#mysql_version_array[@]} -gt 0 ]]; then
				MYSQL_VERSION=$(select_from_list "Select MySQL version:" "${mysql_version_array[@]}" "false")
			else
				print_warning "Unable to get MySQL version list, using default version 8.0.41"
				MYSQL_VERSION="8.0.41"
			fi
		else
			print_warning "Unable to get MySQL version list, using default version 8.0.41"
			MYSQL_VERSION="8.0.41"
		fi
	fi

	# MySQL Router version automatically matches MySQL version
	print_info "MySQL Router version will be automatically set to match MySQL version: $MYSQL_VERSION"

	echo
	print_success "Parameter configuration completed:"
	print_success "  StorageClass: $STORAGE_CLASS"
	print_success "  Namespace: $NAMESPACE"
	print_success "  NodePort IP: $NODEPORT_IP (auto-detected)"
	print_success "  MySQL Version: $MYSQL_VERSION"
	print_success "  Router Version: $MYSQL_VERSION (automatically matches MySQL version)"
	echo
}

# Create temporary directory and copy YAML files
prepare_yaml_files() {
	print_info "Preparing YAML configuration files..."

	# Create temporary directory
	mkdir -p "$TEMP_DIR"

	# Copy or download YAML files to temporary directory
	local raw_base="https://raw.githubusercontent.com/upmio/demo/main/innodb-cluster/example"
	for yaml_file in "${YAML_FILES[@]}"; do
		if [[ -f "$YAML_DIR/$yaml_file" ]]; then
			cp "$YAML_DIR/$yaml_file" "$TEMP_DIR/"
			print_info "Using local template: $yaml_file"
		else
			print_info "Downloading template: $yaml_file"
			local url="$raw_base/$yaml_file"
			if curl -fsSL "$url" -o "$TEMP_DIR/$yaml_file"; then
				print_success "$yaml_file downloaded successfully"
			else
				print_error "Failed to download $yaml_file from $url"
				exit 1
			fi
		fi
	done

	print_success "YAML files preparation completed"
}

# Generate random identifier for Kubernetes resource names
# Generates lowercase alphanumeric string (6-8 characters) compliant with Kubernetes naming conventions
generate_random_identifier() {
	local length="${1:-6}"  # Default length is 6
	
	# Ensure length is between 6-8
	if [[ "$length" -lt 6 || "$length" -gt 8 ]]; then
		length=6
	fi
	
	# Generate random string using lowercase letters and numbers
	# Ensure it starts with a letter (Kubernetes requirement)
	local first_char
	first_char=$(printf "%c" $((97 + RANDOM % 26)))  # a-z
	
	local remaining_chars=""
	for ((i=1; i<length; i++)); do
		local char_type=$((RANDOM % 36))
		if [[ $char_type -lt 26 ]]; then
			# Letter (a-z)
			remaining_chars+=$(printf "%c" $((97 + char_type)))
		else
			# Number (0-9)
			remaining_chars+=$(printf "%c" $((48 + char_type - 26)))
		fi
	done
	
	echo "${first_char}${remaining_chars}"
}

# Escape special characters for sed replacement text
escape_sed_replacement() {
	local input="$1"
	# Replace each special character individually to avoid conflicts
	local result="$input"
	# Escape backslashes (must be first)
	result="${result//\\/\\\\}"
	# Escape forward slashes
	result="${result//\//\\/}"
	# Escape ampersands
	result="${result//&/\\&}"
	printf '%s' "$result"
}

# Replace parameters in YAML files
replace_yaml_parameters() {
	print_info "Starting parameter replacement in YAML files..."

	# Generate random identifiers for resource names
	mysql_random_id=$(generate_random_identifier 6)
	router_random_id=$(generate_random_identifier 6)
	
	print_info "Generated random identifiers:"
	print_info "  MySQL UnitSet identifier: $mysql_random_id"
	print_info "  MySQL Router UnitSet identifier: $router_random_id"

	# Escape special characters to avoid sed errors
	local escaped_namespace=$(escape_sed_replacement "$NAMESPACE")
	local escaped_storage_class=$(escape_sed_replacement "$STORAGE_CLASS")
	local escaped_nodeport_ip=$(escape_sed_replacement "$NODEPORT_IP")
	local escaped_mysql_version=$(escape_sed_replacement "$MYSQL_VERSION")
	local escaped_router_version=$(escape_sed_replacement "$MYSQL_VERSION")
	local escaped_mysql_random_id=$(escape_sed_replacement "$mysql_random_id")
	local escaped_router_random_id=$(escape_sed_replacement "$router_random_id")

	# Replace NAMESPACE environment variable value in gen-secret.yaml
	# Use pipe delimiter to avoid conflicts with common characters
	sed_inplace 's|\$default|'"${escaped_namespace}"'|g' "$TEMP_DIR/gen-secret.yaml"

	# Replace parameters in mysql-us.yaml
	sed_inplace 's|namespace: default|namespace: '"${escaped_namespace}"'|g' "$TEMP_DIR/mysql-us.yaml"
	sed_inplace 's|storageClassName: lvm-localpv|storageClassName: '"${escaped_storage_class}"'|g' "$TEMP_DIR/mysql-us.yaml"
	sed_inplace 's|version: [0-9][0-9.]*|version: '"${escaped_mysql_version}"'|g' "$TEMP_DIR/mysql-us.yaml"
	# Replace xxx with random identifier in mysql UnitSet name
	sed_inplace 's|demo-mysql-xxx|demo-mysql-'"${escaped_mysql_random_id}"'|g' "$TEMP_DIR/mysql-us.yaml"

	# Replace namespace and service references in mysql-group-replication.yaml
	sed_inplace 's|namespace: default|namespace: '"${escaped_namespace}"'|g' "$TEMP_DIR/mysql-group-replication.yaml"
	sed_inplace 's|\.default|.'"${escaped_namespace}"'|g' "$TEMP_DIR/mysql-group-replication.yaml"
	# Replace xxx with same random identifier in MysqlGroupReplication name and service references
	sed_inplace 's|demo-mysql-xxx|demo-mysql-'"${escaped_mysql_random_id}"'|g' "$TEMP_DIR/mysql-group-replication.yaml"

	# Replace parameters in mysql-router-us.yaml
	sed_inplace 's|namespace: default|namespace: '"${escaped_namespace}"'|g' "$TEMP_DIR/mysql-router-us.yaml"
	sed_inplace 's|upm.api/nodeport-ip: [0-9][0-9.]*|upm.api/nodeport-ip: '"${escaped_nodeport_ip}"'|g' "$TEMP_DIR/mysql-router-us.yaml"
	sed_inplace 's|version: [0-9][0-9.]*|version: '"${escaped_router_version}"'|g' "$TEMP_DIR/mysql-router-us.yaml"
	# Replace yyy with random identifier in mysql-router UnitSet name
	sed_inplace 's|demo-mysql-router-yyy|demo-mysql-router-'"${escaped_router_random_id}"'|g' "$TEMP_DIR/mysql-router-us.yaml"
	# Replace xxx with mysql random identifier in MYSQL_SERVICE_NAME reference
	sed_inplace 's|demo-mysql-xxx|demo-mysql-'"${escaped_mysql_random_id}"'|g' "$TEMP_DIR/mysql-router-us.yaml"

	print_success "Parameter replacement completed"
	print_success "Resource names with random identifiers:"
	print_success "  MySQL UnitSet: demo-mysql-${mysql_random_id}"
	print_success "  MySQL Router UnitSet: demo-mysql-router-${router_random_id}"
	print_success "  MysqlGroupReplication: demo-mysql-${mysql_random_id}"
}

# Apply YAML file
apply_yaml_file() {
	local yaml_file="$1"
	local file_path="$TEMP_DIR/$yaml_file"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Displaying configuration file content: $yaml_file"
		echo "======================================"
		echo "# File: $yaml_file"
		echo "======================================"
		cat "$file_path"
		echo
		echo "======================================"
		echo "# End of file: $yaml_file"
		echo "======================================"
		echo
	else
		print_info "Applying configuration file: $yaml_file"

		if kubectl apply -f "$file_path"; then
			print_success "$yaml_file applied successfully"
		else
			print_error "$yaml_file application failed"
			return 1
		fi
	fi
}

# Wait for resource to be ready
wait_for_resource() {
	local resource_type="$1"
	local resource_name="$2"
	local namespace="$3"
	local timeout="${4:-300}"

	print_info "Waiting for $resource_type/$resource_name to be ready..."

	# For UnitSet, use custom logic to check readyUnits equals units
	if [[ "$resource_type" == "unitset" ]]; then
		wait_for_unitset "$resource_name" "$namespace" "$timeout"
		return $?
	else
		# For other resource types, use original logic
		if kubectl wait --for=condition=Ready "$resource_type/$resource_name" -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
			print_success "$resource_type/$resource_name is ready"
			return 0
		else
			print_warning "$resource_type/$resource_name wait timeout, continuing to next step"
			return 1
		fi
	fi
}

# Wait for UnitSet readiness (readyUnits equals units)
wait_for_unitset() {
	local unitset_name="$1"
	local namespace="$2"
	local timeout="${3:-300}"

	local start_time=$(date +%s)
	local end_time=$((start_time + timeout))

	while [[ $(date +%s) -lt $end_time ]]; do
		# Get UnitSet status information
		local status_json
		status_json=$(kubectl get unitset "$unitset_name" -n "$namespace" -o jsonpath='{.status}' 2>/dev/null)

		if [[ -n "$status_json" ]]; then
			# Extract units and readyUnits count
			local units
			local ready_units
			units=$(echo "$status_json" | jq -r '.units // 0' 2>/dev/null || echo "0")
			ready_units=$(echo "$status_json" | jq -r '.readyUnits // 0' 2>/dev/null || echo "0")

			# Check if readyUnits equals units and both are greater than 0
			if [[ "$units" -gt 0 && "$ready_units" -eq "$units" ]]; then
				print_success "unitset/$unitset_name is ready (readyUnits: $ready_units/$units)"
				return 0
			fi

			# Show current status
			print_info "unitset/$unitset_name status: readyUnits: $ready_units/$units"
		fi

		sleep 5
	done

	print_warning "unitset/$unitset_name wait timeout, continuing to next step"
	return 1
}

# Wait for MysqlGroupReplication readiness (status.ready equals true)
wait_for_mysql_group_replication() {
	local mgr_name="$1"
	local namespace="$2"
	local timeout="${3:-600}"  # Default 10 minutes timeout
	local check_interval="${4:-8}"  # Default 8 seconds check interval

	print_info "Waiting for MysqlGroupReplication $mgr_name to be ready..."
	print_info "Timeout: ${timeout}s, Check interval: ${check_interval}s"

	local start_time=$(date +%s)
	local end_time=$((start_time + timeout))
	local check_count=0

	while [[ $(date +%s) -lt $end_time ]]; do
		check_count=$((check_count + 1))
		local current_time=$(date +%s)
		local elapsed_time=$((current_time - start_time))

		# Get MysqlGroupReplication status information
		local status_ready
		status_ready=$(kubectl get mysqlgroupreplication "$mgr_name" -n "$namespace" -o jsonpath='{.status.ready}' 2>/dev/null)

		if [[ "$status_ready" == "true" ]]; then
			print_success "MysqlGroupReplication $mgr_name is ready (status.ready: true)"
			print_info "Ready after ${elapsed_time}s (${check_count} checks)"
			return 0
		fi

		# Show current status with progress indicator
		local progress_dots=""
		local dot_count=$((check_count % 4))
		for ((i=0; i<dot_count; i++)); do
			progress_dots+="."
		done

		if [[ -n "$status_ready" ]]; then
			print_info "MysqlGroupReplication $mgr_name status: ready=$status_ready (${elapsed_time}s elapsed)$progress_dots"
		else
			print_info "MysqlGroupReplication $mgr_name status: checking... (${elapsed_time}s elapsed)$progress_dots"
		fi

		# Check if resource exists
		if ! kubectl get mysqlgroupreplication "$mgr_name" -n "$namespace" &>/dev/null; then
			print_error "MysqlGroupReplication $mgr_name not found in namespace $namespace"
			return 1
		fi

		sleep "$check_interval"
	done

	print_warning "MysqlGroupReplication $mgr_name wait timeout after ${timeout}s"
	print_info "Final status check..."
	
	# Final status check and detailed error information
	local final_status
	final_status=$(kubectl get mysqlgroupreplication "$mgr_name" -n "$namespace" -o jsonpath='{.status}' 2>/dev/null)
	if [[ -n "$final_status" ]]; then
		print_info "Final status: $final_status"
	fi
	
	# Show resource description for troubleshooting
	print_info "Resource description for troubleshooting:"
	kubectl describe mysqlgroupreplication "$mgr_name" -n "$namespace" 2>/dev/null || true
	
	return 1
}

# Check Job status
wait_for_job() {
	local job_name="$1"
	local namespace="$2"
	local timeout="${3:-300}"

	print_info "Waiting for Job $job_name to complete..."

	if kubectl wait --for=condition=Complete "job/$job_name" -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
		print_success "Job $job_name executed successfully"
		return 0
	else
		print_warning "Job $job_name execution timeout or failed"
		kubectl describe job "$job_name" -n "$namespace" || true
		return 1
	fi
}

# Deploy InnoDB Cluster
deploy_innodb_cluster() {
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Displaying InnoDB Cluster configuration file content..."
	else
		print_info "Starting InnoDB Cluster deployment..."
	fi
	echo

	# 1. Apply gen-secret.yaml
	apply_yaml_file "gen-secret.yaml"
	if [[ "$DRY_RUN" != "true" ]]; then
		wait_for_job "generate-innodb-cluster-secret-job" "$NAMESPACE" 180
	fi
	echo

	# 2. Apply mysql-us.yaml
	apply_yaml_file "mysql-us.yaml"
	if [[ "$DRY_RUN" != "true" ]]; then
		sleep 10
		wait_for_resource "unitset" "demo-mysql-${mysql_random_id}" "$NAMESPACE" 600
	fi
	echo

	# 3. Apply mysql-group-replication.yaml
	apply_yaml_file "mysql-group-replication.yaml"
	if [[ "$DRY_RUN" != "true" ]]; then
		sleep 5
		# Wait for MysqlGroupReplication to be ready
		wait_for_mysql_group_replication "demo-mysql-${mysql_random_id}-replication" "$NAMESPACE" 600 8
	fi
	echo

	# 4. Apply mysql-router-us.yaml
	apply_yaml_file "mysql-router-us.yaml"
	if [[ "$DRY_RUN" != "true" ]]; then
		sleep 10
		wait_for_resource "unitset" "demo-mysql-router-${router_random_id}" "$NAMESPACE" 300
	fi
	echo

	if [[ "$DRY_RUN" == "true" ]]; then
		print_success "[DRY-RUN] YAML configuration file content display completed!"
	else
		print_success "InnoDB Cluster deployment completed!"
	fi
}

# Show deployment status
show_deployment_status() {
	print_info "Deployment status check..."
	echo

	print_info "UnitSet status:"
	kubectl get unitset -n "$NAMESPACE" -o wide || true
	echo

	print_info "Pod status:"
	kubectl get pods -n "$NAMESPACE" -l "upm.api/service-group.name=demo" || true
	echo

	print_info "Service status:"
	kubectl get svc -n "$NAMESPACE" -l "upm.api/service-group.name=demo" || true
	echo

	print_info "Secret status:"
	kubectl get secret -n "$NAMESPACE" "innodb-cluster-sg-demo-secret" || true
	echo

	# Get NodePort information - use correct selector to find mysql-router service
	local nodeport_svc
	nodeport_svc=$(kubectl get svc -n "$NAMESPACE" -l "unitset.name" --no-headers 2>/dev/null | grep "mysql-router" | grep "NodePort" | awk '{print $1}' | head -1 || echo "")

	if [[ -n "$nodeport_svc" ]]; then
		local nodeport
		nodeport=$(kubectl get svc "$nodeport_svc" -n "$NAMESPACE" -o yaml 2>/dev/null | grep "nodePort:" | head -1 | awk '{print $2}' || echo "")

		if [[ -n "$nodeport" ]]; then
			print_success "InnoDB Cluster access information:"
			echo "  - NodePort IP: $NODEPORT_IP"
			echo "  - NodePort port: $nodeport"
			echo "  - Connection address: $NODEPORT_IP:$nodeport"
		fi
	fi
}

# Show usage information
show_usage_info() {
	# Get NodePort port number - use correct selector to find mysql-router service
	local nodeport_svc
	nodeport_svc=$(kubectl get svc -n "$NAMESPACE" -l "unitset.name" --no-headers 2>/dev/null | grep "mysql-router" | grep "NodePort" | awk '{print $1}' | head -1 || echo "")

	local nodeport="<NodePort Port>"
	if [[ -n "$nodeport_svc" ]]; then
		local actual_nodeport
		actual_nodeport=$(kubectl get svc "$nodeport_svc" -n "$NAMESPACE" -o yaml 2>/dev/null | grep "nodePort:" | head -1 | awk '{print $2}' || echo "")
		if [[ -n "$actual_nodeport" ]]; then
			nodeport="$actual_nodeport"
		fi
	fi

	# Get MySQL password dynamically from gen-secret.yaml
	local mysql_password="mypassword123"  # fallback default
	
	# Try to read password from gen-secret.yaml in current directory first, then example directory
	local gen_secret_file=""
	if [[ -f "gen-secret.yaml" ]]; then
		gen_secret_file="gen-secret.yaml"
	elif [[ -f "example/gen-secret.yaml" ]]; then
		gen_secret_file="example/gen-secret.yaml"
	fi
	
	if [[ -n "$gen_secret_file" ]]; then
		# Extract the first password from SECRET_VALUES line
		local extracted_password
		extracted_password=$(grep -A 1 "SECRET_VALUES" "$gen_secret_file" 2>/dev/null | grep "value:" | sed -n 's/.*value: "\([^,]*\).*/\1/p' || echo "")
		if [[ -n "$extracted_password" ]]; then
			mysql_password="$extracted_password"
		fi
	fi

	echo
	print_info "Usage Instructions:"
	echo "1. Connect to InnoDB Cluster using MySQL client:"
	echo "   mysql -h $NODEPORT_IP -P $nodeport -u radminuser -p"
	echo "   Password: $mysql_password"
	echo
	echo "2. View cluster status:"
	echo "   kubectl get unitset -n $NAMESPACE"
	echo "   kubectl get pods -n $NAMESPACE"
	echo
	echo "3. View logs:"
	echo "   kubectl logs -n $NAMESPACE -l upm.api/service.type=mysql"
	echo "   kubectl logs -n $NAMESPACE -l upm.api/service.type=mysql-router"
	echo
	echo "4. Verify deployment - Use MySQL database verification script for comprehensive check:"
	echo "   The verify-mysql.sh script is an independent MySQL database verification tool designed"
	echo "   to validate MySQL services deployed by deploy-innodb-cluster.sh with DBA-level output"
	echo
	echo "   Download and run verification script:"
	echo "   curl -sSL https://raw.githubusercontent.com/upmio/demo/main/innodb-cluster/verify-mysql.sh -o verify-mysql.sh"
	echo "   chmod +x verify-mysql.sh"
	echo "   ./verify-mysql.sh -h <mysql-host> -P 3306 -u root -p <password> -v"
	echo
	echo "   Example usage with deployed MySQL service:"
	echo "   # Get MySQL service endpoint first:"
	echo "   kubectl get svc -n $NAMESPACE"
	echo "   # Then run verification (replace <service-ip> with actual IP):"
	echo "   ./verify-mysql.sh -h <service-ip> -P 3306 -u root -p <root-password> -v -r report.txt"
	echo
	echo "   Verification script features include:"
	echo "   - MySQL connection and authentication testing"
	echo "   - Comprehensive server information collection (version, storage engines, variables)"
	echo "   - InnoDB Cluster status and configuration verification"
	echo "   - Database CRUD operations testing with transaction support"
	echo "   - Performance benchmarking (connection, query, transaction performance)"
	echo "   - DBA-level technical output with SQL command display"
	echo "   - Detailed verification report generation"
	echo "   - Cluster features testing (read-write separation, consistency)"
	echo
	echo "   Script parameters:"
	echo "   -h, --host HOST        MySQL server host (required)"
	echo "   -P, --port PORT        MySQL server port (default: 3306)"
	echo "   -u, --user USERNAME    MySQL username (default: root)"
	echo "   -p, --password PASS    MySQL password (required)"
	echo "   -d, --database DB      Default database to use (optional)"
	echo "   -v, --verbose          Enable verbose DBA-level output"
	echo "   -r, --report FILE      Generate detailed report to file"
	echo
	echo "   View verification script help:"
	echo "   ./verify-mysql.sh --help"
	echo
}

# Main function
main() {
	# Parse command line arguments
	parse_arguments "$@"

	# Show help information
	if [[ "$SHOW_HELP" == "true" ]]; then
		show_help
		exit 0
	fi

	echo "======================================"
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "    InnoDB Cluster Configuration Preview (DRY-RUN)"
	else
		echo "    InnoDB Cluster Automated Deployment Script"
	fi
	echo "======================================"
	echo

	# Check dependencies and files
	if [[ "$DRY_RUN" != "true" ]]; then
		check_dependencies
	fi
	check_yaml_files

	# Auto-detect NodePort IP
	auto_detect_nodeport_ip

	# Get user input
	get_user_input

	# Install UPM package components after getting user input (only in non-dry-run mode)
	if [[ "$DRY_RUN" != "true" ]]; then
		install_upm_packages "$MYSQL_VERSION"
	fi

	# Skip confirmation for automated deployment

	echo
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "Starting to generate and display YAML configuration..."
	else
		print_info "Starting deployment..."
	fi

	# Prepare and deploy
	prepare_yaml_files
	replace_yaml_parameters
	deploy_innodb_cluster

	# Show status (only in non-dry-run mode)
	if [[ "$DRY_RUN" != "true" ]]; then
		show_deployment_status
		show_usage_info
		print_success "InnoDB Cluster deployment script execution completed!"
	else
		print_success "YAML configuration file preview completed!"
		echo
		print_info "Tip: Remove --dry-run parameter to execute actual deployment"
	fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
