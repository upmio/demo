# UPM (Unified Management Platform) Operator Installation Script

This is an interactive script tool for automated installation of UPM (Unified
Platform Management) core components in Kubernetes clusters. This script can
quickly deploy UPM's core Operator components, providing a foundational
platform for subsequent database and middleware management.

## Features

### Core Functions

- **Automated Installation**: One-click deployment of UPM core Operator components
- **Interactive Configuration**: User-friendly command-line interface with
  custom configuration support
- **Dependency Checking**: Automatic detection and validation of Kubernetes
  cluster environment
- **Version Management**: Support for specifying UPM version for installation
- **Namespace Management**: Automatic creation and management of UPM-related namespaces

### Operational Features

- **Installation Verification**: Automatic validation of installation results
  and component status
- **Log Collection**: Provides detailed installation logs and error diagnostics
- **Rollback Support**: Support for quick rollback in case of installation failure
- **Resource Monitoring**: Real-time monitoring of resource usage during
  installation process

## System Requirements

### Basic Environment

- **Kubernetes**: Version 1.29+
- **kubectl**: Configured and able to access the target cluster
- **Helm**: Version 3.0+ (for installing cert-manager)
- **curl**: For downloading resource files

### Resource Requirements

- **CPU**: At least 2 cores available
- **Memory**: At least 4GB available memory
- **Storage**: At least 10GB available storage space
- **Network**: Internet access to download images and resources

### Optional Components

- **StorageClass**: For persistent storage (recommended)
- **Prometheus**: For monitoring integration (optional)
- **Ingress Controller**: For external access (optional)

## Quick Start

### 1. Download Script and Interactive Installation**

```bash
curl -sSL \
  https://raw.githubusercontent.com/upmio/demo/main/install-operator/install-operator.sh \
  -o install-operator.sh
chmod +x install-operator.sh
./install-operator.sh
```

The script will guide you through the following steps:

1. **Environment Check**: Verify required tools and cluster connectivity
2. **Node Selection**: Select target nodes for UPM installation
3. **Dependency Check**: Check and install cert-manager (if needed)
4. **Component Installation**: Install UPM Operator components
5. **Health Verification**: Verify installation results and component status

### 2. Installation Verification

After installation completion, verify component status:

```bash
# Check UPM Operator status
kubectl get pods -n upm-system

# Check CRD resources
kubectl get crd | grep upm

# Check node labels
kubectl get nodes --show-labels | grep upm
```

Expected output:

```bash
# Pod status should be Running
NAME                                READY   STATUS    RESTARTS   AGE
compose-operator-xxx                1/1     Running   0          2m
unit-operator-xxx                   1/1     Running   0          2m


# Target nodes should have upm.operator/node=true label
```

## Troubleshooting

### Common Issues

#### 1. cert-manager Installation Failure

**Error Message**: `cert-manager installation failed`

**Solution**:

```bash
# Manually install cert-manager
kubectl apply -f \
  https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for Pods to be ready
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager -n cert-manager --timeout=300s
```

#### 2. Node Selection Failure

**Error Message**: `No suitable nodes found`

**Solution**:

```bash
# Check node status
kubectl get nodes

# Manually add label to node
kubectl label node <node-name> upm.operator/node=true
```

#### 3. Operator Pod Startup Failure

**Solution**:

```bash
# View Pod details
kubectl describe pod -n upm-system \
  -l app.kubernetes.io/name=unit-operator

# View Pod logs
kubectl logs -n upm-system \
  -l app.kubernetes.io/name=unit-operator

# Check resource quotas
kubectl describe nodes
```

#### 4. Network Connectivity Issues

**Error Message**: `Failed to download resources`

**Solution**:

```bash
# Check network connectivity
curl -I https://github.com

# If in internal network environment, proxy configuration may be needed
export https_proxy=http://your-proxy:port
```

For more detailed troubleshooting information, please check the common issues above.

## Configuration Files

### Operator Configuration

Main configuration parameters for UPM Operator:

```yaml
# values.yaml
operator:
  image:
    repository: upmio/unit-operator
    tag: "latest"
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 128Mi
  nodeSelector:
    upm.operator/node: "true"
```

### Network Configuration

```yaml
network:
  # Service mesh configuration
  serviceMesh:
    enabled: false
    provider: "istio"  # istio, linkerd
  
  # Network policy
  networkPolicy:
    enabled: true
    ingress:
      - from:
        - namespaceSelector:
            matchLabels:
              name: upm-system
```

## Resource Cleanup

### Complete Cleanup

If you need to completely remove UPM and all its components:

```bash
# Delete all UPM-related resources
kubectl delete namespace upm-system
kubectl delete crd $(kubectl get crd | grep upm | awk '{print $1}')

# Delete cert-manager (if no longer needed)
kubectl delete -f \
  https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Delete Helm release
helm uninstall unit-operator -n upm-system
```

### Data-Preserving Cleanup

If you only want to reinstall UPM while preserving data:

```bash
# Only delete the Operator
helm uninstall unit-operator -n upm-system

# Reinstall
helm install unit-operator upmio/unit-operator \
  --namespace upm-system \
  --create-namespace
```

## Version Compatibility

- **Kubernetes**: Supports version 1.29+
- **Helm**: Supports version 3.0+
- **cert-manager**: Supports version 1.10+

## Contributing

Welcome to submit Issues and Pull Requests to improve this script.

## License

This project is licensed under the Apache 2.0 License. For details, please
see the [LICENSE](../LICENSE) file.
