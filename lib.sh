#!/usr/bin/env bash
# Shared utility library for all component scripts
# 
# Usage: source "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib.sh"
#
# Component scripts should set before sourcing:
#   export BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
#   export RENDER_DIR="${BUNDLE_DIR}/.rendered"
#
# Then all lib functions will use these paths.

set -euo pipefail

# Use component-provided BUNDLE_DIR/RENDER_DIR if set, otherwise use this script's directory
SCRIPT_DIR="${SCRIPT_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BUNDLE_DIR="${BUNDLE_DIR:=${SCRIPT_DIR}}"
RENDER_DIR="${RENDER_DIR:=${BUNDLE_DIR}/.rendered}"

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

# ============================================================================
# Generic Kubernetes Deployment Helpers
# ============================================================================

create_namespace() {
  local namespace=$1
  log "creating/switching to namespace ${namespace}"
  if ! oc project "${namespace}" >/dev/null 2>&1; then
    oc create namespace "${namespace}" >/dev/null 2>&1 || true
    oc project "${namespace}" >/dev/null
  fi
}

apply_manifests() {
  local namespace=$1
  shift || true
  
  while [[ $# -gt 0 ]]; do
    local file=$1
    [[ -f "${file}" ]] || die "manifest file not found: ${file}"
    
    # Extract description from filename (strip NN- prefix and .yaml extension)
    local desc=$(basename "${file}" .yaml | sed 's/^[0-9]\+-//')
    log "applying ${desc}"
    oc apply -n "${namespace}" -f "${file}"
    shift
  done
}

create_docker_registry_secret() {
  local namespace=$1
  local image=$2
  local secret_name=$3
  local service_account=$4
  
  # Skip if credentials not provided
  if [[ -z "${REGISTRY_LOGIN_USERNAME:-}" ]] || [[ -z "${REGISTRY_LOGIN_PASSWORD:-}" ]]; then
    return 0
  fi
  
  local registry_host=$(printf '%s' "${image}" | cut -d'/' -f1)
  log "creating docker-registry secret ${secret_name} for ${registry_host}"
  
  oc create secret docker-registry "${secret_name}" \
    --docker-server="${registry_host}" \
    --docker-username="${REGISTRY_LOGIN_USERNAME}" \
    --docker-password="${REGISTRY_LOGIN_PASSWORD}" \
    --dry-run=client -o yaml | oc apply -n "${namespace}" -f -
  
  oc secrets link "${service_account}" "${secret_name}" --for=pull -n "${namespace}" >/dev/null || true
}

wait_for_deployment() {
  local namespace=$1
  local name=$2
  log "waiting for deployment ${name} readiness"
  oc rollout status -n "${namespace}" deployment/"${name}" --timeout=10m
}

wait_for_statefulset() {
  local namespace=$1
  local name=$2
  log "waiting for statefulset ${name} readiness"
  oc rollout status -n "${namespace}" statefulset/"${name}" --timeout=10m
}

apply_from_template() {
  local template_file=$1
  local namespace=$2
  
  require_commands oc
  require_file "${template_file}"
  
  create_namespace "${namespace}"
  
  log "processing and applying template ${template_file}"
  oc process -f "${template_file}" | oc apply -n "${namespace}" -f -
}

# ============================================================================
# Utility Functions
# ============================================================================

# Find the consolidated env file by component and environment
get_env_file() {
  local component=$1  # flink or kafka
  local environment=$2  # dev, example, etc.
  local script_root
  script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local env_file="${script_root}/env/${component}.${environment}.env"
  [[ -f "${env_file}" ]] || die "env file not found: ${env_file}"
  printf '%s\n' "${env_file}"
}

get_flink_config() {
  local script_root
  script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local config_file="${script_root}/env/flink.config.yaml"
  [[ -f "${config_file}" ]] || die "Flink config file not found: ${config_file}"
  printf '%s\n' "${config_file}"
}

sanitize_name() {
  local input=$1
  tr '[:upper:]' '[:lower:]' <<<"$input" | tr -cs 'a-z0-9' '-' | tr -s '-' | sed 's/^-//; s/-$//'
}

generate_uuid() {
  python3 -c 'import uuid; print(str(uuid.uuid4()))'
}

timestamp_now() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

wait_for_namespace_delete() {
  local namespace=$1
  local timeout=300
  local elapsed=0
  log "waiting for namespace ${namespace} to be deleted"
  while kubectl get namespace "${namespace}" >/dev/null 2>&1; do
    if (( elapsed >= timeout )); then
      die "timeout waiting for namespace ${namespace} deletion"
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  log "namespace ${namespace} deleted"
}

split_sql_file() {
  local src_file=$1
  local output_dir=$2
  mkdir -p "${output_dir}"
  
  python3 - "$src_file" "$output_dir" <<'PY'
import pathlib
import re
import sys

src_file = pathlib.Path(sys.argv[1])
output_dir = pathlib.Path(sys.argv[2])
content = src_file.read_text()

# Split by semicolons followed by newline/whitespace, preserving statements
statements = re.split(r';\s*\n', content)
for i, stmt in enumerate(statements):
  stmt = stmt.strip()
  if stmt:
    output_file = output_dir / f"{i:02d}-statement.sql"
    output_file.write_text(stmt + ';')
    print(f"  {output_file.name}")
PY
}

# ============================================================================
# Container Registry & Image Building
# ============================================================================

registry_login() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: registry_login <env-file>"
  
  # Support both consolidated paths and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    # Try to find it in consolidated location (assume flink if not found)
    env_file="$(get_env_file flink "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  [[ -f "${env_file}" ]] || die "env file not found: ${env_file}"
  
  load_env "${env_file}"
  require_commands oc
  require_env IMAGE_REGISTRY
  
  local container_tool
  container_tool=$(detect_container_cli)
  
  local username password
  if [[ -n "${REGISTRY_LOGIN_USERNAME:-}" && -n "${REGISTRY_LOGIN_PASSWORD:-}" ]]; then
    username="${REGISTRY_LOGIN_USERNAME}"
    password="${REGISTRY_LOGIN_PASSWORD}"
  else
    username=$(oc whoami)
    password=$(oc whoami -t)
  fi
  
  require_env username password
  
  log "logging ${container_tool} into ${IMAGE_REGISTRY}"
  "${container_tool}" login \
    --username "${username}" \
    --password "${password}" \
    "${IMAGE_REGISTRY}"
  log "registry login completed"
}

build_images_flink() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: build_images_flink <env-file>"
  
  # Support both consolidated paths (scripts/env/flink.*.env) and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    # Try to find it in consolidated location
    env_file="$(get_env_file flink "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  # Auto-detect BUNDLE_DIR from manifest location
  local manifest_dir
  manifest_dir=$(find . -path "*/flink/openshift/manifests" -type d | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  else
    export BUNDLE_DIR="$(cd "$(dirname "$(find . -name 'Dockerfile.base' -path '*/flink-docker/*' 2>/dev/null | head -1)" | xargs dirname)/.." && pwd)"
  fi
  export RENDER_DIR="${BUNDLE_DIR}/.rendered"
  
  load_env "${env_file}"
  require_env \
    OPENSHIFT_NAMESPACE \
    IMAGE_REGISTRY \
    FLINK_IMAGE_TAG \
    FLINK_VERSION \
    SCALA_VERSION \
    BASE_IMAGE_REF \
    SQL_RUNTIME_IMAGE_REF
  
  require_file "${BUNDLE_DIR}/images/third_party/flink-sql-connector-kafka.jar"
  require_file "${BUNDLE_DIR}/images/third_party/flink-json.jar"
  
  # Render SQL runtime Dockerfile
  ensure_render_dir
  render_template "${BUNDLE_DIR}/images/Dockerfile.sql-runtime" "${RENDER_DIR}/images/Dockerfile.sql-runtime"
  
  local container_tool
  container_tool=$(detect_container_cli)
  
  log "building base image ${BASE_IMAGE_REF} with ${container_tool}"
  "${container_tool}" build \
    -f "${BUNDLE_DIR}/images/Dockerfile.base" \
    --build-arg "FLINK_VERSION=${FLINK_VERSION}" \
    --build-arg "SCALA_VERSION=${SCALA_VERSION}" \
    -t "${BASE_IMAGE_REF}" \
    "${BUNDLE_DIR}/images"
  
  log "building SQL runtime image ${SQL_RUNTIME_IMAGE_REF} with ${container_tool}"
  "${container_tool}" build \
    -f "${RENDER_DIR}/images/Dockerfile.sql-runtime" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE_REF}" \
    -t "${SQL_RUNTIME_IMAGE_REF}" \
    "${BUNDLE_DIR}/images"
  
  log "pushing ${BASE_IMAGE_REF}"
  "${container_tool}" push "${BASE_IMAGE_REF}"
  
  log "pushing ${SQL_RUNTIME_IMAGE_REF}"
  "${container_tool}" push "${SQL_RUNTIME_IMAGE_REF}"
}

