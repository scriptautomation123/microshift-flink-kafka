#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

MANIFESTS_DIR="${BUNDLE_DIR}/manifests"
OUTPUT_FILE="${MANIFESTS_DIR}/10-namespace-identities-governance-all-environments-example.yaml"

SOURCE_FILES=(
  "${MANIFESTS_DIR}/08-namespace-identities-governance-dev-example.yaml"
  "${MANIFESTS_DIR}/09-namespace-identities-governance-stage-example.yaml"
  "${MANIFESTS_DIR}/07-namespace-identities-governance-example.yaml"
)

CHECK_ONLY=false
if [[ "${1:-}" == "--check" ]]; then
  CHECK_ONLY=true
elif [[ $# -gt 0 ]]; then
  die "unknown argument: $1"
fi

for src in "${SOURCE_FILES[@]}"; do
  require_file "${src}"
done

tmp_file=$(mktemp)
trap 'rm -f "${tmp_file}"' EXIT

for i in "${!SOURCE_FILES[@]}"; do
  cat "${SOURCE_FILES[$i]}" >>"${tmp_file}"
  if [[ $i -lt $((${#SOURCE_FILES[@]} - 1)) ]]; then
    printf '\n---\n' >>"${tmp_file}"
  fi
done

if [[ "${CHECK_ONLY}" == true ]]; then
  if [[ ! -f "${OUTPUT_FILE}" ]]; then
    die "umbrella manifest missing: ${OUTPUT_FILE}"
  fi

  if cmp -s "${tmp_file}" "${OUTPUT_FILE}"; then
    log "umbrella manifest is up to date"
    exit 0
  fi

  die "umbrella manifest is out of date; run scripts/regenerate-namespace-identities-umbrella.sh"
fi

mv "${tmp_file}" "${OUTPUT_FILE}"
trap - EXIT

log "regenerated ${OUTPUT_FILE}"
