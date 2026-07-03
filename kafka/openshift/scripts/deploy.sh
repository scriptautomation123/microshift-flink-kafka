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
: "${REGISTRY_PULL_SECRET_NAME:=ghcr-pull}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RENDER_DIR="${BASE_DIR}/.rendered/manifests"

"${SCRIPT_DIR}/render-manifests.sh" "${ENV_FILE}"

echo "Switching to namespace ${OPENSHIFT_NAMESPACE}"
if ! oc project "${OPENSHIFT_NAMESPACE}" >/dev/null 2>&1; then
	oc create namespace "${OPENSHIFT_NAMESPACE}" >/dev/null 2>&1 || true
	oc project "${OPENSHIFT_NAMESPACE}" >/dev/null
fi

oc apply -n "${OPENSHIFT_NAMESPACE}" -f "${RENDER_DIR}/00-serviceaccount.yaml"

if [[ -n "${REGISTRY_LOGIN_USERNAME:-}" && -n "${REGISTRY_LOGIN_PASSWORD:-}" ]]; then
	registry_host="$(printf '%s' "${KAFKA_IMAGE}" | cut -d'/' -f1)"
	oc create secret docker-registry "${REGISTRY_PULL_SECRET_NAME}" \
		--docker-server="${registry_host}" \
		--docker-username="${REGISTRY_LOGIN_USERNAME}" \
		--docker-password="${REGISTRY_LOGIN_PASSWORD}" \
		--dry-run=client -o yaml | oc apply -n "${OPENSHIFT_NAMESPACE}" -f -
	oc secrets link kafka-runner "${REGISTRY_PULL_SECRET_NAME}" --for=pull -n "${OPENSHIFT_NAMESPACE}" >/dev/null || true
fi

oc apply -n "${OPENSHIFT_NAMESPACE}" -f "${RENDER_DIR}/01-headless-service.yaml"
oc apply -n "${OPENSHIFT_NAMESPACE}" -f "${RENDER_DIR}/02-client-service.yaml"
oc apply -n "${OPENSHIFT_NAMESPACE}" -f "${RENDER_DIR}/03-statefulset.yaml"
oc apply -n "${OPENSHIFT_NAMESPACE}" -f "${RENDER_DIR}/04-pdb.yaml"

echo "Deployment applied"
