#!/bin/bash

# Redis Sentinel Cluster Automated Deployment Script
# Deploy Redis Sentinel services after installing core Operator components

set -euo pipefail

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_DIR="${SCRIPT_DIR}/temp-redis-sentinel"

# Command line arguments
DRY_RUN="false"
SHOW_HELP="false"

# YAML file deployment order (in new execution sequence)
YAML_FILES=(
	"0-project.yaml"
	"1-gen-secret.yaml"
	"2-redis-us.yaml"
	"3.0-redis-replication.yaml"
	"3.1-redis-replication_patch.yaml"
	"4-redis-sentinel-us.yaml"
)

# Global variables - set via command line arguments, fallback to interactive input
STORAGE_CLASS=""
NAMESPACE=""
REDIS_VERSION=""
NODEPORT_IP=""

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

# Help information
show_help() {
	cat << EOF
Deploy Redis Sentinel Cluster Script

This script deploys a Redis Sentinel Cluster with Redis Replication using UPM.

Usage: $0 [OPTIONS]

Options:
  -s, --storage-class STORAGE_CLASS    Kubernetes StorageClass name
  -n, --namespace NAMESPACE            Kubernetes namespace
  -v, --redis-version VERSION          Redis version to deploy
  -i, --nodeport-ip IP                 NodePort IP address (auto-detected if not specified)
  -d, --dry-run                        Show what would be deployed without actually deploying
  -h, --help                           Show this help message

Examples:
  # Interactive deployment (recommended)
  $0

  # Non-interactive deployment with all parameters
  $0 -s local-path -n demo -v 7.0.14 -i 192.168.1.100

  # Dry run to see what would be deployed
  $0 -s local-path -n demo -v 7.0.14 --dry-run

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
			-v|--redis-version)
				REDIS_VERSION="$2"
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

# Error handling function
cleanup() {
	if [[ -d "$TEMP_DIR" ]]; then
		print_info "Cleaning up temporary files..."
		rm -rf "$TEMP_DIR"
	fi
}

trap cleanup EXIT