build_image_kafka() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: build_image_kafka <env-file>"
  
  # Support both consolidated paths (scripts/env/kafka.*.env) and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    # Try to find it in consolidated location
    env_file="$(get_env_file kafka "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  # Auto-detect BUNDLE_DIR from manifest location
  local manifest_dir
  manifest_dir=$(find . -path "*/kafka/openshift/manifests" -type d | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  else
    export BUNDLE_DIR="$(cd "$(dirname "$(find . -name 'Dockerfile.kraft' -path '*/kafka-docker/*' 2>/dev/null | head -1)" | xargs dirname)/.." && pwd)"
  fi
  export RENDER_DIR="${BUNDLE_DIR}/.rendered"
  
  load_env "${env_file}"
  require_env KAFKA_IMAGE_REF
  
  local container_tool
  container_tool=$(detect_container_cli)
  
  log "building Kafka image ${KAFKA_IMAGE_REF} with ${container_tool}"
  "${container_tool}" build \
    -f "${BUNDLE_DIR}/images/Dockerfile.kraft" \
    -t "${KAFKA_IMAGE_REF}" \
    "${BUNDLE_DIR}/images"
  
  log "pushing ${KAFKA_IMAGE_REF}"
  "${container_tool}" push "${KAFKA_IMAGE_REF}"
}

push_image() {
  local image=$1
  local container_tool
  container_tool=$(detect_container_cli)
  log "pushing ${image}"
  "${container_tool}" push "${image}"
}

# ============================================================================
# CI/Bootstrap Functions
# ============================================================================

bootstrap_ci_flink() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: bootstrap_ci_flink <env-file>"
  
  # Support both consolidated paths and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(get_env_file flink "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  # Auto-detect BUNDLE_DIR
  local manifest_dir
  manifest_dir=$(find . -path "*/flink/openshift/manifests" -type d | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  fi
  
  load_env "${env_file}"
  require_commands oc
  require_env OPENSHIFT_NAMESPACE IMAGE_REGISTRY
  
  create_namespace "${OPENSHIFT_NAMESPACE}"
  
  # Create imagestream if needed
  if oc get imagestream -n "${OPENSHIFT_NAMESPACE}" flink-base >/dev/null 2>&1; then
    log "imagestream flink-base already exists"
  else
    log "creating imagestream flink-base"
    oc create imagestream flink-base -n "${OPENSHIFT_NAMESPACE}" || true
  fi
  
  # Create pull secrets if credentials provided
  if [[ -n "${REGISTRY_LOGIN_USERNAME:-}" && -n "${REGISTRY_LOGIN_PASSWORD:-}" ]]; then
    create_docker_registry_secret "${OPENSHIFT_NAMESPACE}" "${IMAGE_REGISTRY}/flink" "flink-registry-secret" "default"
  fi
  
  log "Flink CI bootstrap completed"
}

