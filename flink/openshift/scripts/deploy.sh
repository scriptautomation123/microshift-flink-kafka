#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}
shift || true

RUN_BUILD=true
RUN_APPLY=true
RUN_SUBMIT=true
WAIT_FOR_READY=false
INCLUDE_EXAMPLE_SECRETS=false
RUN_BOOTSTRAP_CI=false
RUN_CREATE_SECRETS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      RUN_BUILD=false
      ;;
    --skip-apply)
      RUN_APPLY=false
      ;;
    --skip-submit)
      RUN_SUBMIT=false
      ;;
    --bootstrap-ci)
      RUN_BOOTSTRAP_CI=true
      ;;
    --create-secrets)
      RUN_CREATE_SECRETS=true
      ;;
    --preflight)
      RUN_BOOTSTRAP_CI=true
      RUN_CREATE_SECRETS=true
      ;;
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

if [[ "${RUN_BOOTSTRAP_CI}" == true ]]; then
  "${SCRIPT_DIR}/bootstrap-ci.sh" "${ENV_FILE}"
fi

if [[ "${RUN_BUILD}" == true ]]; then
  "${SCRIPT_DIR}/build-images.sh" "${ENV_FILE}"
fi

if [[ "${RUN_CREATE_SECRETS}" == true ]]; then
  "${SCRIPT_DIR}/create-secrets.sh" "${ENV_FILE}"
fi

if [[ "${RUN_APPLY}" == true ]]; then
  apply_args=()
  if [[ "${WAIT_FOR_READY}" == true ]]; then
    apply_args+=(--wait)
  fi
  if [[ "${INCLUDE_EXAMPLE_SECRETS}" == true ]]; then
    apply_args+=(--include-example-secrets)
  fi
  "${SCRIPT_DIR}/apply-manifests.sh" "${ENV_FILE}" "${apply_args[@]}"
fi

if [[ "${RUN_SUBMIT}" == true ]]; then
  "${SCRIPT_DIR}/submit-sql.sh" "${ENV_FILE}"
fi