# Create embedded YAML files
download_yaml_templates() {
	local temp_dir="$1"
	mkdir -p "$temp_dir"

	# Base URL for YAML templates - fixed URL
	local base_url="https://raw.githubusercontent.com/upmio/demo/refs/heads/main/redis-sentinel/templates"

	# List of YAML template files to download
	local yaml_files=(
		"0-project.yaml"
		"1-gen-secret.yaml"
		"2-redis-us.yaml"
		"3.0-redis-replication.yaml"
		"3.1-redis-replication_patch.yaml"
		"4-redis-sentinel-us.yaml"
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

# Get available Redis version list
get_redis_versions() {
	# Get Redis related versions from UPM packages
	local redis_versions
	redis_versions=$(helm search repo upm-packages | grep "redis" | grep -v "redis-sentinel" | awk '{print $3}' | sort -V -r || echo "")

	if [[ -z "$redis_versions" ]]; then
		print_error "Unable to get Redis version list" >&2
		return 1
	else
		echo "$redis_versions"
		return 0
	fi
}

# Validate Redis version
validate_redis_version() {
	local version="$1"
	
	if [[ -z "$version" ]]; then
		return 1
	fi
	
	# Get available Redis versions
	local available_versions
	if ! available_versions=$(get_redis_versions); then
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

# Install UPM package components for specific Redis version
install_upm_packages() {
	local redis_version="$1"
	
	if [[ -z "$redis_version" ]]; then
		print_error "Redis version parameter is required for UPM package installation"
		exit 1
	fi
	
	print_info "Installing UPM package components for Redis version $redis_version..."

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

	# Install specific version of redis and redis-sentinel packages
	print_info "Installing redis-$redis_version and redis-sentinel-$redis_version packages..."
	if "$upm_script" install "redis-$redis_version" "redis-sentinel-$redis_version"; then
		print_success "UPM package components for version $redis_version installed successfully"
	else
		print_error "UPM package components installation failed for version $redis_version"
		exit 1
	fi
}

# Check dependencies
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

	if [[ -z "$REDIS_VERSION" ]]; then
		missing_params+=("Redis Version")
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

	# Validate Redis version
	if [[ -n "$REDIS_VERSION" ]]; then
		if ! validate_redis_version "$REDIS_VERSION"; then
			print_error "Invalid Redis version specified: $REDIS_VERSION"
			print_info "Available Redis versions:"
			if get_redis_versions | while IFS= read -r version; do
				echo "  - $version"
			done; then
				:
			else
				print_warning "Unable to retrieve available Redis versions"
			fi
			exit 1
		fi
	fi

	print_success "Parameter validation passed"
}

# Interactive parameter input
get_user_input() {
	# Select Redis version (only if not provided)
	if [[ -z "$REDIS_VERSION" ]]; then
		local redis_versions
		if redis_versions=$(get_redis_versions); then
			if [[ -n "$redis_versions" ]]; then
				local redis_version_array=()
				while IFS= read -r line; do
					[[ -n "$line" ]] && redis_version_array+=("$line")
				done <<<"$redis_versions"

				if [[ ${#redis_version_array[@]} -gt 0 ]]; then
					REDIS_VERSION=$(select_from_list "Select Redis version:" "${redis_version_array[@]}" "false")
				else
					print_error "Unable to get Redis version list"
					exit 1
				fi
			else
				print_error "Unable to get Redis version list"
				exit 1
			fi
		else
			print_error "Failed to retrieve Redis versions"
			exit 1
		fi
	else
		print_info "Redis Version already specified: $REDIS_VERSION"
		# Validate provided Redis version
		if ! validate_redis_version "$REDIS_VERSION"; then
			print_error "Invalid Redis version specified: $REDIS_VERSION"
			print_info "Available Redis versions:"
			if get_redis_versions | while IFS= read -r version; do
				echo "  - $version"
			done; then
				:
			else
				print_warning "Unable to retrieve available Redis versions"
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
	
	if [[ -n "$REDIS_VERSION" ]]; then
		print_success "  Redis Version: $REDIS_VERSION (provided via command line)"
	else
		print_info "  Redis Version: Not specified, will be configured interactively"
	fi
	
	print_success "  NodePort IP: $NODEPORT_IP (auto-detected)"
	echo
	
	# Check if all parameters are already provided
	local need_interaction=false
	if [[ -z "$STORAGE_CLASS" ]] || [[ -z "$NAMESPACE" ]] || [[ -z "$REDIS_VERSION" ]]; then
		need_interaction=true
	fi
	
	if [[ "$need_interaction" == "false" ]]; then
		print_info "All required parameters provided via command line, skipping interactive configuration"
		validate_parameters
		print_success "Parameter configuration completed:"
		print_success "  StorageClass: $STORAGE_CLASS"
		print_success "  Namespace: $NAMESPACE"
		print_success "  NodePort IP: $NODEPORT_IP"
		print_success "  Redis Version: $REDIS_VERSION"
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
    print_success "  Redis Version: $REDIS_VERSION"
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
	local redis_name_suffix
	local sentinel_name_suffix
	redis_name_suffix=$(generate_random_identifier 5)
	sentinel_name_suffix=$(generate_random_identifier 5)

	# Escape special characters for sed
	local escaped_namespace escaped_nodeport_ip escaped_storage_class escaped_version
	escaped_namespace=$(escape_sed_replacement "$NAMESPACE")
	escaped_nodeport_ip=$(escape_sed_replacement "$NODEPORT_IP")
	escaped_storage_class=$(escape_sed_replacement "$STORAGE_CLASS")
	escaped_version=$(escape_sed_replacement "$REDIS_VERSION")
	local escaped_redis_suffix escaped_sentinel_suffix
	escaped_redis_suffix=$(escape_sed_replacement "$redis_name_suffix")
	escaped_sentinel_suffix=$(escape_sed_replacement "$sentinel_name_suffix")

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
			sed_inplace "s/<redis-name-suffix>/$escaped_redis_suffix/g" "$file_path"
			sed_inplace "s/<sentinel-name-suffix>/$escaped_sentinel_suffix/g" "$file_path"
			
			print_success "✓ $yaml_file processed"
		fi
	done

	# Store identifiers for later use
	REDIS_NAME_SUFFIX="$redis_name_suffix"
	SENTINEL_NAME_SUFFIX="$sentinel_name_suffix"

	print_success "Placeholder replacement completed"
	print_info "Redis name suffix: $REDIS_NAME_SUFFIX"
	print_info "Sentinel name suffix: $SENTINEL_NAME_SUFFIX"
}

# Get NodePort from service
get_service_nodeport() {
	local service_name="$1"
	local namespace="$2"
	local unit_index="$3"
	local full_service_name="$service_name-$unit_index-svc"
	
	print_info "Getting NodePort for $service_name unit-$unit_index..." >&2
	print_info "Full service name: $full_service_name" >&2
	
	# First check if service exists
	if ! kubectl get service "$full_service_name" -n "$namespace" >/dev/null 2>&1; then
		print_error "Service $full_service_name does not exist in namespace $namespace" >&2
		print_info "Available services in namespace $namespace:" >&2
		kubectl get services -n "$namespace" --no-headers -o custom-columns=":metadata.name" 2>/dev/null || print_error "Failed to list services" >&2
		return 1
	fi
	
	# Wait for service to be created and have NodePort
	local max_attempts=30
	local attempt=0
	
	while [[ $attempt -lt $max_attempts ]]; do
		local nodeport
		nodeport=$(kubectl get service "$full_service_name" -n "$namespace" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
		
		print_info "Attempt $((attempt + 1))/$max_attempts: Retrieved NodePort value: '${nodeport:-EMPTY}'" >&2
		
		if [[ -n "$nodeport" && "$nodeport" != "null" && "$nodeport" != "<no value>" ]]; then
			print_success "NodePort for $service_name unit-$unit_index: $nodeport" >&2
			echo "$nodeport"
			return 0
		fi
		
		print_info "Waiting for service $full_service_name to have NodePort... (attempt $((attempt + 1))/$max_attempts)" >&2
		# Show service details for debugging
		if [[ $((attempt % 5)) -eq 0 ]]; then
			print_info "Service details:" >&2
			kubectl get service "$full_service_name" -n "$namespace" -o yaml 2>/dev/null | head -20 || print_error "Failed to get service details" >&2
		fi
		sleep 5
		((attempt++))
	done
	
	print_error "Failed to get NodePort for $service_name unit-$unit_index after $max_attempts attempts" >&2
	print_error "Final service status:" >&2
	kubectl get service "$full_service_name" -n "$namespace" -o wide 2>/dev/null || print_error "Failed to get final service status" >&2
	return 1
}

# Update YAML files with NodePorts
update_yaml_with_nodeports() {
	local redis_service_name="demo-redis-$REDIS_NAME_SUFFIX"
	
	print_info "Updating YAML files with NodePort information..."
	print_info "Redis service name: $redis_service_name"
	print_info "Namespace: $NAMESPACE"
	
	# Get NodePorts for all Redis units
	local unit_0_nodeport unit_1_nodeport unit_2_nodeport
	print_info "Getting NodePort for unit-0..."
	unit_0_nodeport=$(get_service_nodeport "$redis_service_name" "$NAMESPACE" "0")
	local unit_0_result=$?
	
	print_info "Getting NodePort for unit-1..."
	unit_1_nodeport=$(get_service_nodeport "$redis_service_name" "$NAMESPACE" "1")
	local unit_1_result=$?
	
	print_info "Getting NodePort for unit-2..."
	unit_2_nodeport=$(get_service_nodeport "$redis_service_name" "$NAMESPACE" "2")
	local unit_2_result=$?
	
	# Check if any NodePort retrieval failed
	if [[ $unit_0_result -ne 0 || $unit_1_result -ne 0 || $unit_2_result -ne 0 ]]; then
		print_error "Failed to get NodePorts from one or more Redis services:"
		print_error "  Unit-0 result: $unit_0_result (NodePort: ${unit_0_nodeport:-N/A})"
		print_error "  Unit-1 result: $unit_1_result (NodePort: ${unit_1_nodeport:-N/A})"
		print_error "  Unit-2 result: $unit_2_result (NodePort: ${unit_2_nodeport:-N/A})"
		return 1
	fi
	
	if [[ -z "$unit_0_nodeport" || -z "$unit_1_nodeport" || -z "$unit_2_nodeport" ]]; then
		print_error "One or more NodePorts are empty:"
		print_error "  Unit-0 NodePort: ${unit_0_nodeport:-EMPTY}"
		print_error "  Unit-1 NodePort: ${unit_1_nodeport:-EMPTY}"
		print_error "  Unit-2 NodePort: ${unit_2_nodeport:-EMPTY}"
		return 1
	fi
	
	print_success "Successfully retrieved all NodePorts:"
	print_success "  Unit-0 NodePort: $unit_0_nodeport"
	print_success "  Unit-1 NodePort: $unit_1_nodeport"
	print_success "  Unit-2 NodePort: $unit_2_nodeport"
	
	# Escape NodePorts for sed
	local escaped_unit_0 escaped_unit_1 escaped_unit_2
	escaped_unit_0=$(escape_sed_replacement "$unit_0_nodeport")
	escaped_unit_1=$(escape_sed_replacement "$unit_1_nodeport")
	escaped_unit_2=$(escape_sed_replacement "$unit_2_nodeport")
	
	# Update files that need NodePort information
	local files_with_nodeports=("3.0-redis-replication.yaml" "3.1-redis-replication_patch.yaml")
	for yaml_file in "${files_with_nodeports[@]}"; do
		local file_path="$TEMP_DIR/$yaml_file"
		if [[ -f "$file_path" ]]; then
			print_info "Updating $yaml_file with NodePorts..."
			
			sed_inplace "s/<unit-0_nodeport>/$escaped_unit_0/g" "$file_path"
			sed_inplace "s/<unit-1_nodeport>/$escaped_unit_1/g" "$file_path"
			sed_inplace "s/<unit-2_nodeport>/$escaped_unit_2/g" "$file_path"
			
			print_success "✓ $yaml_file updated with NodePorts"
		fi
	done
	
	print_success "NodePort update completed"
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
			"redisreplication")
				local status
				ready=$(kubectl get redisreplication "$resource_name" -n "$namespace" -o jsonpath='{.status.ready}' 2>/dev/null || echo "")
				if [[ "$ready" == "true" ]]; then
					print_success "RedisReplication $resource_name is ready"
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
		print_info "  <version> → $REDIS_VERSION"
		print_info "  <redis-name-suffix> → $REDIS_NAME_SUFFIX"
		print_info "  <sentinel-name-suffix> → $SENTINEL_NAME_SUFFIX"
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

# Deploy Redis Sentinel cluster
deploy_redis_sentinel() {
	print_info "Starting Redis Sentinel cluster deployment..."
	print_info "Deployment order: Project → Secret → Redis UnitSet → Redis Replication → Redis Replication Patch + Sentinel"
	echo

	# Step 0: Create Project
	if ! deploy_step "0" "Create Project" "0-project.yaml" "" "" "" "true"; then
		return 1
	fi

	# Step 1: Generate Secret
	if ! deploy_step "1" "Generate Secret" "1-gen-secret.yaml" "job" "generate-redis-sentinel-secret-job" "120" "true"; then
		return 1
	fi

	# Step 2: Deploy Redis UnitSet
	if ! deploy_step "2" "Deploy Redis UnitSet" "2-redis-us.yaml" "unitset" "demo-redis-$REDIS_NAME_SUFFIX" "300" "true"; then
		return 1
	fi

	# Update YAML files with NodePort information before step 3.0
	print_info "========================================"
	print_info "Getting NodePort information and updating templates"
	print_info "========================================"
	if [[ "$DRY_RUN" != "true" ]]; then
		if ! update_yaml_with_nodeports; then
			print_error "Failed to get NodePort information and update templates"
			print_error "This may be due to:"
			print_error "  1. Redis services not yet available"
			print_error "  2. Network connectivity issues"
			print_error "  3. Insufficient permissions to access services"
			print_error "Please check the Redis UnitSet status and try again"
			return 1
		fi
		print_success "NodePort information update completed"
	else
		print_info "DRY RUN: Would get NodePort information from Redis services and update:"
		print_info "  - 3.0-redis-replication.yaml"
		print_info "  - 3.1-redis-replication_patch.yaml"
		print_info "Note: NodePort placeholders (<unit-X_nodeport>) will be replaced with actual values"
	fi
	echo

	# Step 3.0: Deploy Redis Replication
	if ! deploy_step "3.0" "Create Redis Replication" "3.0-redis-replication.yaml" "redisreplication" "demo-redis-$REDIS_NAME_SUFFIX-replication" "180" "true"; then
		return 1
	fi

	# Step 3.1 & 4: Deploy Redis Replication Patch and Sentinel simultaneously
	print_info "========================================"
	print_info "Step 3.1 & 4: Deploy Redis Replication Patch and Sentinel simultaneously"
	print_info "========================================"
	print_info "Placeholder replacement content (including NodePort information):"
	print_info "  <namespace> → $NAMESPACE"
	print_info "  <nodeport-ip> → $NODEPORT_IP"
	print_info "  <redis-name-suffix> → $REDIS_NAME_SUFFIX"
	print_info "  <sentinel-name-suffix> → $SENTINEL_NAME_SUFFIX"
	if [[ "$DRY_RUN" != "true" ]]; then
		# Show NodePort information if available
		local redis_service_name="demo-redis-$REDIS_NAME_SUFFIX"
		local unit_0_nodeport unit_1_nodeport unit_2_nodeport
		unit_0_nodeport=$(kubectl get service "$redis_service_name-0-svc" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
		unit_1_nodeport=$(kubectl get service "$redis_service_name-1-svc" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
		unit_2_nodeport=$(kubectl get service "$redis_service_name-2-svc" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
		print_info "  <unit-0_nodeport> → $unit_0_nodeport"
		print_info "  <unit-1_nodeport> → $unit_1_nodeport"
		print_info "  <unit-2_nodeport> → $unit_2_nodeport"
	fi

	# Apply both files
	print_info "Applying 3.1-redis-replication_patch.yaml..."
	if ! apply_yaml_file "3.1-redis-replication_patch.yaml"; then
		print_error "Failed to apply Redis replication patch"
		return 1
	fi

	print_info "Applying 4-redis-sentinel-us.yaml..."
	if ! apply_yaml_file "4-redis-sentinel-us.yaml"; then
		print_error "Failed to apply Redis Sentinel UnitSet"
		return 1
	fi

	# Wait for Sentinel UnitSet to be ready
	print_info "Waiting for Sentinel UnitSet to be ready..."
	if ! wait_for_resource "unitset" "demo-redis-sentinel-$SENTINEL_NAME_SUFFIX" "$NAMESPACE" "300"; then
		print_error "Redis Sentinel UnitSet deployment failed"
		return 1
	fi

	print_success "Step 3.1 & 4 completed successfully: Redis Replication Patch and Sentinel deployment completed"
	echo

	# Deployment summary
	print_info "========================================"
	print_success "Redis Sentinel cluster deployment completed!"
	print_info "========================================"
	print_info "Deployment summary:"
	print_info "  - Namespace: $NAMESPACE"
	print_info "  - Redis UnitSet: demo-redis-$REDIS_NAME_SUFFIX"
	print_info "  - Sentinel UnitSet: demo-redis-sentinel-$SENTINEL_NAME_SUFFIX"
	print_info "  - Storage class: $STORAGE_CLASS"
	print_info "  - Redis version: $REDIS_VERSION"
	print_info "  - NodePort IP: $NODEPORT_IP"
	echo
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
		install_upm_packages "$REDIS_VERSION"
	fi

	# Prepare YAML files
	prepare_yaml_files

	# Validate YAML files
	validate_yaml_files

	# Replace placeholders
	replace_placeholders

	# Deploy Redis Sentinel cluster
	deploy_redis_sentinel

	# Display connection information
	display_connection_info

	print_success "Redis Sentinel deployment script completed!"
}

# Display connection information after deployment
display_connection_info() {
	print_info "========================================"
	print_success "Connection Information"
	print_info "========================================"
	
	# Get NodePort services information
	local redis_port sentinel_port
	# Get Redis port (6379) and Sentinel port (26379) from services
	redis_port=$(kubectl get svc -n "$NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="demo-redis-'"$REDIS_NAME_SUFFIX"'-svc")].spec.ports[?(@.port==6379)].nodePort}' 2>/dev/null || echo "")
	sentinel_port=$(kubectl get svc -n "$NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="demo-redis-sentinel-'"$SENTINEL_NAME_SUFFIX"'-svc")].spec.ports[?(@.port==26379)].nodePort}' 2>/dev/null || echo "")
	
	if [[ -z "$redis_port" || -z "$sentinel_port" ]]; then
		print_warning "Unable to retrieve NodePort information automatically"
		print_info "Please check NodePort services manually:"
		print_info "  kubectl get svc -n $NAMESPACE | grep redis"
		echo
	fi
	
	print_info "Redis Sentinel Cluster Access Information:"
	echo
	
	print_info "📋 Database Connection Details:"
	print_info "  • Host: $NODEPORT_IP"
	print_info "  • Redis Password: mypassword123"
	print_info "  • Sentinel Password: mypassword123"
	echo
	
	if [[ -n "$redis_port" && -n "$sentinel_port" ]]; then
		print_info "🔌 NodePort Services:"
		print_info "  • Redis Port (6379):     $redis_port  (data access)"
		print_info "  • Sentinel Port (26379): $sentinel_port  (monitoring & failover)"
		echo
		
		print_info "💻 Connection Commands:"
		print_info "  # Connect to Redis (data operations)"
		print_info "  redis-cli -h $NODEPORT_IP -p $redis_port -a mypassword123"
		echo
		print_info "  # Connect to Redis Sentinel (monitoring)"
		print_info "  redis-cli -h $NODEPORT_IP -p $sentinel_port -a mypassword123"
		echo
	else
		print_info "🔌 NodePort Services:"
		print_info "  Please check services manually: kubectl get svc -n $NAMESPACE"
		echo
	fi
	
	print_info "🧪 Verification Commands:"
	if [[ -n "$redis_port" && -n "$sentinel_port" ]]; then
		print_info "  # Test Redis connection and basic operations"
		print_info "  redis-cli -h $NODEPORT_IP -p $redis_port -a mypassword123 ping"
		echo
		print_info "  # Check Sentinel status and master info"
		print_info "  redis-cli -h $NODEPORT_IP -p $sentinel_port -a mypassword123 sentinel masters"
		echo
	else
		print_info "  # Test Redis connection (replace <REDIS_PORT> with actual port)"
		print_info "  redis-cli -h $NODEPORT_IP -p <REDIS_PORT> -a mypassword123 ping"
		echo
		print_info "  # Check Sentinel status (replace <SENTINEL_PORT> with actual port)"
		print_info "  redis-cli -h $NODEPORT_IP -p <SENTINEL_PORT> -a mypassword123 sentinel masters"
		echo
	fi
	
	print_info "📚 Additional Commands:"
	print_info "  # Check cluster status"
	print_info "  kubectl get pods,svc,pvc -n $NAMESPACE -l upm.api/service-group.name=demo"
	echo
	print_info "  # View Redis logs"
	print_info "  kubectl logs -n $NAMESPACE -l app=demo-redis-$REDIS_NAME_SUFFIX"
	echo
	print_info "  # View Sentinel logs"
	print_info "  kubectl logs -n $NAMESPACE -l app=demo-redis-sentinel-$SENTINEL_NAME_SUFFIX"
	echo
	
	print_success "🎉 Your Redis Sentinel Cluster is ready for use!"
	print_info "========================================"
}

# Global variables for generated identifiers
REDIS_NAME_SUFFIX=""
SENTINEL_NAME_SUFFIX=""

# Run main function
main "$@"