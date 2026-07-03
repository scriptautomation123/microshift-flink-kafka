#!/usr/bin/env bash

set -euo pipefail

: "${KAFKA_NAMESPACE:?KAFKA_NAMESPACE is required}"
: "${KAFKA_CLUSTER_ID:?KAFKA_CLUSTER_ID is required}"
: "${KAFKA_REPLICAS:=3}"
: "${KAFKA_DEFAULT_REPLICATION_FACTOR:=3}"
: "${KAFKA_MIN_INSYNC_REPLICAS:=2}"
: "${KAFKA_NUM_PARTITIONS:=6}"

KAFKA_HOME=${KAFKA_HOME:-/opt/kafka}
HOSTNAME_VALUE=$(hostname)
POD_ORDINAL=${HOSTNAME_VALUE##*-}
NODE_ID=${POD_ORDINAL}
HEADLESS_SERVICE=${KAFKA_HEADLESS_SERVICE:-kafka-headless}
DATA_DIR=${KAFKA_DATA_DIR:-/var/lib/kafka/data}
CONFIG_FILE=${KAFKA_HOME}/config/generated/server.properties

build_quorum_voters() {
  local voters=()
  local i
  for ((i = 0; i < KAFKA_REPLICAS; i++)); do
    voters+=("${i}@kafka-${i}.${HEADLESS_SERVICE}.${KAFKA_NAMESPACE}.svc:9093")
  done
  (IFS=','; echo "${voters[*]}")
}

QUORUM_VOTERS=$(build_quorum_voters)
ADVERTISED_INTERNAL="kafka-${POD_ORDINAL}.${HEADLESS_SERVICE}.${KAFKA_NAMESPACE}.svc:9092"

cat >"${CONFIG_FILE}" <<EOF
process.roles=broker,controller
node.id=${NODE_ID}
controller.quorum.voters=${QUORUM_VOTERS}

listeners=INTERNAL://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
advertised.listeners=INTERNAL://${ADVERTISED_INTERNAL}
listener.security.protocol.map=INTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=INTERNAL
controller.listener.names=CONTROLLER

log.dirs=${DATA_DIR}
num.partitions=${KAFKA_NUM_PARTITIONS}
default.replication.factor=${KAFKA_DEFAULT_REPLICATION_FACTOR}
min.insync.replicas=${KAFKA_MIN_INSYNC_REPLICAS}
offsets.topic.replication.factor=${KAFKA_DEFAULT_REPLICATION_FACTOR}
transaction.state.log.replication.factor=${KAFKA_DEFAULT_REPLICATION_FACTOR}
transaction.state.log.min.isr=${KAFKA_MIN_INSYNC_REPLICAS}
auto.create.topics.enable=false
unclean.leader.election.enable=false

log.retention.hours=168
log.segment.bytes=1073741824
EOF

if [[ ! -f "${DATA_DIR}/meta.properties" ]]; then
  "${KAFKA_HOME}/bin/kafka-storage.sh" format \
    -t "${KAFKA_CLUSTER_ID}" \
    -c "${CONFIG_FILE}" \
    --ignore-formatted
fi

exec "${KAFKA_HOME}/bin/kafka-server-start.sh" "${CONFIG_FILE}"
