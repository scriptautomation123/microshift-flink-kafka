#!/usr/bin/env bash

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

usage() {
  cat <<'EOF'
Usage:
  test-all-functionality.sh [--env <path>] [--clean] [--cleanup-only] [--skip-bootstrap-ci] [--skip-build] [--skip-create-secrets] [--skip-submit] [--skip-sql-smoke] [--no-exercise-delete]

Options:
  --env <path>           Flink env file (default: ../env/dev.env).
  --clean                Remove Flink resources/namespace first, then rebuild and test.
  --cleanup-only         Run cleanup and exit.
  --skip-bootstrap-ci    Skip bootstrap-ci.sh.
  --skip-build           Skip build-images.sh.
  --skip-create-secrets  Skip create-secrets.sh.
  --skip-submit          Skip submit-sql.sh.
  --skip-sql-smoke       Skip post-submit SQL Gateway smoke test against Kafka.
  --no-exercise-delete   Skip delete/redeploy cycle.
  -h, --help             Show help.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${BASE_DIR}/env/dev.env"
CLEAN=false
CLEANUP_ONLY=false
SKIP_BOOTSTRAP_CI=false
SKIP_BUILD=false
SKIP_CREATE_SECRETS=false
SKIP_SUBMIT=false
SKIP_SQL_SMOKE=false
EXERCISE_DELETE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      ENV_FILE="${2:-}"
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
    --skip-bootstrap-ci)
      SKIP_BOOTSTRAP_CI=true
      shift
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --skip-create-secrets)
      SKIP_CREATE_SECRETS=true
      shift
      ;;
    --skip-submit)
      SKIP_SUBMIT=true
      shift
      ;;
    --skip-sql-smoke)
      SKIP_SQL_SMOKE=true
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
  printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*"
}

prepare_env_file() {
  local source_env="$1"
  local work_env
  work_env="$(mktemp)"
  cp "${source_env}" "${work_env}"

  # Keep JAAS values source-safe even when copied verbatim from example env.
  python3 - "${work_env}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
out = []
for line in lines:
    if line.startswith("KAFKA_SASL_JAAS_CONFIG="):
        key, value = line.split("=", 1)
        stripped = value.strip()
        if stripped and not (stripped.startswith("\"") or stripped.startswith("'")):
            escaped = stripped.replace("'", "'\"'\"'")
            out.append(f"{key}='{escaped}'")
            continue
    out.append(line)
path.write_text("\n".join(out) + "\n")
PY

  # shellcheck disable=SC1090
  source "${work_env}"

  if [[ -z "${KAFKA_TRUSTSTORE_FILE:-}" || ! -f "${KAFKA_TRUSTSTORE_FILE:-}" ]]; then
    local truststore
    truststore="$(mktemp)"
    : >"${truststore}"
    sed -i "s|^KAFKA_TRUSTSTORE_FILE=.*$|KAFKA_TRUSTSTORE_FILE=${truststore}|" "${work_env}"
  fi

  echo "${work_env}"
}

load_env() {
  local env_file="$1"
  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a
  : "${OPENSHIFT_NAMESPACE:?OPENSHIFT_NAMESPACE is required}"
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

cleanup_flink() {
  local env_file="$1"
  load_env "${env_file}"

  log "Cleaning Flink resources from namespace ${OPENSHIFT_NAMESPACE}"
  oc delete -n "${OPENSHIFT_NAMESPACE}" deploy/flink-sql-gateway --ignore-not-found || true
  oc delete -n "${OPENSHIFT_NAMESPACE}" sts/flink-jobmanager sts/flink-taskmanager --ignore-not-found || true
  oc delete -n "${OPENSHIFT_NAMESPACE}" svc/flink-sql-gateway flink-jobmanager --ignore-not-found || true
  oc delete -n "${OPENSHIFT_NAMESPACE}" route/flink-sql-gateway --ignore-not-found || true
  oc delete -n "${OPENSHIFT_NAMESPACE}" configmap/flink-config --ignore-not-found || true
  oc delete -n "${OPENSHIFT_NAMESPACE}" sa/flink-runner --ignore-not-found || true
  oc delete -n "${OPENSHIFT_NAMESPACE}" sa/flink-deployer --ignore-not-found || true
  oc delete -n "${OPENSHIFT_NAMESPACE}" sa/flink-sql-submitter --ignore-not-found || true
  oc delete -n "${OPENSHIFT_NAMESPACE}" sa/flink-observer --ignore-not-found || true

  log "Deleting namespace ${OPENSHIFT_NAMESPACE} for true clean reset"
  oc delete ns "${OPENSHIFT_NAMESPACE}" --ignore-not-found || true
  wait_for_namespace_delete "${OPENSHIFT_NAMESPACE}" || true
}

ensure_namespace_identities() {
  if ! oc get ns "${OPENSHIFT_NAMESPACE}" >/dev/null 2>&1; then
    log "Creating target namespace ${OPENSHIFT_NAMESPACE}"
    oc create namespace "${OPENSHIFT_NAMESPACE}" >/dev/null
  fi

  case "${OPENSHIFT_NAMESPACE}" in
    flink-dev)
      log "Applying dev namespace identity baseline"
      oc apply -f "${BASE_DIR}/manifests/08-namespace-identities-governance-dev-example.yaml"
      ;;
    flink-stage)
      log "Applying stage namespace identity baseline"
      oc apply -f "${BASE_DIR}/manifests/09-namespace-identities-governance-stage-example.yaml"
      ;;
    flink-prod)
      log "Applying prod namespace identity baseline"
      oc apply -f "${BASE_DIR}/manifests/07-namespace-identities-governance-example.yaml"
      ;;
    *)
      log "Namespace ${OPENSHIFT_NAMESPACE} has no canned baseline manifest; using direct namespace create"
      ;;
  esac
}