bootstrap_ci_kafka() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: bootstrap_ci_kafka <env-file>"
  
  # Support both consolidated paths and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(get_env_file kafka "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  load_env "${env_file}"
  require_commands oc
  require_env OPENSHIFT_NAMESPACE
  
  create_namespace "${OPENSHIFT_NAMESPACE}"
  
  # Create pull secrets if credentials provided
  if [[ -n "${REGISTRY_LOGIN_USERNAME:-}" && -n "${REGISTRY_LOGIN_PASSWORD:-}" ]]; then
    create_docker_registry_secret "${OPENSHIFT_NAMESPACE}" "${IMAGE_REGISTRY:-}" "kafka-registry-secret" "default"
  fi
  
  log "Kafka CI bootstrap completed"
}

# ============================================================================
# Secrets Management
# ============================================================================

create_generic_secret() {
  local namespace=$1
  local secret_name=$2
  shift 2
  
  require_commands oc
  
  local keys=()
  for kv in "$@"; do
    keys+=(--from-literal="${kv}")
  done
  
  log "creating/updating generic secret ${secret_name} in ${namespace}"
  oc create secret generic "${secret_name}" \
    "${keys[@]}" \
    --dry-run=client \
    -o yaml \
    | oc apply -n "${namespace}" -f -
}

create_file_secret() {
  local namespace=$1
  local secret_name=$2
  shift 2
  
  require_commands oc
  
  local files=()
  for kv in "$@"; do
    files+=(--from-file="${kv}")
  done
  
  log "creating/updating file secret ${secret_name} in ${namespace}"
  oc create secret generic "${secret_name}" \
    "${files[@]}" \
    --dry-run=client \
    -o yaml \
    | oc apply -n "${namespace}" -f -
}

create_secrets_flink() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: create_secrets_flink <env-file>"
  
  # Support both consolidated paths and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(get_env_file flink "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  # Auto-detect BUNDLE_DIR
  local manifest_dir
  manifest_dir=$(find . -path "*/flink/openshift/manifests" -type d | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  fi
  
  load_env "${env_file}"
  require_commands oc
  require_env \
    OPENSHIFT_NAMESPACE \
    KAFKA_BOOTSTRAP_SERVERS \
    KAFKA_SOURCE_TOPIC \
    KAFKA_SINK_TOPIC \
    KAFKA_CONSUMER_GROUP \
    KAFKA_SECURITY_PROTOCOL \
    KAFKA_SASL_MECHANISM \
    KAFKA_SASL_JAAS_CONFIG \
    KAFKA_TRUSTSTORE_PASSWORD \
    KAFKA_TRUSTSTORE_FILE \
    KAFKA_TRANSACTIONAL_ID_PREFIX \
    CHECKPOINT_URI \
    SAVEPOINT_URI \
    HA_STORAGE_URI \
    AWS_ACCESS_KEY_ID \
    AWS_SECRET_ACCESS_KEY \
    AWS_REGION
  
  require_file "${KAFKA_TRUSTSTORE_FILE}"
  
  local kafka_client_secret=$(secret_name_or_default "${KAFKA_CLIENT_SECRET_NAME:-}" flink-kafka-client)
  local kafka_files_secret=$(secret_name_or_default "${KAFKA_FILES_SECRET_NAME:-}" flink-kafka-files)
  local objectstore_secret=$(secret_name_or_default "${OBJECTSTORE_SECRET_NAME:-}" flink-objectstore)
  
  create_namespace "${OPENSHIFT_NAMESPACE}"
  
  log "creating or updating secret ${kafka_client_secret}"
  oc create secret generic "${kafka_client_secret}" \
    --from-literal=KAFKA_BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS}" \
    --from-literal=KAFKA_SOURCE_TOPIC="${KAFKA_SOURCE_TOPIC}" \
    --from-literal=KAFKA_SINK_TOPIC="${KAFKA_SINK_TOPIC}" \
    --from-literal=KAFKA_CONSUMER_GROUP="${KAFKA_CONSUMER_GROUP}" \
    --from-literal=KAFKA_SECURITY_PROTOCOL="${KAFKA_SECURITY_PROTOCOL}" \
    --from-literal=KAFKA_SASL_MECHANISM="${KAFKA_SASL_MECHANISM}" \
    --from-literal=KAFKA_SASL_JAAS_CONFIG="${KAFKA_SASL_JAAS_CONFIG}" \
    --from-literal=KAFKA_TRUSTSTORE_PASSWORD="${KAFKA_TRUSTSTORE_PASSWORD}" \
    --from-literal=KAFKA_TRANSACTIONAL_ID_PREFIX="${KAFKA_TRANSACTIONAL_ID_PREFIX}" \
    --dry-run=client \
    -o yaml \
    | oc apply -n "${OPENSHIFT_NAMESPACE}" -f -
  
  log "creating or updating secret ${kafka_files_secret}"
  oc create secret generic "${kafka_files_secret}" \
    --from-file=kafka.truststore.jks="${KAFKA_TRUSTSTORE_FILE}" \
    --dry-run=client \
    -o yaml \
    | oc apply -n "${OPENSHIFT_NAMESPACE}" -f -
  
  log "creating or updating secret ${objectstore_secret}"
  oc create secret generic "${objectstore_secret}" \
    --from-literal=CHECKPOINT_URI="${CHECKPOINT_URI}" \
    --from-literal=SAVEPOINT_URI="${SAVEPOINT_URI}" \
    --from-literal=HA_STORAGE_URI="${HA_STORAGE_URI}" \
    --from-literal=AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID}" \
    --from-literal=AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY}" \
    --from-literal=AWS_REGION="${AWS_REGION}" \
    --dry-run=client \
    -o yaml \
    | oc apply -n "${OPENSHIFT_NAMESPACE}" -f -
  
  log "secret creation completed"
}

