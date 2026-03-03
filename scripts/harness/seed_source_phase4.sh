#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase4_topics.sh
source "${SCRIPT_DIR}/phase4_topics.sh"

SOURCE_PHASE4_DIR="${ROOT_DIR}/artifacts/latest/source/phase4"
SOURCE_TOPICS_DIR="${SOURCE_PHASE4_DIR}/topics"
SOURCE_GROUPS_DIR="${SOURCE_PHASE4_DIR}/groups"
mkdir -p "${SOURCE_TOPICS_DIR}" "${SOURCE_GROUPS_DIR}"

capture_group_offsets() {
  local bootstrap="$1"
  local group_id="$2"
  local raw_file="$3"
  local parsed_file="$4"

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-consumer-groups --bootstrap-server ${bootstrap} --describe --group ${group_id}" \
    > "${raw_file}"

  awk '
    NF >= 5 && $3 ~ /^[0-9]+$/ && $4 ~ /^[-0-9]+$/ && $5 ~ /^[-0-9]+$/ {
      print $1 "|" $2 "|" $3 "|" $4 "|" $5
    }
  ' "${raw_file}" | LC_ALL=C sort > "${parsed_file}"
}

wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90

grep '^cluster.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt"
grep '^node.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/node_id.txt"

for spec in "${PHASE4_TOPIC_SPECS[@]}"; do
  IFS="|" read -r topic partitions message_count <<< "${spec}"
  topic_dir="${SOURCE_TOPICS_DIR}/${topic}"
  mkdir -p "${topic_dir}"

  if compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --list | grep -Fx '${topic}' >/dev/null"; then
    existing_count="$(compose_cmd exec -T source-broker-1 bash -lc \
      "kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --time -1 2>/dev/null | awk -F: '{sum += \$3} END {print sum + 0}'")"
    if [[ "${existing_count}" -gt 0 ]]; then
      echo "Topic ${topic} already contains ${existing_count} records. Use reset_lab.sh or a fresh topic name." >&2
      exit 1
    fi
  fi

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --create --if-not-exists --topic ${topic} --partitions ${partitions} --replication-factor 3"

  seq 1 "${message_count}" \
    | awk -v topic="${topic}" '{printf "entity-%04d:{\"event\":\"seed\",\"topic\":\"%s\",\"id\":%d,\"amount\":%d}\n", ($1 % 200), topic, $1, (($1 % 29) + 1)}' \
    | compose_cmd exec -T source-broker-1 bash -lc \
      "kafka-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --property parse.key=true --property key.separator=: >/dev/null"

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --topic ${topic}" \
    > "${topic_dir}/topic_describe.txt"

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --time -1" \
    | sort > "${topic_dir}/end_offsets.txt"

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${message_count} --property print.key=true --property key.separator=:" \
    > "${topic_dir}/topic_dump.txt"

  LC_ALL=C sort "${topic_dir}/topic_dump.txt" > "${topic_dir}/topic_dump.sorted.txt"
  hash_file "${topic_dir}/topic_dump.sorted.txt" > "${topic_dir}/topic_dump.sorted.sha256"

  topic_count="$(wc -l < "${topic_dir}/topic_dump.txt" | tr -d ' ')"
  echo "${topic_count}" > "${topic_dir}/topic_dump.count"
  printf 'topic=%s\npartitions=%s\nseed_messages=%s\n' \
    "${topic}" "${partitions}" "${message_count}" > "${topic_dir}/spec.txt"

  if [[ "${topic_count}" -ne "${message_count}" ]]; then
    echo "Expected ${message_count} records, consumed ${topic_count} records from ${topic}." >&2
    exit 1
  fi
done

full_topic_count="$(cat "${SOURCE_TOPICS_DIR}/${PHASE4_FULL_TOPIC}/topic_dump.count")"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE4_FULL_TOPIC} --group ${PHASE4_FULL_GROUP} --from-beginning --max-messages ${full_topic_count} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE4_PARTIAL_TOPIC} --group ${PHASE4_PARTIAL_GROUP} --from-beginning --max-messages ${PHASE4_PARTIAL_INITIAL_MESSAGES} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2

capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE4_FULL_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE4_FULL_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE4_FULL_GROUP}.offsets.txt"
capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE4_PARTIAL_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.offsets.txt"

if [[ ! -s "${SOURCE_GROUPS_DIR}/${PHASE4_FULL_GROUP}.offsets.txt" ]]; then
  echo "No offsets captured for full-consume group ${PHASE4_FULL_GROUP}." >&2
  exit 1
fi
if [[ ! -s "${SOURCE_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.offsets.txt" ]]; then
  echo "No offsets captured for partial-consume group ${PHASE4_PARTIAL_GROUP}." >&2
  exit 1
fi

if ! awk -F'|' -v topic="${PHASE4_FULL_TOPIC}" '$2 == topic {if ($4 != $5) bad=1; seen=1} END {exit (seen && !bad) ? 0 : 1}' \
  "${SOURCE_GROUPS_DIR}/${PHASE4_FULL_GROUP}.offsets.txt"; then
  echo "Expected ${PHASE4_FULL_GROUP} to be fully caught up on ${PHASE4_FULL_TOPIC} before snapshot." >&2
  exit 1
fi

if ! awk -F'|' -v topic="${PHASE4_PARTIAL_TOPIC}" '
  $2 == topic {
    if ($4 + 0 > $5 + 0) bad=1
    if ($4 + 0 < $5 + 0) partial=1
    seen=1
  }
  END {exit (seen && !bad && partial) ? 0 : 1}
' "${SOURCE_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.offsets.txt"; then
  echo "Expected ${PHASE4_PARTIAL_GROUP} to be partially consumed on ${PHASE4_PARTIAL_TOPIC} before snapshot." >&2
  exit 1
fi

echo "Phase 4 source seeding complete."
