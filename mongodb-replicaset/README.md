# MongoDB ReplicaSet Automated Deployment

## High-Availability MongoDB Cluster Solution for Kubernetes

[Quick Start](#quick-start) • [Features](#features) •
[Deployment Architecture](#deployment-architecture) • [Troubleshooting](#troubleshooting)

## 📖 Project Overview

This project provides a complete **MongoDB ReplicaSet** automated deployment
solution designed specifically for Kubernetes environments.
Through declarative configuration and cloud-native technologies, it enables
rapid deployment, automatic failover, and elastic scaling of MongoDB clusters.

### 🎯 Design Goals

- **High Availability**: ReplicaSet architecture with automatic primary election
- **Automated Operations**: Zero-intervention fault detection and recovery
- **Cloud Native**: Fully compatible with Kubernetes ecosystem
- **Production Ready**: Enterprise-grade security and performance optimization

This is a script tool for automated deployment of MongoDB ReplicaSet in
Kubernetes clusters. The script supports both interactive and non-interactive
deployment modes, enabling rapid setup of high-availability MongoDB cluster
environments.

## Features

### 🚀 Core Features

- **One-Click Deployment**: Supports both interactive and command-line
  parameter deployment modes
- **High Availability Architecture**: 3-node MongoDB ReplicaSet
- **Automatic Failover**: Automatic primary node election during failures
- **Data Persistence**: Uses PVC to ensure data safety
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
│  │ MongoDB Node 1  │  │ MongoDB Node 2  │  │ MongoDB Node 3  │ │
│  │   (Primary)     │  │   (Secondary)   │  │   (Secondary)   │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────┘ │
│           │                     │                     │        │
│           └─────────────────────┼─────────────────────┘        │
│                                 │                              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                Application Layer                        │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Architecture Overview

- **MongoDB ReplicaSet**: 3-node MongoDB cluster with automatic primary election
- **Persistent Storage**: Each node uses independent PVC
- **Service Discovery**: Implemented through Kubernetes Service
- **High Availability**: Supports automatic recovery from any single point
  of failure

This script will deploy the following components:

1. **MongoDB UnitSet**: 3-node MongoDB UnitSet
2. **ReplicaSet Controller**: MongoDBReplicaSet CRD to manage ReplicaSet
3. **Secret Management**: Automatic generation and management of database
   user passwords
4. **Monitoring Configuration**: Integration with Prometheus PodMonitor
   (optional)

## System Requirements

### Basic Environment

- **Kubernetes**: v1.29+
- **kubectl**: Configured and able to access target cluster
- **Helm**: v3.8+ (for retrieving UPM package versions)
- **curl**: For downloading YAML templates
- **jq**: For JSON processing
- **sed**: For text processing
- **Unit Operator**: UPM custom resource definitions and operator
- **Compose Operator**: UPM custom resource definitions and operator
- **Storage**: StorageClass supporting dynamic PVC allocation

### Resource Requirements

- **CPU**: At least 1 core per MongoDB node (recommended 2 cores)
- **Memory**: At least 2Gi per MongoDB node (recommended 4Gi)
- **Storage**: At least 20Gi persistent storage per node
- **Network**: Good internal cluster network connectivity

### Optional Components

- **Prometheus**: For monitoring integration (optional)
- **Grafana**: For monitoring visualization (optional)

## Quick Start

### 1. Deploy MongoDB ReplicaSet

```bash
# Download script directly
curl -sSL \
  https://raw.githubusercontent.com/upmio/demo/main/mongodb-replicaset/deploy-mongodb-replicaset.sh \
  -o deploy-mongodb-replicaset.sh
chmod +x deploy-mongodb-replicaset.sh
./deploy-mongodb-replicaset.sh
```

### 2. Interactive Deployment

```bash

# Run interactive deployment
./deploy-mongodb-replicaset.sh

# Follow prompts to enter configuration:
# - StorageClass name (auto-detected from available options)
# - Namespace (default: default)
# - MongoDB version (auto-detected from available versions)
# - NodePort IP (auto-detected from cluster nodes)
```

### 3. Non-Interactive Deployment

```bash
# Deploy directly with command-line parameters (short form)
./deploy-mongodb-replicaset.sh \
  -s local-path \
  -n production \
  -v 7.0.0 \
  -i 192.168.1.100

# Deploy with long parameter names
./deploy-mongodb-replicaset.sh \
  --storage-class local-path \
  --namespace production \
  --mongodb-version 7.0.0 \
  --nodeport-ip 192.168.1.100
```

## Command Line Parameters

The deployment script supports the following command-line parameters:

| Parameter | Short Form | Description | Default | Example |
|-----------|------------|-------------|---------|----------|
| `--storage-class` | `-s` | Kubernetes StorageClass name | auto-detect | `-s local-path` |
| `--namespace` | `-n` | Kubernetes namespace | default | `-n demo` |
| `--mongodb-version` | `-v` | MongoDB version to deploy | auto-detect | `-v 7.0.0` |
| `--nodeport-ip` | `-i` | NodePort IP address | auto-detected | `-i 192.168.1.100` |
| `--dry-run` | `-d` | Show what would be deployed without actually deploying | false | `--dry-run` |
| `--help` | `-h` | Show help message | - | `--help` |

### Usage Examples

```bash
# Interactive deployment (recommended)
./deploy-mongodb-replicaset.sh

# Non-interactive deployment with all parameters
./deploy-mongodb-replicaset.sh \
  -s local-path \
  -n demo \
  -v 7.0.0 \
  -i 192.168.1.100

# Using long parameter names
./deploy-mongodb-replicaset.sh \
  --storage-class local-path \
  --namespace mongo-production \
  --mongodb-version 7.0.0

# Dry run to see what would be deployed
./deploy-mongodb-replicaset.sh \
  -s local-path \
  -n demo \
  -v 7.0.0 \
  --dry-run

# View help
./deploy-mongodb-replicaset.sh --help
```

## Post-Deployment Usage Guide

### Connect to Database

This deployment does not expose NodePort by default. Use in-cluster Service or
port-forward to access MongoDB:

```bash
# Forward local 27017 to one MongoDB pod
kubectl -n <namespace> port-forward pod/demo-mongodb-<suffix>-0 27017:27017

# Connect using mongo shell
mongo --host 127.0.0.1 --port 27017 -u admin -p
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

# Check MongoDB ReplicaSet status
kubectl get mongodbreplicaset -n <namespace>
```

### View Logs

```bash
# View MongoDB logs
kubectl logs -n <namespace> -l upm.api/service.type=mongodb

# View specific Pod logs
kubectl logs -n <namespace> <pod-name>
```

### Retrieve Database Passwords

```bash
# View passwords in Secret
kubectl get secret mongodb-replicaset-sg-demo-secret -n <namespace> \
  -o yaml

# Decode admin user password
kubectl get secret mongodb-replicaset-sg-demo-secret -n <namespace> \
  -o jsonpath='{.data.admin}' | base64 -d
```

## Database User Description

The script automatically creates the following database users (stored in Secret):

| Username | Password | Privileges | Purpose |
|----------|----------|------------|----------|
| `admin` | Auto-generated | Admin | Cluster administration |

### Retrieve Passwords

```bash
# Get admin password
kubectl get secret mongodb-replicaset-sg-demo-secret \
  -n <namespace> \
  -o jsonpath='{.data.admin}' | base64 -d
```

## Monitoring Integration

### Prometheus Monitoring

If Prometheus Operator is installed in the cluster, the script will
automatically create PodMonitor resources:

```bash
# View monitoring configuration (PodMonitor)
kubectl get podmonitor -n <namespace>
```

### Grafana Dashboard

Recommended Grafana dashboards:

- **MongoDB Overview**: General MongoDB metrics dashboard
- **ReplicaSet Health**: Monitor primary/secondary state and replication lag

### Key Monitoring Metrics

- `mongodb_up`: MongoDB service availability
- `mongodb_connections`: Connection count
- `mongodb_opcounters`: Operation counters
- `mongodb_replication_lag`: ReplicaSet replication lag

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

#### 3. Pod Startup Failure

**Solution**:

```bash
# View Pod details
kubectl describe pod <pod-name> -n <namespace>

# View Pod logs
kubectl logs <pod-name> -n <namespace>

# Check resource quotas
kubectl describe nodes
```

#### 4. UPM Package Installation Failure

**Error Message**: `UPM package component installation failed`

**Solution**:

```bash
# Manually download UPM package management script
curl -sSL \
  https://raw.githubusercontent.com/upmio/upm-packages/main/upm-pkg-mgm.sh \
  -o ../upm-pkg-mgm.sh
chmod +x ../upm-pkg-mgm.sh

# Manually install UPM packages
../upm-pkg-mgm.sh install mongodb-community
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

# Check MongoDBReplicaSet detailed information
kubectl describe mongodbreplicaset demo-mongodb-<suffix>-replicaset -n <namespace>
```

## Cleanup Resources

### Complete Cleanup

```bash
# Manual deletion
kubectl delete namespace mongo-cluster
```

### Data-Preserving Cleanup

```bash
# Delete only UnitSet resources, preserve PVCs
kubectl delete unitset -n mongo-cluster \
  -l upm.api/service-group.name=demo
```

### Storage Cleanup

```bash
# Delete PVCs (Warning: This will delete all data)
kubectl delete pvc -n mongo-cluster \
  -l app.kubernetes.io/name=mongodb
```

To clean up deployed resources, you can use the following commands:

```bash
# Delete UnitSet resources
kubectl delete unitset -n <namespace> \
  -l upm.api/service-group.name=demo

# Delete ReplicaSet resources
kubectl delete mongodbreplicaset -n <namespace> \
  -l upm.api/service-group.name=demo

# Delete Secret resources
kubectl delete secret mongodb-replicaset-sg-demo-secret \
  -n <namespace>

# Delete possible Job resources
kubectl delete job generate-mongodb-replicaset-secret-job -n <namespace> \
  --ignore-not-found=true
```

## Version Compatibility

| Component | Version | Description |
|-----------|---------|-------------|
| Kubernetes | 1.29+ | Supports UnitSet and UPM CRDs |
| Unit Operator | Latest | UPM custom resource definitions |
| Compose Operator | Latest | UPM custom resource definitions |
| MongoDB | 7.0+ | ReplicaSet architecture |

## License

This project is licensed under the Apache 2.0 License - see the
[LICENSE](../LICENSE) file for details.