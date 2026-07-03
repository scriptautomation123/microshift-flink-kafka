#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}

load_env "${ENV_FILE}"
require_env SQL_GATEWAY_BASE_URL PIPELINE_NAME
require_commands curl python3

render_bundle

API_URL=$(sql_gateway_api_url)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

open_session_response="${TMP_DIR}/open-session.json"

log "opening SQL Gateway session against ${API_URL}"
curl -fsS \
  -H 'Content-Type: application/json' \
  -X POST \
  -d "{\"sessionName\": \"${PIPELINE_NAME}\", \"properties\": {}}" \
  "${API_URL}/sessions" \
  > "${open_session_response}"

SESSION_HANDLE=$(json_get "${open_session_response}" sessionHandle)
[[ -n "${SESSION_HANDLE}" ]] || die "failed to extract sessionHandle from ${open_session_response}"

split_sql_file() {
  local sql_file=$1
  local output_dir=$2

  python3 - "$sql_file" "$output_dir" <<'PY'
import pathlib
import sys

sql_file = pathlib.Path(sys.argv[1])
output_dir = pathlib.Path(sys.argv[2])
output_dir.mkdir(parents=True, exist_ok=True)

statements = []
current = []
for raw_line in sql_file.read_text().splitlines():
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("--"):
        continue
    current.append(raw_line)
    if stripped.endswith(";"):
        statement = "\n".join(current).strip()
        if statement:
            statements.append(statement)
        current = []

tail = "\n".join(current).strip()
if tail:
    statements.append(tail)

for index, statement in enumerate(statements, start=1):
    (output_dir / f"{index:02d}.sql").write_text(statement)
PY
}

configure_session_statement() {
  local statement_file=$1
  local body_file=$2

  python3 - "$statement_file" "$body_file" <<'PY'
import json
import pathlib
import sys

statement_file = pathlib.Path(sys.argv[1])
body_file = pathlib.Path(sys.argv[2])
payload = {
    "statement": statement_file.read_text().strip(),
    "executionTimeout": 0,
}
body_file.write_text(json.dumps(payload))
PY

  curl -fsS \
    -H 'Content-Type: application/json' \
    -X POST \
    --data @"${body_file}" \
    "${API_URL}/sessions/${SESSION_HANDLE}/configure-session" \
    >/dev/null
}

execute_statement() {
  local statement_file=$1
  local body_file=$2
  local response_file=$3

  python3 - "$statement_file" "$body_file" <<'PY'
import json
import pathlib
import sys

statement_file = pathlib.Path(sys.argv[1])
body_file = pathlib.Path(sys.argv[2])
payload = {
    "statement": statement_file.read_text().strip(),
    "executionTimeout": 0,
    "executionConfig": {
        "rest.address": "flink-jobmanager",
        "rest.port": "8081",
    },
}
body_file.write_text(json.dumps(payload))
PY

  curl -fsS \
    -H 'Content-Type: application/json' \
    -X POST \
    --data @"${body_file}" \
    "${API_URL}/sessions/${SESSION_HANDLE}/statements" \
    > "${response_file}"
}

submit_config_file() {
  local relative=$1
  local sql_path
  local split_dir
  local statement_path
  local body_path

  sql_path=$(rendered_file "${relative}")
  split_dir="${TMP_DIR}/$(basename "${relative}" .sql)"
  split_sql_file "${sql_path}" "${split_dir}"

  for statement_path in "${split_dir}"/*.sql; do
    [[ -f "${statement_path}" ]] || continue
    body_path="${statement_path%.sql}.body.json"
    log "configuring session with ${relative} -> $(basename "${statement_path}")"
    configure_session_statement "${statement_path}" "${body_path}"
  done
}

submit_execute_file() {
  local relative=$1
  local sql_path
  local body_path
  local response_path
  local operation_handle

  sql_path=$(rendered_file "${relative}")
  body_path="${TMP_DIR}/$(basename "${relative}").body.json"
  response_path="${TMP_DIR}/$(basename "${relative}").response.json"

  log "executing ${relative}"
  execute_statement "${sql_path}" "${body_path}" "${response_path}"
  operation_handle=$(json_get "${response_path}" operationHandle)
  [[ -n "${operation_handle}" ]] || die "failed to extract operationHandle from ${response_path}"
  log "operation handle for ${relative}: ${operation_handle}"
}

submit_config_file sql/10-session-config.sql
submit_config_file sql/20-kafka-source.sql
submit_config_file sql/30-kafka-sink.sql
submit_execute_file sql/40-pipeline.sql

log "closing SQL Gateway session ${SESSION_HANDLE}"
curl -fsS -X DELETE "${API_URL}/sessions/${SESSION_HANDLE}" >/dev/null

log "SQL bundle submitted successfully"