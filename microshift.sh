#!/usr/bin/env bash
# Consolidated MicroShift utility script
# 
# Consolidates functionality from:
#   - test-all-functionality.sh
#   - provision-local-pv.sh
#   - install-docker-podman-forwarding.sh
#   - configure-podman-dns.sh
#
# Usage: microshift.sh [subcommand] [options]

set -euo pipefail

# ============================================================================
# Core Helper Functions
# ============================================================================

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "this command requires root privileges (use sudo)"
  fi
}

# ============================================================================
# DNS Configuration Command
# ============================================================================

show_configure_dns_help() {
  cat <<'EOF'
Usage: microshift.sh configure-dns [options]

Configure Podman DNS settings.

Options:
  --dns1 <ip>      Primary DNS server (default: 1.1.1.1)
  --dns2 <ip>      Secondary DNS server (default: 8.8.8.8)
  -h, --help       Show this help

This command requires root privileges.

Example:
  sudo microshift.sh configure-dns --dns1 1.1.1.1 --dns2 8.8.8.8
EOF
}

cmd_configure_dns() {
  local dns1="1.1.1.1"
  local dns2="8.8.8.8"
  local target="/etc/containers/containers.conf"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dns1)
        dns1="${2:-}"
        shift 2
        ;;
      --dns2)
        dns2="${2:-}"
        shift 2
        ;;
      -h|--help)
        show_configure_dns_help
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  require_root

  log "configuring Podman DNS: ${dns1}, ${dns2}"
  install -d -m 0755 /etc/containers
  cat >"${target}" <<CONF
[containers]
dns_servers = ["${dns1}", "${dns2}"]
CONF

  log "wrote ${target}"
}

# ============================================================================
# Docker Forwarding Command
# ============================================================================

show_install_forwarding_help() {
  cat <<'EOF'
Usage: microshift.sh install-forwarding

Install Docker-to-Podman network forwarding systemd service.

This command requires root privileges and Docker to be installed/active.

This creates:
  /usr/local/sbin/podman-docker-forwarding.sh
  /etc/systemd/system/podman-docker-forwarding.service

Example:
  sudo microshift.sh install-forwarding
EOF
}

cmd_install_forwarding() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        show_install_forwarding_help
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  require_root

  log "installing Docker-to-Podman forwarding service"

  install -d -m 0755 /usr/local/sbin
  cat >/usr/local/sbin/podman-docker-forwarding.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
iptables -C DOCKER-USER -i podman0 -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 1 -i podman0 -j ACCEPT
iptables -C DOCKER-USER -o podman0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I DOCKER-USER 2 -o podman0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
SCRIPT
  chmod 0755 /usr/local/sbin/podman-docker-forwarding.sh

  cat >/etc/systemd/system/podman-docker-forwarding.service <<'SERVICE'
[Unit]
Description=Allow Podman bridge traffic through Docker forwarding policy
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/podman-docker-forwarding.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE

  systemctl daemon-reload
  systemctl enable --now podman-docker-forwarding.service
  systemctl status --no-pager podman-docker-forwarding.service

  log "Docker-to-Podman forwarding service installed and enabled"
}

# ============================================================================
# Local PV Provisioning Command
# ============================================================================

show_provision_pv_help() {
  cat <<'EOF'
Usage: microshift.sh provision-pv [options]

Provision local static PersistentVolumes for Kafka and/or Flink namespaces.

Options:
  --kafka-namespace <name>         Kafka namespace (default: kafka-dev)
  --kafka-replicas <count>         Kafka StatefulSet replicas (default: 3)
  --kafka-size <size>              Kafka PVC size per broker (default: 50Gi)

  --flink-namespace <name>         Flink namespace (default: flink-dev)
  --flink-taskmanagers <count>     Flink taskmanager replicas (default: 3)
  --flink-jobmanager-size <size>   Flink JobManager PVC size (default: 20Gi)
  --flink-taskmanager-size <size>  Flink TaskManager PVC size each (default: 100Gi)

  --base-dir <path>                Host path base directory for PVs
                                   (default: /var/lib/microshift-local-pv)

  --kafka-only                     Provision only Kafka PVs
  --flink-only                     Provision only Flink PVs
  --delete                         Delete the generated PVs instead of applying
  -h, --help                       Show this help

Notes:
  This creates static hostPath PVs with pre-bound claimRef entries.
  Use this on local single-node MINC/MicroShift clusters when no dynamic
  StorageClass is available.

Example:
  microshift.sh provision-pv --kafka-namespace kafka-dev --flink-namespace flink-dev
EOF
}

