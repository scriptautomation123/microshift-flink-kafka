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

echo "Suggested topic describe command:"
echo "oc exec -n ${OPENSHIFT_NAMESPACE} kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka.${OPENSHIFT_NAMESPACE}.svc:9092 --describe"
