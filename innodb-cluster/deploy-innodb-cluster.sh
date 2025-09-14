#!/bin/bash

# Deploy InnoDB Cluster Script
# This script deploys a MySQL InnoDB Cluster with Group Replication and MySQL Router
# Based on UPM (Unified Platform Management) architecture

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
MYSQL_VERSION=""
NODEPORT_IP=""

# YAML template files list
YAML_FILES=(
	"0-project.yaml"
	"1-gen-secret.yaml"
	"2-mysql-us.yaml"
	"3-mysql-group-replication.yaml"
	"4-mysql-router-us.yaml"
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
		# macOS
		sed -i '' "$@"
	else
		# Linux
		sed -i "$@"
	fi
}

# Help information
show_help() {
	cat << EOF
Deploy InnoDB Cluster Script

This script deploys a MySQL InnoDB Cluster with Group Replication and MySQL Router using UPM.

Usage: $0 [OPTIONS]

Options:
  -s, --storage-class STORAGE_CLASS    Kubernetes StorageClass name
  -n, --namespace NAMESPACE            Kubernetes namespace
  -v, --mysql-version VERSION          MySQL version to deploy
  -i, --nodeport-ip IP                 NodePort IP address (auto-detected if not specified)
  -d, --dry-run                        Show what would be deployed without actually deploying
  -h, --help                           Show this help message

Examples:
  # Interactive deployment (recommended)
  $0

  # Non-interactive deployment with all parameters
  $0 -s local-path -n demo -v 8.0.41 -i 192.168.1.100

  # Dry run to see what would be deployed
  $0 -s local-path -n demo -v 8.0.41 --dry-run

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
			-v|--mysql-version)
				MYSQL_VERSION="$2"
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

# Create embedded YAML files
download_yaml_templates() {
	local temp_dir="$1"
	mkdir -p "$temp_dir"

	# Base URL for YAML templates - can be configured via environment variable
	local base_url="${YAML_TEMPLATES_BASE_URL:-https://raw.githubusercontent.com/upmio/demo/refs/heads/main/innodb-cluster/templates}"

	# List of YAML template files to download
	local yaml_files=(
		"0-project.yaml"
		"1-gen-secret.yaml"
		"2-mysql-us.yaml"
		"3-mysql-group-replication.yaml"
		"4-mysql-router-us.yaml"
	)

	print_info "Downloading YAML templates from remote repository..."

	# Download each YAML template file
	local download_success=true
	for yaml_file in "${yaml_files[@]}"; do
		local file_url="${base_url}/${yaml_file}"
		local target_file="${temp_dir}/${yaml_file}"

		print_info "Downloading ${yaml_file}..."

		# Download with curl, follow redirects, fail on HTTP errors
		if curl -sSL --fail "$file_url" -o "$target_file"; then
			print_success "Successfully downloaded ${yaml_file}"
		else
			print_error "Failed to download ${yaml_file} from ${file_url}"
			download_success=false
			break
		fi

		# Verify file was downloaded and is not empty
		if [[ ! -s "$target_file" ]]; then
			print_error "Downloaded file ${yaml_file} is empty or corrupted"
			download_success=false
			break
		fi
	done

	# Check if all downloads were successful
	if [[ "$download_success" == "true" ]]; then
		print_success "All YAML templates downloaded successfully to $temp_dir"
	else
		print_error "YAML template download failed. Please check:"
		print_error "  1. Network connectivity"
		print_error "  2. Repository URL: $base_url"
		print_error "  3. Template files availability"
		print_error "You can set custom base URL via: export YAML_TEMPLATES_BASE_URL=<your-url>"
		exit 1
	fi
}

