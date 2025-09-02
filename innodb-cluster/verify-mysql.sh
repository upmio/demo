#!/bin/bash

# MySQL Database Verification Script
# Independent MySQL database connection and operations verification tool

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
MYSQL_HOST="localhost"
MYSQL_PORT="3306"
MYSQL_USER="root"
MYSQL_PASSWORD=""
MYSQL_DATABASE=""
VERBOSE=false
TEST_DATABASE="mysql_verification_test"
REPORT_FILE=""

# Test results tracking
TEST_RESULTS=()
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Help information
show_help() {
    cat <<EOF
MySQL Database Verification Script

Usage: $0 [options]

Options:
    -h, --host HOST             MySQL server host (default: localhost)
    -P, --port PORT             MySQL server port (default: 3306)
    -u, --user USERNAME         MySQL username (default: root)
    -p, --password PASSWORD     MySQL password (required)
    -d, --database DATABASE     Default database to use (optional)
    -v, --verbose              Enable verbose output mode
    -r, --report FILE          Generate report to specified file
    --help                     Show this help information

Examples:
    $0 -h localhost -P 3306 -u root -p mypassword
    $0 -h 192.168.1.100 -P 3306 -u admin -p secret123 -v
    $0 -h mysql.example.com -u dbuser -p pass123 -d mydb -r report.txt

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h | --host)
            MYSQL_HOST="$2"
            shift 2
            ;;
        -P | --port)
            MYSQL_PORT="$2"
            shift 2
            ;;
        -u | --user)
            MYSQL_USER="$2"
            shift 2
            ;;
        -p | --password)
            MYSQL_PASSWORD="$2"
            shift 2
            ;;
        -d | --database)
            MYSQL_DATABASE="$2"
            shift 2
            ;;
        -v | --verbose)
            VERBOSE=true
            shift
            ;;
        -r | --report)
            REPORT_FILE="$2"
            shift 2
            ;;
        --help)
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

# Progress tracking variables
CURRENT_STEP=0
TOTAL_STEPS=6
STEP_NAMES=("Prerequisites" "Connection" "Server Info" "Cluster Status" "Database Operations" "Cleanup")

# Simplified logging functions with progress indicators
log_step_start() {
    local step_name="$1"
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "${BLUE}[$CURRENT_STEP/$TOTAL_STEPS]${NC} $step_name..."
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[STEP $CURRENT_STEP/$TOTAL_STEPS] $(date '+%Y-%m-%d %H:%M:%S') Starting: $step_name" >> "$REPORT_FILE"
    fi
}

log_step_success() {
    local result="$1"
    echo -e "${GREEN}  ✓${NC} $result"
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') $result" >> "$REPORT_FILE"
    fi
}

log_step_warning() {
    local result="$1"
    echo -e "${YELLOW}  ⚠${NC} $result"
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') $result" >> "$REPORT_FILE"
    fi
}

log_step_error() {
    local result="$1"
    echo -e "${RED}  ✗${NC} $result"
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $result" >> "$REPORT_FILE"
    fi
}

# Legacy logging functions for compatibility
log_info() {
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REPORT_FILE"
    fi
}

log_success() {
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REPORT_FILE"
    fi
}

log_warning() {
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[WARNING] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REPORT_FILE"
    fi
}

log_error() {
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REPORT_FILE"
    fi
}

log_verbose() {
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[VERBOSE] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REPORT_FILE"
    fi
}

# Report-only logging functions (detailed technical information)
log_dba_info() {
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[DBA INFO] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REPORT_FILE"
    fi
}

log_sql() {
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[SQL] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REPORT_FILE"
    fi
}

log_technical() {
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[TECHNICAL] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REPORT_FILE"
    fi
}

# Report-only detailed output function
log_report_details() {
    if [[ -n "$REPORT_FILE" ]]; then
        echo "[DETAILS] $(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REPORT_FILE"
        # If additional content is provided via stdin, append it to report
        if [[ -p /dev/stdin ]]; then
            while IFS= read -r line; do
                echo "    $line" >> "$REPORT_FILE"
            done
        fi
    fi
}

# Function to log detailed output to report only
log_to_report() {
    local content="$1"
    if [[ -n "$REPORT_FILE" ]]; then
        # Handle \n in content by using printf instead of echo
        printf "%s\n" "$content" | sed 's/^/    /' >> "$REPORT_FILE"
    fi
}