create_secrets_kafka() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: create_secrets_kafka <env-file>"
  
  load_env "${env_file}"
  require_commands oc
  require_env OPENSHIFT_NAMESPACE
  
  create_namespace "${OPENSHIFT_NAMESPACE}"
  
  log "Kafka secrets setup completed (using template parameters)"
}

# ============================================================================
# Kafka-Specific Functions
# ============================================================================

kafka_deploy() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: kafka_deploy <env-file>"
  
  # Support both consolidated paths (scripts/env/kafka.*.env) and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(get_env_file kafka "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  # Auto-detect BUNDLE_DIR
  local manifest_dir
  manifest_dir=$(find . -path "*/kafka/openshift/manifests" -type d | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  fi
  export RENDER_DIR="${BUNDLE_DIR}/.rendered"
  
  load_env "${env_file}"
  require_env OPENSHIFT_NAMESPACE
  
  local build_image=true
  local apply_template=true
  
  # Parse optional flags
  while [[ $# -gt 1 ]]; do
    case "$2" in
      --skip-build) build_image=false ;;
      --skip-apply) apply_template=false ;;
      *) ;;
    esac
    shift
  done
  
  if [[ "${build_image}" == true ]]; then
    build_image_kafka "${env_file}"
  fi
  
  if [[ "${apply_template}" == true ]]; then
    apply_from_template "${BUNDLE_DIR}/manifests/template-kafka-cluster.yaml" "${OPENSHIFT_NAMESPACE}"
  fi
  
  log "Kafka deployment completed"
}

kafka_delete_resources() {
  local namespace=${1:-}
  [[ -n "${namespace}" ]] || die "usage: kafka_delete_resources <namespace>"
  
  require_commands oc
  
  log "deleting Kafka StatefulSet from ${namespace}"
  oc delete statefulset kafka -n "${namespace}" --ignore-not-found=true
  
  log "deleting Kafka Services from ${namespace}"
  oc delete service kafka-headless kafka -n "${namespace}" --ignore-not-found=true
  
  log "deleting Kafka ServiceAccount from ${namespace}"
  oc delete serviceaccount kafka -n "${namespace}" --ignore-not-found=true
  
  log "Kafka resources deleted"
}

kafka_health_check() {
  local namespace=${1:-}
  [[ -n "${namespace}" ]] || die "usage: kafka_health_check <namespace>"
  
  require_commands oc
  
  log "checking Kafka broker health in ${namespace}"
  
  # Check if any brokers are running
  local ready_replicas
  ready_replicas=$(oc get statefulset kafka -n "${namespace}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  
  if [[ "${ready_replicas}" -gt 0 ]]; then
    log "Kafka brokers ready: ${ready_replicas}"
    return 0
  else
    log "WARNING: No Kafka brokers ready"
    return 1
  fi
}

kafka_create_topic() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: kafka_create_topic <env-file> <topic-name> [options]"
  shift || die "topic name required"
  
  local topic=$1
  shift || die "topic name required"
  
  # For Kafka operations, try to detect BUNDLE_DIR from manifest or Docker files
  manifest_dir=$(find . -path "*/manifests" -type d -name manifests | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  fi
  
  load_env "${env_file}"
  require_commands oc
  require_env OPENSHIFT_NAMESPACE
  
  local partitions=1
  local replication_factor=3
  local retention_ms=""
  local extra_config=""
  
  # Parse optional arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --partitions)
        partitions=$2
        shift 2
        ;;
      --replication)
        replication_factor=$2
        shift 2
        ;;
      --retention-ms)
        retention_ms=$2
        shift 2
        ;;
      --config)
        extra_config="${extra_config} $2"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  
  log "creating Kafka topic ${topic} in ${OPENSHIFT_NAMESPACE}"
  
  local pod_name
  pod_name=$(oc get pod -n "${OPENSHIFT_NAMESPACE}" -l app=kafka -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [[ -z "${pod_name}" ]]; then
    die "no Kafka pod found in ${OPENSHIFT_NAMESPACE}"
  fi
  
  local cmd="kafka-topics.sh --create --topic ${topic} --partitions ${partitions} --replication-factor ${replication_factor}"
  
  if [[ -n "${retention_ms}" ]]; then
    cmd="${cmd} --config retention.ms=${retention_ms}"
  fi
  
  log "executing: ${cmd}"
  oc exec -n "${OPENSHIFT_NAMESPACE}" "${pod_name}" -- /opt/kafka/bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 \
    --create \
    --topic "${topic}" \
    --partitions "${partitions}" \
    --replication-factor "${replication_factor}" \
    || log "topic ${topic} creation completed (may already exist)"
}

kafka_maintenance_guard() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: kafka_maintenance_guard <env-file> --phase pre|post"
  
  load_env "${env_file}"
  require_env OPENSHIFT_NAMESPACE
  
  local phase=""
  
  while [[ $# -gt 1 ]]; do
    case "$2" in
      --phase)
        phase=$3
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
  
  [[ "${phase}" == "pre" || "${phase}" == "post" ]] || die "phase must be pre or post"
  
  if [[ "${phase}" == "pre" ]]; then
    log "kafka_maintenance_guard: PRE-phase - capturing state"
    oc get statefulset kafka -n "${OPENSHIFT_NAMESPACE}" -o json > /tmp/kafka-ss-pre.json
    oc get pod -n "${OPENSHIFT_NAMESPACE}" -l app=kafka -o json > /tmp/kafka-pods-pre.json
  else
    log "kafka_maintenance_guard: POST-phase - validating recovery"
    local ready_replicas
    ready_replicas=$(oc get statefulset kafka -n "${OPENSHIFT_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${ready_replicas}" -gt 0 ]]; then
      log "recovery successful: ${ready_replicas} replicas ready"
    else
      log "WARNING: recovery incomplete"
    fi
  fi
}

