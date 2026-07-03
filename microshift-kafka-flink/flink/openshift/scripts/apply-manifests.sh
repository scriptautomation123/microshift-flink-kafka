#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}
shift || true

WAIT_FOR_READY=false
INCLUDE_EXAMPLE_SECRETS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)
      WAIT_FOR_READY=true
      ;;
    --include-example-secrets)
      INCLUDE_EXAMPLE_SECRETS=true
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

load_env "${ENV_FILE}"
require_env OPENSHIFT_NAMESPACE
require_commands oc python3

render_bundle

log "switching to project ${OPENSHIFT_NAMESPACE}"
oc project "${OPENSHIFT_NAMESPACE}" >/dev/null

log "applying RBAC"
oc apply -n "${OPENSHIFT_NAMESPACE}" -f "$(rendered_file manifests/00-serviceaccount-rbac.yaml)"

log "applying config map"
oc apply -n "${OPENSHIFT_NAMESPACE}" -f "$(rendered_file manifests/01-configmap.yaml)"

if [[ "${INCLUDE_EXAMPLE_SECRETS}" == true ]]; then
  log "applying example secrets"
  oc apply -n "${OPENSHIFT_NAMESPACE}" -f "$(rendered_file manifests/02-secrets-example.yaml)"
fi

log "applying runtime manifests"
oc apply -n "${OPENSHIFT_NAMESPACE}" -f "$(rendered_file manifests/03-jobmanager.yaml)"
oc apply -n "${OPENSHIFT_NAMESPACE}" -f "$(rendered_file manifests/04-taskmanager.yaml)"
oc apply -n "${OPENSHIFT_NAMESPACE}" -f "$(rendered_file manifests/05-sql-gateway.yaml)"
oc apply -n "${OPENSHIFT_NAMESPACE}" -f "$(rendered_file manifests/06-route.yaml)"

if [[ "${WAIT_FOR_READY}" == true ]]; then
  log "waiting for JobManager, TaskManagers, and SQL Gateway readiness"
  oc rollout status -n "${OPENSHIFT_NAMESPACE}" statefulset/flink-jobmanager --timeout=10m
  oc rollout status -n "${OPENSHIFT_NAMESPACE}" statefulset/flink-taskmanager --timeout=10m
  oc rollout status -n "${OPENSHIFT_NAMESPACE}" deployment/flink-sql-gateway --timeout=10m
fi