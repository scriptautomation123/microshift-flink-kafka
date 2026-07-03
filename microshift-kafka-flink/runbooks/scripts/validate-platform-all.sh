#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  validate-platform-all.sh [--kafka-env <path>] [--flink-env <path>] [--kafka-topic <topic>] [--strict] [--skip-runtime] [--json]

Examples:
  validate-platform-all.sh \
    --kafka-env docs/kafka/openshift/env/dev.env \
    --flink-env docs/flink/openshift/env/dev.env \
    --kafka-topic ha-drill
EOF
}

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
KAFKA_ENV="${ROOT_DIR}/docs/kafka/openshift/env/dev.env"
FLINK_ENV="${ROOT_DIR}/docs/flink/openshift/env/dev.env"
KAFKA_TOPIC="ha-drill"
STRICT=false
SKIP_RUNTIME=false
JSON_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kafka-env)
      KAFKA_ENV="$2"
      shift 2
      ;;
    --flink-env)
      FLINK_ENV="$2"
      shift 2
      ;;
    --kafka-topic)
      KAFKA_TOPIC="$2"
      shift 2
      ;;
    --strict)
      STRICT=true
      shift
      ;;
    --skip-runtime)
      SKIP_RUNTIME=true
      shift
      ;;
    --json)
      JSON_MODE=true
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

