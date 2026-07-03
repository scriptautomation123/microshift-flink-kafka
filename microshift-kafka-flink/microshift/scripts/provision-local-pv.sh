#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  provision-local-pv.sh [options]

Options:
  --kafka-namespace <name>          Kafka namespace (default: kafka-dev)
  --kafka-replicas <count>          Kafka StatefulSet replicas (default: 3)
  --kafka-size <size>               Kafka PVC size per broker (default: 50Gi)

  --flink-namespace <name>          Flink namespace (default: flink-dev)
  --flink-taskmanagers <count>      Flink taskmanager replicas (default: 3)
  --flink-jobmanager-size <size>    Flink JobManager PVC size (default: 20Gi)
  --flink-taskmanager-size <size>   Flink TaskManager PVC size each (default: 100Gi)

  --base-dir <path>                 Host path base directory for PVs
                                    (default: /var/lib/microshift-local-pv)

  --kafka-only                      Provision only Kafka PVs
  --flink-only                      Provision only Flink PVs
  --delete                          Delete the generated PVs instead of applying
  -h, --help                        Show help

Notes:
  - This script creates static hostPath PVs with pre-bound claimRef entries.
  - Use this on local single-node MINC/MicroShift clusters when no dynamic
    StorageClass is available.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*"
}

KAFKA_NAMESPACE="kafka-dev"
KAFKA_REPLICAS=3
KAFKA_SIZE="50Gi"

FLINK_NAMESPACE="flink-dev"
FLINK_TASKMANAGERS=3
FLINK_JOBMANAGER_SIZE="20Gi"
FLINK_TASKMANAGER_SIZE="100Gi"

BASE_DIR="/var/lib/microshift-local-pv"
PROVISION_KAFKA=true
PROVISION_FLINK=true
DELETE_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kafka-namespace)
      KAFKA_NAMESPACE="${2:-}"
      shift 2
      ;;
    --kafka-replicas)
      KAFKA_REPLICAS="${2:-}"
      shift 2
      ;;
    --kafka-size)
      KAFKA_SIZE="${2:-}"
      shift 2
      ;;
    --flink-namespace)
      FLINK_NAMESPACE="${2:-}"
      shift 2
      ;;
    --flink-taskmanagers)
      FLINK_TASKMANAGERS="${2:-}"
      shift 2
      ;;
    --flink-jobmanager-size)
      FLINK_JOBMANAGER_SIZE="${2:-}"
      shift 2
      ;;
    --flink-taskmanager-size)
      FLINK_TASKMANAGER_SIZE="${2:-}"
      shift 2
      ;;
    --base-dir)
      BASE_DIR="${2:-}"
      shift 2
      ;;
    --kafka-only)
      PROVISION_KAFKA=true
      PROVISION_FLINK=false
      shift
      ;;
    --flink-only)
      PROVISION_KAFKA=false
      PROVISION_FLINK=true
      shift
      ;;
    --delete)
      DELETE_MODE=true
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

require_cmd oc

if ! [[ "$KAFKA_REPLICAS" =~ ^[0-9]+$ ]] || ! [[ "$FLINK_TASKMANAGERS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: replica counts must be integers" >&2
  exit 1
fi

emit_pv() {
  local name="$1"
  local size="$2"
  local namespace="$3"
  local claim_name="$4"
  local host_path="$5"

  cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/managed-by: swapan-info-local-pv
spec:
  capacity:
    storage: ${size}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  claimRef:
    namespace: ${namespace}
    name: ${claim_name}
  hostPath:
    path: ${host_path}
    type: DirectoryOrCreate
EOF
}

apply_or_delete() {
  local manifest="$1"
  if [[ "${DELETE_MODE}" == true ]]; then
    printf '%s\n' "${manifest}" | oc delete -f - --ignore-not-found
  else
    printf '%s\n' "${manifest}" | oc apply -f -
  fi
}

if [[ "${PROVISION_KAFKA}" == true ]]; then
  log "processing Kafka local PV set (${KAFKA_REPLICAS} replicas)"
  for i in $(seq 0 $((KAFKA_REPLICAS - 1))); do
    pv_name="local-pv-${KAFKA_NAMESPACE}-kafka-${i}"
    claim_name="data-kafka-${i}"
    host_path="${BASE_DIR}/${KAFKA_NAMESPACE}/kafka-${i}"
    apply_or_delete "$(emit_pv "${pv_name}" "${KAFKA_SIZE}" "${KAFKA_NAMESPACE}" "${claim_name}" "${host_path}")"
  done
fi

if [[ "${PROVISION_FLINK}" == true ]]; then
  log "processing Flink local PV set (jobmanager + ${FLINK_TASKMANAGERS} taskmanagers)"

  apply_or_delete "$(emit_pv \
    "local-pv-${FLINK_NAMESPACE}-flink-jobmanager-0" \
    "${FLINK_JOBMANAGER_SIZE}" \
    "${FLINK_NAMESPACE}" \
    "jobmanager-data-flink-jobmanager-0" \
    "${BASE_DIR}/${FLINK_NAMESPACE}/jobmanager-0")"

  for i in $(seq 0 $((FLINK_TASKMANAGERS - 1))); do
    pv_name="local-pv-${FLINK_NAMESPACE}-flink-taskmanager-${i}"
    claim_name="taskmanager-data-flink-taskmanager-${i}"
    host_path="${BASE_DIR}/${FLINK_NAMESPACE}/taskmanager-${i}"
    apply_or_delete "$(emit_pv "${pv_name}" "${FLINK_TASKMANAGER_SIZE}" "${FLINK_NAMESPACE}" "${claim_name}" "${host_path}")"
  done
fi

if [[ "${DELETE_MODE}" == true ]]; then
  log "local PV delete completed"
else
  log "local PV provisioning completed"
fi
