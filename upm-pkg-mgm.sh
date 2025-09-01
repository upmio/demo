#!/usr/bin/env bash

# UPM Package Management Script
# This script provides unified management for all UPM packages including install, uninstall, and upgrade operations

set -euo pipefail

# Default values
NAMESPACE="upm-system"
DRY_RUN=false
HELM_REPO_NAME="upm-packages"
HELM_REPO_URL="https://upmio.github.io/upm-packages"
TIMEOUT="300s"
RELEASE_PREFIX="upm-packages"
ACTION=""

# Cache for package lists
PACKAGE_CACHE=""
COMPONENT_CACHE=""
CACHE_TIMESTAMP=0
CACHE_TTL=300 # 5 minutes cache

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
  echo -e "${BLUE}[INFO]${NC} $1" >&2
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_header() {
  echo -e "${CYAN}$1${NC}"
}

# Normalize user-friendly target aliases to canonical component names
normalize_target() {
  local t="$1"
  case "$t" in
  mysql)
    echo "mysql-community"
    ;;
  mysql-router)
    echo "mysql-router-community"
    ;;
  postgres)
    echo "postgresql"
    ;;
  elastic)
    echo "elasticsearch"
    ;;
  zk)
    echo "zookeeper"
    ;;
  *)
    # pass through other values (already canonical component or specific chart name)
    echo "$t"
    ;;
  esac
}

# Helpers for release status and idempotency
# Return release status string (e.g., deployed, failed, pending-install) or non-zero if not found
get_release_status() {
  local release_name="$1"

  # Try JSON output first if supported and jq is available
  if helm status "$release_name" --namespace="$NAMESPACE" --output json >/dev/null 2>&1; then
    if command -v jq &>/dev/null; then
      helm status "$release_name" --namespace="$NAMESPACE" --output json 2>/dev/null | jq -r '.info.status' 2>/dev/null
      return 0
    fi
  fi

  # Fallback to parsing text output (works across helm versions)
  if helm status "$release_name" --namespace="$NAMESPACE" >/dev/null 2>&1; then
    helm status "$release_name" --namespace="$NAMESPACE" 2>/dev/null | awk -F': ' '/^STATUS:/ {print tolower($2); exit}'
    return 0
  fi

  return 1
}

is_release_deployed() {
  local release_name="$1"
  local status
  if status=$(get_release_status "$release_name"); then
    [[ "$status" == "deployed" ]]
    return $?
  fi
  return 1
}

# Function to display help
show_help() {
  cat <<EOF
UPM Package Management Script

This script provides unified management for all UPM packages including install, uninstall, and upgrade operations.

USAGE:
    $0 <ACTION> [OPTIONS] [TARGETS]

ACTIONS:
    install                         Install packages (default)
    uninstall                       Uninstall packages
    upgrade                         Upgrade packages
    list                            List available packages and installed releases
    status                          Show status of installed packages

TARGETS:
    all                             All available packages
    <component>                     Component type (e.g., mysql-community, postgresql)
    <chart-name>                    Specific chart name (e.g., mysql-community-8.4.5)

NOTE: Available components and packages are dynamically fetched from the helm repository.
Use './upm-pkg-mgm.sh list' to see currently available options.

OPTIONS:
    -n, --namespace NAMESPACE      Kubernetes namespace (default: upm-system)
    -d, --dry-run                  Perform a dry run without making changes
    -t, --timeout TIMEOUT          Helm timeout duration (default: 300s)
    -p, --prefix PREFIX            Release name prefix (default: upm-packages)
    -h, --help                     Show this help message

EXAMPLES:
    # Install all packages
    $0 install all

    # Install MySQL components only
    $0 install mysql-community mysql-router-community

    # Uninstall specific package
    $0 uninstall mysql-community-8.4.5

    # Upgrade all packages
    $0 upgrade all

    # List all available packages
    $0 list

    # Show status of installed packages
    $0 status

    # Dry run installation
    $0 install --dry-run mysql-community

NOTE:
  - You can pass multiple component names in one command, e.g.:
      $0 install mysql mysql-router proxysql
    Aliases are supported: mysql -> mysql-community, mysql-router -> mysql-router-community, postgres -> postgresql, elastic -> elasticsearch, zk -> zookeeper.
  - These are UPM packages that require UPM CRDs to function.

EOF
}

