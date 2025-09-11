# Redis Sentinel Cluster Automated Deployment

This project provides automated deployment and demonstration tools for Redis
Sentinel clusters, based on Kubernetes and UPM platform, including a comprehensive
Python-based demo tool for testing cluster functionality.

## Project Overview

Redis Sentinel is a high availability solution for Redis, providing automatic
failover, configuration provider, and notification functions. This deployment
tool automates the entire Redis Sentinel cluster deployment process, including:

- Redis master-slave replication cluster
- Redis Sentinel monitoring service
- Automatic failover configuration
- Persistent storage configuration
- NodePort service exposure
- Comprehensive Python demo tool for cluster testing and demonstration

## Prerequisites

### System Requirements

- Kubernetes cluster (with kubectl configured)
- Helm 3.x
- UPM Operator components installed

### Required Tools

- `kubectl` - Kubernetes command-line tool
- `helm` - Kubernetes package manager
- `curl` - For downloading template files
- `jq` - JSON processing tool
- `sed` - Text processing tool
- `python3` - Python 3.7+ (for demo tool)

### Storage Requirements

- Available StorageClass in the cluster
- Recommended to use local-path or other persistent storage

## Usage

### Deployment Script (deploy-redis-sentinel.sh)

#### Basic Usage

```bash
# Interactive deployment (recommended)
./deploy-redis-sentinel.sh

# Non-interactive deployment
./deploy-redis-sentinel.sh --namespace redis-system --storage-class local-path

# Preview mode (no actual deployment)
./deploy-redis-sentinel.sh --dry-run

# Specify Redis version
./deploy-redis-sentinel.sh --redis-version 7.0.14
```

#### Command Line Parameters

- `--dry-run` - Preview mode, shows generated YAML content without actual deployment
- `--help` - Display help information
- `--namespace <namespace>` - Specify deployment namespace
- `--storage-class <class>` - Specify StorageClass
- `--redis-version <version>` - Specify Redis version

**Note:** NodePort IP will be automatically detected from the first available Kubernetes node.

#### Deployment Process

The script deploys components in the following order:

1. **Project** - Create UPM project
2. **Secret** - Generate Redis authentication keys
3. **Redis UnitSet** - Deploy Redis master-slave cluster
4. **Redis Replication** - Configure master-slave replication
5. **Redis Replication Patch** - Apply replication patches
6. **Redis Sentinel UnitSet** - Deploy Sentinel monitoring service

### Redis Sentinel Demo Tool (redis-sentinel-demo.py)

This project includes a comprehensive Python-based demo tool for testing and demonstrating Redis Sentinel cluster functionality.

#### Prerequisites

- Python 3.7+
- Required Python packages:
  ```bash
  pip install redis colorama
  ```

#### Usage

```bash
# Basic usage - interactive mode
python redis-sentinel-demo.py

# With custom log level
python redis-sentinel-demo.py --log-level DEBUG

# With configuration file
python redis-sentinel-demo.py --config config.json
```

#### Features

The demo tool provides comprehensive testing and demonstration capabilities:

**1. Cluster Information Display**

- Real-time cluster status monitoring
- Master/slave node information
- Sentinel node status and configuration
- Replication lag and health metrics

**2. Session Management Demo**

- User session creation and management
- Session expiration handling
- Active session listing and cleanup

**3. CRUD Operations Demo**

- Basic Redis data operations (SET, GET, DELETE)
- Data type demonstrations (strings, lists, sets, hashes)
- Batch operations and transactions

**4. Cache Operations Demo**

- Cache data with TTL management
- Cache hit/miss statistics
- Cache invalidation strategies

**5. Counter Operations Demo**
- Atomic increment/decrement operations
- Counter reset and retrieval
- Distributed counter management

**6. High Availability Testing**

- Connection status verification
- Manual failover testing
- Read-write consistency validation
- Performance stress testing

#### Interactive Menu System

The tool provides an intuitive menu-driven interface:

```text
Redis Sentinel Demo Program
==================================================
1. Show Cluster Information
2. Session Management Demo
3. CRUD Operations Demo
4. Cache Operations Demo
5. Counter Operations Demo
6. High Availability Test
0. Exit Program
==================================================
```

#### Configuration

The tool supports both interactive configuration and configuration files:

**Interactive Setup:**

