#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase6_topics.sh
source "${SCRIPT_DIR}/phase6_topics.sh"

SOURCE_PHASE6_DIR="${ROOT_DIR}/artifacts/latest/source/phase6"
SOURCE_TOPICS_DIR="${SOURCE_PHASE6_DIR}/topics"
SOURCE_GROUPS_DIR="${SOURCE_PHASE6_DIR}/groups"
SOURCE_ACLS_DIR="${SOURCE_PHASE6_DIR}/acls"
mkdir -p "${SOURCE_TOPICS_DIR}" "${SOURCE_GROUPS_DIR}" "${SOURCE_ACLS_DIR}"

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

normalize_acl_list() {
  local in_file="$1"
  local out_file="$2"

  sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' "${in_file}" \
    | sed '/^$/d' \
    | LC_ALL=C sort -u > "${out_file}"
}

wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90

grep '^cluster.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt"
grep '^node.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/node_id.txt"

for spec in "${PHASE6_TOPIC_SPECS[@]}"; do
  IFS="|" read -r topic partitions message_count cleanup <<< "${spec}"
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

  create_cmd="kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --create --if-not-exists --topic ${topic} --partitions ${partitions} --replication-factor 3"
  if [[ "${cleanup}" == "compact" ]]; then
    create_cmd="${create_cmd} --config cleanup.policy=compact"
  fi
  compose_cmd exec -T source-broker-1 bash -lc "${create_cmd}"

  if [[ "${cleanup}" == "compact" ]]; then
    seq 1 "${message_count}" \
      | awk -v topic="${topic}" '{printf "entity-%03d:{\"event\":\"state\",\"topic\":\"%s\",\"seq\":%d,\"status\":\"s%d\"}\n", ($1 % 120), topic, $1, ($1 % 7)}' \
      | compose_cmd exec -T source-broker-1 bash -lc \
        "kafka-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --property parse.key=true --property key.separator=: >/dev/null"
  else
    seq 1 "${message_count}" \
      | awk -v topic="${topic}" '{printf "entity-%05d:{\"event\":\"seed\",\"topic\":\"%s\",\"id\":%d,\"amount\":%d}\n", $1, topic, $1, (($1 % 23) + 1)}' \
      | compose_cmd exec -T source-broker-1 bash -lc \
        "kafka-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --property parse.key=true --property key.separator=: >/dev/null"
  fi

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
  wc -l < "${topic_dir}/topic_dump.txt" | tr -d ' ' > "${topic_dir}/topic_dump.count"
done

full_topic_count="$(cat "${SOURCE_TOPICS_DIR}/${PHASE6_FULL_TOPIC}/topic_dump.count")"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE6_FULL_TOPIC} --group ${PHASE6_FULL_GROUP} --from-beginning --max-messages ${full_topic_count} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE6_PARTIAL_TOPIC} --group ${PHASE6_PARTIAL_GROUP} --from-beginning --max-messages ${PHASE6_PARTIAL_INITIAL_MESSAGES} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2

capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE6_FULL_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE6_FULL_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE6_FULL_GROUP}.offsets.txt"
capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE6_PARTIAL_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.offsets.txt"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-acls --bootstrap-server ${SOURCE_BOOTSTRAP} --add --allow-principal ${PHASE6_ACL_PRODUCER_PRINCIPAL} --operation Write --operation Describe --topic ${PHASE6_FULL_TOPIC}"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-acls --bootstrap-server ${SOURCE_BOOTSTRAP} --add --allow-principal ${PHASE6_ACL_FULL_CONSUMER_PRINCIPAL} --operation Read --operation Describe --topic ${PHASE6_FULL_TOPIC}"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-acls --bootstrap-server ${SOURCE_BOOTSTRAP} --add --allow-principal ${PHASE6_ACL_FULL_CONSUMER_PRINCIPAL} --operation Read --group ${PHASE6_FULL_GROUP}"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-acls --bootstrap-server ${SOURCE_BOOTSTRAP} --add --allow-principal ${PHASE6_ACL_PARTIAL_CONSUMER_PRINCIPAL} --operation Read --topic dr.p6.secure. --resource-pattern-type prefixed"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-acls --bootstrap-server ${SOURCE_BOOTSTRAP} --add --allow-principal ${PHASE6_ACL_PARTIAL_CONSUMER_PRINCIPAL} --operation Read --group ${PHASE6_PARTIAL_GROUP}"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-acls --bootstrap-server ${SOURCE_BOOTSTRAP} --add --allow-principal ${PHASE6_ACL_ADMIN_PRINCIPAL} --operation Alter --operation Describe --cluster"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-acls --bootstrap-server ${SOURCE_BOOTSTRAP} --add --deny-principal ${PHASE6_ACL_DENY_PRINCIPAL} --operation Delete --topic ${PHASE6_FULL_TOPIC}"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-acls --bootstrap-server ${SOURCE_BOOTSTRAP} --list" \
  > "${SOURCE_ACLS_DIR}/acls.list.raw.txt"
normalize_acl_list "${SOURCE_ACLS_DIR}/acls.list.raw.txt" "${SOURCE_ACLS_DIR}/acls.list.normalized.txt"

for marker in \
  "${PHASE6_ACL_PRODUCER_PRINCIPAL}" \
  "${PHASE6_ACL_FULL_CONSUMER_PRINCIPAL}" \
  "${PHASE6_ACL_PARTIAL_CONSUMER_PRINCIPAL}" \
  "${PHASE6_ACL_ADMIN_PRINCIPAL}" \
  "${PHASE6_ACL_DENY_PRINCIPAL}" \
  "${PHASE6_FULL_TOPIC}" \
  "dr.p6.secure." \
  "${PHASE6_FULL_GROUP}" \
  "${PHASE6_PARTIAL_GROUP}"; do
  if ! grep -q "${marker}" "${SOURCE_ACLS_DIR}/acls.list.normalized.txt"; then
    echo "Expected ACL marker '${marker}' not found in source ACL snapshot." >&2
    exit 1
  fi
done

if ! awk -F'|' -v topic="${PHASE6_FULL_TOPIC}" '$2 == topic {if ($4 != $5) bad=1; seen=1} END {exit (seen && !bad) ? 0 : 1}' \
  "${SOURCE_GROUPS_DIR}/${PHASE6_FULL_GROUP}.offsets.txt"; then
  echo "Expected ${PHASE6_FULL_GROUP} to be fully caught up before snapshot." >&2
  exit 1
fi

if ! awk -F'|' -v topic="${PHASE6_PARTIAL_TOPIC}" '
  $2 == topic {
    if ($4 + 0 > $5 + 0) bad=1
    if ($4 + 0 < $5 + 0) partial=1
    seen=1
  }
  END {exit (seen && !bad && partial) ? 0 : 1}
' "${SOURCE_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.offsets.txt"; then
  echo "Expected ${PHASE6_PARTIAL_GROUP} to be partial before snapshot." >&2
  exit 1
fi

echo "Phase 6 source seeding complete."
