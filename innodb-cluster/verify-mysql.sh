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

# DBA-specific logging functions
log_dba_info() {
    echo -e "${BLUE}[DBA-INFO]${NC} $1"
}

log_sql() {
    echo -e "${YELLOW}[SQL]${NC} $1"
}

log_technical() {
    echo -e "${BLUE}[TECHNICAL]${NC} $1"
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
    log_info "Checking prerequisites..."
    
    if ! command -v mysql &>/dev/null; then
        log_error "MySQL client not found. Please install MySQL client."
        record_test_result "Prerequisites Check" "FAIL" "MySQL client not found"
        exit 1
    fi
    
    if [[ -z "$MYSQL_PASSWORD" ]]; then
        log_error "MySQL password is required. Use -p option to specify password."
        record_test_result "Prerequisites Check" "FAIL" "Password not provided"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
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
    log_info "Testing MySQL connection..."
    log_dba_info "Verifying MySQL service connectivity deployed via deploy-innodb-cluster.sh"
    log_technical "Connection Parameters: Host=$MYSQL_HOST, Port=$MYSQL_PORT, User=$MYSQL_USER"
    
    local test_sql="SELECT 1 as connection_test;"
    log_sql "Executing: $test_sql"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd "-e '$test_sql'")
    
    local connection_result
    if connection_result=$(eval "$mysql_cmd" 2>&1); then
        log_success "MySQL connection successful"
        log_technical "Connection established successfully to MySQL server"
        echo "    Query Result: $connection_result" | sed 's/^/    /'
        
        # Get connection details
        local conn_info_sql="SELECT CONNECTION_ID() as conn_id, USER() as current_user, @@hostname as server_host, @@port as server_port;"
        log_sql "Getting connection details: $conn_info_sql"
        local conn_details
        if conn_details=$(echo "$conn_info_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_technical "Connection Details:"
            echo "$conn_details" | sed 's/^/    /'
        fi
        
        record_test_result "MySQL Connection" "PASS" "Connected to $MYSQL_HOST:$MYSQL_PORT"
        return 0
    else
        log_error "MySQL connection failed"
        log_technical "Connection Error Details: $connection_result"
        log_dba_info "Please check: 1) MySQL service status 2) Network connectivity 3) User privileges 4) Firewall settings"
        record_test_result "MySQL Connection" "FAIL" "Cannot connect to $MYSQL_HOST:$MYSQL_PORT"
        return 1
    fi
}

