#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}

load_env "${ENV_FILE}"
require_commands oc python3
require_env \
  KAFKA_BOOTSTRAP_SERVERS \
  KAFKA_SOURCE_TOPIC \
  KAFKA_SINK_TOPIC \
  SQL_GATEWAY_BASE_URL

KAFKA_TEST_NAMESPACE=${KAFKA_TEST_NAMESPACE:-}
KAFKA_TEST_POD=${KAFKA_TEST_POD:-kafka-0}
SMOKE_MESSAGE_COUNT=${SMOKE_MESSAGE_COUNT:-3}
SMOKE_POLL_RETRIES=${SMOKE_POLL_RETRIES:-18}
SMOKE_POLL_SLEEP_SECONDS=${SMOKE_POLL_SLEEP_SECONDS:-10}

if ! [[ "${SMOKE_MESSAGE_COUNT}" =~ ^[0-9]+$ ]] || [[ "${SMOKE_MESSAGE_COUNT}" -lt 1 ]]; then
  die "SMOKE_MESSAGE_COUNT must be a positive integer"
fi

if [[ -z "${KAFKA_TEST_NAMESPACE}" ]]; then
  # Expected in-cluster form: service.namespace.svc:port
  bootstrap_host=$(printf '%s' "${KAFKA_BOOTSTRAP_SERVERS}" | cut -d',' -f1 | cut -d':' -f1)
  inferred_ns=$(printf '%s' "${bootstrap_host}" | awk -F'.' '{print $2}')
  if [[ -n "${inferred_ns}" ]]; then
    KAFKA_TEST_NAMESPACE="${inferred_ns}"
  else
    KAFKA_TEST_NAMESPACE="kafka-dev"
  fi
fi

require_env KAFKA_TEST_NAMESPACE KAFKA_TEST_POD

RUN_ID="smoke-$(date +%s)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT
INPUT_FILE="${TMP_DIR}/input.jsonl"

python3 - "${INPUT_FILE}" "${SMOKE_MESSAGE_COUNT}" "${RUN_ID}" <<'PY'
import datetime
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
count = int(sys.argv[2])
run_id = sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc)

lines = []
for idx in range(1, count + 1):
    event_time = (now + datetime.timedelta(seconds=idx)).isoformat().replace('+00:00', 'Z')
    payload = {
        "user_id": f"{run_id}-u{idx}",
        "payload": f"payload-{run_id}-{idx}",
        "event_time": event_time,
    }
    lines.append(json.dumps(payload))

out.write_text("\n".join(lines) + "\n")
PY

log "ensuring kafka source/sink topics exist in namespace ${KAFKA_TEST_NAMESPACE}"
oc exec -n "${KAFKA_TEST_NAMESPACE}" "${KAFKA_TEST_POD}" -- \
  /opt/kafka/bin/kafka-topics.sh \
  --create --if-not-exists \
  --topic "${KAFKA_SOURCE_TOPIC}" \
  --partitions 3 \
  --replication-factor 3 \
  --bootstrap-server "${KAFKA_BOOTSTRAP_SERVERS}" >/dev/null

oc exec -n "${KAFKA_TEST_NAMESPACE}" "${KAFKA_TEST_POD}" -- \
  /opt/kafka/bin/kafka-topics.sh \
  --create --if-not-exists \
  --topic "${KAFKA_SINK_TOPIC}" \
  --partitions 3 \
  --replication-factor 3 \
  --bootstrap-server "${KAFKA_BOOTSTRAP_SERVERS}" >/dev/null

log "producing ${SMOKE_MESSAGE_COUNT} smoke records to ${KAFKA_SOURCE_TOPIC}"
oc exec -i -n "${KAFKA_TEST_NAMESPACE}" "${KAFKA_TEST_POD}" -- \
  /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server "${KAFKA_BOOTSTRAP_SERVERS}" \
  --topic "${KAFKA_SOURCE_TOPIC}" < "${INPUT_FILE}"

log "polling sink topic ${KAFKA_SINK_TOPIC} for run marker ${RUN_ID}"
for attempt in $(seq 1 "${SMOKE_POLL_RETRIES}"); do
  output=$(oc exec -n "${KAFKA_TEST_NAMESPACE}" "${KAFKA_TEST_POD}" -- \
    /opt/kafka/bin/kafka-console-consumer.sh \
    --bootstrap-server "${KAFKA_BOOTSTRAP_SERVERS}" \
    --topic "${KAFKA_SINK_TOPIC}" \
    --from-beginning \
    --timeout-ms 5000 \
    --max-messages 2000 2>/dev/null || true)

  if printf '%s\n' "${output}" | grep -q "${RUN_ID}"; then
    log "sql gateway smoke test passed: sink topic contains records for ${RUN_ID}"
    exit 0
  fi

  log "attempt ${attempt}/${SMOKE_POLL_RETRIES}: sink data not visible yet; waiting ${SMOKE_POLL_SLEEP_SECONDS}s"
  sleep "${SMOKE_POLL_SLEEP_SECONDS}"
done

die "sql gateway smoke test failed: no sink records found for marker ${RUN_ID}"
