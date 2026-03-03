#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase3_topics.sh
source "${SCRIPT_DIR}/phase3_topics.sh"

SOURCE_PHASE3_DIR="${ROOT_DIR}/artifacts/latest/source/phase3"
TARGET_PHASE3_DIR="${ROOT_DIR}/artifacts/latest/target/phase3"
mkdir -p "${TARGET_PHASE3_DIR}"

wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 90
wait_for_schema_registry "${TARGET_SCHEMA_SERVICE}" "${TARGET_SCHEMA_URL}" 90

source_cluster_id="$(cat "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt")"
target_cluster_id="$(grep '^cluster.id=' "${ROOT_DIR}/data/target/broker1/meta.properties" | cut -d= -f2)"
if [[ "${source_cluster_id}" != "${target_cluster_id}" ]]; then
  echo "Cluster ID mismatch: source=${source_cluster_id} target=${target_cluster_id}" >&2
  exit 1
fi

source_schema_dir="${SOURCE_PHASE3_DIR}/schemas"
target_schema_dir="${TARGET_PHASE3_DIR}/schemas"
mkdir -p "${target_schema_dir}"

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe --topic _schemas" \
  > "${target_schema_dir}/_schemas_topic_describe.txt"

if ! grep -q "cleanup.policy=compact" "${target_schema_dir}/_schemas_topic_describe.txt"; then
  echo "_schemas topic on target is not compacted as expected." >&2
  exit 1
fi

compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc \
  "curl -fsS ${TARGET_SCHEMA_URL}/subjects | tr -d '[]\"' | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort" \
  > "${target_schema_dir}/subjects.txt"

diff -u "${source_schema_dir}/subjects.txt" "${target_schema_dir}/subjects.txt"

while IFS= read -r subject; do
  [[ -z "${subject}" ]] && continue
  compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc \
    "curl -fsS ${TARGET_SCHEMA_URL}/subjects/${subject}/versions/latest | tr -d '\n'" \
    > "${target_schema_dir}/${subject}.latest.json" < /dev/null
  diff -u "${source_schema_dir}/${subject}.latest.json" "${target_schema_dir}/${subject}.latest.json"
done < "${target_schema_dir}/subjects.txt"

