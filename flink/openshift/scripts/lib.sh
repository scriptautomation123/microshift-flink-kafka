#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly RENDER_DIR="${BUNDLE_DIR}/.rendered"

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_commands() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: ${cmd}"
  done
}

load_env() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: <script> <env-file>"
  [[ -f "${env_file}" ]] || die "env file not found: ${env_file}"
  set -a
  # shellcheck disable=SC1090
  . "${env_file}"
  set +a
}

require_env() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "required environment variable is empty: ${name}"
  done
}

require_file() {
  local path=$1
  [[ -f "${path}" ]] || die "required file not found: ${path}"
}

detect_container_cli() {
  if [[ -n "${CONTAINER_CLI:-}" ]]; then
    command -v "${CONTAINER_CLI}" >/dev/null 2>&1 || die "container CLI not found: ${CONTAINER_CLI}"
    printf '%s\n' "${CONTAINER_CLI}"
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    printf 'podman\n'
    return 0
  fi

  if command -v docker >/dev/null 2>&1; then
    printf 'docker\n'
    return 0
  fi

  die "no supported container CLI found; install podman or docker"
}

ensure_render_dir() {
  mkdir -p "${RENDER_DIR}"
}

render_template() {
  local src=$1
  local dest=$2
  mkdir -p "$(dirname "${dest}")"
  python3 - "$src" "$dest" <<'PY'
import os
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
text = src.read_text()
pattern = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
missing = sorted(set(match.group(1) for match in pattern.finditer(text) if match.group(1) not in os.environ))
if missing:
    raise SystemExit(f"missing template variables for {src}: {', '.join(missing)}")
rendered = pattern.sub(lambda match: os.environ[match.group(1)], text)
dest.write_text(rendered)
PY
}

render_tree() {
  ensure_render_dir
  local path
  for path in "$@"; do
    if [[ -d "${path}" ]]; then
      while IFS= read -r file; do
        local rel=${file#"${BUNDLE_DIR}/"}
        render_template "${file}" "${RENDER_DIR}/${rel}"
      done < <(find "${path}" -type f | sort)
    else
      local rel=${path#"${BUNDLE_DIR}/"}
      render_template "${path}" "${RENDER_DIR}/${rel}"
    fi
  done
}

render_bundle() {
  require_commands python3
  render_tree \
    "${BUNDLE_DIR}/conf" \
    "${BUNDLE_DIR}/manifests" \
    "${BUNDLE_DIR}/sql" \
    "${BUNDLE_DIR}/images/Dockerfile.sql-runtime"
}

json_get() {
  local file=$1
  local key=$2
  python3 - "$file" "$key" <<'PY'
import json
import pathlib
import sys

file_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
data = json.loads(file_path.read_text())
value = data.get(key, "")
if isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

sql_gateway_api_url() {
  require_env SQL_GATEWAY_BASE_URL
  printf '%s/v1\n' "${SQL_GATEWAY_BASE_URL%/}"
}

rendered_file() {
  local rel=$1
  printf '%s/%s\n' "${RENDER_DIR}" "${rel}"
}

secret_name_or_default() {
  local provided=${1:-}
  local fallback=$2
  if [[ -n "${provided}" ]]; then
    printf '%s\n' "${provided}"
  else
    printf '%s\n' "${fallback}"
  fi
}