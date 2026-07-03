#!/usr/bin/env bash

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

usage() {
  cat <<'EOF'
Usage:
  test-all-functionality.sh [--env <path>] [--topic <name>] [--clean] [--cleanup-only] [--skip-image-build] [--no-exercise-delete]

Options:
  --env <path>          Kafka env file (default: ../env/dev.env).
  --topic <name>        Topic used for maintenance assertions (default: ha-drill).
  --clean               Remove namespace/resources first, then rebuild and test.
  --cleanup-only        Run cleanup and exit.
  --skip-image-build    Skip build-image.sh (useful when image already exists).
  --no-exercise-delete  Skip delete/redeploy cycle.
  -h, --help            Show help.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${BASE_DIR}/env/dev.env"
TOPIC="ha-drill"
CLEAN=false
CLEANUP_ONLY=false
SKIP_IMAGE_BUILD=false
EXERCISE_DELETE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="${2:-}"
      shift 2
      ;;
    --topic)
      TOPIC="${2:-}"
      shift 2
      ;;
    --clean)
      CLEAN=true
      shift
      ;;
    --cleanup-only)
      CLEANUP_ONLY=true
      shift
      ;;
    --skip-image-build)
      SKIP_IMAGE_BUILD=true
      shift
      ;;
    --no-exercise-delete)
      EXERCISE_DELETE=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${ENV_FILE}" != /* ]]; then
  ENV_FILE="$(cd "${PWD}" && pwd)/${ENV_FILE}"
fi
[[ -f "${ENV_FILE}" ]] || { echo "env file not found: ${ENV_FILE}" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" >&2
}

wait_for_namespace_delete() {
  local ns="$1"
  local i=0
  while oc get ns "${ns}" >/dev/null 2>&1; do
    i=$((i + 1))
    if [[ ${i} -gt 60 ]]; then
      echo "ERROR: namespace ${ns} deletion timeout" >&2
      return 1
    fi
    sleep 5
  done
}

prepare_env_file() {
  local source_env="$1"
  local work_env
  work_env="$(mktemp)"
  cp "${source_env}" "${work_env}"

  set -a
  # shellcheck disable=SC1090
  . "${source_env}"
  set +a

  : "${OPENSHIFT_NAMESPACE:?OPENSHIFT_NAMESPACE is required}"
  : "${KAFKA_IMAGE:?KAFKA_IMAGE is required}"

  if [[ -z "${KAFKA_CLUSTER_ID:-}" ]]; then
    log "KAFKA_CLUSTER_ID missing in env; generating ephemeral id"
    local generated_id
    generated_id="$(${SCRIPT_DIR}/generate-kraft-cluster-id.sh)"
    generated_id="$(printf '%s' "${generated_id}" | tr -d '\n\r')"
    sed -i "s|^KAFKA_CLUSTER_ID=.*$|KAFKA_CLUSTER_ID=${generated_id}|" "${work_env}"
  fi

  echo "${work_env}"
}

cleanup_kafka() {
  local env_file="$1"
  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a

  : "${OPENSHIFT_NAMESPACE:?OPENSHIFT_NAMESPACE is required}"

  log "Cleaning Kafka resources in ${OPENSHIFT_NAMESPACE}"
  "${SCRIPT_DIR}/delete.sh" "${env_file}" || true
  oc delete pvc -n "${OPENSHIFT_NAMESPACE}" -l app.kubernetes.io/name=kafka --ignore-not-found || true
  oc delete ns "${OPENSHIFT_NAMESPACE}" --ignore-not-found || true
  wait_for_namespace_delete "${OPENSHIFT_NAMESPACE}" || true
}

create_test_topic() {
  local env_file="$1"
  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a

  local bootstrap="kafka.${OPENSHIFT_NAMESPACE}.svc:9092"

  log "Ensuring test topic ${TOPIC} exists"
  oc exec -n "${OPENSHIFT_NAMESPACE}" kafka-0 -- \
    /opt/kafka/bin/kafka-topics.sh \
    --create \
    --if-not-exists \
    --topic "${TOPIC}" \
    --partitions 3 \
    --replication-factor 3 \
    --bootstrap-server "${bootstrap}" >/dev/null
}

run_deploy_cycle() {
  local env_file="$1"

  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a

  if ! oc project "${OPENSHIFT_NAMESPACE}" >/dev/null 2>&1; then
    oc create namespace "${OPENSHIFT_NAMESPACE}" >/dev/null 2>&1 || true
    oc project "${OPENSHIFT_NAMESPACE}" >/dev/null
  fi

  "${SCRIPT_DIR}/render-manifests.sh" "${env_file}"

  # Validate rendered manifests apply cleanly client-side.
  find "${BASE_DIR}/.rendered/manifests" -type f -name '*.yaml' | sort | while IFS= read -r manifest; do
    oc apply --dry-run=client -f "${manifest}" >/dev/null
  done

  if [[ "${SKIP_IMAGE_BUILD}" != true ]]; then
    "${SCRIPT_DIR}/build-image.sh" "${env_file}"
  fi

  "${SCRIPT_DIR}/deploy.sh" "${env_file}"
  "${SCRIPT_DIR}/check.sh" "${env_file}"

  create_test_topic "${env_file}"
  "${SCRIPT_DIR}/maintenance-guard.sh" "${env_file}" --topic "${TOPIC}" --phase pre
  "${SCRIPT_DIR}/maintenance-guard.sh" "${env_file}" --topic "${TOPIC}" --phase post
}

log "Validating Kafka script syntax"
for s in \
  build-image.sh \
  check.sh \
  delete.sh \
  deploy.sh \
  generate-kraft-cluster-id.sh \
  maintenance-guard.sh \
  render-manifests.sh \
  test-all-functionality.sh; do
  bash -n "${SCRIPT_DIR}/${s}"
done

require_cmd oc
require_cmd python3

WORK_ENV="$(prepare_env_file "${ENV_FILE}")"
trap 'rm -f "${WORK_ENV}"' EXIT

if [[ "${CLEANUP_ONLY}" == true ]]; then
  cleanup_kafka "${WORK_ENV}"
  log "Kafka cleanup-only completed"
  exit 0
fi

if [[ "${CLEAN}" == true ]]; then
  cleanup_kafka "${WORK_ENV}"
fi

log "Running Kafka full deploy/check/guard cycle"
run_deploy_cycle "${WORK_ENV}"

if [[ "${EXERCISE_DELETE}" == true ]]; then
  log "Exercising delete and redeploy to verify full lifecycle"
  cleanup_kafka "${WORK_ENV}"
  run_deploy_cycle "${WORK_ENV}"
fi

log "Kafka full functionality test completed"
