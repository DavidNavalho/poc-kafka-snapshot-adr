#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TOPIC="${1:-dr.basic.orders}"
MESSAGE_COUNT="${2:-1200}"
PARTITIONS="${3:-6}"

mkdir -p "${ROOT_DIR}/artifacts/latest/source"
SOURCE_ARTIFACT_DIR="${ROOT_DIR}/artifacts/latest/source"

wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90

if compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --list | grep -Fx '${TOPIC}' >/dev/null"; then
  EXISTING_COUNT="$(compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${TOPIC} --time -1 2>/dev/null | awk -F: '{sum += \$3} END {print sum + 0}'")"
  if [[ "${EXISTING_COUNT}" -gt 0 ]]; then
    echo "Topic ${TOPIC} already contains ${EXISTING_COUNT} records. Use reset_lab.sh or a fresh topic name." >&2
    exit 1
  fi
fi

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --create --if-not-exists --topic ${TOPIC} --partitions ${PARTITIONS} --replication-factor 3"

seq 1 "${MESSAGE_COUNT}" \
  | awk '{printf "customer-%03d:{\"event\":\"seed\",\"order_id\":%d,\"amount\":%d}\n", ($1 % 23), $1, (($1 % 17) + 1)}' \
  | compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${TOPIC} --property parse.key=true --property key.separator=: >/dev/null"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --topic ${TOPIC}" \
  > "${SOURCE_ARTIFACT_DIR}/topic_describe.txt"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${TOPIC} --time -1" \
  | sort > "${SOURCE_ARTIFACT_DIR}/end_offsets.txt"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${TOPIC} --from-beginning --max-messages ${MESSAGE_COUNT} --property print.key=true --property key.separator=:" \
  > "${SOURCE_ARTIFACT_DIR}/topic_dump.txt"

LC_ALL=C sort "${SOURCE_ARTIFACT_DIR}/topic_dump.txt" > "${SOURCE_ARTIFACT_DIR}/topic_dump.sorted.txt"
SOURCE_HASH="$(hash_file "${SOURCE_ARTIFACT_DIR}/topic_dump.sorted.txt")"
echo "${SOURCE_HASH}" > "${SOURCE_ARTIFACT_DIR}/topic_dump.sorted.sha256"

SOURCE_COUNT="$(wc -l < "${SOURCE_ARTIFACT_DIR}/topic_dump.txt" | tr -d ' ')"
echo "${SOURCE_COUNT}" > "${SOURCE_ARTIFACT_DIR}/topic_dump.count"

if [[ "${SOURCE_COUNT}" != "${MESSAGE_COUNT}" ]]; then
  echo "Expected ${MESSAGE_COUNT} records, consumed ${SOURCE_COUNT} records from ${TOPIC}." >&2
  exit 1
fi

grep '^cluster.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${SOURCE_ARTIFACT_DIR}/cluster_id.txt"
grep '^node.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${SOURCE_ARTIFACT_DIR}/node_id.txt"

echo "Seeded ${TOPIC} with ${MESSAGE_COUNT} records."