for spec in "${PHASE3_TOPIC_SPECS[@]}"; do
  IFS="|" read -r topic cleanup _ _ schema_file record_mode key_schema_file <<< "${spec}"
  source_topic_dir="${SOURCE_PHASE3_DIR}/${topic}"
  target_topic_dir="${TARGET_PHASE3_DIR}/${topic}"
  mkdir -p "${target_topic_dir}"

  source_count="$(cat "${source_topic_dir}/topic_dump.count")"
  expected_final_count="$((source_count + PHASE3_POST_RESTORE_PER_TOPIC))"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe --topic ${topic}" \
    > "${target_topic_dir}/topic_describe.txt"

  if [[ "${cleanup}" == "compact" ]]; then
    if ! grep -q "cleanup.policy=compact" "${target_topic_dir}/topic_describe.txt"; then
      echo "Expected compacted topic config for ${topic}, but cleanup.policy=compact not found." >&2
      exit 1
    fi
  fi

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --time -1" \
    | sort > "${target_topic_dir}/end_offsets.txt"
  diff -u "${source_topic_dir}/end_offsets.txt" "${target_topic_dir}/end_offsets.txt"

  if [[ "${record_mode}" == "state" ]]; then
    compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc \
      "kafka-protobuf-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${source_count} --property schema.registry.url=${TARGET_SCHEMA_URL} --property print.key=true --property key.separator='|'" \
      | awk '/^\{/{print}' > "${target_topic_dir}/topic_dump_before_smoke.txt"
  else
    compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc \
      "kafka-protobuf-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${source_count} --property schema.registry.url=${TARGET_SCHEMA_URL}" \
      | awk '/^\{/{print}' > "${target_topic_dir}/topic_dump_before_smoke.txt"
  fi

  LC_ALL=C sort "${target_topic_dir}/topic_dump_before_smoke.txt" > "${target_topic_dir}/topic_dump_before_smoke.sorted.txt"
  target_hash="$(hash_file "${target_topic_dir}/topic_dump_before_smoke.sorted.txt")"
  source_hash="$(cat "${source_topic_dir}/topic_dump.sorted.sha256")"
  echo "${target_hash}" > "${target_topic_dir}/topic_dump_before_smoke.sha256"

  if [[ "${source_hash}" != "${target_hash}" ]]; then
    echo "Payload mismatch for ${topic}: source/target hashes differ." >&2
    exit 1
  fi

  if [[ "${record_mode}" == "state" ]]; then
    seq 1 "${PHASE3_POST_RESTORE_PER_TOPIC}" \
      | awk '{printf "{\"customer_id\":\"customer-%03d\"}|{\"customer_id\":\"customer-%03d\",\"tier\":\"t%d\",\"active\":%s,\"seq\":%d}\n", ($1 % 140), ($1 % 140), ($1 % 5), (($1 % 2) ? "true" : "false"), (900000 + $1)}' \
      | compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc \
        "SCHEMA=\$(tr '\n' ' ' < ${schema_file}); kafka-protobuf-console-producer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --property schema.registry.url=${TARGET_SCHEMA_URL} --property value.schema=\"\${SCHEMA}\" --property key.schema.file=${key_schema_file} --property parse.key=true --property key.separator='|' >/dev/null"
  else
    seq 1 "${PHASE3_POST_RESTORE_PER_TOPIC}" \
      | awk '{printf "{\"order_id\":\"post-%06d\",\"amount\":%d,\"status\":\"%s\",\"event_ts\":%d}\n", $1, (($1 % 9) + 1), (($1 % 2) ? "NEW" : "PAID"), (1800000000 + $1)}' \
      | compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc \
        "SCHEMA=\$(tr '\n' ' ' < ${schema_file}); kafka-protobuf-console-producer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --property schema.registry.url=${TARGET_SCHEMA_URL} --property value.schema=\"\${SCHEMA}\" >/dev/null"
  fi

  group_suffix="$(echo "${topic}" | tr -c '[:alnum:]' '-')"
  group_id="dr.phase3.validation.${group_suffix}"
  compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc \
    "kafka-protobuf-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --group ${group_id} --from-beginning --max-messages 8 --property schema.registry.url=${TARGET_SCHEMA_URL} >/dev/null"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --describe --group ${group_id}" \
    > "${target_topic_dir}/consumer_group_describe.txt"

  if ! grep -q "${topic}" "${target_topic_dir}/consumer_group_describe.txt"; then
    echo "Expected group ${group_id} to have offsets for ${topic}." >&2
    exit 1
  fi

  if [[ "${record_mode}" == "state" ]]; then
    compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc \
      "kafka-protobuf-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${expected_final_count} --property schema.registry.url=${TARGET_SCHEMA_URL} --property print.key=true --property key.separator='|'" \
      | awk '/^\{/{print}' > "${target_topic_dir}/topic_dump_after_smoke.txt"
  else
    compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc \
      "kafka-protobuf-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${expected_final_count} --property schema.registry.url=${TARGET_SCHEMA_URL}" \
      | awk '/^\{/{print}' > "${target_topic_dir}/topic_dump_after_smoke.txt"
  fi

  baseline_count="$(wc -l < "${target_topic_dir}/topic_dump_before_smoke.txt" | tr -d ' ')"
  final_count="$(wc -l < "${target_topic_dir}/topic_dump_after_smoke.txt" | tr -d ' ')"

  if [[ "${baseline_count}" -ne "${source_count}" ]]; then
    echo "Baseline count mismatch for ${topic}: expected ${source_count}, got ${baseline_count}." >&2
    exit 1
  fi
  if [[ "${final_count}" -ne "${expected_final_count}" ]]; then
    echo "Final count mismatch for ${topic}: expected ${expected_final_count}, got ${final_count}." >&2
    exit 1
  fi

  hash_file "${target_topic_dir}/topic_dump_after_smoke.txt" > "${target_topic_dir}/topic_dump_after_smoke.sha256"
done

echo "Phase 3 validation succeeded:"
echo "- cluster.id parity: OK"
echo "- _schemas topic/config parity: OK"
echo "- schema subjects/latest versions parity: OK"
echo "- per-topic protobuf payload parity before smoke: OK"
echo "- per-topic post-restore produce/consume smoke: OK"