emit_pv() {
  local name="$1"
  local size="$2"
  local namespace="$3"
  local claim_name="$4"
  local host_path="$5"

  cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${name}
  labels:
    app.kubernetes.io/managed-by: microshift-local-pv
spec:
  capacity:
    storage: ${size}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  claimRef:
    namespace: ${namespace}
    name: ${claim_name}
  hostPath:
    path: ${host_path}
    type: DirectoryOrCreate
EOF
}

apply_or_delete() {
  local manifest="$1"
  local delete_mode="$2"
  if [[ "${delete_mode}" == "true" ]]; then
    printf '%s\n' "${manifest}" | oc delete -f - --ignore-not-found
  else
    printf '%s\n' "${manifest}" | oc apply -f -
  fi
}

cmd_provision_pv() {
  local kafka_namespace="kafka-dev"
  local kafka_replicas=3
  local kafka_size="50Gi"
  local flink_namespace="flink-dev"
  local flink_taskmanagers=3
  local flink_jobmanager_size="20Gi"
  local flink_taskmanager_size="100Gi"
  local base_dir="/var/lib/microshift-local-pv"
  local provision_kafka=true
  local provision_flink=true
  local delete_mode=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kafka-namespace)
        kafka_namespace="${2:-}"
        shift 2
        ;;
      --kafka-replicas)
        kafka_replicas="${2:-}"
        shift 2
        ;;
      --kafka-size)
        kafka_size="${2:-}"
        shift 2
        ;;
      --flink-namespace)
        flink_namespace="${2:-}"
        shift 2
        ;;
      --flink-taskmanagers)
        flink_taskmanagers="${2:-}"
        shift 2
        ;;
      --flink-jobmanager-size)
        flink_jobmanager_size="${2:-}"
        shift 2
        ;;
      --flink-taskmanager-size)
        flink_taskmanager_size="${2:-}"
        shift 2
        ;;
      --base-dir)
        base_dir="${2:-}"
        shift 2
        ;;
      --kafka-only)
        provision_kafka=true
        provision_flink=false
        shift
        ;;
      --flink-only)
        provision_kafka=false
        provision_flink=true
        shift
        ;;
      --delete)
        delete_mode=true
        shift
        ;;
      -h|--help)
        show_provision_pv_help
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  require_cmd oc

  if ! [[ "$kafka_replicas" =~ ^[0-9]+$ ]] || ! [[ "$flink_taskmanagers" =~ ^[0-9]+$ ]]; then
    die "replica counts must be integers"
  fi

  if [[ "${provision_kafka}" == true ]]; then
    log "provisioning Kafka local PVs (${kafka_replicas} replicas)"
    for i in $(seq 0 $((kafka_replicas - 1))); do
      pv_name="local-pv-${kafka_namespace}-kafka-${i}"
      claim_name="data-kafka-${i}"
      host_path="${base_dir}/${kafka_namespace}/kafka-${i}"
      apply_or_delete "$(emit_pv "${pv_name}" "${kafka_size}" "${kafka_namespace}" "${claim_name}" "${host_path}")" "${delete_mode}"
    done
  fi

  if [[ "${provision_flink}" == true ]]; then
    log "provisioning Flink local PVs (jobmanager + ${flink_taskmanagers} taskmanagers)"

    apply_or_delete "$(emit_pv \
      "local-pv-${flink_namespace}-flink-jobmanager-0" \
      "${flink_jobmanager_size}" \
      "${flink_namespace}" \
      "jobmanager-data-flink-jobmanager-0" \
      "${base_dir}/${flink_namespace}/jobmanager-0")" "${delete_mode}"

    for i in $(seq 0 $((flink_taskmanagers - 1))); do
      pv_name="local-pv-${flink_namespace}-flink-taskmanager-${i}"
      claim_name="taskmanager-data-flink-taskmanager-${i}"
      host_path="${base_dir}/${flink_namespace}/taskmanager-${i}"
      apply_or_delete "$(emit_pv "${pv_name}" "${flink_taskmanager_size}" "${flink_namespace}" "${claim_name}" "${host_path}")" "${delete_mode}"
    done
  fi

  if [[ "${delete_mode}" == true ]]; then
    log "local PV deletion completed"
  else
    log "local PV provisioning completed"
  fi
}

# ============================================================================
# Cluster Test Command
# ============================================================================

show_test_all_help() {
  cat <<'EOF'
Usage: microshift.sh test-all [options]

Run comprehensive MicroShift cluster validation and functionality tests.

Options:
  --clean                  Delete any existing MINC cluster before full test
  --cleanup-only           Delete MINC cluster and exit
  --run-host-config        Execute root-level host config scripts (sudo required)
  --dns1 <ip>              Primary DNS for configure-podman-dns (default: 1.1.1.1)
  --dns2 <ip>              Secondary DNS for configure-podman-dns (default: 8.8.8.8)
  --skip-local-pv          Skip local static PV provisioning helper
  -h, --help               Show this help

Examples:
  microshift.sh test-all --clean
  sudo microshift.sh test-all --run-host-config --clean
EOF
}