# Normalize relative paths.
if [[ "${KAFKA_ENV}" != /* ]]; then
  KAFKA_ENV="${ROOT_DIR}/${KAFKA_ENV}"
fi
if [[ "${FLINK_ENV}" != /* ]]; then
  FLINK_ENV="${ROOT_DIR}/${FLINK_ENV}"
fi

if [[ "${JSON_MODE}" == true ]]; then
  echo "{\"event\":\"start\",\"root\":\"${ROOT_DIR}\"}"
else
  echo "Root: ${ROOT_DIR}"
fi

PASS=0
FAIL=0
WARN=0

run_check() {
  local name="$1"
  shift
  if [[ "${JSON_MODE}" != true ]]; then
    echo "==> CHECK: ${name}"
  fi
  set +e
  "$@"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    if [[ "${JSON_MODE}" == true ]]; then
      echo "{\"check\":\"${name}\",\"status\":\"PASS\",\"rc\":0}"
    else
      echo "PASS: ${name}"
    fi
    PASS=$((PASS + 1))
  else
    if [[ "${JSON_MODE}" == true ]]; then
      echo "{\"check\":\"${name}\",\"status\":\"FAIL\",\"rc\":${rc}}"
    else
      echo "FAIL: ${name} (rc=${rc})"
    fi
    FAIL=$((FAIL + 1))
  fi
}

warn_check() {
  local msg="$1"
  if [[ "${JSON_MODE}" == true ]]; then
    echo "{\"warning\":\"${msg}\"}"
  else
    echo "WARN: ${msg}"
  fi
  WARN=$((WARN + 1))
}

run_check "required tool: bash" command -v bash
run_check "required tool: find" command -v find
run_check "required tool: grep" command -v grep
run_check "required tool: awk" command -v awk
run_check "required tool: sed" command -v sed
run_check "required tool: python3" command -v python3

if command -v oc >/dev/null 2>&1; then
  run_check "oc whoami" oc whoami
else
  warn_check "oc not found; runtime cluster checks will be skipped"
fi

# 1) Script syntax validation across packages.
while IFS= read -r script; do
  run_check "bash -n ${script#${ROOT_DIR}/}" bash -n "$script"
done < <(find "${ROOT_DIR}/docs" -type f -name '*.sh' | sort)

# 2) Executable bit checks for scripts.
while IFS= read -r script; do
  if [[ ! -x "$script" ]]; then
    warn_check "not executable: ${script#${ROOT_DIR}/}"
  fi
done < <(find "${ROOT_DIR}/docs" -type f -name '*.sh' | sort)

# 3) Kafka manifest render and dry-run checks.
if [[ -f "${KAFKA_ENV}" ]]; then
  run_check "kafka render manifests" "${ROOT_DIR}/docs/kafka/openshift/scripts/render-manifests.sh" "${KAFKA_ENV}"

  if command -v oc >/dev/null 2>&1; then
    if [[ -d "${ROOT_DIR}/docs/kafka/openshift/.rendered/manifests" ]]; then
      while IFS= read -r manifest; do
        run_check "kafka oc dry-run: ${manifest#${ROOT_DIR}/}" oc apply --dry-run=client -f "$manifest"
      done < <(find "${ROOT_DIR}/docs/kafka/openshift/.rendered/manifests" -type f -name '*.yaml' | sort)
    else
      warn_check "kafka rendered manifest directory not found; skipping dry-run"
      if [[ "${STRICT}" == true ]]; then
        FAIL=$((FAIL + 1))
      fi
    fi
  fi
else
  warn_check "kafka env missing: ${KAFKA_ENV}"
  if [[ "${STRICT}" == true ]]; then
    FAIL=$((FAIL + 1))
  fi
fi

# 4) Flink render and dry-run checks.
if [[ -f "${FLINK_ENV}" ]]; then
  run_check "flink render bundle" "${ROOT_DIR}/docs/flink/openshift/scripts/render.sh" "${FLINK_ENV}"

  if command -v oc >/dev/null 2>&1; then
    if [[ -d "${ROOT_DIR}/docs/flink/openshift/.rendered/manifests" ]]; then
      while IFS= read -r manifest; do
        run_check "flink oc dry-run: ${manifest#${ROOT_DIR}/}" oc apply --dry-run=client -f "$manifest"
      done < <(find "${ROOT_DIR}/docs/flink/openshift/.rendered/manifests" -type f -name '*.yaml' | sort)
    else
      warn_check "flink rendered manifest directory not found; skipping dry-run"
      if [[ "${STRICT}" == true ]]; then
        FAIL=$((FAIL + 1))
      fi
    fi
  fi
else
  warn_check "flink env missing: ${FLINK_ENV}"
  if [[ "${STRICT}" == true ]]; then
    FAIL=$((FAIL + 1))
  fi
fi

# 5) Non-destructive functional checks if oc session is available.
if [[ "${SKIP_RUNTIME}" == true ]]; then
  warn_check "runtime checks explicitly skipped via --skip-runtime"
elif command -v oc >/dev/null 2>&1; then
  set +e
  oc whoami >/dev/null 2>&1
  OC_SESSION=$?
  set -e

  if [[ $OC_SESSION -eq 0 ]]; then
    run_check "microshift namespaces baseline" bash -lc "oc get ns | grep -E 'openshift-ingress|openshift-dns|openshift-operator-lifecycle-manager' >/dev/null"
    run_check "microshift ingress router running" bash -lc "oc get pods -n openshift-ingress | grep router | grep -E 'Running|Completed' >/dev/null"

    if [[ -f "${KAFKA_ENV}" ]]; then
      run_check "kafka check.sh" "${ROOT_DIR}/docs/kafka/openshift/scripts/check.sh" "${KAFKA_ENV}"
      run_check "kafka maintenance guard" "${ROOT_DIR}/docs/kafka/openshift/scripts/maintenance-guard.sh" "${KAFKA_ENV}" --topic "${KAFKA_TOPIC}" --phase pre
    fi

    if [[ -f "${FLINK_ENV}" ]]; then
      # Only validate namespaces that currently exist to keep this non-destructive and repeatable.
      existing_flink_ns=()
      for ns in flink-dev flink-stage flink-prod; do
        if oc get ns "$ns" >/dev/null 2>&1; then
          existing_flink_ns+=("$ns")
        fi
      done
      if [[ ${#existing_flink_ns[@]} -gt 0 ]]; then
        run_check "flink namespace RBAC validation" "${ROOT_DIR}/docs/flink/openshift/scripts/validate-namespace-identities.sh" --json "${existing_flink_ns[@]}"
      else
        warn_check "no flink-* namespaces found; skipping runtime RBAC check"
      fi
    fi

    run_check "flink umbrella drift check" "${ROOT_DIR}/docs/flink/openshift/scripts/regenerate-namespace-identities-umbrella.sh" --check
  else
    warn_check "oc session not authenticated; runtime checks skipped"
    if [[ "${STRICT}" == true ]]; then
      FAIL=$((FAIL + 1))
    fi
  fi
fi

if [[ "${JSON_MODE}" == true ]]; then
  echo "{\"summary\":{\"pass\":${PASS},\"warn\":${WARN},\"fail\":${FAIL}}}"
else
  echo
  echo "Validation summary: PASS=${PASS}, WARN=${WARN}, FAIL=${FAIL}"
fi
if [[ ${FAIL} -gt 0 ]]; then
  exit 1
fi

if [[ "${JSON_MODE}" != true ]]; then
  echo "All enforced checks passed"
fi