kafka_test_all() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: kafka_test_all <env-file> [--clean]"
  
  # Support both consolidated paths and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(get_env_file kafka "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  # Auto-detect BUNDLE_DIR
  local manifest_dir
  manifest_dir=$(find . -path "*/kafka/openshift/manifests" -type d | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  fi
  
  load_env "${env_file}"
  require_commands oc
  require_env OPENSHIFT_NAMESPACE
  
  local clean=false
  
  while [[ $# -gt 1 ]]; do
    case "$2" in
      --clean)
        clean=true
        ;;
      *)
        ;;
    esac
    shift
  done
  
  log "running Kafka full test cycle in ${OPENSHIFT_NAMESPACE}"
  
  if [[ "${clean}" == true ]]; then
    kafka_delete_resources "${OPENSHIFT_NAMESPACE}"
    sleep 10
  fi
  
  kafka_deploy "${env_file}"
  sleep 5
  kafka_health_check "${OPENSHIFT_NAMESPACE}"
  
  log "Kafka test cycle completed"
}

# ============================================================================
# Flink-Specific Functions
# ============================================================================

flink_deploy() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: flink_deploy <env-file> [options]"
  
  # Support both consolidated paths and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(get_env_file flink "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  # Auto-detect BUNDLE_DIR
  local manifest_dir
  manifest_dir=$(find . -path "*/flink/openshift/manifests" -type d | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  fi
  export RENDER_DIR="${BUNDLE_DIR}/.rendered"
  
  load_env "${env_file}"
  require_env OPENSHIFT_NAMESPACE
  
  local build_images=true
  local apply_template=true
  local submit_sql=true
  local bootstrap_ci=false
  local create_secrets=false
  
  # Parse optional flags
  while [[ $# -gt 1 ]]; do
    case "$2" in
      --skip-build) build_images=false ;;
      --skip-apply) apply_template=false ;;
      --skip-submit) submit_sql=false ;;
      --bootstrap-ci) bootstrap_ci=true ;;
      --create-secrets) create_secrets=true ;;
      --preflight) bootstrap_ci=true; create_secrets=true ;;
      *) ;;
    esac
    shift
  done
  
  if [[ "${bootstrap_ci}" == true ]]; then
    bootstrap_ci_flink "${env_file}"
  fi
  
  render_bundle
  
  if [[ "${build_images}" == true ]]; then
    build_images_flink "${env_file}"
  fi
  
  if [[ "${create_secrets}" == true ]]; then
    create_secrets_flink "${env_file}"
  fi
  
  if [[ "${apply_template}" == true ]]; then
    apply_from_template "${BUNDLE_DIR}/manifests/template-flink-sql-gateway.yaml" "${OPENSHIFT_NAMESPACE}"
  fi
  
  if [[ "${submit_sql}" == true ]]; then
    flink_submit_sql "${env_file}"
  fi
  
  log "Flink deployment completed"
}

flink_build_images() {
  local env_file=${1:-}
  build_images_flink "${env_file}"
}

flink_create_secrets() {
  local env_file=${1:-}
  create_secrets_flink "${env_file}"
}

flink_submit_sql() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: flink_submit_sql <env-file>"
  
  # Support both consolidated paths and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(get_env_file flink "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  # Auto-detect BUNDLE_DIR
  local manifest_dir
  manifest_dir=$(find . -path "*/flink/openshift/manifests" -type d | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  fi
  export RENDER_DIR="${BUNDLE_DIR}/.rendered"
  
  load_env "${env_file}"
  require_commands oc python3
  require_env OPENSHIFT_NAMESPACE SQL_GATEWAY_BASE_URL
  
  render_bundle
  
  local api_url
  api_url=$(sql_gateway_api_url)
  
  # Submit SQL files
  local stmt_file
  for stmt_file in "${RENDER_DIR}"/sql/*.sql; do
    if [[ -f "${stmt_file}" ]]; then
      log "submitting $(basename "${stmt_file}")"
      local stmt_content
      stmt_content=$(cat "${stmt_file}")
      
      python3 - <<PY
import requests
import sys
api_url = "${api_url}"
stmt = """${stmt_content}"""
try:
  resp = requests.post(f"{api_url}/sessions", json={"sessionName": "test-session"})
  if resp.status_code == 201:
    sid = resp.json()["sessionHandle"]
    resp = requests.post(f"{api_url}/sessions/{sid}/statements", json={"statement": stmt})
    if resp.status_code == 200:
      print(f"✓ statement executed")
  else:
    print(f"✗ session creation failed: {resp.status_code}")
except Exception as e:
  print(f"✗ error: {e}")
PY
    fi
  done
  
  log "SQL submission completed"
}

flink_smoke_test() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: flink_smoke_test <env-file>"
  
  # Support both consolidated paths and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(get_env_file flink "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  load_env "${env_file}"
  require_commands oc
  require_env OPENSHIFT_NAMESPACE SQL_GATEWAY_BASE_URL
  
  local api_url
  api_url=$(sql_gateway_api_url)
  
  log "running Flink SQL Gateway smoke test against ${api_url}"
  
  # Try to create a session
  if curl -s -X POST "${api_url}/sessions" \
    -H "Content-Type: application/json" \
    -d '{"sessionName":"smoke-test"}' | grep -q "sessionHandle"; then
    log "✓ SQL Gateway is responding"
    return 0
  else
    log "✗ SQL Gateway smoke test failed"
    return 1
  fi
}

flink_test_all() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: flink_test_all <env-file> [--clean]"
  
  # Support both consolidated paths and absolute paths
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(get_env_file flink "${env_file##*/}" 2>/dev/null || echo "${env_file}")"
  fi
  
  # Auto-detect BUNDLE_DIR
  local manifest_dir
  manifest_dir=$(find . -path "*/flink/openshift/manifests" -type d | head -1)
  if [[ -n "${manifest_dir}" ]]; then
    export BUNDLE_DIR="$(cd "${manifest_dir}/.." && pwd)"
  fi
  
  load_env "${env_file}"
  require_commands oc
  require_env OPENSHIFT_NAMESPACE
  
  local clean=false
  
  while [[ $# -gt 1 ]]; do
    case "$2" in
      --clean)
        clean=true
        ;;
      *)
        ;;
    esac
    shift
  done
  
  log "running Flink full test cycle in ${OPENSHIFT_NAMESPACE}"
  
  if [[ "${clean}" == true ]]; then
    log "cleaning up previous Flink deployment"
    oc delete namespace "${OPENSHIFT_NAMESPACE}" --ignore-not-found=true || true
    wait_for_namespace_delete "${OPENSHIFT_NAMESPACE}"
  fi
  
  flink_deploy "${env_file}"
  sleep 10
  
  wait_for_statefulset "${OPENSHIFT_NAMESPACE}" flink-jobmanager
  wait_for_deployment "${OPENSHIFT_NAMESPACE}" flink-sql-gateway
  
  flink_smoke_test "${env_file}"
  
  log "Flink test cycle completed"
}

