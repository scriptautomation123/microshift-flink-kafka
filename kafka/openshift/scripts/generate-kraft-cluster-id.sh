#!/usr/bin/env bash

set -euo pipefail

if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  exit 0
fi

if [[ -r /proc/sys/kernel/random/uuid ]]; then
  cat /proc/sys/kernel/random/uuid
  exit 0
fi

echo "ERROR: cannot generate UUID; install python3 or provide KAFKA_CLUSTER_ID manually" >&2
exit 1