wait_for_node_ready() {
  local attempts=0
  until oc get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -q '^Ready$'; do
    attempts=$((attempts + 1))
    if [[ ${attempts} -gt 60 ]]; then
      die "node did not become Ready in expected time"
    fi
    sleep 10
  done
}

cleanup_cluster() {
  log "deleting MINC cluster"
  minc delete || true
}

cmd_test_all() {
  local clean=false
  local cleanup_only=false
  local run_host_config=false
  local dns1="1.1.1.1"
  local dns2="8.8.8.8"
  local skip_local_pv=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean)
        clean=true
        shift
        ;;
      --cleanup-only)
        cleanup_only=true
        shift
        ;;
      --run-host-config)
        run_host_config=true
        shift
        ;;
      --dns1)
        dns1="${2:-}"
        shift 2
        ;;
      --dns2)
        dns2="${2:-}"
        shift 2
        ;;
      --skip-local-pv)
        skip_local_pv=true
        shift
        ;;
      -h|--help)
        show_test_all_help
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  log "validating script syntax"
  bash -n "${BASH_SOURCE[0]}"

  require_cmd minc
  require_cmd podman
  require_cmd oc

  if [[ "${cleanup_only}" == true ]]; then
    cleanup_cluster
    log "cleanup-only completed"
    return 0
  fi

  if [[ "${run_host_config}" == true ]]; then
    log "running host DNS configuration"
    cmd_configure_dns --dns1 "${dns1}" --dns2 "${dns2}"

    if systemctl is-active --quiet docker 2>/dev/null; then
      log "Docker detected active; installing podman forwarding service"
      cmd_install_forwarding
    else
      log "Docker service is not active; skipping forwarding service install"
    fi
  fi

  if [[ "${clean}" == true ]]; then
    cleanup_cluster
  fi

  log "creating MINC cluster"
  minc create

  log "validating MINC status"
  minc status
  minc list

  export PATH="$HOME/.local/bin:$PATH"

  log "validating OpenShift API and baseline"
  oc whoami
  oc whoami --show-server
  oc get nodes -o wide
  wait_for_node_ready
  oc get pods -n openshift-operator-lifecycle-manager -o wide || true
  oc get pods -A

  if [[ "${skip_local_pv}" != true ]]; then
    log "provisioning local static PVs for Kafka/Flink namespaces"
    cmd_provision_pv --kafka-namespace kafka-dev --flink-namespace flink-dev || true
  fi

  log "validating ingress listener ports"
  ss -ltnp | grep -E ':(6443|9080|9443)\b' || true

  log "validating API readiness endpoints"
  curl -skI https://127.0.0.1:6443/readyz || true
  curl -sI http://127.0.0.1:9080 || true
  curl -skI https://127.0.0.1:9443 || true

  log "MicroShift full functionality test completed"
}

# ============================================================================
# Main Help & Dispatcher
# ============================================================================

show_main_help() {
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                    MicroShift Utility Script v1.0                            ║
║          Consolidated microshift cluster and environment management          ║
╚══════════════════════════════════════════════════════════════════════════════╝

Usage: microshift.sh <command> [options]

Commands:
  test-all               Run comprehensive cluster validation tests
  configure-dns          Configure Podman DNS settings (requires sudo)
  install-forwarding     Install Docker-to-Podman forwarding service (requires sudo)
  provision-pv           Provision local static PersistentVolumes
  -h, --help             Show this help message

Examples:
  # Run full cluster test
  microshift.sh test-all --clean

  # Configure DNS with custom servers
  sudo microshift.sh configure-dns --dns1 1.1.1.1 --dns2 8.8.8.8

  # Install Docker forwarding (requires Docker active)
  sudo microshift.sh install-forwarding

  # Provision local PVs for Kafka and Flink
  microshift.sh provision-pv --kafka-namespace kafka-dev --flink-namespace flink-dev
scripts/env scripts/flink-docker scripts/flink-sql scripts/kafka-docker scripts/manifests scripts/lib.sh scripts/microshift.sh

For detailed command help:
  microshift.sh <command> --help
EOF
}

# ============================================================================
# Main Script Entry Point
# ============================================================================

main() {
  local cmd="${1:-}"

  case "${cmd}" in
    test-all)
      shift
      cmd_test_all "$@"
      ;;
    configure-dns)
      shift
      cmd_configure_dns "$@"
      ;;
    install-forwarding)
      shift
      cmd_install_forwarding "$@"
      ;;
    provision-pv)
      shift
      cmd_provision_pv "$@"
      ;;
    --help|-h|"")
      show_main_help
      exit 0
      ;;
    *)
      die "unknown command: ${cmd}"
      ;;
  esac
}

main "$@"
