#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}
[[ -n "${ENV_FILE}" ]] || die "usage: $0 <env-file>"
load_env "${ENV_FILE}"

: "${OPENSHIFT_NAMESPACE:?OPENSHIFT_NAMESPACE is required}"
: "${EXTERNAL_ACCESS_MODE:?EXTERNAL_ACCESS_MODE is required}"
: "${KAFKA_EXTERNAL_BROKER_HOSTS:?KAFKA_EXTERNAL_BROKER_HOSTS is required}"
: "${KAFKA_EXTERNAL_BROKER_PORTS:?KAFKA_EXTERNAL_BROKER_PORTS is required}"

oc get sts,pods,svc,pvc,pdb -n "${OPENSHIFT_NAMESPACE}"
oc rollout status sts/kafka-external -n "${OPENSHIFT_NAMESPACE}" --timeout=10m

echo "External access mode: ${EXTERNAL_ACCESS_MODE}"
echo "Advertised broker hostnames: ${KAFKA_EXTERNAL_BROKER_HOSTS}"
echo "Advertised broker ports: ${KAFKA_EXTERNAL_BROKER_PORTS}"
echo "Render output: ${BASE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}/.rendered/${EXTERNAL_ACCESS_MODE}"
