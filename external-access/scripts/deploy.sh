#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}
[[ -n "${ENV_FILE}" ]] || die "usage: $0 <env-file>"
load_env "${ENV_FILE}"

: "${OPENSHIFT_NAMESPACE:?OPENSHIFT_NAMESPACE is required}"
: "${EXTERNAL_ACCESS_MODE:?EXTERNAL_ACCESS_MODE is required}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RENDER_DIR="${BASE_DIR}/.rendered/${EXTERNAL_ACCESS_MODE}"

"${SCRIPT_DIR}/render.sh" "${ENV_FILE}"

oc apply -f "${RENDER_DIR}/00-serviceaccount.yaml"
oc apply -f "${RENDER_DIR}/01-headless-service.yaml"
oc apply -f "${RENDER_DIR}/02-client-service.yaml"
oc apply -f "${RENDER_DIR}/05-envoy-bootstrap.yaml"
oc apply -f "${RENDER_DIR}/03-statefulset.yaml"
oc apply -f "${RENDER_DIR}/04-pdb.yaml"
oc apply -f "${RENDER_DIR}/06-external-services.yaml"

echo "External access overlay applied in mode ${EXTERNAL_ACCESS_MODE}"
