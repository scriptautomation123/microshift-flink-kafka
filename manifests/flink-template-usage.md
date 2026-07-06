# OpenShift Template: Flink SQL Gateway

## Overview

`template-flink-sql-gateway.yaml` is an OpenShift template that deploys a complete Flink SQL Gateway cluster with:
- **JobManager** (1 StatefulSet replica)
- **TaskManagers** (configurable replicas, default 3)
- **SQL Gateway** (2 Deployment replicas)
- **High Availability** (Kubernetes-based HA with persistent storage)
- **Storage** (RocksDB state backend with checkspoints/savepoints)

## Template Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `OPENSHIFT_NAMESPACE` | Yes | - | OpenShift namespace for deployment |
| `FLINK_CLUSTER_ID` | Yes | flink-cluster | Unique cluster identifier for HA |
| `SQL_RUNTIME_IMAGE_REF` | Yes | ghcr.io/owner/flink-sql-runtime:2.3.0 | Container image URL |
| `HA_STORAGE_URI` | Yes | - | HA storage URI (s3://, gs://, or local PV) |
| `CHECKPOINT_URI` | Yes | - | Checkpoint storage URI |
| `SAVEPOINT_URI` | Yes | - | Savepoint storage URI |
| `JOBMANAGER_MEMORY` | No | 3 | JobManager memory (Gi) |
| `JOBMANAGER_STORAGE` | No | 20 | JobManager storage (Gi) |
| `TASKMANAGER_REPLICAS` | No | 3 | Number of TaskManager replicas |
| `TASKMANAGER_MEMORY` | No | 12 | TaskManager memory per pod (Gi) |
| `TASKMANAGER_STORAGE` | No | 100 | TaskManager storage per pod (Gi) |
| `TASKMANAGER_SLOTS` | No | 2 | Task slots per TaskManager |
| `PARALLELISM_DEFAULT` | No | 4 | Default parallelism |
| `ROUTE_HOST` | Yes | - | Route hostname (e.g., flink-sql-gateway-prod.apps.example.com) |

## Usage Examples

### 1. Create from template with parameters file

```bash
oc process -f flink/openshift/manifests/template-flink-sql-gateway.yaml \
  --param-file env/dev.env \
  | oc apply -f -
```

### 2. Create from template with inline parameters

```bash
oc process -f flink/openshift/manifests/template-flink-sql-gateway.yaml \
  -p OPENSHIFT_NAMESPACE=flink-dev \
  -p FLINK_CLUSTER_ID=flink-dev-cluster \
  -p SQL_RUNTIME_IMAGE_REF=ghcr.io/org/flink-sql-runtime:2.3.0 \
  -p HA_STORAGE_URI=s3://my-bucket/flink/ha \
  -p CHECKPOINT_URI=s3://my-bucket/flink/checkpoints \
  -p SAVEPOINT_URI=s3://my-bucket/flink/savepoints \
  -p ROUTE_HOST=flink-sql-gateway-dev.apps.example.com \
  | oc apply -f -
```

### 3. Preview template expansion (dry-run)

```bash
oc process -f flink/openshift/manifests/template-flink-sql-gateway.yaml \
  --param-file env/dev.env \
  -o yaml > /tmp/flink-preview.yaml

# Review before applying
cat /tmp/flink-preview.yaml
```

### 4. Delete resources created from template

```bash
oc delete all,cm,secret,pvc -l app.kubernetes.io/name=flink -n flink-dev
```

## Parameter File Format

Create `env/template-params.env`:

```bash
# Required
OPENSHIFT_NAMESPACE=flink-dev
FLINK_CLUSTER_ID=flink-dev-01
SQL_RUNTIME_IMAGE_REF=quay.io/myorg/flink-sql-runtime:2.3.0
HA_STORAGE_URI=s3://my-state-bucket/ha
CHECKPOINT_URI=s3://my-state-bucket/checkpoints
SAVEPOINT_URI=s3://my-state-bucket/savepoints
ROUTE_HOST=flink-sql-gateway-dev.apps.cluster.example.com

# Optional (uses defaults if omitted)
JOBMANAGER_MEMORY=3
TASKMANAGER_REPLICAS=3
TASKMANAGER_MEMORY=12
```

Then process:

```bash
oc process -f flink/openshift/manifests/template-flink-sql-gateway.yaml \
  --param-file env/template-params.env | oc apply -f -
```

## What Gets Created

### ConfigMap
- `flink-config` — Complete Flink configuration (config.yaml)

### Secrets
- `flink-kafka-client` — Kafka connection credentials (placeholder)
- `flink-kafka-files` — Kafka truststore/certificates
- `flink-objectstore` — AWS S3 credentials for HA/checkpoints

### JobManager
- Service: `flink-jobmanager` (headless, ports 6123, 6124, 8081)
- StatefulSet: 1 replica with persistent volume for HA

### TaskManagers
- Service: `flink-taskmanager` (headless)
- StatefulSet: N replicas (configurable) with persistent volumes

### SQL Gateway
- Service: `flink-sql-gateway` (port 8083)
- Deployment: 2 replicas for HA
- Route: HTTPS edge-terminated route to SQL Gateway

## Persistent Storage

The template creates PersistentVolumeClaims (PVCs) for:
- JobManager: `${JOBMANAGER_STORAGE}Gi` per replica
- TaskManagers: `${TASKMANAGER_STORAGE}Gi` per replica

Storage class defaults to cluster default. To use specific StorageClass, edit template or add StorageClass parameter.

## Accessing SQL Gateway

After deployment:

```bash
# Get SQL Gateway route
oc get route flink-sql-gateway -n flink-dev -o jsonpath='{.spec.host}'

# Query SQL Gateway API
curl -X GET https://flink-sql-gateway-dev.apps.example.com/api/v1/sessions
```

## Upgrading Configuration

To update Flink configuration:

1. Edit `template-flink-sql-gateway.yaml` (ConfigMap data section)
2. Reprocess and apply template
3. Roll out JobManager/TaskManagers:

```bash
oc rollout restart statefulset/flink-jobmanager -n flink-dev
oc rollout restart statefulset/flink-taskmanager -n flink-dev
```

## Troubleshooting

### Check template syntax
```bash
oc process -f flink/openshift/manifests/template-flink-sql-gateway.yaml --param-file env/dev.env -o yaml > /tmp/output.yaml
cat /tmp/output.yaml | oc apply --dry-run=client -f -
```

### View all parameters
```bash
oc process -f flink/openshift/manifests/template-flink-sql-gateway.yaml --parameters
```

### List all created resources
```bash
oc get all,cm,secret,pvc -l app.kubernetes.io/name=flink -n flink-dev
```

## Notes

- Replace `replace-me` placeholder values in secrets with real credentials
- HA_STORAGE_URI, CHECKPOINT_URI, SAVEPOINT_URI must be writable by container
- For local development, use local PV mounted paths instead of S3
- Template assumes `flink-runner` ServiceAccount exists (created separately)
- All resources are created in specified OPENSHIFT_NAMESPACE

## See Also

- [OpenShift Templates Documentation](https://docs.openshift.com/container-platform/latest/openshift_images/using_templates/using-templates.html)
- [Flink on Kubernetes](https://nightlies.apache.org/flink/flink-kubernetes-operator-stable/docs/deployment/native_kubernetes/)
