#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  create-topic.sh <env-file> --topic <name> [--partitions N] [--replication-factor N]
    [--min-insync N] [--retention-ms MS] [--retention-bytes BYTES]
    [--bootstrap-server host:port] [--service-account NAME]
    [--job-timeout 15m] [--keep-job] [--config key=value]

Examples:
  create-topic.sh env/dev.env --topic ha-drill
  create-topic.sh env/dev.env --topic orders.raw --partitions 12 --replication-factor 3 --min-insync 2
  create-topic.sh env/dev.env --topic orders.raw --retention-ms 604800000 --keep-job
EOF
}

sanitize_name() {
  tr '[:upper:]' '[:lower:]' <<<"$1" | tr -cs 'a-z0-9' '-' | tr -s '-' | sed 's/^-//; s/-$//'
}

ENV_FILE=${1:-}
shift || true

[[ -n "${ENV_FILE}" ]] || { usage; exit 1; }
[[ -f "${ENV_FILE}" ]] || { echo "env file not found: ${ENV_FILE}" >&2; exit 1; }

TOPIC=""
PARTITIONS=""
REPLICATION_FACTOR=""
MIN_ISR=""
RETENTION_MS=""
RETENTION_BYTES=""
BOOTSTRAP_SERVER=""
SERVICE_ACCOUNT=""
JOB_TIMEOUT="15m"
KEEP_JOB=false
EXTRA_CONFIG_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --topic)
      TOPIC=${2:-}
      shift 2
      ;;
    --partitions)
      PARTITIONS=${2:-}
      shift 2
      ;;
    --replication-factor)
      REPLICATION_FACTOR=${2:-}
      shift 2
      ;;
    --min-insync|--min-isr)
      MIN_ISR=${2:-}
      shift 2
      ;;
    --retention-ms)
      RETENTION_MS=${2:-}
      shift 2
      ;;
    --retention-bytes)
      RETENTION_BYTES=${2:-}
      shift 2
      ;;
    --bootstrap-server)
      BOOTSTRAP_SERVER=${2:-}
      shift 2
      ;;
    --service-account)
      SERVICE_ACCOUNT=${2:-}
      shift 2
      ;;
    --job-timeout)
      JOB_TIMEOUT=${2:-}
      shift 2
      ;;
    --config)
      EXTRA_CONFIG_ARGS+=("${2:-}")
      shift 2
      ;;
    --keep-job)
      KEEP_JOB=true
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

[[ -n "${TOPIC}" ]] || { echo "--topic is required" >&2; usage; exit 1; }

set -a
# shellcheck disable=SC1090
. "${ENV_FILE}"
set +a

: "${OPENSHIFT_NAMESPACE:?OPENSHIFT_NAMESPACE is required}"
: "${KAFKA_IMAGE:?KAFKA_IMAGE is required}"

BOOTSTRAP_SERVER=${BOOTSTRAP_SERVER:-${KAFKA_BOOTSTRAP_SERVERS:-kafka.${OPENSHIFT_NAMESPACE}.svc:9092}}
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-${KAFKA_SERVICE_ACCOUNT:-kafka-runner}}
PARTITIONS=${PARTITIONS:-${KAFKA_NUM_PARTITIONS:-6}}
REPLICATION_FACTOR=${REPLICATION_FACTOR:-${KAFKA_DEFAULT_REPLICATION_FACTOR:-3}}
MIN_ISR=${MIN_ISR:-${KAFKA_MIN_INSYNC_REPLICAS:-2}}

job_suffix=$(date +%s)
job_topic=$(sanitize_name "${TOPIC}")
[[ -n "${job_topic}" ]] || { echo "topic name is not valid after sanitization: ${TOPIC}" >&2; exit 1; }
job_name="kafka-create-topic-${job_topic}-${job_suffix}"
job_name=${job_name:0:63}
job_name=${job_name%-}

job_file=$(mktemp)
trap 'rm -f "${job_file}"' EXIT

topic_config_args=(--config "min.insync.replicas=${MIN_ISR}")
if [[ -n "${RETENTION_MS}" ]]; then
  topic_config_args+=(--config "retention.ms=${RETENTION_MS}")
fi
if [[ -n "${RETENTION_BYTES}" ]]; then
  topic_config_args+=(--config "retention.bytes=${RETENTION_BYTES}")
fi
for config_value in "${EXTRA_CONFIG_ARGS[@]}"; do
  topic_config_args+=(--config "${config_value}")
done

topic_config_args_text=$(printf ' %q' "${topic_config_args[@]}")

cat > "${job_file}" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job_name}
  namespace: ${OPENSHIFT_NAMESPACE}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 1800
  template:
    spec:
      serviceAccountName: ${SERVICE_ACCOUNT}
      restartPolicy: Never
      containers:
        - name: kafka-topics
          image: ${KAFKA_IMAGE}
          imagePullPolicy: IfNotPresent
          command:
            - /bin/bash
            - -ec
            - |
              set -euo pipefail
              /opt/kafka/bin/kafka-topics.sh \
                --bootstrap-server "${BOOTSTRAP_SERVER}" \
                --create \
                --if-not-exists \
                --topic "${TOPIC}" \
                --partitions "${PARTITIONS}" \
                --replication-factor "${REPLICATION_FACTOR}"${topic_config_args_text}
              /opt/kafka/bin/kafka-topics.sh \
                --bootstrap-server "${BOOTSTRAP_SERVER}" \
                --describe \
                --topic "${TOPIC}"
EOF

echo "Namespace: ${OPENSHIFT_NAMESPACE}"
echo "Job: ${job_name}"
echo "Topic: ${TOPIC}"
echo "Bootstrap server: ${BOOTSTRAP_SERVER}"
echo "Partitions: ${PARTITIONS}"
echo "Replication factor: ${REPLICATION_FACTOR}"
echo "Min ISR: ${MIN_ISR}"

oc apply -f "${job_file}" >/dev/null

if ! oc wait -n "${OPENSHIFT_NAMESPACE}" --for=condition=complete "job/${job_name}" --timeout="${JOB_TIMEOUT}"; then
  echo "ERROR: job ${job_name} did not complete successfully" >&2
  oc describe job -n "${OPENSHIFT_NAMESPACE}" "${job_name}" >&2 || true
  oc logs -n "${OPENSHIFT_NAMESPACE}" "job/${job_name}" >&2 || true
  exit 1
fi

oc logs -n "${OPENSHIFT_NAMESPACE}" "job/${job_name}"

if [[ "${KEEP_JOB}" != true ]]; then
  oc delete job -n "${OPENSHIFT_NAMESPACE}" "${job_name}" --ignore-not-found >/dev/null
fi

echo "Topic ${TOPIC} created or already existed successfully."
