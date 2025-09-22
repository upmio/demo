# 🚀 UPM (Unified Management Platform)

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

**Demo Video:**

Watch the complete deployment and verification process in action:

![UPM Demo](upm-demo.gif)

Video link: [https://asciinema.org/a/740686](https://asciinema.org/a/740686)

### Prerequisites

- **Kubernetes Cluster** (v1.29+)
- **Helm** (v3.16+)
- **kubectl** command-line tool
- **Sufficient cluster resources** (recommended 4+ cores, 8GB+ memory, 2+ workload nodes)

### 🔧 Installation Steps

**Description:**

The `install-operator.sh` script is an automated installation tool that deploys the essential UPM operators (Unit Operator and Compose Operator) to your Kubernetes cluster. These operators enable declarative management and orchestration of MySQL components and services.

```bash
curl -sSL \
  https://raw.githubusercontent.com/upmio/demo/main/install-operator/install-operator.sh \
  -o install-operator.sh
chmod +x install-operator.sh
./install-operator.sh
```

## 🔨 Deployment Examples

### MySQL InnoDB Cluster High Availability

**Description:**

The `deploy-innodb-cluster.sh` script is an automated deployment tool that sets up a production-ready MySQL InnoDB Cluster on Kubernetes. It creates a 3-node high-availability cluster with MySQL Router for load balancing, automatic failover capabilities, and persistent storage configuration.

```bash
# Deploy MySQL InnoDB Cluster
curl -sSL \
  https://raw.githubusercontent.com/upmio/demo/main/innodb-cluster/deploy-innodb-cluster.sh \
  -o deploy-innodb-cluster.sh
chmod +x deploy-innodb-cluster.sh
./deploy-innodb-cluster.sh
```

**Verification:**

The `verify-mysql.sh` script is a comprehensive testing tool designed to validate the MySQL InnoDB Cluster deployment. It performs connection tests, failover scenarios, and data consistency checks to ensure your cluster is functioning correctly.

```bash
# Verify deployment
curl -sSL \
  https://raw.githubusercontent.com/upmio/demo/main/innodb-cluster/verify-mysql.sh \
  -o verify-mysql.sh
chmod +x verify-mysql.sh
./verify-mysql.sh -h <ip_addr> -P <port> -u <username> -p <password>
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
