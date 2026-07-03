# Flink 2.3 on OpenShift Without Operators

This reference bundle targets a single OpenShift namespace with no cluster-admin privileges, no Flink operator, and one namespace-scoped service account.

For the full Ubuntu principal-engineer lifecycle (MicroShift setup, namespace bootstrap, Kafka KRaft setup, Flink dev bootstrap, day-2 operations, and teardown), use:

- [ubuntu-microshift-flink-lifecycle.md](../../runbooks/ubuntu-microshift-flink-lifecycle.md)

For one-click, non-destructive platform validation across MicroShift + Kafka + Flink, use:

- [validate-platform-all.sh](../../runbooks/scripts/validate-platform-all.sh)

## Design Intent

Use this layout when you want a durable, SQL-first Flink platform with:

- one long-lived JobManager
- a fixed TaskManager pool
- one SQL Gateway exposed through an OpenShift Route
- Kafka as both source and sink
- checkpoint, savepoint, and HA metadata stored outside the pods

This bundle assumes:

- OpenShift restricted SCC behavior with arbitrary non-root UIDs
- all workloads stay inside one namespace
- Kafka is external to the namespace
- state durability comes from object storage, not pod disks
- CI/CD submits SQL through the SQL Gateway REST API

Image baseline:

- UBI9-based build/runtime images (`registry.access.redhat.com/ubi9/ubi` and `registry.access.redhat.com/ubi9/ubi-minimal`)
- UBI images are freely redistributable and aligned to OpenShift security and runtime expectations

## Important Flink 2.3 Note

Flink 2.3 reads `config.yaml`, not `flink-conf.yaml`. The runtime config in this bundle is therefore provided as `config.yaml`.

## Bundle Layout

- [conf/config.yaml](conf/config.yaml): production-oriented Flink runtime configuration
- [env/example.env](env/example.env): single source of truth for render-time and deploy-time variables
- [manifests/00-serviceaccount-rbac.yaml](manifests/00-serviceaccount-rbac.yaml): namespace-scoped service identity and RBAC
- [manifests/01-configmap.yaml](manifests/01-configmap.yaml): config map version of the runtime configuration
- [manifests/02-secrets-example.yaml](manifests/02-secrets-example.yaml): example secret objects and mount conventions
- [manifests/03-jobmanager.yaml](manifests/03-jobmanager.yaml): JobManager service and StatefulSet
- [manifests/04-taskmanager.yaml](manifests/04-taskmanager.yaml): TaskManager StatefulSet with PVCs for local state
- [manifests/05-sql-gateway.yaml](manifests/05-sql-gateway.yaml): SQL Gateway service and Deployment
- [manifests/06-route.yaml](manifests/06-route.yaml): OpenShift Route for the SQL Gateway
- [manifests/07-namespace-identities-governance-example.yaml](manifests/07-namespace-identities-governance-example.yaml): ready-to-apply namespace, multi-identity RBAC, quota, and limit range baseline
- [manifests/08-namespace-identities-governance-dev-example.yaml](manifests/08-namespace-identities-governance-dev-example.yaml): ready-to-apply dev namespace baseline with lighter quotas
- [manifests/09-namespace-identities-governance-stage-example.yaml](manifests/09-namespace-identities-governance-stage-example.yaml): ready-to-apply stage namespace baseline with lighter quotas
- [manifests/10-namespace-identities-governance-all-environments-example.yaml](manifests/10-namespace-identities-governance-all-environments-example.yaml): umbrella manifest for dev + stage + prod in one apply
- [sql/10-session-config.sql](sql/10-session-config.sql): session-scoped execution settings
- [sql/20-kafka-source.sql](sql/20-kafka-source.sql): Kafka source table
- [sql/30-kafka-sink.sql](sql/30-kafka-sink.sql): Kafka sink table with exactly-once delivery
- [sql/40-pipeline.sql](sql/40-pipeline.sql): sample long-running insert statement
- [namespaces-and-service-identities.md](namespaces-and-service-identities.md): principal-engineer guide for multi-namespace and multi-service-account design
- [images/Dockerfile.base](images/Dockerfile.base): rootless, low-dependency Flink base image
- [images/Dockerfile.sql-runtime](images/Dockerfile.sql-runtime): SQL runtime image layered on the base image
- [scripts/create-secrets.sh](scripts/create-secrets.sh): creates or updates namespace-scoped runtime secrets with `oc create secret generic`
- [scripts/registry-login.sh](scripts/registry-login.sh): logs the local container CLI into the OpenShift registry for image pushes
- [scripts/bootstrap-ci.sh](scripts/bootstrap-ci.sh): verifies namespace access, ensures imagestreams exist, and performs registry bootstrap
- [scripts/render.sh](scripts/render.sh): renders templates into a throwaway `.rendered/` directory
- [scripts/build-images.sh](scripts/build-images.sh): builds and tags the base and SQL runtime images
- [scripts/apply-manifests.sh](scripts/apply-manifests.sh): renders and applies manifests in namespace-safe order
- [scripts/submit-sql.sh](scripts/submit-sql.sh): opens a SQL Gateway session and submits the SQL bundle
- [scripts/deploy.sh](scripts/deploy.sh): opinionated orchestration entrypoint for build, apply, and submit
- [scripts/regenerate-namespace-identities-umbrella.sh](scripts/regenerate-namespace-identities-umbrella.sh): rebuilds the all-environments namespace identity umbrella manifest from per-environment source manifests
- [scripts/validate-namespace-identities.sh](scripts/validate-namespace-identities.sh): emits a compact namespace/service-account/rolebinding/RBAC snapshot for dev, stage, and prod (or provided namespaces), with optional `--json` output for CI parsing