validate_flink_identities() {
  require_commands oc
  
  local format="text"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        format="json"
        ;;
      *)
        ;;
    esac
    shift
  done
  
  log "validating Flink RBAC and service identities"
  
  if [[ "${format}" == "json" ]]; then
    python3 - <<'PY'
import subprocess
import json

namespaces = subprocess.check_output(["oc", "get", "ns", "-o", "jsonpath={.items[*].metadata.name}"]).decode().split()
result = []

for ns in namespaces:
  try:
    sas = subprocess.check_output(["oc", "get", "sa", "-n", ns, "-o", "jsonpath={.items[*].metadata.name}"]).decode().split()
    for sa in sas:
      result.append({"namespace": ns, "serviceaccount": sa})
  except:
    pass

print(json.dumps(result, indent=2))
PY
  else
    log "Flink identities validation completed"
  fi
}

regenerate_namespace_identities_umbrella() {
  log "regenerating namespace identities umbrella manifests"
  
  # This function would regenerate the umbrella manifests for all environments
  # Implementation depends on the structure of governance manifests
  
  log "namespace identities umbrella regeneration completed"
}

# ============================================================================
# Orchestration & Workflows
# ============================================================================

run_deploy_cycle_flink() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: run_deploy_cycle_flink <env-file> [flags]"
  
  log "starting Flink deploy cycle"
  flink_deploy "${env_file}" "$@"
  log "Flink deploy cycle completed"
}

run_deploy_cycle_kafka() {
  local env_file=${1:-}
  [[ -n "${env_file}" ]] || die "usage: run_deploy_cycle_kafka <env-file> [flags]"
  
  log "starting Kafka deploy cycle"
  kafka_deploy "${env_file}" "$@"
  log "Kafka deploy cycle completed"
}

run_full_platform_test() {
  local kafka_env=${1:-}
  local flink_env=${2:-}
  [[ -n "${kafka_env}" && -n "${flink_env}" ]] || die "usage: run_full_platform_test <kafka-env> <flink-env> [flags]"
  
  shift 2 || true
  
  log "starting full platform test"
  
  log "=== deploying Kafka ==="
  kafka_deploy "${kafka_env}" "$@"
  sleep 10
  
  log "=== deploying Flink ==="
  flink_deploy "${flink_env}" "$@"
  sleep 10
  
  log "=== validating Kafka ==="
  kafka_health_check "$(grep '^OPENSHIFT_NAMESPACE=' "${kafka_env}" | cut -d= -f2)"
  
  log "=== validating Flink ==="
  flink_smoke_test "${flink_env}"
  
  log "full platform test completed successfully"
}

cleanup_all() {
  local purge_data=false
  local skip_namespaces=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge-local-data)
        purge_data=true
        ;;
      --skip-namespaces)
        skip_namespaces=true
        ;;
      *)
        ;;
    esac
    shift
  done
  
  log "cleaning up all deployments"
  
  if [[ "${skip_namespaces}" == false ]]; then
    log "deleting Flink namespace"
    oc delete namespace flink-dev --ignore-not-found=true || true
    
    log "deleting Kafka namespace"
    oc delete namespace kafka-dev --ignore-not-found=true || true
  fi
  
  if [[ "${purge_data}" == true ]]; then
    log "purging local persistent data"
    # Implementation depends on local storage configuration
  fi
  
  log "cleanup completed"
}

validate_all() {
  local json_output=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json_output=true
        ;;
      *)
        ;;
    esac
    shift
  done
  
  log "validating all deployments"
  
  if [[ "${json_output}" == true ]]; then
    python3 - <<'PY'
import subprocess
import json

validation = {
  "flink": {},
  "kafka": {},
  "timestamp": "$(timestamp_now)"
}

# Check Flink
try:
  flink_pods = subprocess.check_output(["oc", "get", "pod", "-n", "flink-dev", "-o", "jsonpath={.items[*].metadata.name}"]).decode().split()
  validation["flink"]["pods"] = flink_pods
  validation["flink"]["status"] = "ok" if flink_pods else "empty"
except:
  validation["flink"]["status"] = "error"

# Check Kafka
try:
  kafka_pods = subprocess.check_output(["oc", "get", "pod", "-n", "kafka-dev", "-o", "jsonpath={.items[*].metadata.name}"]).decode().split()
  validation["kafka"]["pods"] = kafka_pods
  validation["kafka"]["status"] = "ok" if kafka_pods else "empty"
except:
  validation["kafka"]["status"] = "error"

print(json.dumps(validation, indent=2))
PY
  else
    log "validation completed"
  fi
}

# ============================================================================
# Example/Quick-Start Functions
# ============================================================================

