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

### 1. Download Script

```bash
# Clone repository
git clone https://github.com/upmio/demo.git
cd demo/innodb-cluster

# Or download script directly
curl -sSL \
  https://raw.githubusercontent.com/upmio/demo/main/innodb-cluster/\
deploy-mysql-cluster.sh \
  -o deploy-mysql-cluster.sh
chmod +x deploy-mysql-cluster.sh
```

### 2. Interactive Deployment

```bash
# Run interactive deployment
./verify-mysql.sh

# Follow prompts to enter configuration:
# - Cluster name (default: mysql-cluster)
# - Namespace (default: default)
# - MySQL version (default: 8.0.41)
# - Storage size (default: 20Gi)
# - Storage class name (default: auto-detect)
```

### 3. Non-Interactive Deployment

```bash
# Deploy directly with command-line parameters
./verify-mysql.sh \
  --cluster-name my-mysql \
  --namespace production \
  --mysql-version 8.0.41 \
  --storage-size 50Gi \
  --storage-class fast-ssd
```

## Command Line Parameters

The script supports the following command-line parameters:

| Parameter | Description | Default | Example |
|-----------|-------------|---------|----------|
| `--cluster-name` | Cluster name | mysql-cluster | `--cluster-name my-mysql` |
| `--namespace` | Deployment namespace | default | `--namespace mysql-prod` |
| `--mysql-version` | MySQL version | 8.0.41 | `--mysql-version 8.0.42` |
| `--storage-size` | Storage size per node | 20Gi | `--storage-size 50Gi` |
| `--storage-class` | StorageClass name | auto-detect | `--storage-class ssd` |
| `--dry-run` | Preview mode, generate config | false | `--dry-run` |
| `--help` | Display help information | - | `--help` |

### Usage Examples

```bash
# Full parameter deployment
./verify-mysql.sh \
  --cluster-name production-mysql \
  --namespace mysql-production \
  --mysql-version 8.0.42 \
  --storage-size 100Gi \
  --storage-class fast-ssd

# Preview configuration
./verify-mysql.sh --dry-run

# View help
./verify-mysql.sh --help
```

## Post-Deployment Usage Guide

### Connect to Database

After deployment, the script will display connection information:

```bash
# Connect via MySQL Router (Recommended)
mysql -h <NodePort-IP> -P <NodePort-Port> -u root -p

# Example
mysql -h 10.37.132.105 -P 30306 -u root -p
```

### 查看集群状态

```bash
# 查看 UnitSet 状态
kubectl get unitset -n <namespace>

# 查看 Pod 状态
kubectl get pods -n <namespace> \
  -l "upm.api/service-group.name=demo"

# 查看服务状态
kubectl get svc -n <namespace> \
  -l "upm.api/service-group.name=demo"

# 查看 Group Replication 状态
kubectl get mysqlgroupreplication -n <namespace>
```

### 查看日志

```bash
# 查看 MySQL 日志
kubectl logs -n <namespace> -l upm.api/service.type=mysql

# 查看 MySQL Router 日志
kubectl logs -n <namespace> -l upm.api/service.type=mysql-router

# 查看特定 Pod 日志
kubectl logs -n <namespace> <pod-name>
```

### 获取数据库密码

```bash
# 查看 Secret 中的密码
kubectl get secret innodb-cluster-sg-demo-secret -n <namespace> \
  -o yaml

# 解码 root 用户密码
kubectl get secret innodb-cluster-sg-demo-secret -n <namespace> \
  -o jsonpath='{.data.root}' | base64 -d
```

## Database User Description

The script automatically creates the following database users:

| Username | Password | Privileges | Purpose |
|----------|----------|------------|----------|
| `root` | Auto-generated | Super admin | Database management |
| `mysql_router` | Auto-generated | Routing privileges | MySQL Router connect |
| `monitor` | Auto-generated | Monitoring privileges | Prometheus monitor |

### Retrieve Passwords

```bash
# Get root password
kubectl get secret mysql-cluster-secret \
  -n <namespace> \
  -o jsonpath='{.data.root-password}' | base64 -d

# Get router password
kubectl get secret mysql-cluster-secret \
  -n <namespace> \
  -o jsonpath='{.data.router-password}' | base64 -d

# Get monitor password
kubectl get secret mysql-cluster-secret \
  -n <namespace> \
  -o jsonpath='{.data.monitor-password}' | base64 -d
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

### 调试命令

```bash
# 检查集群连接
kubectl cluster-info

