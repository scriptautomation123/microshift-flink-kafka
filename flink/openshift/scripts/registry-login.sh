#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ENV_FILE=${1:-}

load_env "${ENV_FILE}"
require_commands oc
require_env IMAGE_REGISTRY

CONTAINER_TOOL=$(detect_container_cli)

if [[ -n "${REGISTRY_LOGIN_USERNAME:-}" && -n "${REGISTRY_LOGIN_PASSWORD:-}" ]]; then
  REGISTRY_USERNAME=${REGISTRY_LOGIN_USERNAME}
  REGISTRY_PASSWORD=${REGISTRY_LOGIN_PASSWORD}
else
  REGISTRY_USERNAME=$(oc whoami)
  REGISTRY_PASSWORD=$(oc whoami -t)
fi

require_env REGISTRY_USERNAME REGISTRY_PASSWORD

log "logging ${CONTAINER_TOOL} into ${IMAGE_REGISTRY}"
"${CONTAINER_TOOL}" login \
  --username "${REGISTRY_USERNAME}" \
  --password "${REGISTRY_PASSWORD}" \
  "${IMAGE_REGISTRY}"

log "registry login completed"