# Function to parse command line arguments
parse_args() {
  # Check if help is requested first
  for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
      show_help
      exit 0
    fi
  done

  if [[ $# -eq 0 ]]; then
    print_error "No action specified. Use --help for usage information."
    exit 1
  fi

  ACTION="$1"
  shift

  # Validate action
  case "$ACTION" in
  install | uninstall | upgrade | list | status) ;;
  *)
    print_error "Invalid action: $ACTION"
    show_help
    exit 1
    ;;
  esac

  local targets=()

  while [[ $# -gt 0 ]]; do
    case $1 in
    -n | --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -d | --dry-run)
      DRY_RUN=true
      shift
      ;;
    -t | --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    -p | --prefix)
      RELEASE_PREFIX="$2"
      shift 2
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    -*)
      print_error "Unknown option: $1"
      show_help
      exit 1
      ;;
    *)
      # Allow multiple component names and aliases in a single command
      local normalized
      normalized=$(normalize_target "$1")
      targets+=("$normalized")
      shift
      ;;
    esac
  done

  # Set targets based on action
  case "$ACTION" in
  install | uninstall | upgrade)
    if [[ ${#targets[@]} -eq 0 ]]; then
      print_error "No targets specified for $ACTION action"
      show_help
      exit 1
    fi
    SELECTED_TARGETS=("${targets[@]}")
    ;;
  list | status)
    # These actions don't require targets
    SELECTED_TARGETS=()
    ;;
  esac
}

# Function to check prerequisites
check_prerequisites() {
  print_info "Checking prerequisites..."

  # Check if kubectl is installed
  if ! command -v kubectl &>/dev/null; then
    print_error "kubectl is not installed"
    exit 1
  fi

  # Check if helm is installed
  if ! command -v helm &>/dev/null; then
    print_error "helm is not installed"
    exit 1
  fi

  # Check if kubernetes cluster is accessible (skip for 'list' and for DRY_RUN)
  if [[ "$ACTION" != "list" && "$DRY_RUN" != true ]]; then
    if ! kubectl cluster-info --request-timeout=10s >/dev/null; then
      print_error "Kubernetes cluster is not accessible"
      exit 1
    fi
  fi

  # Check if jq is installed for JSON parsing (optional)
  if ! command -v jq &>/dev/null; then
    print_warning "jq is not installed. JSON parsing will be limited."
  fi

  print_success "Prerequisites check passed"
}

# Function to create namespace if it doesn't exist
create_namespace() {
  if [[ "$ACTION" == "install" ]]; then
    print_info "Creating namespace: $NAMESPACE"

    if [[ "$DRY_RUN" == true ]]; then
      print_info "DRY_RUN: would ensure namespace $NAMESPACE exists"
      return
    fi

    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
      print_warning "Namespace $NAMESPACE already exists"
    else
      kubectl create namespace "$NAMESPACE"
      print_success "Namespace $NAMESPACE created"
    fi
  fi
}

# Function to add helm repository
add_helm_repo() {
  if [[ "$ACTION" == "install" ]]; then
    print_info "Adding helm repository: $HELM_REPO_NAME"

    if helm repo list | grep -q "^$HELM_REPO_NAME "; then
      print_info "Repository $HELM_REPO_NAME already exists, updating..."
      helm repo update "$HELM_REPO_NAME"
    else
      helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL"
      print_success "Repository $HELM_REPO_NAME added"
    fi
  fi
}

# Function to check if cache is valid
is_cache_valid() {
  local current_time
  current_time=$(date +%s)
  [[ $((current_time - CACHE_TIMESTAMP)) -lt $CACHE_TTL && -n "$PACKAGE_CACHE" ]]
}

# Function to fetch available packages from helm repo
fetch_available_packages() {
  if is_cache_valid; then
    echo "$PACKAGE_CACHE"
    return
  fi

  print_info "Fetching available packages from helm repository..."

  # Ensure repository is added and updated
  if ! helm repo list | grep -q "^$HELM_REPO_NAME "; then
    helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null 2>&1
  fi
  helm repo update "$HELM_REPO_NAME" >/dev/null 2>&1

  # Search for all charts in the repository
  local packages
  if command -v jq &>/dev/null; then
    packages=$(helm search repo "$HELM_REPO_NAME/" --output json 2>/dev/null | jq -r '.[].name' | sed "s|^$HELM_REPO_NAME/||" | sort)
  else
    # Fallback: parse table output when jq is unavailable
    # Skip header line, take first column (chart name), strip repo prefix
    packages=$(helm search repo "$HELM_REPO_NAME/" --output table 2>/dev/null | tail -n +2 | awk '{print $1}' | sed "s|^$HELM_REPO_NAME/||" | sort)
  fi

  if [[ -z "$packages" ]]; then
    print_error "Failed to fetch packages from helm repository"
    return 1
  fi

  # Update cache
  PACKAGE_CACHE="$packages"
  CACHE_TIMESTAMP=$(date +%s)

  echo "$packages"
}

# Function to categorize packages by component type
get_component_categories() {
  if is_cache_valid && [[ -n "$COMPONENT_CACHE" ]]; then
    echo "$COMPONENT_CACHE"
    return
  fi

  local packages
  if is_cache_valid && [[ -n "$PACKAGE_CACHE" ]]; then
    packages="$PACKAGE_CACHE"
  else
    if ! fetch_available_packages >/dev/null 2>&1; then
      return 1
    fi
    packages="$PACKAGE_CACHE"
  fi

  local components=""
  local mysql_community=""
  local mysql_router_community=""
  local postgresql=""
  local proxysql=""
  local pgbouncer=""
  local elasticsearch=""
  local kibana=""
  local kafka=""
  local redis=""
  local zookeeper=""
  local other=""

  for package in $packages; do
    case "$package" in
    mysql-community-*)
      if [[ -z "$mysql_community" ]]; then
        mysql_community="$package"
      else
        mysql_community="$mysql_community $package"
      fi
      ;;
    mysql-router-community-*)
      if [[ -z "$mysql_router_community" ]]; then
        mysql_router_community="$package"
      else
        mysql_router_community="$mysql_router_community $package"
      fi
      ;;
    postgresql-*)
      if [[ -z "$postgresql" ]]; then
        postgresql="$package"
      else
        postgresql="$postgresql $package"
      fi
      ;;
    proxysql-*)
      if [[ -z "$proxysql" ]]; then
        proxysql="$package"
      else
        proxysql="$proxysql $package"
      fi
      ;;
    pgbouncer-*)
      if [[ -z "$pgbouncer" ]]; then
        pgbouncer="$package"
      else
        pgbouncer="$pgbouncer $package"
      fi
      ;;
    elasticsearch-*)
      if [[ -z "$elasticsearch" ]]; then
        elasticsearch="$package"
      else
        elasticsearch="$elasticsearch $package"
      fi
      ;;
    kibana-*)
      if [[ -z "$kibana" ]]; then
        kibana="$package"
      else
        kibana="$kibana $package"
      fi
      ;;
    kafka-*)
      if [[ -z "$kafka" ]]; then
        kafka="$package"
      else
        kafka="$kafka $package"
      fi
      ;;
    redis-*)
      if [[ -z "$redis" ]]; then
        redis="$package"
      else
        redis="$redis $package"
      fi
      ;;
    zookeeper-*)
      if [[ -z "$zookeeper" ]]; then
        zookeeper="$package"
      else
        zookeeper="$zookeeper $package"
      fi
      ;;
    *)
      if [[ -z "$other" ]]; then
        other="$package"
      else
        other="$other $package"
      fi
      ;;
    esac
  done

  # Build components result
  if [[ -n "$mysql_community" ]]; then
    components="mysql-community:$mysql_community"
  fi
  if [[ -n "$mysql_router_community" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|mysql-router-community:$mysql_router_community"
    else
      components="mysql-router-community:$mysql_router_community"
    fi
  fi
  if [[ -n "$postgresql" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|postgresql:$postgresql"
    else
      components="postgresql:$postgresql"
    fi
  fi
  if [[ -n "$proxysql" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|proxysql:$proxysql"
    else
      components="proxysql:$proxysql"
    fi
  fi
  if [[ -n "$pgbouncer" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|pgbouncer:$pgbouncer"
    else
      components="pgbouncer:$pgbouncer"
    fi
  fi
  if [[ -n "$elasticsearch" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|elasticsearch:$elasticsearch"
    else
      components="elasticsearch:$elasticsearch"
    fi
  fi
  if [[ -n "$kibana" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|kibana:$kibana"
    else
      components="kibana:$kibana"
    fi
  fi
  if [[ -n "$kafka" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|kafka:$kafka"
    else
      components="kafka:$kafka"
    fi
  fi
  if [[ -n "$redis" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|redis:$redis"
    else
      components="redis:$redis"
    fi
  fi
  if [[ -n "$zookeeper" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|zookeeper:$zookeeper"
    else
      components="zookeeper:$zookeeper"
    fi
  fi
  if [[ -n "$other" ]]; then
    if [[ -n "$components" ]]; then
      components="$components|other:$other"
    else
      components="other:$other"
    fi
  fi

  # Update cache
  COMPONENT_CACHE="$components"

  echo "$components"
}

# Function to get packages for a specific component
get_component_packages() {
  local component="$1"
  local components
  components=$(get_component_categories)

  # Parse components to find the requested component
  local old_ifs="$IFS"
  IFS='|'
  for component_entry in $components; do
    local comp_name="${component_entry%%:*}"
    local comp_packages="${component_entry#*:}"

    if [[ "$comp_name" == "$component" ]]; then
      IFS="$old_ifs"
      echo "$comp_packages"
      return
    fi
  done
  IFS="$old_ifs"

  # If component not found, check if it's a valid package name
  local packages
  if is_cache_valid && [[ -n "$PACKAGE_CACHE" ]]; then
    packages="$PACKAGE_CACHE"
  else
    if ! fetch_available_packages; then
      echo ""
      return
    fi
    packages="$PACKAGE_CACHE"
  fi
  for package in $packages; do
    if [[ "$package" == "$component" ]]; then
      echo "$component"
      return
    fi
  done

  echo ""
}

# Function to get all available packages
get_all_packages() {
  if fetch_available_packages; then
    echo "$PACKAGE_CACHE"
  else
    echo ""
  fi
}

# Function to get packages from targets
get_packages_from_targets() {
  local result=""

  # Ensure SELECTED_TARGETS is set
  if [[ ${#SELECTED_TARGETS[@]} -eq 0 ]]; then
    echo ""
    return
  fi

  for target in "${SELECTED_TARGETS[@]}"; do
    case "$target" in
    all)
      local all_packages
      if ! all_packages=$(get_all_packages); then
        return 1
      fi
      for package in $all_packages; do
        if [[ -z "$result" ]]; then
          result="$package"
        else
          result="$result $package"
        fi
      done
      ;;
    *)
      # Check if it's a component group or specific package
      local component_packages
      component_packages=$(get_component_packages "$target")

      if [[ -n "$component_packages" ]]; then
        for package in $component_packages; do
          if [[ -z "$result" ]]; then
            result="$package"
          else
            result="$result $package"
          fi
        done
      else
        print_error "Invalid package or component name: $target"
        print_info "Available components and packages:"
        # Ensure the list is visible even when stdout is piped; write to stderr
        show_available_components 1>&2
        return 1
      fi
      ;;
    esac
  done

  # Remove duplicates while preserving order
  local unique_result=""
  if [[ -n "$result" ]]; then
    for package in $result; do
      local duplicate=false
      for upackage in $unique_result; do
        if [[ "$upackage" == "$package" ]]; then
          duplicate=true
          break
        fi
      done
      if [[ "$duplicate" == false ]]; then
        if [[ -z "$unique_result" ]]; then
          unique_result="$package"
        else
          unique_result="$unique_result $package"
        fi
      fi
    done
  fi

  echo "$unique_result"
}

# Function to show available components
show_available_components() {
  local components
  components=$(get_component_categories)

  if [[ -z "$components" ]]; then
    echo "  No packages available from repo $HELM_REPO_NAME at $HELM_REPO_URL"
    return
  fi

  local old_ifs="$IFS"
  IFS='|'
  for component_entry in $components; do
    local comp_name="${component_entry%%:*}"
    local comp_packages="${component_entry#*:}"

    # Normalize name: trim spaces and unify separators
    local comp_key
    comp_key=$(echo "$comp_name" | tr -d ' \t\r')
    case "$comp_key" in
    mysql-community)
      echo "  mysql-community: MySQL Community Server (all versions)"
      ;;
    mysql-router-community)
      echo "  mysql-router-community: MySQL Router Community (all versions)"
      ;;
    postgresql)
      echo "  postgresql: PostgreSQL Server (all versions)"
      ;;
    proxysql)
      echo "  proxysql: ProxySQL (all versions)"
      ;;
    pgbouncer)
      echo "  pgbouncer: PgBouncer (all versions)"
      ;;
    elasticsearch)
      echo "  elasticsearch: Elasticsearch"
      ;;
    kibana)
      echo "  kibana: Kibana"
      ;;
    kafka)
      echo "  kafka: Kafka"
      ;;
    redis)
      echo "  redis: Redis"
      ;;
    zookeeper)
      echo "  zookeeper: Zookeeper"
      ;;
    other)
      echo "  other: Other packages"
      ;;
    *)
      # Fallback to always show a section header to avoid missing titles
      echo "  ${comp_key}: Other packages"
      ;;
    esac

    # Show individual packages
    for package in $comp_packages; do
      echo "    - $package"
    done
    echo
  done
  IFS="$old_ifs"
}

# Function to install package
install_package() {
  local package_name="$1"
  local release_name="${RELEASE_PREFIX}-${package_name}"

  print_info "Installing UPM package: $package_name"

  # Idempotency:
  # - If release already deployed, skip
  # - If release exists but not deployed, converge with upgrade --install
  if is_release_deployed "$release_name"; then
    print_warning "Release $release_name already deployed, skipping install"
    return 0
  elif get_release_status "$release_name" >/dev/null 2>&1; then
    print_info "Release $release_name exists but status is not deployed, reconciling with upgrade --install"
    local up_cmd="helm upgrade"
    local up_opts=("--install" "--namespace=$NAMESPACE" "--timeout=$TIMEOUT")
    if [[ "$DRY_RUN" == true ]]; then
      up_opts+=("--dry-run" "--debug")
    fi
    up_opts+=("$release_name" "$HELM_REPO_NAME/$package_name")
    print_info "Running: $up_cmd ${up_opts[*]}"
    if $up_cmd "${up_opts[@]}"; then
      print_success "UPM package $package_name reconciled successfully as $release_name"
      if [[ "$DRY_RUN" != true ]]; then
        sleep 2
        verify_package_installation "$release_name" "$package_name"
      fi
      return 0
    else
      print_error "Failed to reconcile UPM package $package_name"
      return 1
    fi
  fi

  local helm_cmd="helm install"
  local helm_opts=()

  # Add namespace option
  helm_opts+=("--namespace=$NAMESPACE")

  # Add dry-run option if specified
  if [[ "$DRY_RUN" == true ]]; then
    helm_opts+=("--dry-run" "--debug")
  fi

  # Add timeout option
  helm_opts+=("--timeout=$TIMEOUT")

  # Add release name and package
  helm_opts+=("$release_name" "$HELM_REPO_NAME/$package_name")

  # Show the command being executed
  print_info "Running: $helm_cmd ${helm_opts[*]}"

  # Execute helm command
  local attempt=1
  local max_attempts=3
  local delays=(2 5 10)
  local installed=false
  while (( attempt <= max_attempts )); do
    if $helm_cmd "${helm_opts[@]}"; then
      installed=true
      break
    fi
    if (( attempt < max_attempts )); then
      print_warning "Install failed for $package_name (attempt $attempt/$max_attempts). Retrying in ${delays[$((attempt-1))]}s..."
      sleep "${delays[$((attempt-1))]}"
    fi
    ((attempt++))
  done

  if [[ "$installed" == true ]]; then
    print_success "UPM package $package_name installed successfully as $release_name"

    # Verify installation if not dry run
    if [[ "$DRY_RUN" != true ]]; then
      sleep 2
      verify_package_installation "$release_name" "$package_name"
    fi
  else
    print_error "Failed to install UPM package $package_name after $max_attempts attempts"
    return 1
  fi
}

# Function to uninstall package
uninstall_package() {
  local package_name="$1"
  local release_name="${RELEASE_PREFIX}-${package_name}"

  print_info "Uninstalling UPM package: $package_name"

  # Check if release exists
  if ! helm status "$release_name" --namespace="$NAMESPACE" &>/dev/null; then
    print_warning "Release $release_name not found, skipping..."
    return 0
  fi

  local helm_cmd="helm uninstall"
  local helm_opts=()

  # Add namespace option
  helm_opts+=("--namespace=$NAMESPACE")

  # Add dry-run option if specified
  if [[ "$DRY_RUN" == true ]]; then
    helm_opts+=("--dry-run")
  fi

  # Add release name
  helm_opts+=("$release_name")

  # Show the command being executed
  print_info "Running: $helm_cmd ${helm_opts[*]}"

  # Execute helm command
  if $helm_cmd "${helm_opts[@]}"; then
    print_success "UPM package $package_name uninstalled successfully"
  else
    print_error "Failed to uninstall UPM package $package_name"
    return 1
  fi
}

# Function to upgrade package
upgrade_package() {
  local package_name="$1"
  local release_name="${RELEASE_PREFIX}-${package_name}"

  print_info "Upgrading UPM package: $package_name"

  # Check if release exists
  if ! helm status "$release_name" --namespace="$NAMESPACE" &>/dev/null; then
    print_warning "Release $release_name not found, skipping..."
    return 0
  fi

  # Ensure helm repository is updated to get latest versions
  print_info "Updating helm repository to ensure latest versions..."
  if ! helm repo update "$HELM_REPO_NAME" >/dev/null 2>&1; then
    print_warning "Failed to update helm repository, continuing with upgrade..."
  fi

  local helm_cmd="helm upgrade"
  local helm_opts=()

  # Add namespace option
  helm_opts+=("--namespace=$NAMESPACE")

  # Add dry-run option if specified
  if [[ "$DRY_RUN" == true ]]; then
    helm_opts+=("--dry-run" "--debug")
  fi

  # Add timeout option
  helm_opts+=("--timeout=$TIMEOUT")

  # Add release name and package
  helm_opts+=("$release_name" "$HELM_REPO_NAME/$package_name")

  # Show the command being executed
  print_info "Running: $helm_cmd ${helm_opts[*]}"

  # Execute helm command
  if $helm_cmd "${helm_opts[@]}"; then
    print_success "UPM package $package_name upgraded successfully"

    # Verify installation if not dry run
    if [[ "$DRY_RUN" != true ]]; then
      sleep 2
      verify_package_installation "$release_name" "$package_name"
    fi
  else
    print_error "Failed to upgrade UPM package $package_name"
    return 1
  fi
}

# Function to filter UPM-managed releases
filter_upm_releases() {
  local releases="$1"

  if command -v jq &>/dev/null && [[ "$releases" == *"["* ]]; then
    # JSON mode - validate JSON first
    if echo "$releases" | jq . >/dev/null 2>&1; then
      # Return a JSON array for downstream processing/counting
      echo "$releases" | jq --arg prefix "$RELEASE_PREFIX" '[.[] | select(.name | startswith($prefix))]'
    else
      # Invalid JSON, return empty array
      echo "[]"
    fi
  else
    # Table mode - filter lines that start with the prefix
    echo "$releases" | grep -E "^${RELEASE_PREFIX}-" || echo ""
  fi
}

# Function to get UPM-managed releases only
get_upm_releases() {
  local output_format="$1" # "json" or "table"

  if [[ "$output_format" == "json" ]]; then
    local all_releases
    all_releases=$(helm list --namespace "$NAMESPACE" --output json 2>/dev/null || echo "[]")
    filter_upm_releases "$all_releases"
  else
    local all_releases
    all_releases=$(helm list --namespace "$NAMESPACE" --output table 2>/dev/null || echo "")
    if [[ -n "$all_releases" ]]; then
      echo "$all_releases" | awk -v p="${RELEASE_PREFIX}-" 'NR==1 || $0 ~ "^" p'
    fi
  fi
}

# Function to count UPM-managed releases
count_upm_releases() {
  local releases
  local count=0

  if command -v jq &>/dev/null; then
    releases=$(get_upm_releases "json")
    if echo "$releases" | jq . >/dev/null 2>&1; then
      count=$(echo "$releases" | jq '. | length' 2>/dev/null || echo "0")
    else
      count=0
    fi
  else
    releases=$(get_upm_releases "table")
    if [[ -n "$releases" ]]; then
      count=$(echo "$releases" | grep -c "^${RELEASE_PREFIX}-" || echo "0")
    fi
  fi

  echo "$count"
}

# Function to verify package installation
verify_package_installation() {
  local release_name="$1"
  local package_name="$2"

  print_info "Verifying UPM package installation: $release_name"

  # Check package status
  if helm status "$release_name" --namespace="$NAMESPACE" >/dev/null 2>&1; then
    print_success "UPM package $release_name verification passed"

    # Show package status
    echo "Package Status:"
    helm status "$release_name" --namespace="$NAMESPACE" | head -10
    echo
  else
    print_warning "UPM package $release_name verification failed"
  fi
}

# Function to list available packages
list_packages() {
  print_header "Available UPM Packages"
  echo

  show_available_components

  print_header "Installed UPM Releases"
  echo
  local releases
  releases=$(get_upm_releases "table")
  if [[ -n "$releases" && "$releases" != "[]" ]]; then
    echo "$releases"
  else
    echo "No UPM releases found in namespace $NAMESPACE"
  fi
}

# Function to show status of installed packages
show_status() {
  print_header "UPM Packages Status"
  echo

  local installed_count
  installed_count=$(count_upm_releases)

  print_info "Found $installed_count UPM package releases in namespace $NAMESPACE"

  if [[ "$installed_count" -gt 0 ]]; then
    echo
    get_upm_releases "table"
  else
    print_warning "No UPM package releases found in namespace $NAMESPACE"
  fi
}

# Function to execute action on packages
execute_action() {
  local package_list
  # Pre-fetch package list once in parent shell to populate cache for subshells
  fetch_available_packages >/dev/null 2>&1 || true

  if ! package_list=$(get_packages_from_targets); then
    return 1
  fi

  if [[ -z "$package_list" ]]; then
    print_warning "No packages to process"
    return 0
  fi

  local packages
  read -ra packages <<<"$package_list"

  print_info "Processing ${#packages[@]} packages for $ACTION action"
  echo

  local failed_packages=()

  for package in "${packages[@]}"; do
    case "$ACTION" in
    install)
      if ! install_package "$package"; then
        failed_packages+=("$package")
      fi
      ;;
    uninstall)
      if ! uninstall_package "$package"; then
        failed_packages+=("$package")
      fi
      ;;
    upgrade)
      if ! upgrade_package "$package"; then
        failed_packages+=("$package")
      fi
      ;;
    esac

    # Add delay between operations if not dry run
    if [[ "$DRY_RUN" != true ]]; then
      sleep 3
    fi
  done

  # Print summary
  if [[ ${#failed_packages[@]} -eq 0 ]]; then
    print_success "All packages processed successfully!"
  else
    print_error "Failed to process the following packages:"
    for package in "${failed_packages[@]}"; do
      echo "  - $package"
    done
    return 1
  fi
}

# Main function
main() {
  print_header "UPM Package Management"
  echo

  parse_args "$@"

  case "$ACTION" in
  list)
    check_prerequisites
    list_packages
    ;;
  status)
    check_prerequisites
    show_status
    ;;
  install | uninstall | upgrade)
    check_prerequisites
    create_namespace
    add_helm_repo

    if execute_action; then
      print_success "$ACTION action completed successfully!"
    else
      print_error "$ACTION action completed with errors"
      exit 1
    fi
    ;;
  esac
}

# Run main function
main "$@"
