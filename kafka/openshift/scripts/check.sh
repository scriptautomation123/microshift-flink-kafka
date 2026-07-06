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

oc get sts,pods,svc,pvc,pdb -n "${OPENSHIFT_NAMESPACE}"
oc rollout status sts/kafka -n "${OPENSHIFT_NAMESPACE}" --timeout=10m

echo "Kafka bootstrap service endpoints:"
oc get endpoints -n "${OPENSHIFT_NAMESPACE}" kafka -o wide

echo "Suggested topic creation command:"
echo "kafka/openshift/scripts/create-topic.sh kafka/openshift/env/dev.env --topic <topic>"

echo "Suggested topic describe command with local Kafka CLI tools:"
echo "oc port-forward -n ${OPENSHIFT_NAMESPACE} svc/kafka 9092:9092 &"
echo "kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic <topic>"
