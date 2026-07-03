#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

require_commands oc date grep sort tr sed

NAMESPACES=(flink-dev flink-stage flink-prod)
OUTPUT_MODE=text

usage() {
  cat <<'EOF'
Usage:
  validate-namespace-identities.sh [--json] [NAMESPACE...]

Examples:
  validate-namespace-identities.sh
  validate-namespace-identities.sh --json
  validate-namespace-identities.sh flink-stage flink-prod
  validate-namespace-identities.sh --json flink-dev flink-stage
EOF
}

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      OUTPUT_MODE=json
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        POSITIONAL_ARGS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
  NAMESPACES=("${POSITIONAL_ARGS[@]}")
fi

if [[ "${OUTPUT_MODE}" == "json" ]]; then
  require_commands python3
fi

VALIDATION_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

RECORDS=()

for ns in "${NAMESPACES[@]}"; do
  ns_status=$(oc get ns "${ns}" -o jsonpath='{.status.phase}')

  sa_list=$(oc get sa -n "${ns}" -o custom-columns=NAME:.metadata.name --no-headers \
    | grep -E '^flink-(runner|deployer|sql-submitter|observer)$' \
    | sort \
    | tr '\n' ',' \
    | sed 's/,$//')

  rb_list=$(oc get rolebinding -n "${ns}" -o custom-columns=NAME:.metadata.name --no-headers \
    | grep -E '^flink-(runner|deployer|sql-submitter|observer)$' \
    | sort \
    | tr '\n' ',' \
    | sed 's/,$//')

  set +e
  out1=$(oc auth can-i create deployments.apps --as="system:serviceaccount:${ns}:flink-deployer" -n "${ns}" 2>/dev/null)
  rc1=$?
  out2=$(oc auth can-i create deployments.apps --as="system:serviceaccount:${ns}:flink-observer" -n "${ns}" 2>/dev/null)
  rc2=$?
  out3=$(oc auth can-i get pods --as="system:serviceaccount:${ns}:flink-sql-submitter" -n "${ns}" 2>/dev/null)
  rc3=$?
  set -e

  RECORDS+=("${ns}|${ns_status}|${sa_list}|${rb_list}|${out1}|${rc1}|${out2}|${rc2}|${out3}|${rc3}")
done

if [[ "${OUTPUT_MODE}" == "json" ]]; then
  python3 - "${VALIDATION_TIMESTAMP}" "${RECORDS[@]}" <<'PY'
import json
import sys

timestamp = sys.argv[1]
records = sys.argv[2:]

def csv_list(value):
    return [item for item in value.split(',') if item]

namespaces = []
for record in records:
    namespace, status, sa_csv, rb_csv, dep_out, dep_rc, obs_out, obs_rc, sub_out, sub_rc = record.split('|', 9)
    namespaces.append(
        {
            "namespace": namespace,
            "status": status,
            "serviceAccounts": csv_list(sa_csv),
            "roleBindings": csv_list(rb_csv),
            "canI": {
                "deployerCreateDeployments": {
                    "allowed": dep_out,
                    "rc": int(dep_rc),
                },
                "observerCreateDeployments": {
                    "allowed": obs_out,
                    "rc": int(obs_rc),
                },
                "submitterGetPods": {
                    "allowed": sub_out,
                    "rc": int(sub_rc),
                },
            },
        }
    )

print(
    json.dumps(
        {
            "validationTimestamp": timestamp,
            "namespaces": namespaces,
        },
        indent=2,
    )
)
PY
  exit 0
fi

echo "VALIDATION_TIMESTAMP=${VALIDATION_TIMESTAMP}"
for record in "${RECORDS[@]}"; do
  IFS='|' read -r ns ns_status sa_list rb_list out1 rc1 out2 rc2 out3 rc3 <<<"${record}"
  echo "NAMESPACE=${ns}"
  echo "NS_STATUS=${ns_status}"
  echo "SAS=${sa_list}"
  echo "ROLEBINDINGS=${rb_list}"
  echo "CANI_DEPLOYER_CREATE_DEPLOYMENTS=${out1} (rc=${rc1})"
  echo "CANI_OBSERVER_CREATE_DEPLOYMENTS=${out2} (rc=${rc2})"
  echo "CANI_SUBMITTER_GET_PODS=${out3} (rc=${rc3})"
  echo "---"
done
