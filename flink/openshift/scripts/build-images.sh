#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}

load_env "${ENV_FILE}"
require_env \
  OPENSHIFT_NAMESPACE \
  IMAGE_REGISTRY \
  FLINK_IMAGE_TAG \
  FLINK_VERSION \
  SCALA_VERSION \
  BASE_IMAGE_REF \
  SQL_RUNTIME_IMAGE_REF

render_bundle
require_commands oc python3

[[ -f "${BUNDLE_DIR}/images/third_party/flink-sql-connector-kafka.jar" ]] || die "missing staged connector jar: images/third_party/flink-sql-connector-kafka.jar"
[[ -f "${BUNDLE_DIR}/images/third_party/flink-json.jar" ]] || die "missing staged format jar: images/third_party/flink-json.jar"

CONTAINER_TOOL=$(detect_container_cli)

log "building base image ${BASE_IMAGE_REF} with ${CONTAINER_TOOL}"
"${CONTAINER_TOOL}" build \
  -f "${BUNDLE_DIR}/images/Dockerfile.base" \
  --build-arg "FLINK_VERSION=${FLINK_VERSION}" \
  --build-arg "SCALA_VERSION=${SCALA_VERSION}" \
  -t "${BASE_IMAGE_REF}" \
  "${BUNDLE_DIR}/images"

log "building SQL runtime image ${SQL_RUNTIME_IMAGE_REF} with ${CONTAINER_TOOL}"
"${CONTAINER_TOOL}" build \
  -f "${RENDER_DIR}/images/Dockerfile.sql-runtime" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE_REF}" \
  -t "${SQL_RUNTIME_IMAGE_REF}" \
  "${BUNDLE_DIR}/images"

log "pushing ${BASE_IMAGE_REF}"
"${CONTAINER_TOOL}" push "${BASE_IMAGE_REF}"

log "pushing ${SQL_RUNTIME_IMAGE_REF}"
"${CONTAINER_TOOL}" push "${SQL_RUNTIME_IMAGE_REF}"