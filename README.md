# 🚀 UPM Unified Management Platform

## Enterprise-Grade Stateful Service Management Platform for Kubernetes

[Quick Start](#-quick-start) •
[Supported Services](#-supported-services) •
[Deployment Examples](#-deployment-examples)

---

## 📖 Project Overview

**UPM (Unified Platform Management)** is a modern Kubernetes-native platform
specifically designed for automated management of enterprise-grade databases
and middleware services.
Through declarative configuration and cloud-native technologies,
UPM simplifies the deployment, scaling, and operations of complex services.

### 🏗️ Core Architecture

| Component | Function | Repository |
|-----------|----------|------------|
| **Unit Operator** | Universal workload orchestration engine providing unified lifecycle management for databases and middleware | [upmio/unit-operator][1] |
| **Compose Operator** | Advanced orchestration engine supporting automated deployment and management of complex multi-component applications | [upmio/compose-operator][2] |
| **UPM Packages** | Production-ready Helm Chart collection containing best-practice configurations for mainstream databases and middleware | [upmio/upm-packages][3] |

[1]: https://github.com/upmio/unit-operator
[2]: https://github.com/upmio/compose-operator
[3]: https://github.com/upmio/upm-packages

## 🎯 Supported Services

### Database Services

- **MySQL** - High-availability InnoDB Cluster
- **PostgreSQL** - Enterprise-grade relational database
- **Redis** - High-performance in-memory database
- **MongoDB** - Document-oriented NoSQL database
- **ClickHouse** - Columnar analytical database
- **TiDB** - Distributed NewSQL database

### Middleware Services

- **Apache Kafka** - Distributed streaming platform
- **RabbitMQ** - Enterprise message queue
- **Elasticsearch** - Distributed search and analytics engine
- **Zookeeper** - Distributed coordination service
- **Etcd** - Distributed key-value store
- **MinIO** - High-performance object storage

## 🚀 Quick Start

### Prerequisites

- **Kubernetes Cluster** (v1.29+)
- **Helm** (v3.8+)
- **kubectl** command-line tool
- **Sufficient cluster resources** (recommended 4 cores, 8GB+ memory)

### 1. Install UPM Platform

```bash
# Clone the repository
git clone https://github.com/upmio/demo.git
cd demo

# Run the installation script
./install-upm/install-upm.sh
```

### 2. Verify Installation

```bash
# Check UPM component status
kubectl get pods -n upm-system

# List available service packages
helm search repo upm
```

## 💡 Deployment Examples

### MySQL InnoDB Cluster High Availability

```bash
# Deploy 3-node MySQL InnoDB Cluster
./innodb-cluster/verify-mysql.sh
```

**Features:**

- ✅ Automatic failover
- ✅ Read-write splitting
- ✅ Data consistency guarantee
- ✅ Online scaling
- ✅ Automated backup and recovery

## 📚 Documentation & Resources

- 💬 [Community Support](https://github.com/upmio/demo/discussions) -
  Technical discussions and Q&A
- 🐛 [Issue Reporting](https://github.com/upmio/demo/issues) - Bug reports
  and feature requests

## 📄 License

This project is licensed under the [Apache License 2.0](LICENSE).

---

**🌟 If this project helps you, please give us a Star!**