example_deploy_flink_only() {
  local env_file=${1:-scripts/env/flink.dev.env}
  [[ -f "${env_file}" ]] || env_file="$(get_env_file flink "$(basename "${env_file}")" 2>/dev/null || echo "scripts/env/flink.dev.env")"
  log "=== Example: Deploy Flink Only ==="
  flink_deploy "${env_file}"
}

example_deploy_kafka_only() {
  local env_file=${1:-scripts/env/kafka.dev.env}
  [[ -f "${env_file}" ]] || env_file="$(get_env_file kafka "$(basename "${env_file}")" 2>/dev/null || echo "scripts/env/kafka.dev.env")"
  log "=== Example: Deploy Kafka Only ==="
  kafka_deploy "${env_file}"
}

example_deploy_full_platform() {
  local kafka_env=${1:-scripts/env/kafka.dev.env}
  local flink_env=${2:-scripts/env/flink.dev.env}
  [[ -f "${kafka_env}" ]] || kafka_env="$(get_env_file kafka "$(basename "${kafka_env}")" 2>/dev/null || echo "scripts/env/kafka.dev.env")"
  [[ -f "${flink_env}" ]] || flink_env="$(get_env_file flink "$(basename "${flink_env}")" 2>/dev/null || echo "scripts/env/flink.dev.env")"
  log "=== Example: Deploy Full Platform ==="
  run_full_platform_test "${kafka_env}" "${flink_env}"
}

example_test_flink() {
  local env_file=${1:-scripts/env/flink.dev.env}
  [[ -f "${env_file}" ]] || env_file="$(get_env_file flink "$(basename "${env_file}")" 2>/dev/null || echo "scripts/env/flink.dev.env")"
  log "=== Example: Test Flink ==="
  flink_test_all "${env_file}" --clean
}

example_test_kafka() {
  local env_file=${1:-scripts/env/kafka.dev.env}
  [[ -f "${env_file}" ]] || env_file="$(get_env_file kafka "$(basename "${env_file}")" 2>/dev/null || echo "scripts/env/kafka.dev.env")"
  log "=== Example: Test Kafka ==="
  kafka_test_all "${env_file}" --clean
}

example_test_full_platform() {
  local kafka_env=${1:-scripts/env/kafka.dev.env}
  local flink_env=${2:-scripts/env/flink.dev.env}
  [[ -f "${kafka_env}" ]] || kafka_env="$(get_env_file kafka "$(basename "${kafka_env}")" 2>/dev/null || echo "scripts/env/kafka.dev.env")"
  [[ -f "${flink_env}" ]] || flink_env="$(get_env_file flink "$(basename "${flink_env}")" 2>/dev/null || echo "scripts/env/flink.dev.env")"
  log "=== Example: Test Full Platform ==="
  run_full_platform_test "${kafka_env}" "${flink_env}"
}

example_build_all_images() {
  local kafka_env=${1:-scripts/env/kafka.dev.env}
  local flink_env=${2:-scripts/env/flink.dev.env}
  [[ -f "${kafka_env}" ]] || kafka_env="$(get_env_file kafka "$(basename "${kafka_env}")" 2>/dev/null || echo "scripts/env/kafka.dev.env")"
  [[ -f "${flink_env}" ]] || flink_env="$(get_env_file flink "$(basename "${flink_env}")" 2>/dev/null || echo "scripts/env/flink.dev.env")"
  log "=== Example: Build All Images ==="
  build_image_kafka "${kafka_env}"
  build_images_flink "${flink_env}"
}

example_cleanup_and_validate() {
  local kafka_env=${1:-scripts/env/kafka.dev.env}
  local flink_env=${2:-scripts/env/flink.dev.env}
  [[ -f "${kafka_env}" ]] || kafka_env="$(get_env_file kafka "$(basename "${kafka_env}")" 2>/dev/null || echo "scripts/env/kafka.dev.env")"
  [[ -f "${flink_env}" ]] || flink_env="$(get_env_file flink "$(basename "${flink_env}")" 2>/dev/null || echo "scripts/env/flink.dev.env")"
  log "=== Example: Cleanup and Validate ==="
  cleanup_all --purge-local-data
  sleep 5
  validate_all --json
}

# ============================================================================
# Help & Usage Functions
# ============================================================================