# 检查资源使用情况
kubectl top nodes
kubectl top pods -n <namespace>

# 检查事件
kubectl get events -n <namespace> \
  --sort-by='.lastTimestamp'

# 检查 UnitSet 详细信息
kubectl describe unitset <unitset-name> \
  -n <namespace>
```

## Cleanup Resources

### Complete Cleanup

```bash
# Delete all related resources
./deploy-mysql-cluster.sh --cleanup \
  --namespace mysql-cluster

# Or manual deletion
kubectl delete namespace mysql-cluster
```

### Data-Preserving Cleanup

```bash
# Delete only Pods and Services, preserve PVCs
kubectl delete deployment,statefulset,service -n mysql-cluster \
  -l app.kubernetes.io/name=mysql
kubectl delete deployment,service -n mysql-cluster \
  -l app.kubernetes.io/name=mysql-router
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
kubectl delete unitset demo-mysql-xxx demo-mysql-router-yyy \
  -n <namespace>

# Delete Group Replication resources
kubectl delete mysqlgroupreplication demo-mysql-xxx-replication \
  -n <namespace>

# Delete Secret resources
kubectl delete secret innodb-cluster-sg-demo-secret \
  -n <namespace>

# Delete possible Job resources
kubectl delete job generate-innodb-cluster-secret-job -n upm-system \
  --ignore-not-found=true
```

## Configuration File Description

### MySQL Configuration

The script uses the following default configuration:

```ini
[mysqld]
server-id=1
gtid-mode=ON
enforce-gtid-consistency=ON
binlog-format=ROW
log-bin=mysql-bin
log-slave-updates=ON
master-info-repository=TABLE
relay-log-info-repository=TABLE
transaction-write-set-extraction=XXHASH64
loose-group_replication_group_name="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
loose-group_replication_start_on_boot=OFF
loose-group_replication_local_address="mysql-cluster-0.mysql-cluster:33061"
loose-group_replication_group_seeds="mysql-cluster-0.mysql-cluster:33061,\
mysql-cluster-1.mysql-cluster:33061,mysql-cluster-2.mysql-cluster:33061"
loose-group_replication_bootstrap_group=OFF
```

### MySQL Router Configuration

```ini
[DEFAULT]
logging_folder=/tmp/mysqlrouter/log
runtime_folder=/tmp/mysqlrouter/run
config_folder=/tmp/mysqlrouter

[logger]
level=INFO

[metadata_cache:bootstrap]
router_id=1
bootstrap_server_addresses=mysql-cluster:3306
user=mysql_router
metadata_cluster=prodCluster
ttl=0.5

[routing:bootstrap_rw]
bind_address=0.0.0.0
bind_port=6446
destinations=metadata-cache://prodCluster/default?role=PRIMARY
routing_strategy=first-available

[routing:bootstrap_ro]
bind_address=0.0.0.0
bind_port=6447
destinations=metadata-cache://prodCluster/default?role=SECONDARY
routing_strategy=round-robin-with-fallback
```

The script uses the following YAML template files (located in the
`example/` directory):

- `gen-secret.yaml`: Job configuration for generating database
  passwords
- `mysql-us.yaml`: UnitSet configuration for MySQL InnoDB Cluster
- `mysql-router-us.yaml`: UnitSet configuration for MySQL Router
- `mysql-group-replication.yaml`: MySQL Group Replication
  configuration

Placeholders in these template files will be replaced with actual
values during deployment.

## Version Compatibility

| Component | Version | Description |
|-----------|---------|-------------|
| Kubernetes | 1.29+ | Supports StatefulSet and Service |
| MySQL | 8.0+ | Supports Group Replication |
| MySQL Router | 8.0+ | Matches MySQL version |

## Contributing

We welcome Issues and Pull Requests to improve this project.

### Development Guidelines

1. Fork this repository
2. Create a feature branch
   (`git checkout -b feature/AmazingFeature`)
3. Commit your changes
   (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch
   (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the Apache 2.0 License - see the
[LICENSE](../LICENSE) file for details.
