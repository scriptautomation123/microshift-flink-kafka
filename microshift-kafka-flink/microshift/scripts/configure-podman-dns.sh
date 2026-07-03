#!/usr/bin/env bash

set -euo pipefail

DNS1=${1:-1.1.1.1}
DNS2=${2:-8.8.8.8}
TARGET=/etc/containers/containers.conf

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root (sudo)." >&2
  exit 1
fi

install -d -m 0755 /etc/containers
cat >"${TARGET}" <<EOF
[containers]
dns_servers = ["${DNS1}", "${DNS2}"]
EOF

echo "Wrote ${TARGET} with dns_servers=[${DNS1}, ${DNS2}]"
