#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}

load_env "${ENV_FILE}"
require_commands oc
require_env \
  OPENSHIFT_NAMESPACE \
  KAFKA_BOOTSTRAP_SERVERS \
  KAFKA_SOURCE_TOPIC \
  KAFKA_SINK_TOPIC \
  KAFKA_CONSUMER_GROUP \
  KAFKA_SECURITY_PROTOCOL \
  KAFKA_SASL_MECHANISM \
  KAFKA_SASL_JAAS_CONFIG \
  KAFKA_TRUSTSTORE_PASSWORD \
  KAFKA_TRUSTSTORE_FILE \
  KAFKA_TRANSACTIONAL_ID_PREFIX \
  CHECKPOINT_URI \
  SAVEPOINT_URI \
  HA_STORAGE_URI \
  AWS_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY \
  AWS_REGION

require_file "${KAFKA_TRUSTSTORE_FILE}"

KAFKA_CLIENT_SECRET_NAME=$(secret_name_or_default "${KAFKA_CLIENT_SECRET_NAME:-}" flink-kafka-client)
KAFKA_FILES_SECRET_NAME=$(secret_name_or_default "${KAFKA_FILES_SECRET_NAME:-}" flink-kafka-files)
OBJECTSTORE_SECRET_NAME=$(secret_name_or_default "${OBJECTSTORE_SECRET_NAME:-}" flink-objectstore)

log "switching to project ${OPENSHIFT_NAMESPACE}"
oc project "${OPENSHIFT_NAMESPACE}" >/dev/null

log "creating or updating secret ${KAFKA_CLIENT_SECRET_NAME}"
oc create secret generic "${KAFKA_CLIENT_SECRET_NAME}" \
  --from-literal=KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS}" \
  --from-literal=KAFKA_SOURCE_TOPIC="${KAFKA_SOURCE_TOPIC}" \
  --from-literal=KAFKA_SINK_TOPIC="${KAFKA_SINK_TOPIC}" \
  --from-literal=KAFKA_CONSUMER_GROUP="${KAFKA_CONSUMER_GROUP}" \
  --from-literal=KAFKA_SECURITY_PROTOCOL="${KAFKA_SECURITY_PROTOCOL}" \
  --from-literal=KAFKA_SASL_MECHANISM="${KAFKA_SASL_MECHANISM}" \
  --from-literal=KAFKA_SASL_JAAS_CONFIG="${KAFKA_SASL_JAAS_CONFIG}" \
  --from-literal=KAFKA_TRUSTSTORE_PASSWORD="${KAFKA_TRUSTSTORE_PASSWORD}" \
  --from-literal=KAFKA_TRANSACTIONAL_ID_PREFIX="${KAFKA_TRANSACTIONAL_ID_PREFIX}" \
  --dry-run=client \
  -o yaml \
  | oc apply -n "${OPENSHIFT_NAMESPACE}" -f -

log "creating or updating secret ${KAFKA_FILES_SECRET_NAME}"
oc create secret generic "${KAFKA_FILES_SECRET_NAME}" \
  --from-file=kafka.truststore.jks="${KAFKA_TRUSTSTORE_FILE}" \
  --dry-run=client \
  -o yaml \
  | oc apply -n "${OPENSHIFT_NAMESPACE}" -f -

log "creating or updating secret ${OBJECTSTORE_SECRET_NAME}"
oc create secret generic "${OBJECTSTORE_SECRET_NAME}" \
  --from-literal=CHECKPOINT_URI="${CHECKPOINT_URI}" \
  --from-literal=SAVEPOINT_URI="${SAVEPOINT_URI}" \
  --from-literal=HA_STORAGE_URI="${HA_STORAGE_URI}" \
  --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
  --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
  --from-literal=AWS_REGION="${AWS_REGION}" \
  --dry-run=client \
  -o yaml \
  | oc apply -n "${OPENSHIFT_NAMESPACE}" -f -

log "secret creation completed"