- Sentinel node configuration (host:port)
- Master service name
- Authentication credentials (if required)

**Configuration File Format (JSON):**

```json
{
  "sentinels": [
    {"host": "localhost", "port": 26379},
    {"host": "localhost", "port": 26380},
    {"host": "localhost", "port": 26381}
  ],
  "service_name": "mymaster",
  "password": "your_password"
}
```

## Deployment Components

### Template Files (templates/)

- `0-project.yaml` - UPM project definition
- `1-gen-secret.yaml` - Redis secret generation job
- `2-redis-us.yaml` - Redis UnitSet definition
- `3.0-redis-replication.yaml` - Redis master-slave replication configuration
- `3.1-redis-replication_patch.yaml` - Replication configuration patch
- `4-redis-sentinel-us.yaml` - Redis Sentinel UnitSet definition

### Deployment Architecture

```text
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Redis Master  │    │  Redis Replica  │    │  Redis Replica  │
│    (Unit-0)     │◄──►│    (Unit-1)     │    │    (Unit-2)     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         ▲                       ▲                       ▲
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌─────────────────┐
                    │ Redis Sentinel  │
                    │   (3 instances) │
                    └─────────────────┘
```

## Troubleshooting

### Common Issues

#### 1. StorageClass Unavailable

**Error Message:** "No available StorageClass found in the cluster"

**Solution:**

```bash
# Install local-path-provisioner
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
```

#### 2. Helm Repository Issues

**Error Message:** "Failed to add helm repository 'upm-packages'"

**Solution:**

```bash
# Manually add Helm repository
helm repo add upm-packages https://upmio.github.io/upm-packages
helm repo update
```

#### 3. UPM Package Download Failure

**Error Message:** "UPM package management script download failed"

**Solution:**

```bash
# Manually download UPM management script
curl -sSL \
  https://raw.githubusercontent.com/upmio/upm-packages/main/upm-pkg-mgm.sh \
  -o ../upm-pkg-mgm.sh
chmod +x ../upm-pkg-mgm.sh
```

#### 4. Python Dependencies Missing

**Error Message:** "ModuleNotFoundError: No module named 'redis'" or "No module named 'colorama'"

**Solution:**

```bash
# Install required Python packages
pip install redis colorama

# Or using pip3
pip3 install redis colorama
```

#### 5. Python Demo Tool Connection Issues

**Error Message:** "Connection failed" or "Sentinel not reachable"

**Solution:**

- Verify Redis Sentinel cluster is running
- Check Sentinel node addresses and ports
- Ensure network connectivity to Sentinel nodes
- Verify authentication credentials if required

#### 6. Resource Wait Timeout

**Error Message:** "Resource not ready"

**Solution:**

```bash
# Check resource status
kubectl get unitset -n <namespace>
kubectl describe unitset <resource-name> -n <namespace>

# Check Pod status
kubectl get pods -n <namespace>
kubectl logs <pod-name> -n <namespace>
```

### Log Viewing

```bash
# View deployment logs
kubectl logs -l app=redis -n <namespace>

# View Sentinel logs
kubectl logs -l app=redis-sentinel -n <namespace>

# View events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Python demo tool logs (when using --log-level DEBUG)
python redis-sentinel-demo.py --log-level DEBUG
```

### Cleanup Deployment

```bash
# Delete entire namespace (use with caution)
kubectl delete namespace <namespace>

# Or delete resources individually
kubectl delete unitset --all -n <namespace>
kubectl delete redisreplication --all -n <namespace>
kubectl delete job --all -n <namespace>
kubectl delete project <namespace>
```

## Important Notes

1. **Production Environment Usage**: Recommend validating deployment process
   in test environment first
2. **Resource Configuration**: Adjust CPU, memory, and storage configuration
   according to actual requirements
3. **Network Security**: NodePort services expose to outside the cluster,
   pay attention to network security configuration
4. **Backup Strategy**: Establish appropriate data backup and recovery
   strategies
5. **Monitoring and Alerting**: Configure appropriate monitoring and alerting
   mechanisms

## Support

If you encounter issues, please check:

1. Kubernetes cluster status
2. Whether UPM Operator is running normally
3. Network connectivity and DNS resolution
4. Storage and permission configuration

For more information, please refer to the
[UPM Official Documentation](https://github.com/upmio/upm-packages).