run_deploy_cycle() {
  local env_file="$1"
  load_env "${env_file}"

  ensure_namespace_identities

  "${SCRIPT_DIR}/regenerate-namespace-identities-umbrella.sh"
  "${SCRIPT_DIR}/regenerate-namespace-identities-umbrella.sh" --check

  "${SCRIPT_DIR}/render.sh" "${env_file}"

  if [[ -d "${BASE_DIR}/.rendered/manifests" ]]; then
    find "${BASE_DIR}/.rendered/manifests" -type f -name '*.yaml' | sort | while IFS= read -r manifest; do
      oc apply --dry-run=client -f "${manifest}" >/dev/null
    done
  fi

  if [[ "${SKIP_BOOTSTRAP_CI}" != true ]]; then
    "${SCRIPT_DIR}/bootstrap-ci.sh" "${env_file}"
  fi

  if [[ "${SKIP_BUILD}" != true ]]; then
    "${SCRIPT_DIR}/build-images.sh" "${env_file}"
  fi

  if [[ "${SKIP_CREATE_SECRETS}" != true ]]; then
    "${SCRIPT_DIR}/create-secrets.sh" "${env_file}"
  fi

  "${SCRIPT_DIR}/apply-manifests.sh" "${env_file}" --wait

  if [[ "${SKIP_SUBMIT}" != true ]]; then
    "${SCRIPT_DIR}/submit-sql.sh" "${env_file}"
  fi

  if [[ "${SKIP_SUBMIT}" != true && "${SKIP_SQL_SMOKE}" != true ]]; then
    "${SCRIPT_DIR}/smoke-sql-gateway-kafka.sh" "${env_file}"
  fi

  # Validate identity posture in all existing flink namespaces.
  existing=()
  for ns in flink-dev flink-stage flink-prod; do
    if oc get ns "${ns}" >/dev/null 2>&1; then
      existing+=("${ns}")
    fi
  done
  if [[ ${#existing[@]} -gt 0 ]]; then
    "${SCRIPT_DIR}/validate-namespace-identities.sh" --json "${existing[@]}"
  fi
}

log "Validating Flink script syntax"
for s in \
  apply-manifests.sh \
  bootstrap-ci.sh \
  build-images.sh \
  create-secrets.sh \
  deploy.sh \
  lib.sh \
  regenerate-namespace-identities-umbrella.sh \
  registry-login.sh \
  render.sh \
  smoke-sql-gateway-kafka.sh \
  submit-sql.sh \
  validate-namespace-identities.sh \
  test-all-functionality.sh; do
  bash -n "${SCRIPT_DIR}/${s}"
done

require_cmd oc
require_cmd python3

WORK_ENV="$(prepare_env_file "${ENV_FILE}")"
trap 'rm -f "${WORK_ENV}"' EXIT

if [[ "${CLEANUP_ONLY}" == true ]]; then
  cleanup_flink "${WORK_ENV}"
  log "Flink cleanup-only completed"
  exit 0
fi

if [[ "${CLEAN}" == true ]]; then
  cleanup_flink "${WORK_ENV}"
fi

log "Running Flink full deploy/check cycle"
run_deploy_cycle "${WORK_ENV}"

if [[ "${EXERCISE_DELETE}" == true ]]; then
  log "Exercising delete and redeploy to verify full lifecycle"
  cleanup_flink "${WORK_ENV}"
  run_deploy_cycle "${WORK_ENV}"
fi

log "Flink full functionality test completed"