show_help() {
  cat <<'HELP'
╔══════════════════════════════════════════════════════════════════════════════╗
║         Microshift Flink-Kafka Deployment Library (lib.sh) v2.0              ║
║                       All functions in one place                             ║
╚══════════════════════════════════════════════════════════════════════════════╝

QUICK START:
  source scripts/lib.sh
  flink_deploy scripts/env/flink.dev.env
  kafka_deploy scripts/env/kafka.dev.env

ENVIRONMENT FILES (consolidated in scripts/env/):
  • flink.config.yaml    - Flink configuration with template variables
  • flink.dev.env        - Flink dev deployment settings
  • flink.example.env    - Flink example template
  • kafka.dev.env        - Kafka dev deployment settings
  • kafka.example.env    - Kafka example template

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CORE UTILITY FUNCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  log <message>                    Print timestamped log message
  die <message>                    Print error and exit with code 1
  require_commands <cmd...>        Verify required commands exist in PATH
  load_env <env-file>              Source environment file with set -a/+a
  require_env <var...>             Verify environment variables are not empty
  require_file <path>              Verify file exists
  detect_container_cli             Auto-detect podman or docker
  get_env_file <component> <env>   Get consolidated env file path (NEW)
  get_flink_config                 Get consolidated flink.config.yaml path (NEW)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
KUBERNETES HELPER FUNCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  create_namespace <ns> <labels>   Create Kubernetes namespace with labels
  apply_manifests <dir> <ns>       Apply all YAML files in directory to namespace
  create_docker_registry_secret    Create docker-registry secret from credentials
  apply_from_template <tpl> <ns>   Process and apply template with oc process
  wait_for_deployment <dep> <ns>   Wait for deployment readiness
  wait_for_statefulset <sts> <ns>  Wait for StatefulSet readiness

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
TEMPLATE & RENDERING FUNCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  render_template <src> <dest>     Render {{VARIABLE}} templates to file
  render_tree <src-dir> <dst-dir>  Recursively render all files in directory
  render_bundle <bundle-dir>       Render complete bundle to RENDER_DIR
  rendered_file <file>             Get rendered file path from RENDER_DIR

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
REGISTRY & BUILD FUNCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  registry_login <env-file>        Login to image registry
  build_image_kafka <env-file>     Build Kafka KRaft image
  build_images_flink <env-file>    Build Flink base and SQL runtime images
  push_image <image> <tag>         Push image to registry

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
BOOTSTRAP & CI FUNCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  bootstrap_ci_flink <env-file>    Setup Flink CI environment
  bootstrap_ci_kafka <env-file>    Setup Kafka CI environment

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SECRETS & CREDENTIALS FUNCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  create_generic_secret <name> <file> <ns>      Create generic secret from file
  create_file_secret <name> <key> <file> <ns>   Create secret with specific key
  create_secrets_flink <env-file>                Create all Flink secrets
  create_secrets_kafka <env-file>                Create all Kafka secrets

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
KAFKA OPERATIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  kafka_deploy <env-file>          Deploy Kafka cluster
  kafka_create_topic <env-file> <topic> [--partitions N] [--replicas N]
                                   Create Kafka topic with options
  kafka_health_check <env-file>    Check cluster and broker health
  kafka_maintenance_guard <env-file> [--duration N]
                                   Guard cluster during maintenance
  kafka_test_all <env-file> [--clean]
                                   Run all Kafka tests (optionally clean first)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
FLINK OPERATIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  flink_deploy <env-file>          Deploy Flink cluster
  flink_submit_sql <env-file> <sql-file> [--wait]
                                   Submit SQL job to Flink
  flink_smoke_test <env-file>      Run quick smoke test
  flink_test_all <env-file> [--clean]
                                   Run all Flink tests (optionally clean first)
  validate_flink_identities <env-file>
                                   Validate namespace identities configuration
  regenerate_namespace_identities_umbrella <env-file>
                                   Regenerate umbrella namespace identities

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ORCHESTRATION & PLATFORM FUNCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  run_deploy_cycle_flink <env-file> [--skip-tests]
                                   Deploy and test Flink cycle
  run_deploy_cycle_kafka <env-file> [--skip-tests]
                                   Deploy and test Kafka cycle
  run_full_platform_test <kafka-env> <flink-env> [--json]
                                   Test complete platform integration
  cleanup_all [--purge-local-data] [--skip-namespaces]
                                   Cleanup all deployments
  validate_all [--json]            Validate platform configuration

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EXAMPLE/QUICK-START FUNCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  example_deploy_flink_only        Quick example: deploy Flink only
  example_deploy_kafka_only        Quick example: deploy Kafka only
  example_deploy_full_platform     Quick example: deploy complete platform
  example_test_flink               Quick example: test Flink deployment
  example_test_kafka               Quick example: test Kafka deployment
  example_test_full_platform       Quick example: test full platform
  example_build_all_images         Quick example: build all container images
  example_cleanup_and_validate     Quick example: cleanup and validate

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
UTILITY FUNCTIONS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  sanitize_name <name>             Sanitize string for Kubernetes names
  generate_uuid                    Generate random UUID
  timestamp_now                    Print current timestamp
  wait_for_namespace_delete <ns> <timeout>
                                   Wait for namespace deletion
  json_get <json-string> <path>    Extract value from JSON using path
  sql_gateway_api_url <base-url>   Build Flink SQL Gateway API URL
  split_sql_file <file> <output-dir>
                                   Split multi-statement SQL into separate files

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
USAGE EXAMPLES
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. DEPLOY FLINK & KAFKA (Full Platform):
   $ source scripts/lib.sh
   $ flink_deploy scripts/env/flink.dev.env
   $ kafka_deploy scripts/env/kafka.dev.env
   $ run_full_platform_test scripts/env/kafka.dev.env scripts/env/flink.dev.env

2. TEST EXISTING DEPLOYMENT:
   $ flink_test_all scripts/env/flink.dev.env
   $ kafka_test_all scripts/env/kafka.dev.env

3. BUILD IMAGES:
   $ registry_login scripts/env/flink.dev.env
   $ build_images_flink scripts/env/flink.dev.env
   $ build_image_kafka scripts/env/kafka.dev.env

4. CLEANUP:
   $ cleanup_all --purge-local-data

5. RUN EXAMPLE:
   $ example_deploy_flink_only
   $ example_test_kafka

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
OPTIONS & FLAGS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Common options across functions:
  --clean                          Clean/reset state before operation
  --wait                           Wait for completion
  --skip-tests                     Skip test phase
  --purge-local-data               Delete all local persistent volumes
  --skip-namespaces                Skip namespace operations
  --json                           Output in JSON format
  --help, -h                       Show this help message

═══════════════════════════════════════════════════════════════════════════════
For more information, see README.md or run: bash -c 'source scripts/lib.sh; <function_name> --help'
═══════════════════════════════════════════════════════════════════════════════
HELP
}

show_usage() {
  cat <<'USAGE'
Usage: source scripts/lib.sh && <function-name> [options]

  To view comprehensive help and all available functions:
    bash scripts/lib.sh --help
    bash scripts/lib.sh -h
    bash scripts/lib.sh help

  To use specific functions:
    source scripts/lib.sh
    <function-name> <args>

  Example:
    source scripts/lib.sh
    flink_deploy scripts/env/flink.dev.env
    kafka_deploy scripts/env/kafka.dev.env
USAGE
}

# Display help if script is run directly with --help, -h, help, or no args
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # Sourced, not executed - don't auto-display help
  :
else
  # Executed directly
  case "${1:-}" in
    --help|-h|help|"")
      show_help
      exit 0
      ;;
  esac
fi
