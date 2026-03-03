#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase3_topics.sh
source "${SCRIPT_DIR}/phase3_topics.sh"

SOURCE_PHASE3_DIR="${ROOT_DIR}/artifacts/latest/source/phase3"
mkdir -p "${SOURCE_PHASE3_DIR}"

wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90
wait_for_schema_registry "${SOURCE_SCHEMA_SERVICE}" "${SOURCE_SCHEMA_URL}" 90

grep '^cluster.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt"
grep '^node.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/node_id.txt"

for spec in "${PHASE3_TOPIC_SPECS[@]}"; do
  IFS="|" read -r topic cleanup partitions message_count schema_file record_mode key_schema_file <<< "${spec}"
  topic_dir="${SOURCE_PHASE3_DIR}/${topic}"
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

  if [[ "${record_mode}" == "state" ]]; then
    seq 1 "${message_count}" \
      | awk '{printf "{\"customer_id\":\"customer-%03d\"}|{\"customer_id\":\"customer-%03d\",\"tier\":\"t%d\",\"active\":%s,\"seq\":%d}\n", ($1 % 140), ($1 % 140), ($1 % 5), (($1 % 2) ? "true" : "false"), $1}' \
      | compose_cmd exec -T "${SOURCE_SCHEMA_SERVICE}" bash -lc \
        "SCHEMA=\$(tr '\n' ' ' < ${schema_file}); kafka-protobuf-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --property schema.registry.url=${SOURCE_SCHEMA_URL} --property value.schema=\"\${SCHEMA}\" --property key.schema.file=${key_schema_file} --property parse.key=true --property key.separator='|' >/dev/null"
  else
    seq 1 "${message_count}" \
      | awk '{printf "{\"order_id\":\"ord-%06d\",\"amount\":%d,\"status\":\"%s\",\"event_ts\":%d}\n", $1, (($1 % 13) + 1), (($1 % 2) ? "NEW" : "PAID"), (1700000000 + $1)}' \
      | compose_cmd exec -T "${SOURCE_SCHEMA_SERVICE}" bash -lc \
        "SCHEMA=\$(tr '\n' ' ' < ${schema_file}); kafka-protobuf-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --property schema.registry.url=${SOURCE_SCHEMA_URL} --property value.schema=\"\${SCHEMA}\" >/dev/null"
  fi

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --topic ${topic}" \
    > "${topic_dir}/topic_describe.txt"

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --time -1" \
    | sort > "${topic_dir}/end_offsets.txt"

  if [[ "${record_mode}" == "state" ]]; then
    compose_cmd exec -T "${SOURCE_SCHEMA_SERVICE}" bash -lc \
      "kafka-protobuf-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${message_count} --property schema.registry.url=${SOURCE_SCHEMA_URL} --property print.key=true --property key.separator='|'" \
      | awk '/^\{/{print}' > "${topic_dir}/topic_dump.txt"
  else
    compose_cmd exec -T "${SOURCE_SCHEMA_SERVICE}" bash -lc \
      "kafka-protobuf-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${message_count} --property schema.registry.url=${SOURCE_SCHEMA_URL}" \
      | awk '/^\{/{print}' > "${topic_dir}/topic_dump.txt"
  fi

  LC_ALL=C sort "${topic_dir}/topic_dump.txt" > "${topic_dir}/topic_dump.sorted.txt"
  topic_hash="$(hash_file "${topic_dir}/topic_dump.sorted.txt")"
  echo "${topic_hash}" > "${topic_dir}/topic_dump.sorted.sha256"

  topic_count="$(wc -l < "${topic_dir}/topic_dump.txt" | tr -d ' ')"
  echo "${topic_count}" > "${topic_dir}/topic_dump.count"
  printf 'topic=%s\ncleanup=%s\npartitions=%s\nseed_messages=%s\nschema_file=%s\nrecord_mode=%s\nkey_schema_file=%s\n' \
    "${topic}" "${cleanup}" "${partitions}" "${message_count}" "${schema_file}" "${record_mode}" "${key_schema_file}" > "${topic_dir}/spec.txt"

  if [[ "${topic_count}" -ne "${message_count}" ]]; then
    echo "Expected ${message_count} records, consumed ${topic_count} records from ${topic}." >&2
    exit 1
  fi
done

schemas_dir="${SOURCE_PHASE3_DIR}/schemas"
mkdir -p "${schemas_dir}"

compose_cmd exec -T "${SOURCE_SCHEMA_SERVICE}" bash -lc \
  "curl -fsS ${SOURCE_SCHEMA_URL}/subjects | tr -d '[]\"' | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort" \
  > "${schemas_dir}/subjects.txt"

while IFS= read -r subject; do
  [[ -z "${subject}" ]] && continue
  compose_cmd exec -T "${SOURCE_SCHEMA_SERVICE}" bash -lc \
    "curl -fsS ${SOURCE_SCHEMA_URL}/subjects/${subject}/versions/latest | tr -d '\n'" \
    > "${schemas_dir}/${subject}.latest.json" < /dev/null
done < "${schemas_dir}/subjects.txt"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --topic _schemas" \
  > "${schemas_dir}/_schemas_topic_describe.txt"

echo "Phase 3 source seeding complete."
