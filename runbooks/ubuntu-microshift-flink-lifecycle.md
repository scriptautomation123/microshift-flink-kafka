# Ubuntu MicroShift + Kafka + Flink Lifecycle Runbook (Principal Engineer)

This is the single operational entrypoint for:

1. Local MicroShift setup on Ubuntu
2. Namespace and service identity bootstrap
3. Kafka KRaft setup (no operator, no ZooKeeper)
4. Flink dev bootstrap from scratch
5. Day-2 update and management for both Kafka and Flink
6. Targeted cleanup and full teardown
7. One-click validation of platform functionality

Use this runbook as the primary workflow and follow linked package docs for deeper details.

## 0. Scope And Operating Model

This runbook targets:

- Ubuntu host
- MINC-based local MicroShift cluster
- Kafka KRaft platform under [docs/kafka/openshift](../kafka/openshift/README.md)
- Flink SQL platform under [docs/flink/openshift](../flink/openshift/README.md)
- Namespace-scoped RBAC and service identities

This runbook assumes you operate as a platform owner in a local environment where `oc` can authenticate with sufficient privileges.

## 1. Platform Setup (MicroShift First)

Primary source docs:

- [docs/microshift/install.md](../microshift/install.md)
- [docs/microshift/configure.md](../microshift/configure.md)

Execution order:

1. Install host prerequisites, `oc`, and `minc`.
2. Configure Podman DNS and Docker coexistence forwarding (if Docker is running).
3. Create/recreate the cluster with MINC.
4. Provision local static PVs for Kafka/Flink namespaces when dynamic storage class is not present.
5. Validate baseline (`oc whoami`, node `Ready`, ingress/router pod health).

Recommended local PV provisioning command:

```bash
cd docs/microshift
scripts/provision-local-pv.sh --kafka-namespace kafka-dev --flink-namespace flink-dev
```

Hard gate before moving forward:

- Cluster is healthy per [docs/microshift/configure.md](../microshift/configure.md).

## 2. Namespace Bootstrap

Create Flink namespace identities from repository manifests:

```bash
cd /home/swapanc/Documents/swapan-info
export PATH="$HOME/.local/bin:$PATH"
oc apply -f docs/flink/openshift/manifests/08-namespace-identities-governance-dev-example.yaml
```

Create Kafka namespace if absent (or keep explicit in env file and let deploy create it):

```bash
oc new-project kafka-dev || true
```

## 3. Kafka KRaft Setup From Scratch

Primary source docs:

- [docs/kafka/openshift/README.md](../kafka/openshift/README.md)
- [docs/kafka/openshift/hardening-and-failure-drills.md](../kafka/openshift/hardening-and-failure-drills.md)

### 3.1 Create Kafka dev env

```bash
cd docs/kafka/openshift
cp env/example.env env/dev.env
```

Set required values in `env/dev.env`:

- `OPENSHIFT_NAMESPACE=kafka-dev`
- `KAFKA_IMAGE` (simplest local/dev choice: `ghcr.io/<owner-or-org>/kafka-kraft:3.7.1`)
- `KAFKA_CLUSTER_ID` (generate with [generate-kraft-cluster-id.sh](../kafka/openshift/scripts/generate-kraft-cluster-id.sh))
- storage fields (`KAFKA_STORAGE_CLASS`, `KAFKA_STORAGE_SIZE`)

### 3.2 Build and deploy Kafka

```bash
cd docs/kafka/openshift
scripts/build-image.sh env/dev.env
scripts/deploy.sh env/dev.env
scripts/check.sh env/dev.env
```

## 4. Flink Dev Bootstrap From Scratch

Primary source docs:

- [docs/flink/openshift/README.md](../flink/openshift/README.md)
- [docs/flink/openshift/namespaces-and-service-identities.md](../flink/openshift/namespaces-and-service-identities.md)

### 4.1 Create Flink dev env

```bash
cd docs/flink/openshift
cp env/example.env env/dev.env
```

Set required values in `env/dev.env`:

- `OPENSHIFT_NAMESPACE=flink-dev`
- `FLINK_CLUSTER_ID`
- `IMAGE_REGISTRY` (simplest local/dev choice: `ghcr.io/<owner-or-org>`)
- Kafka endpoint/auth settings (point to your Kafka deployment or external Kafka)
- object-store and truststore settings
- `SQL_GATEWAY_BASE_URL`

### 4.2 Stage required connector JARs

Place both files before image build:

- [docs/flink/openshift/images/third_party/flink-sql-connector-kafka.jar](../flink/openshift/images/third_party/flink-sql-connector-kafka.jar)
- [docs/flink/openshift/images/third_party/flink-json.jar](../flink/openshift/images/third_party/flink-json.jar)

### 4.3 Deploy Flink dev end-to-end

```bash
cd docs/flink/openshift
scripts/deploy.sh env/dev.env --preflight --wait
scripts/validate-namespace-identities.sh --json flink-dev
```

## 5. Day-2 Operations (Kafka + Flink)

### 5.1 Kafka day-2

1. Re-run health checks:

```bash
docs/kafka/openshift/scripts/check.sh docs/kafka/openshift/env/dev.env
```

2. Run non-destructive maintenance guard before/after maintenance:

```bash
docs/kafka/openshift/scripts/maintenance-guard.sh docs/kafka/openshift/env/dev.env --topic ha-drill --phase pre
docs/kafka/openshift/scripts/maintenance-guard.sh docs/kafka/openshift/env/dev.env --topic ha-drill --phase post
```

3. Follow failure drills:

