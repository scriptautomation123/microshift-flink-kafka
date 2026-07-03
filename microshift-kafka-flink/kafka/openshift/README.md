# Kafka KRaft On OpenShift Without Operators

This package provides a principal-engineer baseline to run Apache Kafka in KRaft mode on OpenShift using only namespace-scoped resources:

- no Kafka operator
- no cluster-admin requirements for deployment
- no ZooKeeper
- StatefulSet + headless service
- rootless-compatible container image built from Apache Kafka binaries

Image baseline:

- UBI9-based container images (`registry.access.redhat.com/ubi9/ubi` and `registry.access.redhat.com/ubi9/ubi-minimal`)
- UBI images are freely redistributable and suitable for OpenShift restricted SCC patterns

This is inspired by the high-availability principles from Learnkube's Kafka HA pattern and adapted for OpenShift namespace-scoped operation.

## What You Get

- `images/Dockerfile.kraft`: rootless-compatible Kafka image built from Apache Kafka OSS binaries
- `images/bin/start-kafka-kraft.sh`: startup script that derives broker identity from StatefulSet ordinal
- `manifests/00-serviceaccount.yaml`: namespace-scoped service account
- `manifests/01-headless-service.yaml`: stable network identities for brokers
- `manifests/02-client-service.yaml`: in-cluster bootstrap service
- `manifests/03-statefulset.yaml`: 3-node KRaft StatefulSet with PVCs
- `manifests/04-pdb.yaml`: disruption guardrail (`minAvailable: 2`)
- `env/example.env`: deployment-time variables
- `scripts/build-image.sh`: build and push Kafka KRaft image
- `scripts/deploy.sh`: apply manifests in order
- `scripts/check.sh`: readiness and topic-level checks
- `scripts/delete.sh`: remove Kafka resources

## Design Notes

1. KRaft only: `process.roles=broker,controller`, `controller.quorum.voters` derived from pod ordinals.
2. Stable identity: StatefulSet pod hostnames (`kafka-0`, `kafka-1`, `kafka-2`) plus headless service.
3. Persistent data: one PVC per broker.
4. HA defaults: `default.replication.factor=3`, `min.insync.replicas=2`.
5. OpenShift-safe: non-root runtime, writable group permissions.

## Quick Start

```bash
cd docs/kafka/openshift
cp env/example.env env/dev.env
# edit env/dev.env

scripts/build-image.sh env/dev.env
scripts/deploy.sh env/dev.env
scripts/check.sh env/dev.env
```

## What To Configure In env/dev.env

- `OPENSHIFT_NAMESPACE`
- `KAFKA_IMAGE`
- `KAFKA_CLUSTER_ID` (use script below)
- `KAFKA_STORAGE_CLASS`
- `KAFKA_STORAGE_SIZE`

Registry recommendation:

- Simplest local/dev path is GitHub Container Registry, for example:
  `KAFKA_IMAGE=ghcr.io/<owner-or-org>/kafka-kraft:3.7.1`
- If OpenShift internal registry is available and reachable from your runner, you can use that instead.

Private registry support:

- Set `REGISTRY_LOGIN_USERNAME` and `REGISTRY_LOGIN_PASSWORD` in env.
- `scripts/deploy.sh` will create/update a docker-registry secret (default `REGISTRY_PULL_SECRET_NAME=ghcr-pull`) and link it to `kafka-runner` for image pulls.

Storage note for local MINC clusters:

- If no default dynamic `StorageClass` exists, pre-provision static local PVs before deploy:
  `docs/microshift/scripts/provision-local-pv.sh --kafka-only --kafka-namespace <namespace>`

Generate a cluster id:

```bash
docs/kafka/openshift/scripts/generate-kraft-cluster-id.sh
```

## Day-2 Operations

For the full Ubuntu principal-engineer lifecycle (MicroShift setup, namespace bootstrap, Kafka KRaft setup, Flink setup, day-2 operations, and teardown), use:

- [ubuntu-microshift-flink-lifecycle.md](../../runbooks/ubuntu-microshift-flink-lifecycle.md)

For one-click, non-destructive platform validation across MicroShift + Kafka + Flink, use:

- [validate-platform-all.sh](../../runbooks/scripts/validate-platform-all.sh)

For principal-engineer hardening and HA failure drills (node drain, broker replacement, ISR verification), use:

- [hardening-and-failure-drills.md](hardening-and-failure-drills.md)

For a non-destructive pre/post maintenance validation helper (health + topic describe + ISR assertions), use:

- [scripts/maintenance-guard.sh](scripts/maintenance-guard.sh)

Example:

```bash
docs/kafka/openshift/scripts/maintenance-guard.sh docs/kafka/openshift/env/dev.env --topic ha-drill --phase pre
docs/kafka/openshift/scripts/maintenance-guard.sh docs/kafka/openshift/env/dev.env --topic ha-drill --phase post
```

Scale brokers (example):

```bash
oc scale sts/kafka -n <namespace> --replicas=3
```

Check StatefulSet and PVC health:

```bash
oc get sts,pods,pvc -n <namespace>
```

Validate topic replication and ISR from a broker pod:

```bash
oc exec -n <namespace> kafka-0 -- /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server kafka.<namespace>.svc:9092 \
  --describe
```

## Cleanup

```bash
docs/kafka/openshift/scripts/delete.sh env/dev.env
```

If you also want namespace deletion, do it explicitly:

```bash
oc delete ns <namespace>
```