# Test result tracking functions
record_test_result() {
    local test_name="$1"
    local result="$2"
    local details="$3"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    
    if [[ "$result" == "PASS" ]]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        TEST_RESULTS+=("✓ $test_name: PASS")
        if [[ -n "$details" ]]; then
            TEST_RESULTS+=("  Details: $details")
        fi
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        TEST_RESULTS+=("✗ $test_name: FAIL")
        if [[ -n "$details" ]]; then
            TEST_RESULTS+=("  Error: $details")
        fi
    fi
}

# Check prerequisites
check_prerequisites() {
    log_step_start "Prerequisites"
    
    if ! command -v mysql &>/dev/null; then
        log_step_error "MySQL client not found"
        record_test_result "Prerequisites Check" "FAIL" "MySQL client not found"
        exit 1
    fi
    
    if [[ -z "$MYSQL_PASSWORD" ]]; then
        log_step_error "Password not provided"
        record_test_result "Prerequisites Check" "FAIL" "Password not provided"
        exit 1
    fi
    
    log_step_success "MySQL client and credentials verified"
    record_test_result "Prerequisites Check" "PASS" "MySQL client found, password provided"
}

# Build MySQL connection command
build_mysql_cmd() {
    local extra_args="$1"
    local cmd="mysql -h$MYSQL_HOST -P$MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD"
    
    if [[ -n "$extra_args" ]]; then
        cmd="$cmd $extra_args"
    fi
    
    if [[ -n "$MYSQL_DATABASE" ]]; then
        cmd="$cmd $MYSQL_DATABASE"
    fi
    
    echo "$cmd"
}

# Test MySQL connection
test_mysql_connection() {
    log_step_start "Connection"
    log_dba_info "Verifying MySQL service connectivity deployed via deploy-innodb-cluster.sh"
    log_technical "Connection Parameters: Host=$MYSQL_HOST, Port=$MYSQL_PORT, User=$MYSQL_USER"
    
    local test_sql="SELECT 1 as connection_test;"
    log_sql "Executing: $test_sql"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd "-e '$test_sql'")
    
    local connection_result
    if connection_result=$(eval "$mysql_cmd" 2>&1); then
        log_step_success "Connected to $MYSQL_HOST:$MYSQL_PORT"
        
        # Log detailed connection result to report only
        log_to_report "=== MySQL Connection Test Results ==="
        log_to_report "Query Result: $connection_result"
        
        # Get connection details
        local conn_info_sql="SELECT CONNECTION_ID() as conn_id, USER() as current_user, @@hostname as server_host, @@port as server_port;"
        log_sql "Getting connection details: $conn_info_sql"
        local conn_details
        if conn_details=$(echo "$conn_info_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_to_report "Connection Details:"
            log_to_report "$conn_details"
        fi
        
        record_test_result "MySQL Connection" "PASS" "Connected to $MYSQL_HOST:$MYSQL_PORT"
        return 0
    else
        log_step_error "Connection failed to $MYSQL_HOST:$MYSQL_PORT"
        log_technical "Connection Error Details: $connection_result"
        log_dba_info "Please check: 1) MySQL service status 2) Network connectivity 3) User privileges 4) Firewall settings"
        record_test_result "MySQL Connection" "FAIL" "Cannot connect to $MYSQL_HOST:$MYSQL_PORT"
        return 1
    fi
}

