# MicroShift + Kafka + Flink: Complete Platform Guide

**Single authoritative source for all platform operations, design, deployment, and day-2 management.**

---

## Table of Contents

1. [Navigation & Quick Links](#navigation--quick-links)
2. [Getting Started](#getting-started)
3. [Architecture & Design](#architecture--design)
4. [Platform Installation (MicroShift)](#platform-installation-microshift)
5. [Platform Configuration](#platform-configuration)
6. [Namespaces & Service Identities](#namespaces--service-identities)
7. [Kafka Deployment & Operations](#kafka-deployment--operations)
8. [Flink Deployment & Operations](#flink-deployment--operations)
9. [Day-2 Operations](#day-2-operations)
10. [Kafka HA Hardening & Failure Drills](#kafka-ha-hardening--failure-drills)
11. [Troubleshooting](#troubleshooting)
12. [Cleanup & Teardown](#cleanup--teardown)
13. [One-Click Deployment](#one-click-deployment)
14. [Reference & Scripts](#reference--scripts)

---

## Navigation & Quick Links

### Fast Navigation by Topic

#### Getting Started
- **[Quick Start (5 minutes)](#getting-started)** — Two fastest paths to working platform
- **[Prerequisites](#prerequisites)** — Host requirements

#### Platform Setup
- **[MicroShift Installation](#platform-installation-microshift)** — Packages, clients, cluster bootstrap
- **[MicroShift Configuration](#platform-configuration)** — DNS, Docker coexistence, storage
- **[Namespaces & RBAC](#namespaces--service-identities)** — Service account setup

#### Deployment
- **[Kafka Deployment](#kafka-deployment--operations)** — Build, deploy, verify
- **[Flink Deployment](#flink-deployment--operations)** — Build, deploy, verify

#### Operations
- **[Day-2 Operations](#day-2-operations)** — Health checks, maintenance, updates
- **[HA Drills](#kafka-ha-hardening--failure-drills)** — Failure scenarios and recovery
- **[Troubleshooting](#troubleshooting)** — Common issues and solutions

#### Reference
- **[One-Click Deployment](#one-click-deployment)** — Fully automated
- **[Quick Commands](#quick-reference-common-commands)** — Common oc/kubectl commands
- **[Scripts](#reference--scripts)** — Script locations and purposes

### Navigation by Role

#### For First-Time Users
1. [Prerequisites](#prerequisites)
2. [Quick Start → Path 1 (Automated)](#path-1-fully-automated-recommended-for-first-time-users)
3. [Verify: Deployment Verification](#deployment-verification)
4. [Next: Day-2 Operations](#day-2-operations)

#### For DevOps / Platform Engineers
1. [Architecture](#architecture--design)
2. [Installation](#platform-installation-microshift) + [Configuration](#platform-configuration)
3. [RBAC Design](#namespaces--service-identities)
4. [Day-2 Operations](#day-2-operations)
5. [HA Drills](#kafka-ha-hardening--failure-drills)

#### For Data Engineers
1. [Flink Architecture](#flink-jobmanager-vs-taskmanager)
2. [Flink Deployment](#flink-deployment--operations)
3. [Kafka Integration](#kafka-deployment--operations)
4. [Troubleshooting](#troubleshooting)

#### For SRE / Operators
1. [Full Setup Path](#path-2-step-by-step-for-more-control)
2. [Day-2 Operations](#day-2-operations)
3. [HA Drills](#kafka-ha-hardening--failure-drills)
4. [Troubleshooting](#troubleshooting)
5. [Cleanup](#cleanup--teardown)

---

## Getting Started

### Two Paths

#### Path 1: Fully Automated (Recommended for First-Time Users)

Set credentials:
```bash
export GH_OWNER="your-org"
export GH_USER="your-github-username"
export GH_PAT="your-github-personal-access-token"
```

Run:
```bash
runbooks/scripts/test-all --clean --auto-ghcr --kafka-topic ha-drill
```

This deploys everything end-to-end in 10-15 minutes.

#### Path 2: Step-by-Step (For More Control)

Follow sections in order:
1. [Platform Installation](#platform-installation-microshift) — 30 min
2. [Platform Configuration](#platform-configuration) — 15 min
3. [Namespaces & RBAC](#namespaces--service-identities) — 5 min
4. [Kafka Deployment](#kafka-deployment--operations) → Quick Start — 10 min
5. [Flink Deployment](#flink-deployment--operations) → Quick Start — 15 min
6. Verify: [Day-2 Operations → Validation](#validation)

### Prerequisites

- Ubuntu 22.04+
- `podman` (3.4+) or `docker` (20.10+)
- 8+ GB RAM (16+ GB recommended)
- 50+ GB disk
- Internet connectivity for package/image downloads

---

## Architecture & Design

### Platform Overview

**MicroShift**: Lightweight Kubernetes on Podman/Docker via MINC wrapper
- Single-node cluster
- Includes OLM (Operator Lifecycle Manager)
- ~1 GB footprint

**Kafka**: 3-broker KRaft cluster (no ZooKeeper)
- StatefulSet-based
- Namespace-scoped RBAC
- Local PersistentVolumes for data
- HA defaults: replication factor 3, min.insync.replicas 2
- Built from UBI9 images (freely redistributable)
- No Kafka operator required

**Flink**: SQL Gateway + JobManager + TaskManagers
- SQL-first approach for declarative workloads
- Namespace-scoped RBAC with 4 service identities (runner, deployer, submitter, observer)
- Integration with Kafka via connectors
- RocksDB state backend for TaskManagers
- Built from UBI9 images
- No Flink operator required

### Design Principles

1. **No operators**: All resources are StatefulSets, Services, ConfigMaps, Secrets—no CRDs required
2. **Namespace isolation**: Each component has its own namespace with RBAC boundaries
3. **HA-first defaults**: 3-node clusters, replication factor 3, min.insync.replicas 2, PodDisruptionBudgets
4. **Non-root containers**: All images built to run as non-root for OpenShift compatibility
5. **Single-source-of-truth**: All procedures, design patterns, and operational guides in this document

### Component Architecture

#### Flink: JobManager vs TaskManager

**JobManager (Master)**
- Receives jobs (SQL, JAR, DataStream)
- Builds execution graph
- Manages checkpoints and savepoints
- Exposes REST API for monitoring
- Low memory requirements
- Deployment: 1 JobManager pod in `flink-dev`

**TaskManager (Worker)**
- Executes user-defined functions (map, filter, window, etc.)
- Manages state (RocksDB)
- Communicates with other TaskManagers
- High memory requirements
- Deployment: 2+ TaskManager pods in `flink-dev`

#### Kafka: KRaft (Quorum Controller)

**Architecture**:
- 3 brokers, each pod runs both broker + controller
- Controllers form quorum for distributed consensus
- No ZooKeeper: all coordination within Kafka cluster

**Storage**:
- Controller metadata: `/var/local/kafka-logs/__cluster_metadata-0/`
- Broker data: `/var/local/kafka-logs/`
- Both on local PersistentVolumes

**Network**:
- Headless Service for stable DNS: `kafka-0.kafka-headless.kafka-dev.svc`, etc.
- Client Service: `kafka-client.kafka-dev.svc:9092`

#### MicroShift: Kubernetes Without the Overhead

```
Ubuntu Host
    ↓
Podman (rootful or rootless)
    ↓
MINC (MicroShift orchestrator)
    ↓
MicroShift Cluster
    ├─ kube-system
    ├─ openshift-operator-lifecycle-manager
    ├─ kafka-dev
    └─ flink-dev
```

---

## Platform Installation (MicroShift)

### Installation Goals

1. Prepare host packages
2. Install and validate Podman
3. Install and validate `oc`, `kubectl`
4. Install and validate MINC
5. Bootstrap cluster

### Step 1: Host Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  conntrack \
  curl \
  iptables \
  jq \
  nftables \
  uidmap \
  podman
```

### Step 2: Validate Podman

```bash
podman info --format '{{.Host.NetworkBackend}} {{.Host.Security.Rootless}}'
```

### Step 3: Install OpenShift Client (`oc`, `kubectl`)

```bash
arch=$(uname -m)
case "$arch" in
  x86_64) oc_arch="amd64" ;;
  aarch64|arm64) oc_arch="arm64" ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

version="4.19.0"
base_url="https://mirror.openshift.com/pub/openshift-v4/${oc_arch}/clients/ocp/${version}"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

cd "$workdir"
curl -fsSLO "$base_url/openshift-client-linux-${version}.tar.gz"
tar -xzf "openshift-client-linux-${version}.tar.gz"
mkdir -p "$HOME/.local/bin"
install -m 0755 oc "$HOME/.local/bin/oc"
install -m 0755 kubectl "$HOME/.local/bin/kubectl"
```

Validate:
```bash
bash -lc 'command -v oc && oc version --client'
```

### Step 4: Install MINC

```bash
curl -fsSL -o /tmp/minc https://github.com/minc-org/minc/releases/download/v0.1.0/minc-linux-amd64
sudo install -m 0755 /tmp/minc /usr/local/bin/minc
minc version
```

For arm64, use matching release asset.

### Step 5: Set MINC Defaults

```bash
minc config set provider podman
minc config set allow-rootless true
minc config view
```

### Step 6: Create Cluster

```bash
minc delete || true
minc create
```

Validate:
```bash
minc status
minc list
```

### Step 7: Initial Cluster Health Checks

```bash
export PATH="$HOME/.local/bin:$PATH"
oc whoami
oc whoami --show-server
oc get nodes -o wide
oc get pods -n openshift-operator-lifecycle-manager -o wide
ss -ltnp | grep -E ':(6443|9080|9443)\b' || true
```

Expected baseline:
- ✓ `oc whoami` succeeds
- ✓ Node is `Ready`
- ✓ OLM pods (`catalog-operator`, `olm-operator`) running
- ✓ Listeners on 6443, 9080, 9443

---

## Platform Configuration

### Step 1: Configure Podman DNS

If Docker is running, Podman needs explicit DNS configuration.

**Automated path**:
```bash
sudo microshift.sh configure-dns --dns1 1.1.1.1 --dns2 8.8.8.8
```

**Manual path**:
```bash
sudo install -d -m 0755 /etc/containers
sudo tee /etc/containers/containers.conf >/dev/null <<'EOF'
[containers]
dns_servers = ["1.1.1.1", "8.8.8.8"]
EOF
```

Validate:
```bash
sudo podman run --rm docker.io/library/alpine:3.20 cat /etc/resolv.conf
```

### Step 2: Validate Podman Egress

```bash
sudo podman run --rm docker.io/library/busybox:1.36 sh -c 'nslookup quay.io 1.1.1.1; echo ---; wget -T 10 -O- http://1.1.1.1 2>&1 | sed -n "1,20p"'
```

### Step 3: Docker + Podman Coexistence (If Docker Running)

**Automated path**:
```bash
sudo microshift.sh install-forwarding
```

**Manual path**:
```bash
sudo iptables -I DOCKER-USER 1 -i podman0 -j ACCEPT
sudo iptables -I DOCKER-USER 2 -o podman0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

### Step 4: Recreate Cluster After Runtime Changes

```bash
minc delete || true
minc create
```

### Step 5: Cluster Validation

```bash
export PATH="$HOME/.local/bin:$PATH"
oc whoami && oc whoami --show-server
oc get nodes -o wide
oc get pods -n openshift-operator-lifecycle-manager
ss -ltnp | grep -E ':(6443|9080|9443)\b' || true
```

**Hard gate**: Cluster must be Ready, OLM pods running, listeners active.

### Step 6: Local PV Provisioning (For Single-Node MINC)

If no default dynamic `StorageClass` exists, provision static local PVs:

```bash
microshift.sh provision-pv --kafka-namespace kafka-dev --flink-namespace flink-dev
```

Verify:
```bash
oc get pv
oc get pvc -n kafka-dev
oc get pvc -n flink-dev
```

### Troubleshooting Configuration

**Issue**: Kafka/Flink pods stay `Pending` with `pod has unbound immediate PersistentVolumeClaims`
- **Solution**: Run `microshift.sh provision-pv` for target namespaces

**Issue**: Docker works but Podman has no egress
- **Solution**: Verify nftables/iptables forwarding rules, re-apply forwarding service

**Issue**: MINC create succeeds but OLM in `ImagePullBackOff`
- **Solution**: Verify Podman DNS resolver and egress; on Docker coexistence hosts, verify `DOCKER-USER` permits `podman0` forwarding

---

## Namespaces & Service Identities

This section applies to both Kafka and Flink. Each component uses different identity models suited to its operational needs.

### Design Principles

1. Separate environments by namespace
2. Separate duties by service account
3. Bind smallest practical set of permissions
4. Avoid `default` service account for workloads
5. Prefer namespace-scoped Role/RoleBinding over cluster-scoped

### Recommended Namespace Model

**Environment layout** (for both Kafka and Flink):
```
kafka-dev     / flink-dev
kafka-stage   / flink-stage
kafka-prod    / flink-prod
```

Or shared-platform layout:
```
kafka-platform-dev     / flink-platform-dev
kafka-platform-stage   / flink-platform-stage
kafka-platform-prod    / flink-platform-prod
```

Do not mix unrelated production/non-production workloads in one namespace if you want clean RBAC/quota/audit boundaries.

### Kafka Service Identity Model

**Minimal pattern**: One runtime identity for broker pods

**`kafka-runner`** — Runtime identity for Kafka broker pods
- Purpose: Pod communication, status checks, metadata management
- Scope: Runtime only (minimal RBAC for broker-to-broker discovery)
- No separate deployer/submitter identities needed unless running Kafka operations automation

**Quick Setup**:
```bash
oc create serviceaccount kafka-runner -n kafka-prod

oc create role kafka-runner \
  --verb=get,list,watch,create,update,patch \
  --resource=configmaps \
  -n kafka-prod

oc adm policy add-role-to-user kafka-runner -z kafka-runner -n kafka-prod
```

Kafka manifests in `manifests/00-serviceaccount.yaml` define the complete identity setup.

### Flink Service Identity Model

**Full separation pattern**: Role-separated model for runtime, deployment, submission, observation

1. **`flink-runner`** — Runtime identity for JobManager, TaskManagers, SQL Gateway pods
2. **`flink-deployer`** — CI/CD identity for manifest apply and rollout operations
3. **`flink-sql-submitter`** — Submission automation identity for SQL job submission
4. **`flink-observer`** — Read-only identity for diagnostics and dashboards

This separation is necessary because Flink requires distinct capabilities across runtime, deployment, and submission workflows.

**Quick Setup** (for flink-prod):

Create service accounts:
```bash
oc create serviceaccount flink-runner -n flink-prod
oc create serviceaccount flink-deployer -n flink-prod
oc create serviceaccount flink-sql-submitter -n flink-prod
oc create serviceaccount flink-observer -n flink-prod
```

Create roles:
```bash
# Runtime role
oc create role flink-runner \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=configmaps \
  -n flink-prod

oc create role flink-runner-discovery \
  --verb=get,list,watch \
  --resource=pods,services,endpoints \
  -n flink-prod

oc create role flink-runner-events \
  --verb=create,patch \
  --resource=events \
  -n flink-prod

# Deployer role
oc create role flink-deployer \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=configmaps,secrets,services,routes,persistentvolumeclaims,serviceaccounts \
  -n flink-prod

oc create role flink-deployer-workloads \
  --verb=get,list,watch,create,update,patch,delete \
  --resource=deployments,statefulsets \
  -n flink-prod

# Observer role
oc create role flink-observer \
  --verb=get,list,watch \
  --resource=pods,services,endpoints,events,configmaps \
  -n flink-prod

# Submitter role (optional)
oc create role flink-sql-submitter \
  --verb=get,list,watch \
  --resource=pods,services,endpoints,events \
  -n flink-prod
```

Bind roles:
```bash
oc adm policy add-role-to-user flink-runner -z flink-runner -n flink-prod
oc adm policy add-role-to-user flink-runner-discovery -z flink-runner -n flink-prod
oc adm policy add-role-to-user flink-runner-events -z flink-runner -n flink-prod
oc adm policy add-role-to-user flink-deployer -z flink-deployer -n flink-prod
oc adm policy add-role-to-user flink-deployer-workloads -z flink-deployer -n flink-prod
oc adm policy add-role-to-user flink-sql-submitter -z flink-sql-submitter -n flink-prod
oc adm policy add-role-to-user flink-observer -z flink-observer -n flink-prod
```

### Ready-To-Apply Manifests

**Kafka**: 
```bash
oc apply -f manifests/00-serviceaccount.yaml
```

**Flink** (all environments):
```bash
oc apply -f manifests/10-namespace-identities-governance-all-environments-example.yaml
```

Or individual environments:
```bash
oc apply -f manifests/08-namespace-identities-governance-dev-example.yaml
oc apply -f manifests/09-namespace-identities-governance-stage-example.yaml
oc apply -f manifests/07-namespace-identities-governance-example.yaml
```

### Validation Checklist

```bash
# Namespace existence
oc get ns | grep '^kafka-'
oc get ns | grep '^flink-'

# Service accounts
oc get sa -n kafka-prod
oc get sa -n flink-prod

# Role bindings
oc get rolebinding -n kafka-prod
oc get rolebinding -n flink-prod

# Effective permissions (examples)
oc auth can-i get pods --as=system:serviceaccount:flink-prod:flink-observer -n flink-prod
oc auth can-i create deployments.apps --as=system:serviceaccount:flink-prod:flink-deployer -n flink-prod
oc auth can-i create deployments.apps --as=system:serviceaccount:flink-prod:flink-observer -n flink-prod  # should DENY
```

---

## Kafka Deployment & Operations

### What You Get

**Consolidated Package Structure** (all at root level):

**Docker Images**:
- `kafka-docker/Dockerfile.kraft` — Rootless-compatible Kafka image built from Apache Kafka OSS binaries
- `kafka-docker/bin/start-kafka-kraft.sh` — Startup script deriving broker identity from StatefulSet ordinal

**Kubernetes Resources**:
- `manifests/00-serviceaccount.yaml` — Service account and RBAC
- `manifests/01-headless-service.yaml` — Stable network identities for brokers
- `manifests/02-client-service.yaml` — In-cluster bootstrap service
- `manifests/03-statefulset.yaml` — 3-node KRaft StatefulSet with PVCs
- `manifests/04-pdb.yaml` — PodDisruptionBudget (minAvailable: 2)

**Configuration**:
- `env/kafka.dev.env` — Deployment variables (previously env/example.env)
- `env/kafka.example.env` — Template with all variables documented

**Operations** (provided by lib.sh functions):
- `kafka_deploy()` — Deploy Kafka cluster
- `kafka_health_check()` — Readiness and health checks
- `kafka_delete_resources()` — Remove resources
- `kafka_create_topic()` — Create topics via Job

### Design Notes

1. KRaft only: `process.roles=broker,controller`, quorum voters derived from pod ordinals
2. Stable identity: StatefulSet pod hostnames (`kafka-0`, `kafka-1`, `kafka-2`) + headless service
3. Persistent data: One PVC per broker
4. HA defaults: `default.replication.factor=3`, `min.insync.replicas=2`
5. OpenShift-safe: Non-root runtime, writable group permissions
6. Image baseline: UBI9-based container images (freely redistributable)
7. Service identity: `kafka-runner` ServiceAccount with minimal RBAC

### Quick Start

```bash
# 1. Create config from template  
cp env/kafka.example.env env/kafka.dev.env

# 2. Edit env/kafka.dev.env with your values:
#    - OPENSHIFT_NAMESPACE=kafka-dev
#    - KAFKA_IMAGE=ghcr.io/<owner-or-org>/kafka-kraft:3.7.1
#    - KAFKA_CLUSTER_ID (generate with commands below)
#    - KAFKA_STORAGE_CLASS=local-path
#    - KAFKA_STORAGE_SIZE=50Gi

# 3. Generate cluster ID
KAFKA_CLUSTER_ID=$( \
  echo -n "$(od -An -tx1 -N16 /dev/urandom | tr -d ' ')" | \
  cut -c1-22
)
echo "Generated KAFKA_CLUSTER_ID: ${KAFKA_CLUSTER_ID}"
# Update env/kafka.dev.env with this value

# 4. Build and deploy using lib.sh functions
source lib.sh
kafka_deploy "kafka-dev" "env/kafka.dev.env"
kafka_health_check "kafka-dev"
```

### Configuration (env/dev.env)

Required fields:
- `OPENSHIFT_NAMESPACE` — Namespace for Kafka (default: kafka-dev)
- `KAFKA_IMAGE` — Docker image reference
- `KAFKA_CLUSTER_ID` — Unique cluster identifier
- `KAFKA_STORAGE_CLASS` — StorageClass for PVCs (default: local-path)
- `KAFKA_STORAGE_SIZE` — PVC size per broker (default: 50Gi)

Registry options:
- **GitHub Container Registry** (recommended for local/dev): `ghcr.io/<owner-or-org>/kafka-kraft:3.7.1`
- Private registry: Set `REGISTRY_LOGIN_USERNAME` and `REGISTRY_LOGIN_PASSWORD`

Generate cluster ID:
```bash
KAFKA_CLUSTER_ID=$(echo -n "$(od -An -tx1 -N16 /dev/urandom | tr -d ' ')" | cut -c1-22)
echo "Generated KAFKA_CLUSTER_ID: ${KAFKA_CLUSTER_ID}"
# Update env/kafka.dev.env with this value
```

Storage note for local MINC clusters:
- If no default dynamic `StorageClass` exists, pre-provision static local PVs before deploy:
  `microshift.sh provision-pv --kafka-only --kafka-namespace <namespace>`

### Deployment Verification

```bash
# Brokers healthy
oc get pods -n kafka-dev -o wide | grep kafka
oc get sts kafka -n kafka-dev
oc get svc -n kafka-dev

# Cluster operational
oc port-forward -n kafka-dev svc/kafka 9092:9092 &
kafka-broker-api-versions.sh --bootstrap-server localhost:9092
kill %1

# Topics exist
oc exec -n kafka-dev kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --list
```

**Hard gates**:
- ✓ All 3 broker pods Running and Ready
- ✓ Headless service endpoints healthy
- ✓ Cluster bootstrap and listeners operational
- ✓ At least one topic created

---

## Flink Deployment & Operations

### What You Get

**Consolidated Package Structure** (all at root level):

**Configuration**:
- `env/flink.config.yaml` — Production-oriented Flink runtime config (Flink 2.3 uses config.yaml, not flink-conf.yaml)
- `env/flink.dev.env` — Deployment variables (previously env/example.env)
- `env/flink.example.env` — Template with all variables documented

**Kubernetes Resources**:
- `manifests/00-serviceaccount-rbac.yaml` — Service identities and RBAC
- `manifests/01-configmap.yaml` — Runtime configuration
- `manifests/02-secrets-example.yaml` — Example secrets
- `manifests/03-jobmanager.yaml` — JobManager service and StatefulSet
- `manifests/04-taskmanager.yaml` — TaskManager StatefulSet with PVCs
- `manifests/05-sql-gateway.yaml` — SQL Gateway service and Deployment
- `manifests/06-route.yaml` — OpenShift Route for SQL Gateway
- `manifests/07-10-namespace-identities-*.yaml` — Ready-to-apply RBAC and governance

**SQL Definitions**:
- `flink-sql/10-session-config.sql` — Session execution settings
- `flink-sql/20-kafka-source.sql` — Kafka source table
- `flink-sql/30-kafka-sink.sql` — Kafka sink table (exactly-once)
- `flink-sql/40-pipeline.sql` — Sample insert statement

**Docker Images**:
- `flink-docker/Dockerfile.base` — Rootless Flink base image
- `flink-docker/Dockerfile.sql-runtime` — SQL runtime image
- `flink-docker/third_party/` — Connector JARs and dependencies

**Operations** (provided by lib.sh functions):
- `flink_deploy()` — Deploy Flink cluster
- `flink_build_images()` — Build Flink images
- `flink_submit_sql()` — Submit SQL to Gateway
- `flink_test_all()` — Full Flink functionality test

### Design Intent

Use this layout when you want a durable, SQL-first Flink platform with:

- One long-lived JobManager
- Fixed TaskManager pool
- SQL Gateway exposed through OpenShift Route
- Kafka as both source and sink
- Checkpoint, savepoint, and HA metadata stored outside pods
- OpenShift restricted SCC behavior with arbitrary non-root UIDs
- All workloads staying inside one namespace
- Kafka external to the namespace
- State durability from object storage, not pod disks
- CI/CD submitting SQL through SQL Gateway REST API

Image baseline:
- UBI9-based build/runtime images (freely redistributable and aligned to OpenShift security)

### Quick Start

```bash
# 1. Create config from template
cp env/flink.example.env env/flink.dev.env

# 2. Edit env/flink.dev.env with your values:
#    - OPENSHIFT_NAMESPACE=flink-dev
#    - BASE_IMAGE_REF=ghcr.io/<owner-or-org>/flink-base:2.3.0
#    - SQL_RUNTIME_IMAGE_REF=ghcr.io/<owner-or-org>/flink-sql-runtime:2.3.0
#    - KAFKA_BROKER_HOST=kafka-0.kafka-headless.kafka-dev.svc
#    - KAFKA_BROKER_PORT=9092

# 3. Stage connector JARs
#    - Copy flink-sql-connector-kafka*.jar to flink-docker/third_party/
#    - Copy flink-json*.jar to flink-docker/third_party/

# 4. Deploy using lib.sh functions
source lib.sh
flink_deploy "flink-dev" "env/flink.dev.env" --wait
validate_flink_identities "flink-dev"
```

### Configuration (env/dev.env)

Required fields:
- `OPENSHIFT_NAMESPACE` — Namespace for Flink (default: flink-dev)
- `BASE_IMAGE_REF` — Flink base image reference
- `SQL_RUNTIME_IMAGE_REF` — Flink SQL runtime image reference
- `KAFKA_BROKER_HOST` — Kafka bootstrap host
- `KAFKA_BROKER_PORT` — Kafka port (default: 9092)

Optional fields:
- `OBJECTSTORE_S3_*` — S3-compatible object store for checkpoints
- `REGISTRY_LOGIN_*` — Private registry credentials

### Deployment Verification

```bash
# Component health
oc get pods -n flink-dev -o wide
oc get deployment jobmanager -n flink-dev
oc get deployment taskmanager -n flink-dev

# Services
oc get svc -n flink-dev
oc get routes -n flink-dev

# SQL Gateway endpoint
GATEWAY=$(oc get route flink-sql-gateway -n flink-dev -o jsonpath='{.spec.host}')
echo "SQL Gateway: https://${GATEWAY}"

# Validate RBAC
oc get serviceaccount -n flink-dev
oc get rolebinding -n flink-dev
```

**Hard gates**:
- ✓ JobManager pod Running and Ready
- ✓ At least 1 TaskManager pod Running and Ready
- ✓ SQL Gateway pod Running and Ready
- ✓ Route created for SQL Gateway access
- ✓ Service identities created

---

## Day-2 Operations

### Kafka Day-2 Operations

#### Health Checks

```bash
source lib.sh
kafka_health_check "kafka-dev"
```

#### Pre/Post-Maintenance Guard

Before maintenance:
```bash
source lib.sh
kafka_maintenance_guard "kafka-dev" "env/kafka.dev.env" --topic ha-drill --phase pre
```

After maintenance:
```bash
source lib.sh
kafka_maintenance_guard "kafka-dev" "env/kafka.dev.env" --topic ha-drill --phase post
```

#### Create Drill Topic

```bash
source lib.sh
kafka_create_topic "kafka-dev" "ha-drill" \
  --partitions 3 \
  --replication-factor 3 \
  --min-insync 2
```

#### Verify Topic

```bash
oc port-forward -n kafka-dev svc/kafka 9092:9092 &
kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic ha-drill
kill %1
```

### Flink Day-2 Operations

#### Update Namespace Governance

```bash
source lib.sh

# Dry-run:
regenerate_namespace_identities_umbrella "flink-dev" --check

# Apply:
regenerate_namespace_identities_umbrella "flink-dev"
```

#### Update Runtime Config or SQL

```bash
# Edit env/flink.config.yaml or flink-sql/ files, then:
source lib.sh
flink_deploy "flink-dev" "env/flink.dev.env" --wait
```

#### Rotate Secrets

```bash
source lib.sh
flink_create_secrets "flink-dev" "env/flink.dev.env"
```

#### Verify RBAC

```bash
scripts/validate-namespace-identities.sh --json flink-dev flink-stage flink-prod
```

### Validation

#### Cluster Health

```bash
export PATH="$HOME/.local/bin:$PATH"
oc get nodes -o wide
oc get pods -A
oc get pods -n kafka-dev
oc get pods -n flink-dev
```

#### Kafka

```bash
oc exec -n kafka-dev kafka-0 -- /opt/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server localhost:9092
```

#### Flink

```bash
GATEWAY=$(oc get route -n flink-dev flink-sql-gateway -o jsonpath={.spec.host})
curl -s https://${GATEWAY}/v1/health/ready | jq .
```

#### One-Click Platform Validation

```bash
runbooks/scripts/validate-platform-all.sh
```

---

## Kafka HA Hardening & Failure Drills

### Objectives

1. Validate cluster continues serving during single-broker disruption
2. Verify PodDisruptionBudget blocks unsafe disruptions
3. Practice broker recovery when node is permanently lost
4. Verify ISR convergence after recovery

### Preconditions

```bash
export PATH="$HOME/.local/bin:$PATH"
source lib.sh
kafka_health_check "kafka-dev"
```

Requirements:
- Kafka deployed and healthy
- At least 3 schedulable worker nodes
- Can run `oc adm drain/cordon`
- Optional: run maintenance-guard before/after each drill

### 1. Baseline Hardening Controls

These are pre-configured in manifests:

- Replication: `default.replication.factor=3`, `min.insync.replicas=2`
- PDB: `minAvailable: 2` in `manifests/04-pdb.yaml`
- Topology spread and anti-affinity in StatefulSet
- Rootless runtime image

### 2. Create Drill Topic

```bash
source lib.sh
kafka_create_topic "kafka-dev" "ha-drill" \
  --partitions 3 \
  --replication-factor 3 \
  --min-insync 2
```

Describe baseline:
```bash
export NS=kafka-dev
oc port-forward -n "$NS" svc/kafka 9092:9092 &
kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic ha-drill
# Expected: 3 replicas, ISR = [0,1,2] (all healthy)
```

### 3. Produce and Consume Baseline Data

```bash
oc exec -n "$NS" kafka-0 -- bash -lc '
for i in $(seq 1 20); do
  echo "baseline-${i}"
done | /opt/kafka/bin/kafka-console-producer.sh \
  --topic ha-drill --broker-list kafka:9092
'

oc exec -n "$NS" kafka-1 -- /opt/kafka/bin/kafka-console-consumer.sh \
  --topic ha-drill --from-beginning \
  --bootstrap-server kafka.${NS}.svc:9092 | head -5
```

### 4. Identify Leader and Hosting Node

```bash
oc exec -n "$NS" kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --describe --topic ha-drill \
  --bootstrap-server kafka.${NS}.svc:9092
```

Map leader ID to pod:
```bash
oc get pod -n "$NS" -o wide -l app.kubernetes.io/name=kafka
```

If leader is broker 1, target pod is `kafka-1`.

### 5. Drill A: Single Broker Disruption

Cordon and drain node hosting leader:
```bash
export NODE=<node-hosting-leader>
oc adm cordon "$NODE"
oc adm drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force
```

Watch pods:
```bash
oc get pod -n "$NS" -o wide -l app.kubernetes.io/name=kafka -w
```

Re-check leader/ISR:
```bash
oc exec -n "$NS" kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --describe --topic ha-drill \
  --bootstrap-server kafka.${NS}.svc:9092
```

Expected:
- Leader migrates to another ISR member
- Cluster continues serving with 2 brokers
- ISR drops to 2 temporarily

Validate produce/consume during disruption:
```bash
oc exec -n "$NS" kafka-2 -- bash -lc '
echo "during-drain" | /opt/kafka/bin/kafka-console-producer.sh \
  --topic ha-drill --broker-list kafka:9092
'
```

Uncordon:
```bash
oc adm uncordon "$NODE"
```

Post-maintenance assertion:
```bash
scripts/maintenance-guard.sh env/dev.env --topic ha-drill --phase post
```

### 6. Drill B: PDB Blocks Unsafe Second Drain

With one broker unavailable, attempt draining second node:
```bash
export NODE2=<another-kafka-node>
oc adm drain "$NODE2" --ignore-daemonsets --delete-emptydir-data --force
```

Expected:
- Drain fails to evict Kafka pod due to PDB
- Prevents dropping below quorum-safe posture

Inspect PDB:
```bash
oc get pdb -n "$NS"
oc describe pdb kafka -n "$NS"
```

### 7. Drill C: Permanent Node Loss & Broker Replacement

If node doesn't return:

1. Remove failed node from inventory (platform step)
2. Identify stuck broker pod (`Pending`):
```bash
oc get pod -n "$NS" -o wide -l app.kubernetes.io/name=kafka
oc get pvc -n "$NS" -l app.kubernetes.io/name=kafka
```

3. Delete problematic PVC (StatefulSet will create new pod):
```bash
oc delete pvc kafka-logs-kafka-<N> -n "$NS"
```

4. Monitor new broker startup and ISR convergence:
```bash
oc get pod -n "$NS" -o wide -l app.kubernetes.io/name=kafka -w
oc exec -n "$NS" kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --describe --topic ha-drill \
  --bootstrap-server kafka.${NS}.svc:9092
```

Expected:
- New broker pod starts
- ISR grows back to 3
- Replication catches up

---

## Troubleshooting

### DNS Issues

**Symptom**: Podman has no egress, but Docker works

**Diagnostics**:
```bash
ls -l /etc/resolv.conf
sed -n '1,80p' /etc/resolv.conf
sed -n '1,80p' /run/systemd/resolve/resolv.conf
sudo podman run --rm docker.io/library/alpine:3.20 cat /etc/resolv.conf
sudo podman run --rm docker.io/library/busybox:1.36 nslookup quay.io 1.1.1.1
```

**Solution**: Apply `microshift.sh configure-dns`, then recreate cluster

### Networking Issues

**Symptom**: MINC create succeeds but OLM in `ImagePullBackOff`

**Solution**: Verify Podman DNS and egress; on Docker coexistence hosts, verify `DOCKER-USER` permits `podman0` forwarding

### Storage Issues

**Symptom**: Kafka/Flink pods stay `Pending` with `pod has unbound immediate PersistentVolumeClaims`

**Solution**:
```bash
microshift.sh provision-pv --kafka-namespace kafka-dev --flink-namespace flink-dev
oc get pvc -n kafka-dev
oc get pvc -n flink-dev
```

### MINC Issues

**Symptom**: `minc create --allow-rootless` fails

**Solution**:
```bash
minc config set allow-rootless true
minc create
```

**Symptom**: Cluster has stale references after host reboot

**Solution**:
```bash
minc delete || true
sudo podman rm -f microshift 2>/dev/null || true
sudo podman network rm podman 2>/dev/null || true
sudo podman network create podman
minc create
```

### Kafka Issues

**Symptom**: Brokers stuck in `CrashLoopBackOff`

**Diagnostics**:
```bash
oc logs -n kafka-dev kafka-0 --tail=50
```

**Common causes**:
- PVC not bound (provision local PVs)
- Permissions issue on PV (check pod SCC)
- Configuration error in env/dev.env

### Flink Issues

**Symptom**: JobManager or TaskManager stuck `Pending`

**Diagnostics**:
```bash
oc describe pod -n flink-dev <pod-name>
oc logs -n flink-dev <pod-name> --tail=50
```

**Common causes**:
- PVC not bound (provision local PVs)
- Insufficient TaskManager resources (reduce replicas/memory)
- SQL Gateway deployment failing (check manifests applied)

---

## Cleanup & Teardown

### Kafka-Only Cleanup (Keep Cluster)

```bash
source lib.sh
kafka_delete_resources "kafka-dev"
```

### Flink-Only Cleanup (Keep Cluster)

```bash
# Manual deletion (component folders consolidated)
oc delete -f manifests/ -n flink-dev --selector=app.kubernetes.io/name=flink
```

Or delete entire namespace:
```bash
oc delete namespace flink-dev
```

### Targeted Cleanup

```bash
# Remove only workloads, keep namespaces/RBAC
oc delete statefulset,deployment -n kafka-dev
oc delete statefulset,deployment -n flink-dev

# Remove pods
oc delete pod -n kafka-dev --all
oc delete pod -n flink-dev --all

# Remove namespaces entirely
oc delete ns kafka-dev flink-dev
```

### Full Cluster Teardown

```bash
minc delete
minc list  # should be empty
oc list || true  # should fail (no cluster)
```

### Optional: Wipe Local Data

```bash
sudo podman rm -f microshift 2>/dev/null || true
sudo podman network rm podman 2>/dev/null || true
rm -rf "$HOME/.kube"
```

---

## One-Click Deployment

Fully automated end-to-end:

```bash
export GH_OWNER="your-org"
export GH_USER="your-github-username"
export GH_PAT="your-github-personal-access-token"

runbooks/scripts/test-all --clean --auto-ghcr --kafka-topic ha-drill
```

This runs:
1. Platform setup (MicroShift installation & configuration)
2. Namespace bootstrap with RBAC
3. Kafka build & deploy with validation
4. Flink build & deploy with validation
5. End-to-end data flow test (Kafka → Flink → Kafka)
6. Platform validation snapshot

**Estimated time**: 10-15 minutes (depends on image pulls and host resources)

For non-destructive platform validation:
```bash
runbooks/scripts/validate-platform-all.sh
```

---

## Reference & Scripts

### Quick Reference: Common Commands

```bash
# Set PATH (all tools in ~/.local/bin)
export PATH="$HOME/.local/bin:$PATH"

# Cluster status
oc whoami && oc whoami --show-server
oc get nodes -o wide
oc get pods -n kafka-dev
oc get pods -n flink-dev

# Kafka health
oc port-forward -n kafka-dev svc/kafka 9092:9092 &
kafka-broker-api-versions.sh --bootstrap-server localhost:9092
kill %1

# Flink health
GATEWAY=$(oc get route -n flink-dev flink-sql-gateway -o jsonpath='{.spec.host}')
curl -s https://${GATEWAY}/v1/health/ready | jq .

# Kafka operations
source lib.sh
kafka_health_check "kafka-dev"
kafka_maintenance_guard "kafka-dev" "env/kafka.dev.env" --topic ha-drill --phase pre
kafka_maintenance_guard "kafka-dev" "env/kafka.dev.env" --topic ha-drill --phase post

# Flink operations
source lib.sh
validate_flink_identities "flink-dev"
regenerate_namespace_identities_umbrella "flink-dev" --check

# Full cleanup
runbooks/scripts/cleanup-all --purge-local-data

# Full deployment
runbooks/scripts/test-all --clean --auto-ghcr --kafka-topic ha-drill
```

### Script Locations

**Consolidated Scripts** (Root Level):

All component operations are now provided by functions in `lib.sh` rather than separate scripts:

- **lib.sh** — Central library with 60+ functions for all operations
  - **Kafka ops**: `kafka_deploy()`, `kafka_delete_resources()`, `kafka_health_check()`, `kafka_create_topic()`, `kafka_maintenance_guard()`, `kafka_test_all()`
  - **Flink ops**: `flink_deploy()`, `flink_build_images()`, `flink_create_secrets()`, `flink_submit_sql()`, `flink_smoke_test()`, `flink_test_all()`, `validate_flink_identities()`, `regenerate_namespace_identities_umbrella()`
  - **Platform ops**: `run_full_platform_test()`, `cleanup_all()`, `validate_all()`
  - **Utilities**: `load_env()`, `require_env()`, `render_template()`, `render_tree()`, `create_namespace()`, `apply_manifests()`, `wait_for_deployment()`, `wait_for_statefulset()`

- **microshift.sh** — MicroShift cluster management (consolidated from 4 original scripts)
  - `microshift.sh configure-dns` — Configure Podman DNS
  - `microshift.sh install-forwarding` — Docker/Podman coexistence
  - `microshift.sh provision-pv` — Provision local PersistentVolumes
  - `microshift.sh test-all` — Comprehensive cluster validation and testing
  - Usage: `microshift.sh --help` or `microshift.sh <command> --help`

**Runbook Scripts** (`runbooks/scripts/`):

These orchestrate the lib.sh functions for complete workflows:

- `test-all` — Full platform deployment with validation
- `validate-platform-all.sh` — Non-destructive health check
- `cleanup-all` — Cleanup workloads/namespaces/cluster

### Configuration Files

**Kafka** (`env/`):
- `kafka.dev.env` — Development environment
- `kafka.example.env` — Template with all variables documented

**Flink** (`env/`):
- `flink.dev.env` — Development environment
- `flink.example.env` — Template with all variables documented
- `flink.config.yaml` — Flink SQL runtime configuration

### Manifest Locations

**Kafka** (`manifests/`):
- StatefulSet, Service, PDB, RBAC, ConfigMap

**Flink** (`manifests/`):
- JobManager, TaskManager, SQL Gateway, RBAC, governance

---

## Documentation Management

This is the **single authoritative source** for all platform procedures, design patterns, and operations.

**Key Principles**:
1. ✓ All procedures documented once in this guide
2. ✓ No duplicate content across multiple files
3. ✓ Internal links via markdown anchors instead of file separation
4. ✓ Clear table of contents and role-based navigation
5. ✓ Comprehensive reference sections at the end

**When Updating Documentation**:
1. Edit only this file (PLATFORM-COMPLETE-GUIDE.md)
2. Update TABLE OF CONTENTS if adding new sections
3. Use markdown anchors for internal links: `[text](#anchor)`
4. Keep scripts self-contained and idempotent

---

**Last Updated**: 2026-07-06  
**Status**: Master document - single source of truth  
**Maintenance**: Update this document only; all navigation and component READMEs reference sections here
