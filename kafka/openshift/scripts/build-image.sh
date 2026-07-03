#!/usr/bin/env bash

set -euo pipefail

ENV_FILE=${1:-}
[[ -n "${ENV_FILE}" ]] || { echo "usage: $0 <env-file>" >&2; exit 1; }
[[ -f "${ENV_FILE}" ]] || { echo "env file not found: ${ENV_FILE}" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

: "${KAFKA_IMAGE:?KAFKA_IMAGE is required}"
: "${KAFKA_VERSION:=3.7.1}"
: "${SCALA_VERSION:=2.13}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if command -v podman >/dev/null 2>&1; then
  CONTAINER_CLI=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CLI=docker
else
  echo "ERROR: podman or docker is required" >&2
  exit 1
fi

echo "Building ${KAFKA_IMAGE} with ${CONTAINER_CLI}"
"${CONTAINER_CLI}" build \
  -f "${BASE_DIR}/images/Dockerfile.kraft" \
  --build-arg "KAFKA_VERSION=${KAFKA_VERSION}" \
  --build-arg "SCALA_VERSION=${SCALA_VERSION}" \
  -t "${KAFKA_IMAGE}" \
  "${BASE_DIR}/images"

echo "Pushing ${KAFKA_IMAGE}"
"${CONTAINER_CLI}" push "${KAFKA_IMAGE}"

echo "Image build and push completed"
