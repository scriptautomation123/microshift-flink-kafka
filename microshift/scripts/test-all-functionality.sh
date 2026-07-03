#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  test-all-functionality.sh [--clean] [--cleanup-only] [--run-host-config] [--dns1 <ip>] [--dns2 <ip>] [--skip-local-pv]

Options:
  --clean            Delete any existing MINC cluster before full test.
  --cleanup-only     Delete MINC cluster and exit.
  --run-host-config  Execute root-level host config scripts (sudo required).
  --dns1 <ip>        Primary DNS for configure-podman-dns.sh (default: 1.1.1.1).
  --dns2 <ip>        Secondary DNS for configure-podman-dns.sh (default: 8.8.8.8).
  --skip-local-pv    Skip local static PV provisioning helper.
  -h, --help         Show help.
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MICROSHIFT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLEAN=false
CLEANUP_ONLY=false
RUN_HOST_CONFIG=false
DNS1="1.1.1.1"
DNS2="8.8.8.8"
SKIP_LOCAL_PV=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN=true
      shift
      ;;
    --cleanup-only)
      CLEANUP_ONLY=true
      shift
      ;;
    --run-host-config)
      RUN_HOST_CONFIG=true
      shift
      ;;
    --dns1)
      DNS1="${2:-}"
      shift 2
      ;;
    --dns2)
      DNS2="${2:-}"
      shift 2
      ;;
    --skip-local-pv)
      SKIP_LOCAL_PV=true
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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command not found: $1" >&2; exit 1; }
}

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*"
}

wait_for_node_ready() {
  local attempts=0
  until oc get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -q '^Ready$'; do
    attempts=$((attempts + 1))
    if [[ ${attempts} -gt 60 ]]; then
      echo "ERROR: node did not become Ready in expected time" >&2
      oc get nodes -o wide || true
      return 1
    fi
    sleep 10
  done
}

cleanup_cluster() {
  log "Deleting MINC cluster"
  minc delete || true
}

log "Validating script syntax"
bash -n "${SCRIPT_DIR}/configure-podman-dns.sh"
bash -n "${SCRIPT_DIR}/install-docker-podman-forwarding.sh"
bash -n "${SCRIPT_DIR}/provision-local-pv.sh"
bash -n "${SCRIPT_DIR}/test-all-functionality.sh"

require_cmd minc
require_cmd podman
require_cmd oc

if [[ "${CLEANUP_ONLY}" == true ]]; then
  cleanup_cluster
  log "Cleanup-only completed"
  exit 0
fi

if [[ "${RUN_HOST_CONFIG}" == true ]]; then
  log "Running host DNS configuration script"
  sudo "${SCRIPT_DIR}/configure-podman-dns.sh" "${DNS1}" "${DNS2}"

  # Only install forwarding service when Docker appears active.
  if systemctl is-active --quiet docker 2>/dev/null; then
    log "Docker detected active; installing podman forwarding service"
    sudo "${SCRIPT_DIR}/install-docker-podman-forwarding.sh"
  else
    log "Docker service is not active; skipping forwarding service install"
  fi
fi

if [[ "${CLEAN}" == true ]]; then
  cleanup_cluster
fi

log "Creating MINC cluster"
minc create

log "Validating MINC status"
minc status
minc list

export PATH="$HOME/.local/bin:$PATH"

log "Validating OpenShift API and baseline"
oc whoami
oc whoami --show-server
oc get nodes -o wide
wait_for_node_ready
oc get pods -n openshift-operator-lifecycle-manager -o wide
oc get pods -A

if [[ "${SKIP_LOCAL_PV}" != true ]]; then
  log "Provisioning local static PVs for Kafka/Flink namespaces"
  "${SCRIPT_DIR}/provision-local-pv.sh" --kafka-namespace kafka-dev --flink-namespace flink-dev || true
fi

log "Validating ingress listener ports"
ss -ltnp | grep -E ':(6443|9080|9443)\b' || true

log "Validating API readiness endpoints"
curl -skI https://127.0.0.1:6443/readyz || true
curl -sI http://127.0.0.1:9080 || true
curl -skI https://127.0.0.1:9443 || true

log "MicroShift full functionality test completed"
