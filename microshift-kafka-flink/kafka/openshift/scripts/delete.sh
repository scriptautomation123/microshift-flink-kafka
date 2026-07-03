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

oc delete -n "${OPENSHIFT_NAMESPACE}" pdb/kafka --ignore-not-found
oc delete -n "${OPENSHIFT_NAMESPACE}" sts/kafka --ignore-not-found
oc delete -n "${OPENSHIFT_NAMESPACE}" svc/kafka svc/kafka-headless --ignore-not-found
oc delete -n "${OPENSHIFT_NAMESPACE}" sa/kafka-runner --ignore-not-found

echo "Kafka resources deleted from namespace ${OPENSHIFT_NAMESPACE}."
echo "PVCs are retained by default; delete manually if you want full data removal:"
echo "oc delete pvc -n ${OPENSHIFT_NAMESPACE} -l app.kubernetes.io/name=kafka"
