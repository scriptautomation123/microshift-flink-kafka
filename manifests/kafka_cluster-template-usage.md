# OpenShift Template: Kafka KRaft Cluster

## Overview

`template-kafka-cluster.yaml` is an OpenShift template that deploys a complete Apache Kafka cluster in KRaft mode (no ZooKeeper) with:

- **ServiceAccount** (kafka-runner)
- **Headless Service** (inter-pod communication)
- **Client Service** (external access)
- **StatefulSet** (3 Kafka broker replicas, configurable)
- **PodDisruptionBudget** (high availability)

## Template Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `OPENSHIFT_NAMESPACE` | Yes | - | OpenShift namespace for deployment |
| `KAFKA_CLUSTER_ID` | Yes | MkVmNDMyMDEyZTkyYjljOGQ= | Unique cluster identifier for KRaft |
| `KAFKA_IMAGE_REF` | Yes | image-registry.openshift-image-registry.svc:5000/kafka-dev/kafka-kraft:3.7.1 | Container image URL |
| `KAFKA_REPLICAS` | No | 3 | Number of broker replicas (odd number recommended) |
| `KAFKA_STORAGE` | No | 50 | Storage size per broker (Gi) |
| `KAFKA_CPU_REQUEST` | No | 1 | CPU request per broker (cores) |
| `KAFKA_CPU_LIMIT` | No | 2 | CPU limit per broker (cores) |
| `KAFKA_MEMORY_REQUEST` | No | 2 | Memory request per broker (Gi) |
| `KAFKA_MEMORY_LIMIT` | No | 4 | Memory limit per broker (Gi) |
| `KAFKA_DEFAULT_REPLICATION_FACTOR` | No | 3 | Default replication factor for topics |
| `KAFKA_MIN_INSYNC_REPLICAS` | No | 2 | Minimum in-sync replicas (production durability) |
| `KAFKA_NUM_PARTITIONS` | No | 6 | Default number of partitions for topics |
| `KAFKA_PDB_MIN_AVAILABLE` | No | 2 | PodDisruptionBudget minimum available replicas |

## Usage Examples

### 1. Create from template with parameters file

```bash
oc process -f kafka/openshift/manifests/template-kafka-cluster.yaml \
  --param-file env/dev.env \
  | oc apply -f -
```

### 2. Create from template with inline parameters

```bash
oc process -f kafka/openshift/manifests/template-kafka-cluster.yaml \
  -p OPENSHIFT_NAMESPACE=kafka-dev \
  -p KAFKA_CLUSTER_ID=MkVmNDMyMDEyZTkyYjljOGQ= \
  -p KAFKA_IMAGE_REF=image-registry.openshift-image-registry.svc:5000/kafka-dev/kafka-kraft:3.7.1 \
  -p KAFKA_REPLICAS=3 \
  -p KAFKA_STORAGE=50 \
  -p KAFKA_CPU_REQUEST=1 \
  -p KAFKA_CPU_LIMIT=2 \
  -p KAFKA_MEMORY_REQUEST=2 \
  -p KAFKA_MEMORY_LIMIT=4 \
  | oc apply -f -
```

### 3. Preview template expansion (dry-run)

```bash
oc process -f kafka/openshift/manifests/template-kafka-cluster.yaml \
  --param-file env/dev.env \
  -o yaml > /tmp/kafka-preview.yaml

# Review before applying
cat /tmp/kafka-preview.yaml
```

### 4. Delete resources created from template

```bash
oc delete all,pvc -l app.kubernetes.io/name=kafka -n kafka-dev
```

## Parameter File Format

Create `env/template-params.env`:

```bash
# Required
OPENSHIFT_NAMESPACE=kafka-dev
KAFKA_CLUSTER_ID=MkVmNDMyMDEyZTkyYjljOGQ=
KAFKA_IMAGE_REF=image-registry.openshift-image-registry.svc:5000/kafka-dev/kafka-kraft:3.7.1

# Optional (uses defaults if omitted)
KAFKA_REPLICAS=3
KAFKA_STORAGE=50
KAFKA_CPU_REQUEST=1
KAFKA_CPU_LIMIT=2
KAFKA_MEMORY_REQUEST=2
KAFKA_MEMORY_LIMIT=4
KAFKA_DEFAULT_REPLICATION_FACTOR=3
KAFKA_MIN_INSYNC_REPLICAS=2
KAFKA_NUM_PARTITIONS=6
KAFKA_PDB_MIN_AVAILABLE=2
```

Then process:

```bash
oc process -f kafka/openshift/manifests/template-kafka-cluster.yaml \
  --param-file env/template-params.env | oc apply -f -
```

## What Gets Created

### ServiceAccount
- `kafka-runner` — Pod identity for Kafka brokers

### Headless Service
- `kafka-headless` — Inter-pod communication (ports 9092 broker, 9093 controller)
- Used for KRaft quorum

### Client Service
- `kafka` — External client access (port 9092)
- Used by producers/consumers

### StatefulSet
- `kafka` — N replicas (configurable, default 3)
- Each pod:
  * Container: `kafka` running KRaft broker
  * Volume mount: `/var/lib/kafka/data` (PVC)
  * Resources: configurable CPU/memory requests and limits
  * Security: non-root, no privileges, read-only filesystem capable

