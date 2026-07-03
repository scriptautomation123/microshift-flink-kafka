# MicroShift Platform Runbook

This directory contains the principal-engineer operating docs and helper scripts for local MicroShift bring-up on Ubuntu using MINC and Podman.

## Scope

Use this runbook set for:

- host preparation and package installation
- `oc` and `minc` installation
- Podman DNS and runtime configuration
- Docker and Podman coexistence hardening
- cluster validation and troubleshooting

Keep Flink runtime deployment docs in `docs/flink/openshift` and keep local platform operations in this directory.

For the full end-to-end Ubuntu operator path (platform + Flink + day-2 + teardown), start with:

- `../runbooks/ubuntu-microshift-flink-lifecycle.md`

## Document Index

- `install.md`: host prerequisites, client installation, and cluster bootstrap
- `configure.md`: runtime DNS, Docker coexistence forwarding, validation, rebuild, cleanup, and troubleshooting

## Next Step Into Flink Platform Docs

After local platform validation is complete, continue with namespace and service identity setup in:

- `../flink/openshift/namespaces-and-service-identities.md`

## Script Index

- `scripts/configure-podman-dns.sh`: writes `/etc/containers/containers.conf` DNS settings
- `scripts/install-docker-podman-forwarding.sh`: installs and enables a systemd oneshot service to allow `podman0` forwarding through `DOCKER-USER`
- `scripts/provision-local-pv.sh`: provisions static local PersistentVolumes for Kafka and Flink PVCs on single-node local clusters

## Typical Workflow

```bash
cd docs/microshift

# 1) install dependencies and clients by following install.md
# 2) configure runtime by following configure.md

# optional helpers
sudo scripts/configure-podman-dns.sh 1.1.1.1 8.8.8.8
sudo scripts/install-docker-podman-forwarding.sh

# optional but recommended on local MINC clusters without dynamic storage class
scripts/provision-local-pv.sh --kafka-namespace kafka-dev --flink-namespace flink-dev
```