## Deployment Order

1. Build and push the base and SQL runtime images.
2. Create the secret objects from your real credentials.
3. Create the config map from `conf/config.yaml`.
4. Apply the RBAC, JobManager, TaskManager, SQL Gateway, and Route manifests.
5. Submit the SQL bundle through the SQL Gateway REST endpoint after rendering placeholder values.

## Scripted Workflow

The bundle now includes an opinionated script set for CI/CD and repeatable operator use.

Typical usage:

```bash
cd docs/flink/openshift
cp env/example.env env/prod.env
# edit env/prod.env with real values

scripts/render.sh env/prod.env
scripts/create-secrets.sh env/prod.env
scripts/bootstrap-ci.sh env/prod.env
scripts/build-images.sh env/prod.env
scripts/apply-manifests.sh env/prod.env --wait
scripts/submit-sql.sh env/prod.env
```

Or run the full flow:

```bash
cd docs/flink/openshift
scripts/deploy.sh env/prod.env --wait
```

Or run the full flow with CI bootstrap and secret creation in the right order:

```bash
cd docs/flink/openshift
scripts/deploy.sh env/prod.env --preflight --wait
```

The scripts deliberately assume:

- `oc` is already authenticated to the target cluster
- the caller can reach the registry host configured in the env file
- the env file contains real truststore, object-store, and registry values if you use `--create-secrets` or `--bootstrap-ci`

The scripts do not apply the example secrets by default. Instead, use [scripts/create-secrets.sh](scripts/create-secrets.sh) to create the real `flink-kafka-client`, `flink-kafka-files`, and `flink-objectstore` secrets from your environment file and truststore path.

Runtime smoke test behavior:

- [scripts/test-all-functionality.sh](scripts/test-all-functionality.sh) now performs a post-submit smoke test that pushes records to the Kafka source topic and verifies transformed records appear on the Kafka sink topic via SQL Gateway submission.
- Use `--skip-sql-smoke` only when you need to skip this end-to-end data-path assertion.

[scripts/deploy.sh](scripts/deploy.sh) supports these preflight flags:

- `--bootstrap-ci`: run registry login and imagestream bootstrap before image builds
- `--create-secrets`: create or update runtime secrets before manifest apply
- `--preflight`: enable both `--bootstrap-ci` and `--create-secrets`

## CI Bootstrap Notes

Runtime manifests pull the Flink image from `SQL_RUNTIME_IMAGE_REF` in your env file.

Simplest local/dev approach:

- Use GitHub Container Registry and set `IMAGE_REGISTRY=ghcr.io/<owner-or-org>`.
- Keep `BASE_IMAGE_REF` and `SQL_RUNTIME_IMAGE_REF` derived from that value.

Alternative:

- Use OpenShift internal registry host/route if your cluster exposes it and your build runner can push to it.

Private registry support:

- Set `REGISTRY_LOGIN_USERNAME` and `REGISTRY_LOGIN_PASSWORD` in env.
- During `scripts/bootstrap-ci.sh`, a docker-registry pull secret (default `REGISTRY_PULL_SECRET_NAME=ghcr-pull`) is created/updated and linked to `flink-runner`.

## Namespace And Identity Model

If you need to create multiple namespaces and multiple namespace-scoped service identities for environments such as dev, stage, and prod, see [namespaces-and-service-identities.md](namespaces-and-service-identities.md).

That guide covers:

- one-namespace-per-environment design
- multiple service accounts per namespace
- least-privilege RBAC for runtime, deployer, submitter, and observer identities
- validation with `oc auth can-i`

## Local MicroShift Platform Docs

All local MicroShift or MINC installation, runtime configuration, and host-level operational guidance now lives under [docs/microshift](../../microshift/README.md).

Use:

- [docs/microshift/README.md](../../microshift/README.md)
- [docs/microshift/install.md](../../microshift/install.md)
- [docs/microshift/configure.md](../../microshift/configure.md)

## Connector Caveat

At the time of writing, Flink 2.3 documentation still notes that there is no published Kafka table connector artifact aligned to 2.3 yet. This bundle therefore assumes your platform team stages an organization-approved Kafka connector JAR in the image build context instead of pulling an assumed Maven coordinate.

## Production Guardrails

- Keep connector JARs version-aligned with the Flink 2.3 runtime.
- Treat SQL files as templates and inject secrets at deploy time rather than committing them.
- Keep checkpoints, savepoints, and HA storage on object storage with read-after-write consistency.
- Use PVCs only for local RocksDB spill, local recovery, and process working directories.
- Expose only the SQL Gateway. Keep JobManager and TaskManager services cluster-internal.