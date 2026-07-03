#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}

load_env "${ENV_FILE}"
require_commands oc
require_env OPENSHIFT_NAMESPACE
: "${REGISTRY_PULL_SECRET_NAME:=ghcr-pull}"

log "verifying namespace access for ${OPENSHIFT_NAMESPACE}"
oc project "${OPENSHIFT_NAMESPACE}" >/dev/null

if [[ -n "${REGISTRY_LOGIN_USERNAME:-}" && -n "${REGISTRY_LOGIN_PASSWORD:-}" ]]; then
  registry_host="$(printf '%s' "${IMAGE_REGISTRY}" | cut -d'/' -f1)"
  log "creating image pull secret ${REGISTRY_PULL_SECRET_NAME} for ${registry_host}"
  oc create secret docker-registry "${REGISTRY_PULL_SECRET_NAME}" \
    --docker-server="${registry_host}" \
    --docker-username="${REGISTRY_LOGIN_USERNAME}" \
    --docker-password="${REGISTRY_LOGIN_PASSWORD}" \
    --dry-run=client \
    -o yaml \
    | oc apply -n "${OPENSHIFT_NAMESPACE}" -f -
  oc secrets link flink-runner "${REGISTRY_PULL_SECRET_NAME}" --for=pull -n "${OPENSHIFT_NAMESPACE}" >/dev/null || true
fi

log "logging into the registry"
"${SCRIPT_DIR}/registry-login.sh" "${ENV_FILE}"

log "ensuring imagestream flink-base exists"
oc get imagestream/flink-base -n "${OPENSHIFT_NAMESPACE}" >/dev/null 2>&1 \
  || oc create imagestream flink-base -n "${OPENSHIFT_NAMESPACE}"

log "ensuring imagestream flink-sql-runtime exists"
oc get imagestream/flink-sql-runtime -n "${OPENSHIFT_NAMESPACE}" >/dev/null 2>&1 \
  || oc create imagestream flink-sql-runtime -n "${OPENSHIFT_NAMESPACE}"

log "CI bootstrap completed"