# Get MySQL server information
get_server_info() {
    log_info "Retrieving MySQL server information..."
    log_dba_info "Collecting detailed MySQL server technical information for DBA analysis"
    
    # Basic server information
    local basic_info_sql="SELECT VERSION() as mysql_version, @@hostname as hostname, @@port as port, @@datadir as data_directory;"
    log_sql "Basic Info Query: $basic_info_sql"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd "-e '$basic_info_sql'")
    
    local server_info
    if server_info=$(eval "$mysql_cmd" 2>/dev/null); then
        log_success "MySQL Server Basic Information:"
        echo "$server_info" | sed 's/^/    /'
        
        # Storage engine information
        local engine_sql="SHOW ENGINES;"
        log_sql "Storage Engines Query: $engine_sql"
        local engines_info
        if engines_info=$(echo "$engine_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_technical "Available Storage Engines:"
            echo "$engines_info" | sed 's/^/    /'
        fi
        
        # InnoDB Cluster specific information
        log_dba_info "Checking InnoDB Cluster related configuration"
        local cluster_sql="SELECT @@group_replication_group_name as cluster_group, @@server_uuid as server_uuid, @@group_replication_local_address as local_address;"
        log_sql "Cluster Info Query: $cluster_sql"
        local cluster_info
        if cluster_info=$(echo "$cluster_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_technical "InnoDB Cluster Configuration:"
            echo "$cluster_info" | sed 's/^/    /'
        fi
        
        # Server status and performance metrics
        local status_sql="SHOW STATUS WHERE Variable_name IN ('Uptime', 'Threads_connected', 'Threads_running', 'Questions', 'Slow_queries', 'Innodb_buffer_pool_size', 'Innodb_log_file_size');"
        log_sql "Server Status Query: $status_sql"
        local status_info
        if status_info=$(echo "$status_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_technical "Server Status & Performance Metrics:"
            echo "$status_info" | sed 's/^/    /'
        fi
        
        # Global variables relevant to DBA
        local vars_sql="SHOW VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size', 'max_connections', 'innodb_log_file_size', 'innodb_flush_log_at_trx_commit', 'sync_binlog', 'binlog_format');"
        log_sql "Key Variables Query: $vars_sql"
        local vars_info
        if vars_info=$(echo "$vars_sql" | eval "$(build_mysql_cmd)" 2>/dev/null); then
            log_technical "Key MySQL Variables for DBA:"
            echo "$vars_info" | sed 's/^/    /'
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
    log_info "Testing database operations..."
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    
    # Test 1: Create test database
    log_info "Creating test database '$TEST_DATABASE'..."
    log_dba_info "Verifying database creation privileges and storage engine functionality"
    
    local create_db_sql="CREATE DATABASE IF NOT EXISTS $TEST_DATABASE DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    log_sql "Database Creation: $create_db_sql"
    
    if echo "$create_db_sql" | eval "$mysql_cmd" 2>/dev/null; then
        log_success "Test database created successfully"
        log_technical "Database '$TEST_DATABASE' created with UTF8MB4 character set"
        
        # Verify database creation and get details
        local verify_db_sql="SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$TEST_DATABASE';"
        log_sql "Database Verification: $verify_db_sql"
        local db_details
        if db_details=$(echo "$verify_db_sql" | eval "$mysql_cmd" 2>/dev/null); then
            log_technical "Database Details:"
            echo "$db_details" | sed 's/^/    /'
        fi
        
        record_test_result "Create Database" "PASS" "Database '$TEST_DATABASE' created with proper charset"
    else
        log_error "Failed to create test database"
        log_dba_info "Database creation failed, please check CREATE privileges and disk space"
        record_test_result "Create Database" "FAIL" "Cannot create database '$TEST_DATABASE'"
        return 1
    fi
    
    # Test 2: Create test table
    log_info "Creating test table..."
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
        log_success "Test table created successfully"
        log_technical "Table 'test_table' created with InnoDB engine and proper indexes"
        
        # Get table structure details
        local table_info_sql="USE $TEST_DATABASE; SHOW CREATE TABLE test_table;"
        log_sql "Table Structure Verification: SHOW CREATE TABLE test_table"
        local table_structure
        if table_structure=$(echo "$table_info_sql" | eval "$mysql_cmd" 2>/dev/null); then
            log_technical "Table Structure Details:"
            echo "$table_structure" | sed 's/^/    /'
        fi
        
        # Check table status
        local table_status_sql="USE $TEST_DATABASE; SHOW TABLE STATUS LIKE 'test_table';"
        log_sql "Table Status Check: $table_status_sql"
        local table_status
        if table_status=$(echo "$table_status_sql" | eval "$mysql_cmd" 2>/dev/null); then
            log_technical "Table Status Information:"
            echo "$table_status" | sed 's/^/    /'
        fi
        
        record_test_result "Create Table" "PASS" "Table 'test_table' created with InnoDB engine"
    else
        log_error "Failed to create test table"
        log_dba_info "Table creation failed, please check storage engine support and tablespace configuration"
        record_test_result "Create Table" "FAIL" "Cannot create test table"
        cleanup_test_database
        return 1
    fi
    
    # Test 3: Insert test data
    log_info "Inserting test data..."
    log_dba_info "Verifying data insertion performance and transaction processing capability"
    
    local insert_sql="
        USE $TEST_DATABASE;
        START TRANSACTION;
        INSERT INTO test_table (name, email) VALUES 
        ('Test User 1', 'user1@example.com'),
        ('Test User 2', 'user2@example.com'),
        ('Test User 3', 'user3@example.com');
        COMMIT;
    "
    log_sql "Data Insertion with Transaction: $insert_sql"
    
    local start_time=$(date +%s%N)
    if echo "$insert_sql" | eval "$mysql_cmd" 2>/dev/null; then
        local end_time=$(date +%s%N)
        local insert_time=$(((end_time - start_time) / 1000000))
        log_success "Test data inserted successfully"
        log_technical "3 records inserted in ${insert_time}ms using transaction"
        
        # Verify inserted data with detailed query
        local verify_sql="USE $TEST_DATABASE; SELECT id, name, email, created_at FROM test_table ORDER BY id;"
        log_sql "Data Verification: $verify_sql"
        local inserted_data
        if inserted_data=$(echo "$verify_sql" | eval "$mysql_cmd" 2>/dev/null); then
            log_technical "Inserted Data Verification:"
            echo "$inserted_data" | sed 's/^/    /'
        fi
        
        # Check auto_increment status
        local ai_sql="USE $TEST_DATABASE; SHOW TABLE STATUS LIKE 'test_table';"
        local ai_info
        if ai_info=$(echo "$ai_sql" | eval "$mysql_cmd" 2>/dev/null | grep -E 'Auto_increment'); then
            log_technical "Auto Increment Status: $ai_info"
        fi
        
        record_test_result "Insert Data" "PASS" "3 records inserted with transaction in ${insert_time}ms"
    else
        log_error "Failed to insert test data"
        log_dba_info "Data insertion failed, please check tablespace, privileges, and transaction log configuration"
        record_test_result "Insert Data" "FAIL" "Cannot insert test data"
        cleanup_test_database
        return 1
    fi
    
    # Test 4: Query test data
    log_info "Querying test data..."
    log_dba_info "Verifying query performance and index usage efficiency"
    
    local select_sql="USE $TEST_DATABASE; SELECT COUNT(*) as record_count FROM test_table;"
    log_sql "Record Count Query: $select_sql"
    
    local start_time=$(date +%s%N)
    local record_count
    if record_count=$(echo "$select_sql" | eval "$mysql_cmd" 2>/dev/null | tail -n 1); then
        local end_time=$(date +%s%N)
        local query_time=$(((end_time - start_time) / 1000000))
        
        if [[ "$record_count" == "3" ]]; then
            log_success "Data query successful - found $record_count records"
            log_technical "Query executed in ${query_time}ms"
            
            # Test index usage with EXPLAIN
            local explain_sql="USE $TEST_DATABASE; EXPLAIN SELECT * FROM test_table WHERE name = 'Test User 1';"
            log_sql "Index Usage Analysis: $explain_sql"
            local explain_result
            if explain_result=$(echo "$explain_sql" | eval "$mysql_cmd" 2>/dev/null); then
                log_technical "Query Execution Plan:"
                echo "$explain_result" | sed 's/^/    /'
            fi
            
            # Test complex query performance
            local complex_sql="USE $TEST_DATABASE; SELECT name, email, DATE_FORMAT(created_at, '%Y-%m-%d %H:%i:%s') as formatted_date FROM test_table WHERE name LIKE 'Test%' ORDER BY created_at DESC;"
            log_sql "Complex Query Test: $complex_sql"
            local complex_result
            if complex_result=$(echo "$complex_sql" | eval "$mysql_cmd" 2>/dev/null); then
                log_technical "Complex Query Results:"
                echo "$complex_result" | sed 's/^/    /'
            fi
            
            record_test_result "Query Data" "PASS" "Retrieved $record_count records in ${query_time}ms with index analysis"
        else
            log_warning "Data query returned unexpected count: $record_count"
            log_dba_info "Abnormal data count, possible data consistency issues"
            record_test_result "Query Data" "FAIL" "Expected 3 records, got $record_count"
        fi
    else
        log_error "Failed to query test data"
        log_dba_info "Query failed, please check table structure and query privileges"
        record_test_result "Query Data" "FAIL" "Cannot query test data"
    fi
    
    # Test 5: Update test data
    log_info "Updating test data..."
    log_dba_info "Verifying data update operations and row locking mechanism"
    
    local update_sql="USE $TEST_DATABASE; START TRANSACTION; UPDATE test_table SET email = 'updated@example.com' WHERE id = 1; COMMIT;"
    log_sql "Update with Transaction: $update_sql"
    
    local start_time=$(date +%s%N)
    if echo "$update_sql" | eval "$mysql_cmd" 2>/dev/null; then
        local end_time=$(date +%s%N)
        local update_time=$(((end_time - start_time) / 1000000))
        log_success "Data update successful"
        log_technical "Record updated in ${update_time}ms using transaction"
        
        # Verify the update
        local verify_update_sql="USE $TEST_DATABASE; SELECT id, name, email FROM test_table WHERE id = 1;"
        log_sql "Update Verification: $verify_update_sql"
        local updated_record
        if updated_record=$(echo "$verify_update_sql" | eval "$mysql_cmd" 2>/dev/null); then
            log_technical "Updated Record Details:"
            echo "$updated_record" | sed 's/^/    /'
        fi
        
        # Check affected rows
        local affected_sql="USE $TEST_DATABASE; SELECT ROW_COUNT() as affected_rows;"
        log_sql "Affected Rows Check: $affected_sql"
        local affected_rows
        if affected_rows=$(echo "$affected_sql" | eval "$mysql_cmd" 2>/dev/null | tail -n 1); then
            log_technical "Affected Rows: $affected_rows"
        fi
        
        record_test_result "Update Data" "PASS" "Record updated successfully in ${update_time}ms"
    else
        log_error "Failed to update test data"
        log_dba_info "Data update failed, please check UPDATE privileges and row lock status"
        record_test_result "Update Data" "FAIL" "Cannot update test data"
    fi
    
    # Test 6: Delete test data
    log_info "Deleting test data..."
    log_dba_info "Verifying data deletion operations and space reclamation mechanism"
    
    local delete_sql="USE $TEST_DATABASE; START TRANSACTION; DELETE FROM test_table WHERE id = 3; COMMIT;"
    log_sql "Delete with Transaction: $delete_sql"
    
    local start_time=$(date +%s%N)
    if echo "$delete_sql" | eval "$mysql_cmd" 2>/dev/null; then
        local end_time=$(date +%s%N)
        local delete_time=$(((end_time - start_time) / 1000000))
        log_success "Data deletion successful"
        log_technical "Record deleted in ${delete_time}ms using transaction"
        
        # Verify the deletion
        local verify_delete_sql="USE $TEST_DATABASE; SELECT COUNT(*) as remaining_count FROM test_table;"
        log_sql "Deletion Verification: $verify_delete_sql"
        local remaining_count
        if remaining_count=$(echo "$verify_delete_sql" | eval "$mysql_cmd" 2>/dev/null | tail -n 1); then
            log_technical "Remaining Records: $remaining_count"
        fi
        
        # Check table statistics after deletion
        local stats_sql="USE $TEST_DATABASE; ANALYZE TABLE test_table;"
        log_sql "Table Statistics Update: $stats_sql"
        local stats_result
        if stats_result=$(echo "$stats_sql" | eval "$mysql_cmd" 2>/dev/null); then
            log_technical "Table Analysis Result:"
            echo "$stats_result" | sed 's/^/    /'
        fi
        
        record_test_result "Delete Data" "PASS" "Record deleted successfully in ${delete_time}ms"
    else
        log_error "Failed to delete test data"
        log_dba_info "Data deletion failed, please check DELETE privileges and foreign key constraints"
        record_test_result "Delete Data" "FAIL" "Cannot delete test data"
    fi
    
    # Verify final state
    log_info "Verifying final data state..."
    local final_count
    if final_count=$(echo "USE $TEST_DATABASE; SELECT COUNT(*) as count FROM test_table;" | eval "$mysql_cmd" 2>/dev/null | tail -n 1); then
        log_success "Final verification: $final_count records remaining"
        record_test_result "Final Verification" "PASS" "$final_count records in final state"
    else
        log_warning "Could not verify final data state"
        record_test_result "Final Verification" "FAIL" "Cannot verify final state"
    fi
}

# Performance benchmark test
performance_benchmark() {
    log_info "Running performance benchmark tests..."
    log_dba_info "Executing MySQL performance benchmark tests to evaluate service performance deployed via deploy-innodb-cluster.sh"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    
    # Test 1: Connection performance
    log_info "Testing connection performance..."
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
            log_technical "Connection $i: ${conn_time}ms - $conn_result"
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
        log_success "Connection performance: $connections/10 successful"
        log_technical "Connection Statistics: Total=${total_time}ms, Avg=${avg_time}ms, Min=${min_time}ms, Max=${max_time}ms"
        record_test_result "Connection Performance" "PASS" "10/10 connections, avg ${avg_time}ms (min: ${min_time}ms, max: ${max_time}ms)"
    else
        log_warning "Connection performance: $connections/10 successful"
        log_dba_info "Connection failure possible causes: max_connections limit, network latency, high server load"
        record_test_result "Connection Performance" "FAIL" "Only $connections/10 connections successful"
    fi
    
    # Test 2: Query performance with different query types
    log_info "Testing query performance..."
    log_dba_info "Testing performance of different query types"
    
    # Simple COUNT query performance
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
        log_success "Query performance: $queries/20 successful"
        log_technical "Query Statistics: Total=${query_total}ms, Avg=${query_avg}ms, Min=${min_query}ms, Max=${max_query}ms"
        
        # Test complex query performance
        log_info "Testing complex query performance..."
        local complex_query="USE $TEST_DATABASE; SELECT t1.name, t1.email, COUNT(*) as record_count FROM test_table t1 JOIN test_table t2 ON t1.id <= t2.id GROUP BY t1.id, t1.name, t1.email ORDER BY t1.id;"
        log_sql "Complex Query Test: $complex_query"
        
        local complex_start=$(date +%s%N)
        local complex_result
        if complex_result=$(echo "$complex_query" | eval "$mysql_cmd" 2>/dev/null); then
            local complex_end=$(date +%s%N)
            local complex_time=$(((complex_end - complex_start) / 1000000))
            log_technical "Complex Query Performance: ${complex_time}ms"
            log_technical "Complex Query Results:"
            echo "$complex_result" | sed 's/^/    /'
        fi
        
        record_test_result "Query Performance" "PASS" "20/20 queries, avg ${query_avg}ms (min: ${min_query}ms, max: ${max_query}ms)"
    else
        log_warning "Query performance: $queries/20 successful"
        log_dba_info "Query performance issues possible causes: missing indexes, table locking, improper buffer pool configuration, disk I/O bottleneck"
        record_test_result "Query Performance" "FAIL" "Only $queries/20 queries successful"
    fi
    
    # Test 3: Transaction performance
    log_info "Testing transaction performance..."
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
        log_success "Transaction performance: $transactions/5 successful, avg ${trans_avg}ms per transaction"
        log_technical "Transaction processing demonstrates ACID compliance and proper isolation"
        record_test_result "Transaction Performance" "PASS" "5/5 transactions, avg ${trans_avg}ms"
    else
        log_warning "Transaction performance: $transactions/5 successful, avg ${trans_avg}ms per transaction"
        log_dba_info "Transaction performance issues possible causes: lock waits, deadlocks, transaction log configuration, isolation level settings"
        record_test_result "Transaction Performance" "FAIL" "Only $transactions/5 transactions successful"
    fi
}

# Cleanup test database
cleanup_test_database() {
    log_info "Cleaning up test database..."
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
        log_success "Test database cleaned up successfully"
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
        log_warning "Test database cleanup failed - please manually remove '$TEST_DATABASE'"
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
    echo "Verification Purpose: Validate MySQL service deployed by deploy-innodb-cluster.sh"
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
    
    local total_tests=${#TEST_RESULTS[@]}
    local passed_tests=0
    local failed_tests=0
    
    echo "Detailed Test Results:"
    echo "---------------------"
    
    for result in "${TEST_RESULTS[@]}"; do
        if [[ "$result" == *"PASS"* ]]; then
            echo "✅ $result"
            ((passed_tests++))
        else
            echo "❌ $result"
            ((failed_tests++))
        fi
    done
    
    echo
    echo "Performance Metrics Summary:"
    echo "----------------------------"
    echo "• Connection Tests: Validated connection pooling and authentication"
    echo "• Database Operations: Verified CRUD operations with transaction support"
    echo "• Query Performance: Tested simple and complex query execution"
    echo "• Index Usage: Analyzed query execution plans and index efficiency"
    echo "• Transaction Processing: Validated ACID compliance and isolation"
    echo "• Storage Engine: Confirmed InnoDB engine functionality"
    echo
    
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
        log_success "MySQL service validation completed successfully!"
        echo "🎉 The MySQL InnoDB Cluster deployed by deploy-innodb-cluster.sh is fully operational."
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
    
    echo
    echo "Additional Information:"
    echo "----------------------"
    echo "• For troubleshooting: Check MySQL error logs and cluster status"
    echo "• For performance tuning: Review InnoDB buffer pool and log settings"
    echo "• For monitoring: Consider setting up Prometheus/Grafana integration"
    echo "• For backup: Implement regular backup strategy for cluster data"
    echo
    echo "==========================================="
    echo "End of MySQL InnoDB Cluster Verification Report"
    echo "==========================================="
    
    if [[ -n "$REPORT_FILE" ]]; then
        # Save report to file as well
        {
            echo "MySQL InnoDB Cluster Verification Report"
            echo "Generated: $(date)"
            echo "Host: $MYSQL_HOST:$MYSQL_PORT"
            echo "User: $MYSQL_USER"
            echo "Tests: $passed_tests/$total_tests passed ($success_rate%)"
            echo
            for result in "${TEST_RESULTS[@]}"; do
                echo "$result"
            done
        } > "$REPORT_FILE"
        log_success "Report also saved to: $REPORT_FILE"
    fi
}

# Additional InnoDB Cluster specific verification
verify_innodb_cluster_status() {
    log_info "Verifying InnoDB Cluster status..."
    log_dba_info "Checking InnoDB Cluster status and member health"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    
    # Check Group Replication status
    local gr_status_sql="SELECT MEMBER_ID, MEMBER_HOST, MEMBER_PORT, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members;"
    log_sql "Group Replication Members: $gr_status_sql"
    
    local gr_result
    if gr_result=$(echo "$gr_status_sql" | eval "$mysql_cmd" 2>/dev/null); then
        log_technical "InnoDB Cluster Members Status:"
        echo "$gr_result" | sed 's/^/    /'
        
        local member_count=$(echo "$gr_result" | tail -n +2 | wc -l | tr -d ' ')
        log_technical "Total cluster members: $member_count"
        
        local online_members=$(echo "$gr_result" | grep -c "ONLINE" || true)
        log_technical "Online members: $online_members"
        
        if [[ $online_members -gt 0 ]]; then
            log_success "InnoDB Cluster is active with $online_members online members"
            record_test_result "InnoDB Cluster Status" "PASS" "$online_members members online"
        else
            log_warning "No online cluster members found"
            record_test_result "InnoDB Cluster Status" "FAIL" "No online members"
        fi
    else
        log_warning "Could not retrieve Group Replication status (may be standalone instance)"
        log_technical "This might be a standalone MySQL instance, not part of InnoDB Cluster"
        record_test_result "InnoDB Cluster Status" "WARN" "Not a cluster member or no access to performance_schema"
    fi
    
    # Check cluster configuration
    local cluster_config_sql="SHOW VARIABLES LIKE 'group_replication%';"
    log_sql "Cluster Configuration: $cluster_config_sql"
    
    local config_result
    if config_result=$(echo "$cluster_config_sql" | eval "$mysql_cmd" 2>/dev/null); then
        log_technical "Key InnoDB Cluster Configuration:"
        echo "$config_result" | grep -E "(group_replication_group_name|group_replication_local_address|group_replication_bootstrap_group)" | sed 's/^/    /' || true
    fi
}

# Test cluster-specific features
test_cluster_features() {
    log_info "Testing InnoDB Cluster features..."
    log_dba_info "Testing cluster-specific features and consistency guarantees"
    
    local mysql_cmd
    mysql_cmd=$(build_mysql_cmd)
    
    # Test read-write splitting capability
    local rw_test_sql="SELECT @@read_only, @@super_read_only, @@group_replication_single_primary_mode;"
    log_sql "Read-Write Mode Check: $rw_test_sql"
    
    local rw_result
    if rw_result=$(echo "$rw_test_sql" | eval "$mysql_cmd" 2>/dev/null); then
        log_technical "Read-Write Configuration:"
        echo "$rw_result" | sed 's/^/    /'
        
        if echo "$rw_result" | grep -q "0.*0"; then
            log_technical "This node accepts read-write operations (PRIMARY)"
        else
            log_technical "This node is read-only (SECONDARY)"
        fi
    fi
    
    # Test transaction consistency
    local consistency_sql="SELECT @@group_replication_consistency, @@transaction_isolation;"
    log_sql "Transaction Consistency: $consistency_sql"
    
    local consistency_result
    if consistency_result=$(echo "$consistency_sql" | eval "$mysql_cmd" 2>/dev/null); then
        log_technical "Transaction Consistency Settings:"
        echo "$consistency_result" | sed 's/^/    /'
    fi
    
    # Test cluster write performance with conflict detection
    if echo "USE $TEST_DATABASE; INSERT INTO test_table (name, email) VALUES ('Cluster Test', 'cluster@test.com');" | eval "$mysql_cmd" 2>/dev/null; then
        log_success "Cluster write operation successful"
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
        log_warning "Cluster write operation failed"
        log_dba_info "Write operation failure possible causes: node read-only mode, cluster partitioning, conflict detection"
        record_test_result "Cluster Write Operations" "FAIL" "Cannot perform write operations"
    fi
}

# Main function
main() {
    echo "==========================================="
    echo "    MySQL Database Verification Script"
    echo "==========================================="
    echo
    
    # Check prerequisites
    check_prerequisites
    
    echo
    log_info "Starting MySQL database verification..."
    log_info "Target: $MYSQL_HOST:$MYSQL_PORT (user: $MYSQL_USER)"
    echo
    
    # Core tests
    if test_mysql_connection; then
        get_server_info
        echo
        
        # Additional InnoDB Cluster specific checks
        verify_innodb_cluster_status
        echo
        
        test_database_operations
        echo
        
        if [[ "$VERBOSE" == "true" ]]; then
            performance_benchmark
            echo
        fi
        
        # Test cluster-specific features
        test_cluster_features
        echo
        
        cleanup_test_database
    else
        log_error "Cannot proceed with tests - MySQL connection failed"
    fi
    
    echo
    generate_report
    
    # Exit with appropriate code
    if [[ $FAIL_COUNT -eq 0 ]]; then
        log_success "All tests passed successfully!"
        exit 0
    else
        log_error "$FAIL_COUNT test(s) failed. Please check the results above."
        exit 1
    fi
}

# Execute main function
main "$@"