# Generate random identifier
generate_random_identifier() {
	local length="${1:-5}"
	local chars="abcdefghijklmnopqrstuvwxyz0123456789"
	local result=""
	
	# Generate random string using $RANDOM
	for ((i=0; i<length; i++)); do
		local random_index=$((RANDOM % ${#chars}))
		result+="${chars:$random_index:1}"
	done
	
	echo "$result"
}

# Escape special characters for sed replacement
escape_sed_replacement() {
	local input="$1"
	# Escape backslashes, forward slashes, and ampersands for sed
	printf '%s\n' "$input" | sed 's/[\\&/]/\\&/g'
}

# Prepare YAML files
prepare_yaml_files() {
	print_info "Preparing YAML configuration files..."

	# Create temporary directory and download YAML templates
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

# Get available MySQL version list
get_mysql_versions() {
	# Get MySQL related versions from UPM packages
	local mysql_versions
	mysql_versions=$(helm search repo upm-packages | grep "mysql" | grep -v "mysql-router" | awk '{print $3}' | sort -V -r || echo "")

	if [[ -z "$mysql_versions" ]]; then
		print_error "Unable to get MySQL version list" >&2
		return 1
	else
		echo "$mysql_versions"
		return 0
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
	if ! available_versions=$(get_mysql_versions); then
		return 1
	fi
	
	# Check if the provided version is in the available versions list
	while IFS= read -r available_version; do
		if [[ "$version" == "$available_version" ]]; then
			return 0
		fi
	done <<< "$available_versions"
	
	return 1
}

# Install UPM package components for specific MySQL version
install_upm_packages() {
	local mysql_version="$1"
	
	if [[ -z "$mysql_version" ]]; then
		print_error "MySQL version parameter is required for UPM package installation"
		exit 1
	fi
	
	print_info "Installing UPM package components for MySQL version $mysql_version..."

	local upm_script="${SCRIPT_DIR}/../upm-pkg-mgm.sh"

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

# Check and add helm repository if needed
check_helm_repo() {
	print_info "Checking helm repository..."
	
	# Check if upm-packages repo exists
	if helm repo list 2>/dev/null | grep -q "upm-packages"; then
		print_success "Helm repository 'upm-packages' already exists"
		return 0
	fi
	
	print_info "Adding helm repository 'upm-packages'..."
	if helm repo add upm-packages https://upmio.github.io/upm-packages; then
		print_success "Successfully added helm repository 'upm-packages'"
		# Update repo to ensure it's accessible
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
}

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

	# Check and add helm repository
	check_helm_repo

	# Check StorageClass
	check_storageclass

	print_success "All dependency checks completed"
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

	if [[ -z "$MYSQL_VERSION" ]]; then
		missing_params+=("MySQL Version")
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

	# Validate MySQL version
	if [[ -n "$MYSQL_VERSION" ]]; then
		if ! validate_mysql_version "$MYSQL_VERSION"; then
			print_error "Invalid MySQL version specified: $MYSQL_VERSION"
			print_info "Available MySQL versions:"
			if get_mysql_versions | while IFS= read -r version; do
				echo "  - $version"
			done; then
				:
			else
				print_warning "Unable to retrieve available MySQL versions"
			fi
			exit 1
		fi
	fi

	print_success "Parameter validation passed"
}

# Interactive parameter input
get_user_input() {
	# Select MySQL version (only if not provided)
	if [[ -z "$MYSQL_VERSION" ]]; then
		local mysql_versions
		if mysql_versions=$(get_mysql_versions); then
			if [[ -n "$mysql_versions" ]]; then
				local mysql_version_array=()
				while IFS= read -r line; do
					[[ -n "$line" ]] && mysql_version_array+=("$line")
				done <<<"$mysql_versions"

				if [[ ${#mysql_version_array[@]} -gt 0 ]]; then
					MYSQL_VERSION=$(select_from_list "Select MySQL version:" "${mysql_version_array[@]}" "false")
				else
					print_error "Unable to get MySQL version list"
					exit 1
				fi
			else
				print_error "Unable to get MySQL version list"
				exit 1
			fi
		else
			print_error "Failed to retrieve MySQL versions"
			exit 1
		fi
	else
		print_info "MySQL Version already specified: $MYSQL_VERSION"
		# Validate provided MySQL version
		if ! validate_mysql_version "$MYSQL_VERSION"; then
			print_error "Invalid MySQL version specified: $MYSQL_VERSION"
			print_info "Available MySQL versions:"
			if get_mysql_versions | while IFS= read -r version; do
				echo "  - $version"
			done; then
				:
			else
				print_warning "Unable to retrieve available MySQL versions"
			fi
			exit 1
		fi
	fi

	# Display current parameter status
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
	
	if [[ -n "$MYSQL_VERSION" ]]; then
		print_success "  MySQL Version: $MYSQL_VERSION (provided via command line)"
	else
		print_info "  MySQL Version: Not specified, will be configured interactively"
	fi
	
	print_success "  NodePort IP: $NODEPORT_IP (auto-detected)"
	echo
	
	# Check if all parameters are already provided
	local need_interaction=false
	if [[ -z "$STORAGE_CLASS" ]] || [[ -z "$NAMESPACE" ]] || [[ -z "$MYSQL_VERSION" ]]; then
		need_interaction=true
	fi
	
	if [[ "$need_interaction" == "false" ]]; then
		print_info "All required parameters provided via command line, skipping interactive configuration"
		validate_parameters
		print_success "Parameter configuration completed:"
		print_success "  StorageClass: $STORAGE_CLASS"
		print_success "  Namespace: $NAMESPACE"
		print_success "  NodePort IP: $NODEPORT_IP"
		print_success "  MySQL Version: $MYSQL_VERSION"
		echo
		return 0
	fi

	print_info "Starting interactive configuration for missing parameters..."

	# Get StorageClass (only if not provided)
	if [[ -z "$STORAGE_CLASS" ]]; then
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
	else
		print_info "StorageClass already specified: $STORAGE_CLASS"
	fi

	# Get Namespace (only if not provided)
	if [[ -z "$NAMESPACE" ]]; then
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
	else
		print_info "Namespace already specified: $NAMESPACE"
	fi

	echo
	print_success "Parameter configuration completed:"
    print_success "  MySQL Version: $MYSQL_VERSION"
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

	# Generate random identifiers
	local mysql_name_suffix
	local router_name_suffix
	mysql_name_suffix=$(generate_random_identifier 5)
	router_name_suffix=$(generate_random_identifier 5)

	# Escape special characters for sed
	local escaped_namespace escaped_nodeport_ip escaped_storage_class escaped_version
	escaped_namespace=$(escape_sed_replacement "$NAMESPACE")
	escaped_nodeport_ip=$(escape_sed_replacement "$NODEPORT_IP")
	escaped_storage_class=$(escape_sed_replacement "$STORAGE_CLASS")
	escaped_version=$(escape_sed_replacement "$MYSQL_VERSION")
	local escaped_mysql_suffix escaped_router_suffix
	escaped_mysql_suffix=$(escape_sed_replacement "$mysql_name_suffix")
	escaped_router_suffix=$(escape_sed_replacement "$router_name_suffix")

	# Process each YAML file
	for yaml_file in "${YAML_FILES[@]}"; do
		local file_path="$TEMP_DIR/$yaml_file"
		if [[ -f "$file_path" ]]; then
			print_info "Processing $yaml_file..."
			
			# Replace basic placeholders
			sed_inplace "s/<namespace>/$escaped_namespace/g" "$file_path"
			sed_inplace "s/<nodeport-ip>/$escaped_nodeport_ip/g" "$file_path"
			sed_inplace "s/<storageClass-name>/$escaped_storage_class/g" "$file_path"
			sed_inplace "s/<version>/$escaped_version/g" "$file_path"
			sed_inplace "s/<mysql-name-suffix>/$escaped_mysql_suffix/g" "$file_path"
			sed_inplace "s/<router-name-suffix>/$escaped_router_suffix/g" "$file_path"
			
			print_success "✓ $yaml_file processed"
		fi
	done

	# Store identifiers for later use
	MYSQL_NAME_SUFFIX="$mysql_name_suffix"
	ROUTER_NAME_SUFFIX="$router_name_suffix"

	print_success "Placeholder replacement completed"
	print_info "MySQL name suffix: $MYSQL_NAME_SUFFIX"
	print_info "Router name suffix: $ROUTER_NAME_SUFFIX"
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
	local timeout="${4:-300}" # Default 5 minutes

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
				
				# Check for failed status
				local failed_status
				failed_status=$(kubectl get job "$resource_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
				if [[ "$failed_status" == "True" ]]; then
					print_error "Job $resource_name failed"
					return 1
				fi
				;;
			"unitset")
				# Check if resource exists
				if ! kubectl get unitset "$resource_name" -n "$namespace" >/dev/null 2>&1; then
					print_info "UnitSet $resource_name does not exist yet, waiting..." >&2
					continue
				fi
				
				local ready_units total_units
				ready_units=$(kubectl get unitset "$resource_name" -n "$namespace" -o json 2>/dev/null | jq -r '.status.readyUnits // 0')
				total_units=$(kubectl get unitset "$resource_name" -n "$namespace" -o json 2>/dev/null | jq -r '.spec.units // 0')
				
				# Handle empty values
				if [[ -z "$ready_units" ]]; then
					ready_units=0
				fi
				if [[ -z "$total_units" ]]; then
					total_units=0
				fi
				
				print_info "UnitSet $resource_name status: ready=$ready_units, desired=$total_units" >&2
				
				# Check if all units are ready
				if [[ "$ready_units" -gt 0 && "$total_units" -gt 0 && "$ready_units" -eq "$total_units" ]]; then
					print_success "UnitSet $resource_name is ready"
					return 0
				fi
				;;
			"mysqlgroupreplication")
				local ready
				ready=$(kubectl get mysqlgroupreplication "$resource_name" -n "$namespace" -o jsonpath='{.status.ready}' 2>/dev/null || echo "")
				if [[ "$ready" == "true" ]]; then
					print_success "MysqlGroupReplication $resource_name is ready"
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

	# Show replacement content if requested
	if [[ "$show_replacements" == "true" ]]; then
		print_info "Placeholder replacement content:"
		print_info "  <namespace> → $NAMESPACE"
		print_info "  <nodeport-ip> → $NODEPORT_IP"
		print_info "  <storageClass-name> → $STORAGE_CLASS"
		print_info "  <version> → $MYSQL_VERSION"
		print_info "  <mysql-name-suffix> → $MYSQL_NAME_SUFFIX"
		print_info "  <router-name-suffix> → $ROUTER_NAME_SUFFIX"
	fi

	# Apply YAML file
	print_info "Applying $yaml_file..."
	if ! apply_yaml_file "$yaml_file"; then
		print_error "Step $step_num failed: Unable to apply $yaml_file"
		return 1
	fi

	# Wait for resource if specified
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

# Deploy InnoDB Cluster
deploy_innodb_cluster() {
	print_info "Starting InnoDB Cluster deployment..."
	print_info "Deployment order: Project → Secret → MySQL UnitSet → MySQL Group Replication → MySQL Router"
	echo

	# Step 0: Create Project
	if ! deploy_step "0" "Create Project" "0-project.yaml" "" "" "" "true"; then
		return 1
	fi

	# Step 1: Generate Secret
	if ! deploy_step "1" "Generate Secret" "1-gen-secret.yaml" "job" "generate-innodb-cluster-secret-job" "120" "true"; then
		return 1
	fi

	# Step 2: Deploy MySQL UnitSet
	if ! deploy_step "2" "Deploy MySQL UnitSet" "2-mysql-us.yaml" "unitset" "demo-mysql-$MYSQL_NAME_SUFFIX" "300" "true"; then
		return 1
	fi

	# Step 3: Deploy MySQL Group Replication
	if ! deploy_step "3" "Create MySQL Group Replication" "3-mysql-group-replication.yaml" "mysqlgroupreplication" "demo-mysql-$MYSQL_NAME_SUFFIX-replication" "180" "true"; then
		return 1
	fi

	# Step 4: Deploy MySQL Router
	if ! deploy_step "4" "Deploy MySQL Router" "4-mysql-router-us.yaml" "unitset" "demo-mysql-router-$ROUTER_NAME_SUFFIX" "300" "true"; then
		return 1
	fi

	# Deployment summary
	print_info "========================================"
	print_success "InnoDB Cluster deployment completed!"
	print_info "========================================"
	print_info "Deployment summary:"
	print_info "  - Namespace: $NAMESPACE"
	print_info "  - MySQL UnitSet: demo-mysql-$MYSQL_NAME_SUFFIX"
	print_info "  - MySQL Router UnitSet: demo-mysql-router-$ROUTER_NAME_SUFFIX"
	print_info "  - Storage class: $STORAGE_CLASS"
	print_info "  - MySQL version: $MYSQL_VERSION"
	print_info "  - NodePort IP: $NODEPORT_IP"
	echo

	# Display connection information
	display_connection_info
}

# Main function
main() {
	# Parse command line arguments
	parse_arguments "$@"

	# Show help if requested
	if [[ "$SHOW_HELP" == "true" ]]; then
		show_help
		exit 0
	fi

	# Check dependencies
	check_dependencies

	# Auto-detect NodePort IP
	auto_detect_nodeport_ip

	# Get user input for missing parameters
	get_user_input

	# Install UPM packages (only in non-dry-run mode)
	if [[ "$DRY_RUN" != "true" ]]; then
		install_upm_packages "$MYSQL_VERSION"
	fi

	# Prepare YAML files
	prepare_yaml_files

	# Validate YAML files
	validate_yaml_files

	# Replace placeholders
	replace_placeholders

	# Deploy InnoDB Cluster
	deploy_innodb_cluster

	print_success "InnoDB Cluster deployment script completed!"
}

# Display connection information after deployment
display_connection_info() {
	print_info "========================================"
	print_success "Connection Information"
	print_info "========================================"
	
	# Get NodePort services information
	local mysql_port mysqlx_port
	# Get MySQL protocol port (6446) and MySQLX protocol port (6447) from the single router service
	mysql_port=$(kubectl get svc -n "$NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="demo-mysql-router-'"$ROUTER_NAME_SUFFIX"'-svc")].spec.ports[?(@.port==6446)].nodePort}' 2>/dev/null || echo "")
	mysqlx_port=$(kubectl get svc -n "$NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="demo-mysql-router-'"$ROUTER_NAME_SUFFIX"'-svc")].spec.ports[?(@.port==6447)].nodePort}' 2>/dev/null || echo "")
	
	if [[ -z "$mysql_port" || -z "$mysqlx_port" ]]; then
		print_warning "Unable to retrieve NodePort information automatically"
		print_info "Please check NodePort services manually:"
		print_info "  kubectl get svc -n $NAMESPACE | grep router"
		echo
	fi
	
	print_info "MySQL InnoDB Cluster Access Information:"
	echo
	
	print_info "📋 Database Connection Details:"
	print_info "  • Host: $NODEPORT_IP"
	print_info "  • Username: radminuser"
	print_info "  • Password: mypassword123"
	echo
	
	if [[ -n "$mysql_port" && -n "$mysqlx_port" ]]; then
		print_info "🔌 NodePort Services:"
		print_info "  • MySQL Protocol Port (6446):  $mysql_port  (read/write capable)"
		print_info "  • MySQLX Protocol Port (6447): $mysqlx_port  (X Protocol)"
		echo
		
		print_info "💻 Connection Commands:"
		print_info "  # Connect via MySQL protocol (standard connection)"
		print_info "  mysql -h $NODEPORT_IP -P $mysql_port -u radminuser -pmypassword123"
		echo
		print_info "  # Connect via MySQLX protocol (X Protocol)"
		print_info "  mysqlsh --uri radminuser:mypassword123@$NODEPORT_IP:$mysqlx_port"
		echo
	else
		print_info "🔌 NodePort Services:"
		print_info "  Please check services manually: kubectl get svc -n $NAMESPACE"
		echo
	fi
	
	print_info "🧪 Verification Script:"
	print_info "  # Test MySQL protocol port connection and cluster status"
	if [[ -n "$mysql_port" ]]; then
		print_info "  ./verify-mysql.sh -h $NODEPORT_IP -P $mysql_port -u radminuser -p mypassword123 -v"
	else
		print_info "  ./verify-mysql.sh -h $NODEPORT_IP -P <MYSQL_PORT> -u radminuser -p mypassword123 -v"
	fi
	
	print_info "📚 Additional Commands:"
	print_info "  # Check cluster status"
	print_info "  kubectl get pods,svc,pvc -n $NAMESPACE -l upm.api/service-group.name=demo"
	echo
	print_info "  # View MySQL Router logs"
	print_info "  kubectl logs -n $NAMESPACE -l app=demo-mysql-router-$ROUTER_NAME_SUFFIX"
	echo
	print_info "  # View MySQL logs"
	print_info "  kubectl logs -n $NAMESPACE -l app=demo-mysql-$MYSQL_NAME_SUFFIX"
	echo
	
	print_success "🎉 Your MySQL InnoDB Cluster is ready for use!"
	print_info "========================================"
}

# Global variables for generated identifiers
MYSQL_NAME_SUFFIX=""
ROUTER_NAME_SUFFIX=""

# Run main function
main "$@"