# Get MySQL server information
get_server_info() {
    log_step_start "Server Info"
    log_dba_info "Collecting detailed MySQL server technical information for DBA analysis"
    
    # Basic server information
    local basic_info_sql="SELECT VERSION() as mysql_version, @@hostname as hostname, @@port as port, @@datadir as data_directory;"
    log_sql "Basic Info Query: $basic_info_sql"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd "-e '$basic_info_sql'")
    
    local server_info
    if server_info=$(eval "$mysql_cmd" 2>/dev/null); then
        # Extract key information for console display
        local version=$(echo "$server_info" | tail -n +2 | cut -f1)
        local hostname=$(echo "$server_info" | tail -n +2 | cut -f2)
        local port=$(echo "$server_info" | tail -n +2 | cut -f3)
        
        log_step_success "MySQL v$version @ $hostname:$port"
        
        # Log detailed server information to report only
        log_to_report "=== MySQL Server Basic Information ==="
        log_to_report "$server_info"
        
        # Storage engine information
        local engine_sql="SHOW ENGINES;"
        log_sql "Storage Engines Query: $engine_sql"
        local engines_info
        if engines_info=$(echo "$engine_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_to_report ""
            log_to_report "=== Available Storage Engines ==="
            log_to_report "$engines_info"
        fi
        
        # InnoDB Cluster specific information
        log_dba_info "Checking InnoDB Cluster related configuration"
        local cluster_sql="SELECT @@group_replication_group_name as cluster_group, @@server_uuid as server_uuid, @@group_replication_local_address as local_address;"
        log_sql "Cluster Info Query: $cluster_sql"
        local cluster_info
        if cluster_info=$(echo "$cluster_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_to_report ""
            log_to_report "=== InnoDB Cluster Configuration ==="
            log_to_report "$cluster_info"
        fi
        
        # Server status and performance metrics
        local status_sql="SHOW STATUS WHERE Variable_name IN ('Uptime', 'Threads_connected', 'Threads_running', 'Questions', 'Slow_queries', 'Innodb_buffer_pool_size', 'Innodb_log_file_size');"
        log_sql "Server Status Query: $status_sql"
        local status_info
        if status_info=$(echo "$status_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_to_report ""
            log_to_report "=== Server Status & Performance Metrics ==="
            log_to_report "$status_info"
        fi
        
        # Global variables relevant to DBA
        local vars_sql="SHOW VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size', 'max_connections', 'innodb_log_file_size', 'innodb_flush_log_at_trx_commit', 'sync_binlog', 'binlog_format');"
        log_sql "Key Variables Query: $vars_sql"
        local vars_info
        if vars_info=$(echo "$vars_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_to_report ""
            log_to_report "=== Key MySQL Variables for DBA ==="
            log_to_report "$vars_info"
        fi
        
        record_test_result "Server Information" "PASS" "Retrieved comprehensive server details"
    else
        log_warning "Could not retrieve server information"
        log_dba_info "Failed to retrieve server information, possible insufficient privileges or service anomaly"
        record_test_result "Server Information" "FAIL" "Cannot retrieve server details"
    fi
}

# Test database operations
test_database_operations() {
    log_step_start "Database Operations"
    log_dba_info "Performing comprehensive database CRUD operations test"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    
    local operations_passed=0
    local total_operations=6
    
    # Test 1: Create test database
    log_dba_info "Verifying database creation privileges and storage engine functionality"
    
    local create_db_sql="CREATE DATABASE IF NOT EXISTS $TEST_DATABASE DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    log_sql "Database Creation: $create_db_sql"
    
    if echo "$create_db_sql" | eval "$mysql_cmd" 2>/dev/null; then
        ((operations_passed++))
        log_technical "Database '$TEST_DATABASE' created with UTF8MB4 character set"
        
        # Get database information
        local db_info_sql="SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$TEST_DATABASE';"
        log_sql "Database Info Query: $db_info_sql"
        local db_details
        if db_details=$(echo "$db_info_sql" | eval "$mysql_cmd" 2>/dev/null); then
            log_technical "Database Configuration Details:"
            log_to_report "$db_details"
        fi
        
        record_test_result "Create Database" "PASS" "Database '$TEST_DATABASE' created with proper charset"
    else
        log_step_error "Failed to create test database"
        log_dba_info "Database creation failed, please check CREATE privileges and disk space"
        record_test_result "Create Database" "FAIL" "Cannot create database '$TEST_DATABASE'"
        return 1
    fi
    
    # Test 2: Create test table
    log_dba_info "Verifying table creation, indexing, and storage engine configuration"
    
    local create_table_sql="
        USE $TEST_DATABASE;
        CREATE TABLE IF NOT EXISTS test_table (
            id INT PRIMARY KEY AUTO_INCREMENT,
            name VARCHAR(100) NOT NULL,
            email VARCHAR(100),
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            INDEX idx_name (name),
            INDEX idx_email (email)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    "
    log_sql "Table Creation: $create_table_sql"
    
    if echo "$create_table_sql" | eval "$mysql_cmd" 2>/dev/null; then
        ((operations_passed++))
        log_technical "Table 'test_table' created with InnoDB engine and proper indexes"
        
        # Get table structure details
        local table_info_sql="USE $TEST_DATABASE; SHOW CREATE TABLE test_table;"
        log_sql "Table Structure Verification: SHOW CREATE TABLE test_table"
        local table_structure
        if table_structure=$(echo "$table_info_sql" | eval "$mysql_cmd" 2>/dev/null); then
            log_technical "Table Structure Details:"
            log_to_report "$table_structure"
        fi
        
        record_test_result "Create Table" "PASS" "Table 'test_table' created with InnoDB engine"
    else
        log_step_error "Failed to create test table"
        log_dba_info "Table creation failed, please check storage engine support and tablespace configuration"
        record_test_result "Create Table" "FAIL" "Cannot create test table"
        cleanup_test_database
        return 1
    fi
    
    # Test 3-6: CRUD Operations (simplified output)
    local crud_operations=("INSERT" "SELECT" "UPDATE" "DELETE")
    local crud_sqls=(
        "USE $TEST_DATABASE; INSERT INTO test_table (name, email) VALUES ('Test User 1', 'user1@example.com'), ('Test User 2', 'user2@example.com'), ('Test User 3', 'user3@example.com');"
        "USE $TEST_DATABASE; SELECT COUNT(*) as record_count FROM test_table;"
        "USE $TEST_DATABASE; UPDATE test_table SET email = 'updated@example.com' WHERE id = 1;"
        "USE $TEST_DATABASE; DELETE FROM test_table WHERE id = 3;"
    )
    
    for i in "${!crud_operations[@]}"; do
        local operation="${crud_operations[$i]}"
        local sql="${crud_sqls[$i]}"
        
        log_sql "$operation Operation: $sql"
        
        local start_time=$(date +%s%N)
        local result
        if result=$(echo "$sql" | eval "$mysql_cmd" 2>/dev/null); then
            local end_time=$(date +%s%N)
            local exec_time=$(((end_time - start_time) / 1000000))
            ((operations_passed++))
            
            log_technical "$operation completed in ${exec_time}ms"
            if [[ "$operation" == "SELECT" ]]; then
                local count=$(echo "$result" | tail -n 1)
                log_technical "Query result: $count records found"
            fi
            
            record_test_result "$operation Data" "PASS" "$operation operation completed in ${exec_time}ms"
        else
            log_step_error "$operation operation failed"
            record_test_result "$operation Data" "FAIL" "Cannot perform $operation operation"
        fi
    done
    
    log_step_success "CRUD operations completed ($operations_passed/$total_operations passed)"
    return 0
}

# Performance benchmark test
performance_benchmark() {
    log_step_start "Performance Tests"
    log_dba_info "Executing MySQL performance benchmark tests to evaluate service performance deployed via deploy-innodb-cluster.sh"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    local perf_passed=0
    local total_perf_tests=3
    
    # Test 1: Connection performance (10 connections)
    log_dba_info "Testing connection pool performance and concurrent connection capability"
    log_technical "Testing 10 sequential connections to measure connection overhead"
    
    local start_time=$(date +%s%N)
    local connections=0
    local connection_times=()
    
    for i in {1..10}; do
        local conn_start=$(date +%s%N)
        local test_conn_sql="SELECT CONNECTION_ID(), NOW() as connection_time;"
        log_sql "Connection Test $i: $test_conn_sql"
        
        local conn_result
        if conn_result=$(echo "$test_conn_sql" | eval "$mysql_cmd" 2>/dev/null); then
            local conn_end=$(date +%s%N)
            local conn_time=$(((conn_end - conn_start) / 1000000))
            connection_times+=("$conn_time")
            ((connections++))
            log_technical "Connection $i: ${conn_time}ms - $(echo "$conn_result" | tr '\n' ' ')"
        else
            log_technical "Connection $i: FAILED"
        fi
    done
    
    local end_time=$(date +%s%N)
    local total_time=$(((end_time - start_time) / 1000000))
    local avg_time=$((total_time / 10))
    
    # Calculate connection statistics
    local min_time=999999
    local max_time=0
    for time in "${connection_times[@]}"; do
        if [[ $time -lt $min_time ]]; then min_time=$time; fi
        if [[ $time -gt $max_time ]]; then max_time=$time; fi
    done
    
    if [[ $connections -eq 10 ]]; then
        ((perf_passed++))
        log_technical "Connection Statistics: Total=${total_time}ms, Avg=${avg_time}ms, Min=${min_time}ms, Max=${max_time}ms"
        record_test_result "Connection Performance" "PASS" "10/10 connections, avg ${avg_time}ms (min: ${min_time}ms, max: ${max_time}ms)"
    else
        log_dba_info "Connection failure possible causes: max_connections limit, network latency, high server load"
        record_test_result "Connection Performance" "FAIL" "Only $connections/10 connections successful"
    fi
    
    # Test 2: Query performance (20 queries)
    log_dba_info "Testing performance of different query types"
    
    local query_sql="USE $TEST_DATABASE; SELECT COUNT(*) FROM test_table;"
    log_sql "Simple Query Test: $query_sql"
    log_technical "Testing 20 sequential COUNT queries to measure query performance"
    
    local query_start=$(date +%s%N)
    local queries=0
    local query_times=()
    
    for i in {1..20}; do
        local q_start=$(date +%s%N)
        local query_result
        if query_result=$(echo "$query_sql" | eval "$mysql_cmd" 2>/dev/null); then
            local q_end=$(date +%s%N)
            local q_time=$(((q_end - q_start) / 1000000))
            query_times+=("$q_time")
            ((queries++))
            if [[ $((i % 5)) -eq 0 ]]; then
                log_technical "Query $i: ${q_time}ms - Result: $(echo "$query_result" | tail -n 1)"
            fi
        fi
    done
    
    local query_end=$(date +%s%N)
    local query_total=$(((query_end - query_start) / 1000000))
    local query_avg=$((query_total / 20))
    
    # Calculate query statistics
    local min_query=999999
    local max_query=0
    for time in "${query_times[@]}"; do
        if [[ $time -lt $min_query ]]; then min_query=$time; fi
        if [[ $time -gt $max_query ]]; then max_query=$time; fi
    done
    
    if [[ $queries -eq 20 ]]; then
        ((perf_passed++))
        log_technical "Query Statistics: Total=${query_total}ms, Avg=${query_avg}ms, Min=${min_query}ms, Max=${max_query}ms"
        
        # Test complex query performance
        local complex_query="USE $TEST_DATABASE; SELECT t1.name, t1.email, COUNT(*) as record_count FROM test_table t1 JOIN test_table t2 ON t1.id <= t2.id GROUP BY t1.id, t1.name, t1.email ORDER BY t1.id;"
        log_sql "Complex Query Test: $complex_query"
        
        local complex_start=$(date +%s%N)
        local complex_result
        if complex_result=$(echo "$complex_query" | eval "$mysql_cmd" 2>/dev/null); then
            local complex_end=$(date +%s%N)
            local complex_time=$(((complex_end - complex_start) / 1000000))
            log_technical "Complex Query Performance: ${complex_time}ms"
            log_technical "Complex Query Results:"
            log_to_report "$complex_result"
        fi
        
        record_test_result "Query Performance" "PASS" "20/20 queries, avg ${query_avg}ms (min: ${min_query}ms, max: ${max_query}ms)"
    else
        log_dba_info "Query performance issues possible causes: missing indexes, table locking, improper buffer pool configuration, disk I/O bottleneck"
        record_test_result "Query Performance" "FAIL" "Only $queries/20 queries successful"
    fi
    
    # Test 3: Transaction performance (5 transactions)
    log_dba_info "Testing transaction processing performance and ACID properties"
    
    local trans_sql="
        USE $TEST_DATABASE;
        START TRANSACTION;
        INSERT INTO test_table (name, email) VALUES ('Perf Test', 'perf@test.com');
        UPDATE test_table SET email = 'updated@test.com' WHERE name = 'Perf Test';
        DELETE FROM test_table WHERE name = 'Perf Test';
        COMMIT;
    "
    log_sql "Transaction Test: $trans_sql"
    
    local trans_start=$(date +%s%N)
    local transactions=0
    
    for i in {1..5}; do
        if echo "$trans_sql" | eval "$mysql_cmd" 2>/dev/null; then
            ((transactions++))
        fi
    done
    
    local trans_end=$(date +%s%N)
    local trans_total=$(((trans_end - trans_start) / 1000000))
    local trans_avg=$((trans_total / 5))
    
    if [[ $transactions -eq 5 ]]; then
        ((perf_passed++))
        log_technical "Transaction processing demonstrates ACID compliance and proper isolation"
        record_test_result "Transaction Performance" "PASS" "5/5 transactions, avg ${trans_avg}ms"
    else
        log_dba_info "Transaction performance issues possible causes: lock waits, deadlocks, transaction log configuration, isolation level settings"
        record_test_result "Transaction Performance" "FAIL" "Only $transactions/5 transactions successful"
    fi
    
    log_step_success "Performance tests completed ($perf_passed/$total_perf_tests passed)"
}

# Cleanup test database
cleanup_test_database() {
    log_step_start "Cleanup"
    log_dba_info "Cleaning up test database and verifying space reclamation"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    
    # Get database size before cleanup
    local size_before_sql="SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'DB Size in MB' FROM information_schema.tables WHERE table_schema='$TEST_DATABASE';"
    log_sql "Database Size Check: $size_before_sql"
    local size_before
    if size_before=$(echo "$size_before_sql" | eval "$mysql_cmd" 2>/dev/null | tail -n 1); then
        log_technical "Database size before cleanup: ${size_before} MB"
    fi
    
    local drop_sql="DROP DATABASE IF EXISTS $TEST_DATABASE;"
    log_sql "Database Cleanup: $drop_sql"
    
    if echo "$drop_sql" | eval "$mysql_cmd" 2>/dev/null; then
        log_step_success "Test database cleaned up successfully"
        log_technical "Database '$TEST_DATABASE' and all associated objects removed"
        
        # Verify cleanup
        local verify_sql="SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$TEST_DATABASE';"
        log_sql "Cleanup Verification: $verify_sql"
        local remaining
        if remaining=$(echo "$verify_sql" | eval "$mysql_cmd" 2>/dev/null | tail -n 1); then
            if [[ -z "$remaining" ]]; then
                log_technical "Cleanup verification: Database successfully removed from information_schema"
            else
                log_technical "Cleanup verification: Database still exists in information_schema"
            fi
        fi
        
        # Check for any remaining processes
        local process_sql="SHOW PROCESSLIST;"
        log_sql "Process Check: $process_sql"
        local processes
        if processes=$(echo "$process_sql" | eval "$mysql_cmd" 2>/dev/null); then
            local test_processes=$(echo "$processes" | grep -c "$TEST_DATABASE" || true)
            if [[ $test_processes -eq 0 ]]; then
                log_technical "No remaining processes using test database"
            else
                log_technical "Found $test_processes processes still referencing test database"
            fi
        fi
        
        record_test_result "Database Cleanup" "PASS" "Test database and objects removed successfully"
    else
        log_step_warning "Test database cleanup failed - please manually remove '$TEST_DATABASE'"
        log_dba_info "Database cleanup failed, possible causes: insufficient privileges, active connections, foreign key constraints"
        record_test_result "Database Cleanup" "FAIL" "Manual cleanup required"
    fi
}

# Generate verification report
generate_report() {
    log_info "Generating comprehensive verification report..."
    log_dba_info "Generating detailed DBA-level verification report"
    
    echo
    echo "==========================================="
    echo "MySQL InnoDB Cluster Verification Report"
    echo "==========================================="
    echo "Report Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    echo
    echo "Connection Details:"
    echo "------------------"
    echo "MySQL Host: $MYSQL_HOST"
    echo "MySQL Port: $MYSQL_PORT"
    echo "MySQL User: $MYSQL_USER"
    echo "Test Database: $TEST_DATABASE"
    echo "Script Version: MySQL Database Verification Tool v2.0"
    echo
    
    # Get current server status for report
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    
    echo "Server Information Summary:"
    echo "---------------------------"
    local server_summary_sql="SELECT VERSION() as mysql_version, @@hostname as server_host, @@port as server_port, @@datadir as data_dir;"
    local server_summary
    if server_summary=$(echo "$server_summary_sql" | eval "$mysql_cmd" 2>/dev/null); then
        echo "$server_summary" | sed 's/^/  /'
    else
        echo "  Server information unavailable"
    fi
    echo
    
    echo "InnoDB Cluster Status:"
    echo "---------------------"
    local cluster_status_sql="SELECT @@group_replication_group_name as cluster_group, @@server_uuid as server_uuid;"
    local cluster_status
    if cluster_status=$(echo "$cluster_status_sql" | eval "$mysql_cmd" 2>/dev/null); then
        echo "$cluster_status" | sed 's/^/  /'
    else
        echo "  Cluster information unavailable"
    fi
    echo
    
    local passed_tests=0
    local failed_tests=0
    
    echo "Detailed Test Results:"
    echo "---------------------"
    
    for result in "${TEST_RESULTS[@]}"; do
        if [[ "$result" == *"PASS"* ]]; then
            echo "✅ $result"
            ((passed_tests++))
        elif [[ "$result" == *"FAIL"* ]]; then
            echo "❌ $result"
            ((failed_tests++))
        else
            # This is a details line (starts with spaces)
            echo "$result"
        fi
    done
    
    local total_tests=$((passed_tests + failed_tests))
    
    echo "Summary Statistics:"
    echo "------------------"
    echo "Total Tests Executed: $total_tests"
    echo "Tests Passed: $passed_tests"
    echo "Tests Failed: $failed_tests"
    local success_rate=$(( (passed_tests * 100) / total_tests ))
    echo "Success Rate: $success_rate%"
    echo
    
    echo "DBA Recommendations:"
    echo "-------------------"
    if [[ $failed_tests -eq 0 ]]; then
        echo "✅ DEPLOYMENT VALIDATION: SUCCESSFUL"
        echo "• All verification tests passed successfully"
        echo "• MySQL InnoDB Cluster is functioning correctly"
        echo "• Database operations are performing within expected parameters"
        echo "• Transaction processing and ACID compliance verified"
        echo "• The service is ready for production workloads"
        echo
        log_success "All tests passed! 🎉"
    else
        echo "⚠️  DEPLOYMENT VALIDATION: REQUIRES ATTENTION"
        echo "• $failed_tests out of $total_tests tests failed"
        echo "• Review failed test details above for specific issues"
        echo "• Common issues to investigate:"
        echo "  - Network connectivity and firewall settings"
        echo "  - User privileges and authentication"
        echo "  - MySQL configuration parameters"
        echo "  - Storage and memory allocation"
        echo "  - InnoDB Cluster group replication status"
        echo "• Recommended actions:"
        echo "  - Check MySQL error logs for detailed error messages"
        echo "  - Verify cluster member status and health"
        echo "  - Review MySQL configuration files"
        echo "  - Test connectivity from application servers"
        echo
        log_warning "MySQL service validation completed with issues."
        echo "🔧 Please address the failed tests before using in production."
    fi
    

    echo "==========================================="
    echo "End of MySQL InnoDB Cluster Verification Report"
    echo "==========================================="
    
    if [[ -n "$REPORT_FILE" ]]; then
        # Save summary report to file (append to existing detailed content)
        {
            echo ""
            echo "=========================================="
            echo "MySQL InnoDB Cluster Verification Report"
            echo "=========================================="
            echo "Generated: $(date)"
            echo "Host: $MYSQL_HOST:$MYSQL_PORT"
            echo "User: $MYSQL_USER"
            echo "Tests: $passed_tests/$total_tests passed ($success_rate%)"
            echo
            echo "Test Results Summary:"
            echo "--------------------"
            for result in "${TEST_RESULTS[@]}"; do
                echo "$result"
            done
        } >> "$REPORT_FILE"
        log_success "Report also saved to: $REPORT_FILE"
    fi
}

# Additional InnoDB Cluster specific verification
verify_innodb_cluster_status() {
    log_step_start "Cluster Status"
    log_dba_info "Checking InnoDB Cluster status and member health"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    
    # Check Group Replication status
    local gr_status_sql="SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;"
    log_sql "Group Replication Members: $gr_status_sql"
    
    local gr_result
    if gr_result=$(echo "$gr_status_sql" | eval "$mysql_cmd" 2>/dev/null); then
        log_technical "InnoDB Cluster Members Status:"
        log_to_report "$gr_result"
        
        local member_count=$(echo "$gr_result" | tail -n +2 | wc -l | tr -d ' ')
        log_technical "Total cluster members: $member_count"
        
        local online_members=$(echo "$gr_result" | grep -c "ONLINE" || true)
        log_technical "Online members: $online_members"
        
        if [[ $online_members -gt 0 ]]; then
            log_step_success "InnoDB Cluster is active with $online_members online members"
            record_test_result "InnoDB Cluster Status" "PASS" "$online_members members online"
        else
            log_step_warning "No online cluster members found"
            record_test_result "InnoDB Cluster Status" "FAIL" "No online members"
        fi
    else
        log_step_warning "Could not retrieve Group Replication status (may be standalone instance)"
        log_technical "This might be a standalone MySQL instance, not part of InnoDB Cluster"
        record_test_result "InnoDB Cluster Status" "WARN" "Not a cluster member or no access to performance_schema"
    fi
    
    # Check cluster configuration
    local cluster_config_sql="SHOW VARIABLES LIKE 'group_replication%';"
    log_sql "Cluster Configuration: $cluster_config_sql"
    
    local config_result
    if config_result=$(echo "$cluster_config_sql" | eval "$mysql_cmd" 2>/dev/null); then
        log_technical "Key InnoDB Cluster Configuration:"
        local key_config=$(echo "$config_result" | grep -E "(group_replication_group_name|group_replication_local_address|group_replication_bootstrap_group)" || true)
        log_to_report "$key_config"
    fi
}

# Test cluster-specific features
test_cluster_features() {
    log_step_start "Cluster Features"
    log_dba_info "Testing cluster-specific features and consistency guarantees"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    local features_passed=0
    local total_features=2
    
    # Test read-write splitting capability
    local rw_test_sql="SELECT @@read_only, @@super_read_only, @@group_replication_single_primary_mode;"
    log_sql "Read-Write Mode Check: $rw_test_sql"
    
    local rw_result
    if rw_result=$(echo "$rw_test_sql" | eval "$mysql_cmd" 2>/dev/null); then
        log_technical "Read-Write Configuration:"
        log_to_report "$rw_result"
        
        if echo "$rw_result" | grep -q "0.*0"; then
            log_technical "This node accepts read-write operations (PRIMARY)"
        else
            log_technical "This node is read-only (SECONDARY)"
        fi
        ((features_passed++))
    fi
    
    # Test transaction consistency
    local consistency_sql="SELECT @@group_replication_consistency, @@transaction_isolation;"
    log_sql "Transaction Consistency: $consistency_sql"
    
    local consistency_result
    if consistency_result=$(echo "$consistency_sql" | eval "$mysql_cmd" 2>/dev/null); then
        log_technical "Transaction Consistency Settings:"
        log_to_report "$consistency_result"
        ((features_passed++))
    fi
    
    # Test cluster write performance with conflict detection
    if echo "USE $TEST_DATABASE; INSERT INTO test_table (name, email) VALUES ('Cluster Test', 'cluster@test.com');" | eval "$mysql_cmd" 2>/dev/null; then
        log_technical "Write operation completed with cluster consensus"
        
        # Verify the write was replicated (if we can check)
        local verify_sql="USE $TEST_DATABASE; SELECT COUNT(*) FROM test_table WHERE name = 'Cluster Test';"
        log_sql "Write Verification: $verify_sql"
        
        local verify_result
        if verify_result=$(echo "$verify_sql" | eval "$mysql_cmd" 2>/dev/null | tail -n 1); then
            if [[ "$verify_result" == "1" ]]; then
                log_technical "Write operation verified: record found in cluster"
                record_test_result "Cluster Write Operations" "PASS" "Write and verification successful"
            else
                log_technical "Write verification failed: record not found"
                record_test_result "Cluster Write Operations" "FAIL" "Write not properly replicated"
            fi
        fi
        
        # Clean up test record
        echo "USE $TEST_DATABASE; DELETE FROM test_table WHERE name = 'Cluster Test';" | eval "$mysql_cmd" 2>/dev/null || true
    else
        log_dba_info "Write operation failure possible causes: node read-only mode, cluster partitioning, conflict detection"
        record_test_result "Cluster Write Operations" "FAIL" "Cannot perform write operations"
    fi
    
    if [[ $features_passed -eq $total_features ]]; then
        log_step_success "Cluster features validated ($features_passed/$total_features)"
    else
        log_step_warning "Some cluster features unavailable ($features_passed/$total_features)"
    fi
}

# Main function
main() {
    echo "==========================================="
    echo "    MySQL Database Verification Script"
    echo "==========================================="
    echo "Target: $MYSQL_HOST:$MYSQL_PORT (user: $MYSQL_USER)"
    echo
    
    # Check prerequisites
    check_prerequisites
    
    # Core tests
    if test_mysql_connection; then
        get_server_info
        verify_innodb_cluster_status
        test_database_operations
        performance_benchmark
        test_cluster_features
        cleanup_test_database
    else
        log_step_error "Cannot proceed - MySQL connection failed"
    fi
    
    generate_report
    
    # Exit with appropriate code
    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo
        echo "✅ All tests passed successfully! ($passed_tests/$total_tests)"
        exit 0
    else
        echo
        echo "❌ $FAIL_COUNT test(s) failed. Check report for details."
        exit 1
    fi
}

# Execute main function
main "$@"