- [docs/kafka/openshift/hardening-and-failure-drills.md](../kafka/openshift/hardening-and-failure-drills.md)

### 5.2 Flink day-2

1. Update namespace governance safely:

```bash
docs/flink/openshift/scripts/regenerate-namespace-identities-umbrella.sh
docs/flink/openshift/scripts/regenerate-namespace-identities-umbrella.sh --check
```

2. Update runtime config or SQL, then redeploy:

```bash
cd docs/flink/openshift
scripts/deploy.sh env/dev.env --wait
```

3. Rotate secrets:

```bash
cd docs/flink/openshift
scripts/create-secrets.sh env/dev.env
```

4. Verify RBAC drift:

```bash
cd docs/flink/openshift
scripts/validate-namespace-identities.sh --json flink-dev flink-stage flink-prod
```

## 6. Cleanup Paths

### 6.1 Kafka-only cleanup (keep cluster)

```bash
docs/kafka/openshift/scripts/delete.sh docs/kafka/openshift/env/dev.env
```

Optional destructive data wipe:

```bash
oc delete pvc -n kafka-dev -l app.kubernetes.io/name=kafka
```

### 6.2 Flink-only cleanup (keep cluster)

```bash
export PATH="$HOME/.local/bin:$PATH"
oc delete -n flink-dev deploy/flink-sql-gateway --ignore-not-found
oc delete -n flink-dev sts/flink-jobmanager sts/flink-taskmanager --ignore-not-found
oc delete -n flink-dev svc/flink-sql-gateway flink-jobmanager --ignore-not-found
oc delete -n flink-dev route/flink-sql-gateway --ignore-not-found
```

Optional Flink namespace reset:

```bash
oc delete ns flink-dev --ignore-not-found
```

## 7. Full Teardown (Delete Both Platform And Workloads)

### 7.1 Delete workload namespaces

```bash
export PATH="$HOME/.local/bin:$PATH"
oc delete ns kafka-dev flink-dev flink-stage flink-prod --ignore-not-found
```

One-click equivalent:

```bash
docs/runbooks/scripts/cleanup-all --skip-cluster-delete
```

### 7.2 Delete MicroShift cluster

```bash
minc delete
```

One-click equivalent (namespaces + cluster):

```bash
docs/runbooks/scripts/cleanup-all
```

### 7.3 Optional higher-impact Podman cleanup

Follow cleanup/reset sections in [docs/microshift/configure.md](../microshift/configure.md).

To also remove local hostPath PV data created by the local PV helper:

```bash
docs/runbooks/scripts/cleanup-all --purge-local-data
```

## 8. One-Click Functional Validation

Full rebuild-and-validate orchestrator (principal engineer):

- [docs/runbooks/scripts/test-all](scripts/test-all)
- [docs/runbooks/scripts/cleanup-all](scripts/cleanup-all)

Component full-function runners:

- [docs/microshift/scripts/test-all-functionality.sh](../microshift/scripts/test-all-functionality.sh)
- [docs/kafka/openshift/scripts/test-all-functionality.sh](../kafka/openshift/scripts/test-all-functionality.sh)
- [docs/flink/openshift/scripts/test-all-functionality.sh](../flink/openshift/scripts/test-all-functionality.sh)

One-click clean rebuild of everything:

```bash
docs/runbooks/scripts/test-all --clean \
	--kafka-env docs/kafka/openshift/env/dev.env \
	--flink-env docs/flink/openshift/env/dev.env \
	--kafka-topic ha-drill
```

One-click clean rebuild with automatic GHCR wiring (temporary envs generated at runtime):

```bash
export GH_OWNER=scriptautomation123
export GH_USER=<github-username>
export GH_PAT=<github-pat-with-packages-read-write>

docs/runbooks/scripts/test-all --clean --auto-ghcr --kafka-topic ha-drill
```

Skip SQL smoke validation when needed:

```bash
docs/runbooks/scripts/test-all --clean --auto-ghcr --flink-skip-sql-smoke
```

Notes:

- `--auto-ghcr` sets Kafka/Flink env values for `kafka-dev` and `flink-dev`, including image refs.
- If `GH_USER` and `GH_PAT` are set, `test-all` logs your local container CLI into GHCR and passes credentials to component scripts to create namespace pull secrets.
- `test-all` now includes a post-install Flink SQL smoke test that pushes records to Kafka source topic and verifies sink output through SQL Gateway-submitted pipeline.

Use the one-click validator to repeatedly validate static and runtime functionality across MicroShift, Kafka, and Flink:

- [docs/runbooks/scripts/validate-platform-all.sh](scripts/validate-platform-all.sh)

Example:

```bash
docs/runbooks/scripts/validate-platform-all.sh \
	--kafka-env docs/kafka/openshift/env/dev.env \
	--flink-env docs/flink/openshift/env/dev.env \
	--kafka-topic ha-drill
```

Useful flags:

- `--skip-runtime`: run static/syntax/render checks without cluster runtime checks.
- `--strict`: treat missing optional inputs/skips as failures.
- `--json`: emit machine-readable check and summary records.

## 9. Reference Map

- Platform setup and host/runtime troubleshooting: [docs/microshift/README.md](../microshift/README.md)
- Kafka deployment bundle and drills: [docs/kafka/openshift/README.md](../kafka/openshift/README.md)
- Flink deployment bundle and script flow: [docs/flink/openshift/README.md](../flink/openshift/README.md)
- Namespace and identity governance: [docs/flink/openshift/namespaces-and-service-identities.md](../flink/openshift/namespaces-and-service-identities.md)