### PodDisruptionBudget
- `kafka` — Ensures minimum replicas available during cluster disruptions
- Default: minAvailable=2 (maintains quorum with 3 replicas)

## High Availability

**KRaft Quorum Requirements:**
- Minimum 3 replicas for quorum (survives 1 failure)
- Min replica configuration:
  * KAFKA_REPLICAS=3 (3 brokers, each is controller)
  * KAFKA_MIN_INSYNC_REPLICAS=2 (producer must write to 2)
  * KAFKA_PDB_MIN_AVAILABLE=2 (keep 2 available during disruptions)

**Topology Spread:**
- maxSkew: 1 (even pod distribution across nodes)
- preferredDuringSchedulingIgnoredDuringExecution (pod anti-affinity)
- Ensures brokers spread across different hosts

## Persistent Storage

Template creates PersistentVolumeClaims (PVCs) for:
- Broker data: `${KAFKA_STORAGE}Gi` per replica
- Default storage class used

To use specific StorageClass, edit template or add parameter.

## Accessing Kafka

### From inside cluster

```bash
# Connect to broker
oc exec -it kafka-0 -n kafka-dev -- bash

# List topics
kafka-topics.sh --bootstrap-server kafka:9092 --list

# Create topic
kafka-topics.sh --bootstrap-server kafka:9092 --create --topic my-topic \
  --replication-factor 3 --partitions 6 --config min.insync.replicas=2
```

### From outside cluster (requires Route)

Expose via Route with SASL/TLS for secure external access (not included in template).

## Configuration

### Broker Configuration (via StatefulSet env vars)

The template passes configuration via environment variables:

```yaml
KAFKA_CLUSTER_ID: "${KAFKA_CLUSTER_ID}"  # KRaft cluster ID
KAFKA_REPLICAS: "${KAFKA_REPLICAS}"      # Expected broker count
KAFKA_DEFAULT_REPLICATION_FACTOR: "3"    # Topic default
KAFKA_MIN_INSYNC_REPLICAS: "2"           # Producer durability
KAFKA_NUM_PARTITIONS: "6"                # Topic default
```

Kafka startup scripts (in image) use these to generate broker.properties.

### Memory and CPU

Adjust JVM heap via memory parameters:
- `KAFKA_MEMORY_REQUEST=2Gi` → minimum available to broker
- `KAFKA_MEMORY_LIMIT=4Gi` → maximum JVM can use
- Actual JVM heap typically: request - 512Mi (for OS/buffers)

## Scaling

### Scale up brokers

```bash
oc scale statefulset kafka -n kafka-dev --replicas=5
```

Wait for new brokers to start and join the cluster:

```bash
oc logs -f kafka-3 -n kafka-dev
oc logs -f kafka-4 -n kafka-dev
```

### Scale down brokers

Before scaling down, ensure leadership is transferred:

```bash
# Gracefully shutdown broker
oc delete pod kafka-2 -n kafka-dev

# Wait for graceful shutdown and new pod to start
oc get pods -n kafka-dev -w
```

## Troubleshooting

### Check template syntax

```bash
oc process -f kafka/openshift/manifests/template-kafka-cluster.yaml \
  --param-file env/dev.env -o yaml > /tmp/output.yaml
cat /tmp/output.yaml | oc apply --dry-run=client -f -
```

### View all parameters

```bash
oc process -f kafka/openshift/manifests/template-kafka-cluster.yaml --parameters
```

### List all created resources

```bashscripts/env scripts/flink-docker scripts/flink-sql scripts/kafka-docker scripts/manifests scripts/lib.sh scripts/microshift.sh
```

### Check broker logs

```bash
oc logs kafka-0 -n kafka-dev
oc logs kafka-1 -n kafka-dev
oc logs kafka-2 -n kafka-dev
```

### Check KRaft quorum status

```bash
oc exec kafka-0 -n kafka-dev -- \
  kafka-metadata.sh --snapshot /var/lib/kafka/data/__cluster_metadata-0/00000000000000000000.log --print
```

## Production Considerations

- **Replicas**: Use odd number (3, 5) for quorum resilience
- **Storage**: Use dedicated StorageClass (fast SSD recommended)
- **Resource Requests**: Base on message throughput and retention
- **Monitoring**: Deploy Prometheus/Grafana to track broker metrics
- **Backup**: Regularly backup state log (KRaft metadata)
- **Security**: Enable SASL/TLS for inter-broker and client communication
- **Retention**: Configure topic log retention based on disk space

## Notes

- Cluster ID is auto-generated; set KAFKA_CLUSTER_ID to consistent value for re-deployments
- All resources created in specified OPENSHIFT_NAMESPACE
- StatefulSet pod names predictable: kafka-0, kafka-1, kafka-2, etc.
- Headless service enables DNS-based pod discovery

## See Also

- [OpenShift Templates Documentation](https://docs.openshift.com/container-platform/latest/openshift_images/using_templates/using-templates.html)
- [Apache Kafka KRaft Documentation](https://kafka.apache.org/documentation/#kraft)
- [Kafka Kubernetes Deployment Best Practices](https://strimzi.io/blog/2021/12/06/kafka-with-kraft/)
