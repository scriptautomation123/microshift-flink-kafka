#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}
[[ -n "${ENV_FILE}" ]] || die "usage: $0 <env-file>"
load_env "${ENV_FILE}"

: "${OPENSHIFT_NAMESPACE:?OPENSHIFT_NAMESPACE is required}"
: "${KAFKA_NAMESPACE:?KAFKA_NAMESPACE is required}"
: "${KAFKA_IMAGE:?KAFKA_IMAGE is required}"
: "${ENVOY_IMAGE:?ENVOY_IMAGE is required}"
: "${KAFKA_CLUSTER_ID:?KAFKA_CLUSTER_ID is required}"
: "${EXTERNAL_ACCESS_MODE:?EXTERNAL_ACCESS_MODE is required}"
: "${KAFKA_EXTERNAL_BROKER_HOSTS:?KAFKA_EXTERNAL_BROKER_HOSTS is required}"
: "${KAFKA_EXTERNAL_BROKER_PORTS:?KAFKA_EXTERNAL_BROKER_PORTS is required}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${BASE_DIR}/.rendered/${EXTERNAL_ACCESS_MODE}"
TMP_DIR="${OUT_DIR}/tmp"

mkdir -p "${TMP_DIR}"
rm -rf "${OUT_DIR:?}"/*
mkdir -p "${TMP_DIR}"

python3 - "$BASE_DIR" "$OUT_DIR" "$EXTERNAL_ACCESS_MODE" <<'PY'
import os
import pathlib
import shutil
import sys

base_dir = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
common_dir = base_dir / 'manifests' / 'common'
mode_dir = base_dir / 'manifests' / mode

if not common_dir.exists():
    raise SystemExit(f'missing common manifests directory: {common_dir}')
if not mode_dir.exists():
    raise SystemExit(f'missing mode manifests directory: {mode_dir}')

values = dict(os.environ)
values.setdefault('KAFKA_EXTERNAL_SERVICE_PORT', values.get('KAFKA_EXTERNAL_LOADBALANCER_PORT', '19092'))
values.setdefault('KAFKA_EXTERNAL_LISTENER_NAME', 'EXTERNAL')

for source_dir in (common_dir, mode_dir):
    for path in sorted(source_dir.glob('*.yaml')):
        text = path.read_text()
        for key, value in values.items():
            text = text.replace(f'{{{{{key}}}}}', value)
        rel = path.name
        (out_dir / rel).write_text(text)
PY

log "Rendered external-access overlay to ${OUT_DIR}"
log "Mode: ${EXTERNAL_ACCESS_MODE}"
