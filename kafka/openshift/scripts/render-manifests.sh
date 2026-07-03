#!/usr/bin/env bash

set -euo pipefail

ENV_FILE=${1:-}
[[ -n "${ENV_FILE}" ]] || { echo "usage: $0 <env-file>" >&2; exit 1; }
[[ -f "${ENV_FILE}" ]] || { echo "env file not found: ${ENV_FILE}" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

: "${OPENSHIFT_NAMESPACE:?OPENSHIFT_NAMESPACE is required}"
: "${KAFKA_IMAGE:?KAFKA_IMAGE is required}"
: "${KAFKA_CLUSTER_ID:?KAFKA_CLUSTER_ID is required}"
: "${KAFKA_REPLICAS:=3}"
: "${KAFKA_STORAGE_CLASS:=}"
: "${KAFKA_STORAGE_SIZE:=50Gi}"
: "${KAFKA_DEFAULT_REPLICATION_FACTOR:=3}"
: "${KAFKA_MIN_INSYNC_REPLICAS:=2}"
: "${KAFKA_NUM_PARTITIONS:=6}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RENDER_DIR="${BASE_DIR}/.rendered/manifests"

mkdir -p "${RENDER_DIR}"

cp "${BASE_DIR}/manifests/00-serviceaccount.yaml" "${RENDER_DIR}/00-serviceaccount.yaml"
cp "${BASE_DIR}/manifests/01-headless-service.yaml" "${RENDER_DIR}/01-headless-service.yaml"
cp "${BASE_DIR}/manifests/02-client-service.yaml" "${RENDER_DIR}/02-client-service.yaml"
cp "${BASE_DIR}/manifests/04-pdb.yaml" "${RENDER_DIR}/04-pdb.yaml"

python3 - "${BASE_DIR}/manifests/03-statefulset.yaml" "${RENDER_DIR}/03-statefulset.yaml" <<'PY'
import pathlib
import sys
import os

src = pathlib.Path(sys.argv[1]).read_text()
repl = {
    'image: image-registry.openshift-image-registry.svc:5000/kafka-dev/kafka-kraft:3.7.1': f'image: {os.environ["KAFKA_IMAGE"]}',
    'value: "REPLACE_ME_CLUSTER_ID"': f'value: "{os.environ["KAFKA_CLUSTER_ID"]}"',
    'value: "3"': f'value: "{os.environ.get("KAFKA_REPLICAS", "3")}"',
    'storage: 50Gi': f'storage: {os.environ.get("KAFKA_STORAGE_SIZE", "50Gi")}',
    'value: "6"': f'value: "{os.environ.get("KAFKA_NUM_PARTITIONS", "6")}"',
}
# Replace each unique token carefully in sequence.
out = src
out = out.replace('image: image-registry.openshift-image-registry.svc:5000/kafka-dev/kafka-kraft:3.7.1', repl['image: image-registry.openshift-image-registry.svc:5000/kafka-dev/kafka-kraft:3.7.1'])
out = out.replace('value: "REPLACE_ME_CLUSTER_ID"', repl['value: "REPLACE_ME_CLUSTER_ID"'])
# Only replace the specific replicas value for KAFKA_REPLICAS line first occurrence after env key.
out = out.replace('            - name: KAFKA_REPLICAS\n              value: "3"', f'            - name: KAFKA_REPLICAS\n              value: "{os.environ.get("KAFKA_REPLICAS", "3")}"')
out = out.replace('            - name: KAFKA_DEFAULT_REPLICATION_FACTOR\n              value: "3"', f'            - name: KAFKA_DEFAULT_REPLICATION_FACTOR\n              value: "{os.environ.get("KAFKA_DEFAULT_REPLICATION_FACTOR", "3")}"')
out = out.replace('            - name: KAFKA_MIN_INSYNC_REPLICAS\n              value: "2"', f'            - name: KAFKA_MIN_INSYNC_REPLICAS\n              value: "{os.environ.get("KAFKA_MIN_INSYNC_REPLICAS", "2")}"')
out = out.replace('            - name: KAFKA_NUM_PARTITIONS\n              value: "6"', f'            - name: KAFKA_NUM_PARTITIONS\n              value: "{os.environ.get("KAFKA_NUM_PARTITIONS", "6")}"')
out = out.replace('            storage: 50Gi', f'            storage: {os.environ.get("KAFKA_STORAGE_SIZE", "50Gi")}')
storage_class = os.environ.get("KAFKA_STORAGE_CLASS", "").strip()
if storage_class:
    out = out.replace(
        '        accessModes: ["ReadWriteOnce"]\n',
        '        accessModes: ["ReadWriteOnce"]\n        storageClassName: ' + storage_class + '\n'
    )
pathlib.Path(sys.argv[2]).write_text(out)
PY

echo "Rendered manifests to ${RENDER_DIR}"
