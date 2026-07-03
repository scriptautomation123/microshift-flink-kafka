# swapan-info

## Getting Started

Fastest path to run the full local lifecycle with automatic GHCR wiring:

```bash
export GH_OWNER="scriptautomation123"
export GH_USER="YOUR_GITHUB_USERNAME"
export GH_PAT="YOUR_GITHUB_PAT_WITH_PACKAGES_READ_WRITE"

docs/runbooks/scripts/test-all --clean --auto-ghcr --kafka-topic ha-drill
```

How to run with SQL smoke enabled (default):

```bash
docs/runbooks/scripts/test-all --clean --auto-ghcr --kafka-topic ha-drill
```

How to skip SQL smoke if needed:

```bash
docs/runbooks/scripts/test-all --clean --auto-ghcr --flink-skip-sql-smoke
```

What this does:

- Runs MicroShift, Kafka, and Flink end-to-end using [docs/runbooks/scripts/test-all](docs/runbooks/scripts/test-all).
- Auto-generates temporary GHCR-ready env files for `kafka-dev` and `flink-dev`.
- If `GH_USER` and `GH_PAT` are set, logs into GHCR and creates/links image pull secrets for Kafka and Flink service accounts.
- After deploy, performs a Flink SQL Gateway smoke test that writes sample data to Kafka source topic and verifies sink output.

One-click full teardown:

```bash
docs/runbooks/scripts/cleanup-all --purge-local-data
```

This removes Kafka/Flink namespaces, deletes the MicroShift cluster, and (with `--purge-local-data`) removes local hostPath PV data directories.

Notes:

- If `GH_OWNER` is not set, `test-all` attempts to derive owner from git origin.
- Auto GHCR mode uses temporary generated env files and does not overwrite existing env files.
- Local static PV setup is handled by the MicroShift flow unless `--microshift-skip-local-pv` is passed.
- Use `--flink-skip-sql-smoke` only if you intentionally want to skip Kafka-backed SQL data-path verification.

Prerequisites:

- `oc` authenticated against your local cluster.
- `minc` available for local MicroShift lifecycle.
- `podman` or `docker` installed for image build/push.

## Platform Runbooks

- Unified Ubuntu lifecycle runbook (MicroShift + Kafka + Flink): [docs/runbooks/ubuntu-microshift-flink-lifecycle.md](docs/runbooks/ubuntu-microshift-flink-lifecycle.md)
- One-click clean rebuild + full stack test: [docs/runbooks/scripts/test-all](docs/runbooks/scripts/test-all)
- One-click full teardown: [docs/runbooks/scripts/cleanup-all](docs/runbooks/scripts/cleanup-all)
- One-click full platform validator: [docs/runbooks/scripts/validate-platform-all.sh](docs/runbooks/scripts/validate-platform-all.sh)
- MicroShift local platform runbooks: [docs/microshift/README.md](docs/microshift/README.md)
- Flink on OpenShift platform bundle: [docs/flink/openshift/README.md](docs/flink/openshift/README.md)
- Kafka KRaft on OpenShift (no operator): [docs/kafka/openshift/README.md](docs/kafka/openshift/README.md)
