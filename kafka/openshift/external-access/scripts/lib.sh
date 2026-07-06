#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

load_env() {
  local env_file=$1
  [[ -f "${env_file}" ]] || die "env file not found: ${env_file}"
  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a
}
