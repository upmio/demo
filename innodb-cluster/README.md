# MySQL InnoDB Cluster Automated Deployment

## High-Availability MySQL Cluster Solution for Kubernetes

[Quick Start](#quick-start) • [Features](#features) •
[Deployment Architecture](#deployment-architecture) • [Troubleshooting](#troubleshooting)

## 📖 Project Overview

This project provides a complete **MySQL InnoDB Cluster** automated deployment
solution designed specifically for Kubernetes environments.
Through declarative configuration and cloud-native technologies, it enables
rapid deployment, automatic failover, and elastic scaling of MySQL clusters.

### 🎯 Design Goals

- **High Availability**: Multi-master architecture based on MySQL Group Replication
- **Automated Operations**: Zero-intervention fault detection and recovery
- **Cloud Native**: Fully compatible with Kubernetes ecosystem
- **Production Ready**: Enterprise-grade security and performance optimization

This is a script tool for automated deployment of MySQL InnoDB Cluster in
Kubernetes clusters. The script supports both interactive and non-interactive
deployment modes, enabling rapid setup of high-availability MySQL cluster
environments.

## Features

### 🚀 Core Features

- **One-Click Deployment**: Supports both interactive and command-line
  parameter deployment modes
- **High Availability Architecture**: 3-node cluster based on MySQL Group Replication
- **Automatic Failover**: Automatic master node switching during node failures
- **Data Persistence**: Uses PVC to ensure data safety
- **Load Balancing**: Built-in MySQL Router for read-write splitting
- **Monitoring Integration**: Optional integration with Prometheus and Grafana

### 🔧 Operations Features

- **Health Checks**: Automatic monitoring of cluster status and node health
- **Backup & Recovery**: Supports scheduled backups and one-click recovery
- **Online Scaling**: Supports dynamic addition and removal of nodes
- **Configuration Management**: Unified configuration file management
- **Log Collection**: Centralized log management and analysis

## Deployment Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                      │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │   MySQL Node 1  │  │   MySQL Node 2  │  │   MySQL Node 3  │ │
│  │   (Primary)     │  │   (Secondary)   │  │   (Secondary)   │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
│           │                     │                     │        │
│           └─────────────────────┼─────────────────────┘        │
│                                 │                              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │              MySQL Router (Load Balancer)              │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                 │                              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                Application Layer                        │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Architecture Overview

- **MySQL InnoDB Cluster**: 3-node Group Replication cluster
- **MySQL Router**: Load balancing and connection routing
- **Persistent Storage**: Each node uses independent PVC
- **Service Discovery**: Implemented through Kubernetes Service
- **High Availability**: Supports automatic recovery from any single point
  of failure

This script will deploy the following components:

1. **MySQL InnoDB Cluster**: 3-node MySQL cluster (Master-Slave replication +
   Group Replication)
2. **MySQL Router**: 2-node load balancer and connection proxy
3. **Secret Management**: Automatic generation and management of database
   user passwords
4. **Monitoring Configuration**: Integration with Prometheus PodMonitor
   (optional)

## System Requirements

### Basic Environment

- **Kubernetes**: v1.29+
- **kubectl**: Configured and able to access target cluster
- **Helm**: v3.8+ (for deploying MySQL components)
- **Unit Operator**: UPM custom resource definitions and operator
- **Compose Operator**: UPM custom resource definitions and operator
- **Storage**: StorageClass supporting dynamic PVC allocation

### Resource Requirements

- **CPU**: At least 1 core per MySQL node (recommended 2 cores)
- **Memory**: At least 2Gi per MySQL node (recommended 4Gi)
- **Storage**: At least 20Gi persistent storage per node
- **Network**: Good internal cluster network connectivity

### Optional Components

- **Prometheus**: For monitoring integration (optional)
- **Grafana**: For monitoring visualization (optional)

## Quick Start

### 1. Deploy MySQL InnoDB Cluster

```bash
# Download script directly
curl -sSL \
  https://raw.githubusercontent.com/upmio/demo/main/innodb-cluster/deploy-innodb-cluster.sh \
  -o deploy-innodb-cluster.sh
chmod +x deploy-innodb-cluster.sh
./deploy-innodb-cluster.sh
```

### 2. Interactive Deployment

```bash

# Run interactive deployment
./deploy-innodb-cluster.sh

# Follow prompts to enter configuration:
# - Namespace (default: default)
# - MySQL version (default: 8.0.41)
# - Storage size (default: 20Gi)
# - Storage class name (default: auto-detect)
```

### 3. Non-Interactive Deployment

```bash
# Deploy directly with command-line parameters
./deploy-innodb-cluster.sh \
  --namespace production \
  --mysql-version 8.0.41 \
  --storage-class fast-ssd
```

## Command Line Parameters

The deployment script supports the following command-line parameters:

| Parameter | Description | Default | Example |
|-----------|-------------|---------|----------|
| `--namespace` | Deployment namespace | default | `--namespace mysql-prod` |
| `--mysql-version` | MySQL version | 8.0.41 | `--mysql-version 8.0.42` |
| `--storage-class` | StorageClass name | auto-detect | `--storage-class ssd` |
| `--dry-run` | Preview mode, generate config | false | `--dry-run` |
| `--help` | Display help information | - | `--help` |

### Usage Examples

```bash
# Full parameter deployment
./deploy-innodb-cluster.sh \
  --namespace mysql-production \
  --mysql-version 8.0.42 \
  --storage-class fast-ssd

# Preview configuration
./deploy-innodb-cluster.sh --dry-run

# View help
./deploy-innodb-cluster.sh --help
```

## MySQL Database Verification

After deployment, you can use the `verify-mysql.sh` script to verify MySQL database connectivity and perform basic database operations testing.

### Script Features

The `verify-mysql.sh` script is an independent MySQL database verification tool that provides:

- **Connection Testing**: Verify MySQL server connectivity
- **Server Information**: Retrieve MySQL server version and status
- **Database Operations**: Test basic CRUD operations (Create, Read, Update, Delete)
- **Performance Benchmarking**: Simple connection and query performance tests
- **Comprehensive Reporting**: Generate detailed verification reports
- **Verbose Logging**: Optional detailed output for troubleshooting

### Usage

```bash
# Basic usage with required parameters
./verify-mysql.sh -h <host> -P <port> -u <username> -p <password>

# Example: Connect to NodePort service
./verify-mysql.sh -h 10.37.132.105 -P 30206 -u radminuser -p mypassword123

# Verbose mode with report generation
./verify-mysql.sh -h <host> -P <port> -u <username> -p <password> -v -r report.txt

# Specify default database
./verify-mysql.sh -h <host> -P <port> -u <username> -p <password> -d mydatabase
```

### Command Line Parameters

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| `-h, --host` | MySQL server host | localhost | No |
| `-P, --port` | MySQL server port | 3306 | No |
| `-u, --user` | MySQL username | root | No |
| `-p, --password` | MySQL password | - | **Yes** |
| `-d, --database` | Default database | - | No |
| `-v, --verbose` | Enable verbose output | false | No |
| `-r, --report` | Generate report file | - | No |
| `--help` | Show help information | - | No |

### Verification Tests

The script performs the following tests:

1. **Prerequisites Check**: Verify MySQL client availability and parameters
2. **MySQL Connection**: Test database connectivity
3. **Server Information**: Retrieve server version and status
4. **Create Database**: Create temporary test database
5. **Create Table**: Create test table with various data types
6. **Insert Data**: Insert sample records
7. **Query Data**: Verify data retrieval
8. **Update Data**: Test data modification
9. **Delete Data**: Test data deletion
10. **Final Verification**: Confirm final data state
11. **Connection Performance**: Test connection speed (verbose mode)
12. **Query Performance**: Test query execution time (verbose mode)
13. **Cleanup**: Remove test database

### Example Output

```bash
$ ./verify-mysql.sh -h 10.37.132.105 -P 30206 -u radminuser -p mypassword123 -v

===========================================
    MySQL Database Verification Script
===========================================

[INFO] Starting MySQL database verification...
[INFO] Target: 10.37.132.105:30206 (user: radminuser)

[SUCCESS] MySQL connection successful
[SUCCESS] MySQL server information:
version	hostname	port
8.0.41	mysql-0	3306

[SUCCESS] Test database created successfully
[SUCCESS] Test table created successfully
[SUCCESS] Test data inserted successfully
[SUCCESS] Data query successful - found 3 records
[SUCCESS] Data update successful
[SUCCESS] Data deletion successful
[SUCCESS] Final verification: 2 records remaining
[SUCCESS] Connection performance: 5/5 successful, average: 45ms
[SUCCESS] Query performance: 12ms
[SUCCESS] Test database cleanup completed

========================================
MySQL Database Verification Report
========================================
Generated at: Mon Jan 27 10:30:45 CST 2025
MySQL Server: 10.37.132.105:30206
Username: radminuser

Test Summary:
=============
Total Tests: 13
Passed: 13
Failed: 0
Success Rate: 100%

[SUCCESS] All tests passed successfully!
```

### Getting Connection Information

To get the connection information for the verification script:

```bash
# Get NodePort service information
kubectl get svc -n <namespace> -l "upm.api/service.type=mysql-router"

# Get database passwords from secret
kubectl get secret innodb-cluster-sg-demo-secret -n <namespace> \
  -o jsonpath='{.data.radminuser}' | base64 -d
```

## Post-Deployment Usage Guide

### Connect to Database

After deployment, the script will display connection information:

```bash
# Connect via MySQL Router (Recommended)
mysql -h <NodePort-IP> -P <NodePort-Port> -u radminuser -p

# Example
mysql -h 10.37.132.105 -P 30306 -u radminuser -p
```

### Check Cluster Status

```bash
# Check UnitSet status
kubectl get unitset -n <namespace>

# Check Pod status
kubectl get pods -n <namespace> \
  -l "upm.api/service-group.name=demo"

# Check service status
kubectl get svc -n <namespace> \
  -l "upm.api/service-group.name=demo"

# Check Group Replication status
kubectl get mysqlgroupreplication -n <namespace>
```

### View Logs

```bash
# View MySQL logs
kubectl logs -n <namespace> -l upm.api/service.type=mysql

# View MySQL Router logs
kubectl logs -n <namespace> -l upm.api/service.type=mysql-router

# View specific Pod logs
kubectl logs -n <namespace> <pod-name>
```

### Retrieve Database Passwords

```bash
# View passwords in Secret
kubectl get secret innodb-cluster-sg-demo-secret -n <namespace> \
  -o yaml

# Decode root user password
kubectl get secret innodb-cluster-sg-demo-secret -n <namespace> \
  -o jsonpath='{.data.root}' | base64 -d
```

## Database User Description

The script automatically creates the following database users:

| Username | Password | Privileges | Purpose |
|----------|----------|------------|----------|
| `root` | Auto-generated | Super admin | Database management |
| `radminuser` | Auto-generated | Routing privileges | MySQL Router connect |
| `monitor` | Auto-generated | Monitoring privileges | Prometheus monitor |
| `replication` | Auto-generated | Replication privileges | Group replication |

### Retrieve Passwords

```bash
# Get root password
kubectl get secret innodb-cluster-sg-demo-secret \
  -n <namespace> \
  -o jsonpath='{.data.root}' | base64 -d

# Get radminuser password
kubectl get secret innodb-cluster-sg-demo-secret \
  -n <namespace> \
  -o jsonpath='{.data.radminuser}' | base64 -d

# Get monitor password
kubectl get secret innodb-cluster-sg-demo-secret \
  -n <namespace> \
  -o jsonpath='{.data.monitor}' | base64 -d

# Get replication password
kubectl get secret innodb-cluster-sg-demo-secret \
  -n <namespace> \
  -o jsonpath='{.data.replication}' | base64 -d
```

## Monitoring Integration

### Prometheus Monitoring

If Prometheus Operator is installed in the cluster, the script will
automatically create PodMonitor resources:

```bash
# View monitoring configuration
kubectl get podmonitor mysql-cluster-monitor

# Check monitoring metrics
curl http://<mysql-pod-ip>:9104/metrics
```

### Grafana Dashboard

Recommended Grafana dashboards:

- **MySQL Overview**: Dashboard ID 7362
- **MySQL InnoDB Cluster**: Dashboard ID 14057

### Key Monitoring Metrics

- `mysql_up`: MySQL service availability
- `mysql_global_status_connections`: Connection count
- `mysql_global_status_threads_running`: Running thread count
- `mysql_global_status_innodb_buffer_pool_reads`: InnoDB buffer pool
  reads
- `mysql_slave_lag_seconds`: Replication lag

### Install Prometheus (Optional)

```bash
# Add Prometheus Helm repository
helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts

# Install Prometheus Stack
helm install prometheus \
  prometheus-community/kube-prometheus-stack
```

## Troubleshooting

### Common Issues

#### 1. StorageClass Does Not Exist

**Error Message**: `StorageClass 'xxx' does not exist`

**Solution**:

```bash
# View available StorageClasses
kubectl get storageclass

# Redeploy with correct StorageClass name
```

#### 2. Namespace Does Not Exist

**Error Message**: `Namespace 'xxx' does not exist`

**Solution**:

```bash
# Create namespace
kubectl create namespace <namespace-name>

# Or use existing namespace
kubectl get namespaces
```

#### 3. NodePort IP Inaccessible

**Issue**: Cannot connect to database via NodePort IP

**Solution**:

```bash
# Check node IP addresses
kubectl get nodes -o wide

# Check NodePort service
kubectl get svc -n <namespace> \
  -l "upm.api/service.type=mysql-router"

# Ensure firewall allows NodePort access
```

#### 4. Pod Startup Failure

**Solution**:

```bash
# View Pod details
kubectl describe pod <pod-name> -n <namespace>

# View Pod logs
kubectl logs <pod-name> -n <namespace>

# Check resource quotas
kubectl describe nodes
```

#### 5. UPM Package Installation Failure

**Error Message**: `UPM package component installation failed`

**Solution**:

```bash
# Manually download UPM package management script
curl -sSL \
  https://raw.githubusercontent.com/upmio/upm-packages/main/upm-pkg-mgm.sh \
  -o ../upm-pkg-mgm.sh
chmod +x ../upm-pkg-mgm.sh

# Manually install UPM packages
../upm-pkg-mgm.sh install mysql mysql-router
```

### Debug Commands

```bash
# Check cluster connectivity
kubectl cluster-info

# Check resource usage
kubectl top nodes
kubectl top pods -n <namespace>

# Check events
kubectl get events -n <namespace> \
  --sort-by='.lastTimestamp'

# Check UnitSet detailed information
kubectl describe unitset <unitset-name> \
  -n <namespace>
```

## Cleanup Resources

### Complete Cleanup

```bash
# Manual deletion
kubectl delete namespace mysql-cluster
```

### Data-Preserving Cleanup

```bash
# Delete only UnitSet resources, preserve PVCs
kubectl delete unitset -n mysql-cluster \
  -l upm.api/service-group.name=demo
```

### Storage Cleanup

```bash
# Delete PVCs (Warning: This will delete all data)
kubectl delete pvc -n mysql-cluster \
  -l app.kubernetes.io/name=mysql
```

To clean up deployed resources, you can use the following commands:

```bash
# Delete UnitSet resources
kubectl delete unitset -n <namespace> \
  -l upm.api/service-group.name=demo

# Delete Group Replication resources
kubectl delete mysqlgroupreplication -n <namespace> \
  -l upm.api/service-group.name=demo

# Delete Secret resources
kubectl delete secret innodb-cluster-sg-demo-secret \
  -n <namespace>

# Delete possible Job resources
kubectl delete job generate-innodb-cluster-secret-job -n <namespace> \
  --ignore-not-found=true
```

## Version Compatibility

| Component | Version | Description |
|-----------|---------|-------------|
| Kubernetes | 1.29+ | Supports UnitSet and UPM CRDs |
| Unit Operator | Latest | UPM custom resource definitions |
| Compose Operator | Latest | UPM custom resource definitions |
| MySQL | 8.0+ | Supports Group Replication |
| MySQL Router | 8.0+ | Matches MySQL version |

## License

This project is licensed under the Apache 2.0 License - see the
[LICENSE](../LICENSE) file for details.
