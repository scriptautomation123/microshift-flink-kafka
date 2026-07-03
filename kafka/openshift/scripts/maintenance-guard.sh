#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  maintenance-guard.sh <env-file> --topic <topic> [--phase pre|post] [--min-isr <n>]

Examples:
  maintenance-guard.sh env/dev.env --topic ha-drill --phase pre
  maintenance-guard.sh env/dev.env --topic ha-drill --phase post --min-isr 2
EOF
}

ENV_FILE=${1:-}
shift || true

[[ -n "${ENV_FILE}" ]] || { usage; exit 1; }
[[ -f "${ENV_FILE}" ]] || { echo "env file not found: ${ENV_FILE}" >&2; exit 1; }

TOPIC=""
PHASE="unspecified"
MIN_ISR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topic)
      TOPIC=${2:-}
      shift 2
      ;;
    --phase)
      PHASE=${2:-}
      shift 2
      ;;
    --min-isr)
      MIN_ISR=${2:-}
      shift 2
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

[[ -n "${TOPIC}" ]] || { echo "--topic is required" >&2; exit 1; }

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

: "${OPENSHIFT_NAMESPACE:?OPENSHIFT_NAMESPACE is required}"

if [[ -z "${MIN_ISR}" ]]; then
  MIN_ISR=${KAFKA_MIN_INSYNC_REPLICAS:-2}
fi

bootstrap="kafka.${OPENSHIFT_NAMESPACE}.svc:9092"

echo "[${PHASE}] Namespace: ${OPENSHIFT_NAMESPACE}"
echo "[${PHASE}] Topic: ${TOPIC}"
echo "[${PHASE}] Expected minimum ISR per partition: ${MIN_ISR}"

# Non-destructive platform health checks.
oc get sts,pods,svc,pvc,pdb -n "${OPENSHIFT_NAMESPACE}"
oc rollout status sts/kafka -n "${OPENSHIFT_NAMESPACE}" --timeout=5m

topic_output=$(oc exec -n "${OPENSHIFT_NAMESPACE}" kafka-0 -- \
  /opt/kafka/bin/kafka-topics.sh \
  --describe \
  --topic "${TOPIC}" \
  --bootstrap-server "${bootstrap}" 2>&1)

if [[ -z "${topic_output}" ]]; then
  echo "ERROR: empty topic describe output for ${TOPIC}" >&2
  exit 1
fi

echo "[${PHASE}] Topic describe output:"
echo "${topic_output}"

partition_lines=$(printf '%s\n' "${topic_output}" | grep 'Partition:' || true)
if [[ -z "${partition_lines}" ]]; then
  echo "ERROR: topic ${TOPIC} does not exist or has no partition metadata" >&2
  exit 1
fi

failures=0
partition_count=0

while IFS= read -r line; do
  [[ -n "${line}" ]] || continue
  partition_count=$((partition_count + 1))

  partition_id=$(printf '%s\n' "${line}" | sed -n 's/.*Partition: \([0-9]\+\).*/\1/p')
  leader_id=$(printf '%s\n' "${line}" | sed -n 's/.*Leader: \([-0-9]\+\).*/\1/p')
  isr_csv=$(printf '%s\n' "${line}" | sed -n 's/.*Isr: \([^ ]*\).*/\1/p')
  replicas_csv=$(printf '%s\n' "${line}" | sed -n 's/.*Replicas: \([^ ]*\).*/\1/p')

  if [[ -z "${partition_id}" || -z "${leader_id}" ]]; then
    echo "ERROR: unable to parse partition metadata: ${line}" >&2
    failures=$((failures + 1))
    continue
  fi

  if [[ "${leader_id}" == "-1" ]]; then
    echo "ERROR: partition ${partition_id} has no leader" >&2
    failures=$((failures + 1))
  fi

  isr_count=0
  if [[ -n "${isr_csv}" ]]; then
    isr_count=$(awk -F',' '{print NF}' <<<"${isr_csv}")
  fi

  replicas_count=0
  if [[ -n "${replicas_csv}" ]]; then
    replicas_count=$(awk -F',' '{print NF}' <<<"${replicas_csv}")
  fi

  if [[ "${isr_count}" -lt "${MIN_ISR}" ]]; then
    echo "ERROR: partition ${partition_id} ISR count ${isr_count} is below ${MIN_ISR}" >&2
    failures=$((failures + 1))
  fi

  echo "[${PHASE}] Partition ${partition_id}: leader=${leader_id}, replicas=${replicas_count}, isr=${isr_count}"
done <<<"${partition_lines}"

if [[ "${partition_count}" -eq 0 ]]; then
  echo "ERROR: no partition lines parsed for topic ${TOPIC}" >&2
  exit 1
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "[${PHASE}] FAILED: ${failures} assertion(s) failed" >&2
  exit 1
fi

echo "[${PHASE}] PASS: health checks and ISR assertions succeeded for topic ${TOPIC}"
