#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase2_topics.sh
source "${SCRIPT_DIR}/phase2_topics.sh"

SOURCE_PHASE2_DIR="${ROOT_DIR}/artifacts/latest/source/phase2"
TARGET_PHASE2_DIR="${ROOT_DIR}/artifacts/latest/target/phase2"
mkdir -p "${TARGET_PHASE2_DIR}"

wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 90

source_cluster_id="$(cat "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt")"
target_cluster_id="$(grep '^cluster.id=' "${ROOT_DIR}/data/target/broker1/meta.properties" | cut -d= -f2)"
if [[ "${source_cluster_id}" != "${target_cluster_id}" ]]; then
  echo "Cluster ID mismatch: source=${source_cluster_id} target=${target_cluster_id}" >&2
  exit 1
fi

for spec in "${PHASE2_TOPIC_SPECS[@]}"; do
  IFS="|" read -r topic cleanup _ _ key_mode <<< "${spec}"
  source_topic_dir="${SOURCE_PHASE2_DIR}/${topic}"
  target_topic_dir="${TARGET_PHASE2_DIR}/${topic}"
  mkdir -p "${target_topic_dir}"

  source_count="$(cat "${source_topic_dir}/topic_dump.count")"
  expected_final_count="$((source_count + PHASE2_POST_RESTORE_PER_TOPIC))"

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

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${source_count} --property print.key=true --property key.separator=:" \
    > "${target_topic_dir}/topic_dump_before_smoke.txt"

  LC_ALL=C sort "${target_topic_dir}/topic_dump_before_smoke.txt" > "${target_topic_dir}/topic_dump_before_smoke.sorted.txt"
  target_hash="$(hash_file "${target_topic_dir}/topic_dump_before_smoke.sorted.txt")"
  source_hash="$(cat "${source_topic_dir}/topic_dump.sorted.sha256")"
  echo "${target_hash}" > "${target_topic_dir}/topic_dump_before_smoke.sha256"

  if [[ "${source_hash}" != "${target_hash}" ]]; then
    echo "Payload mismatch for ${topic}: source/target hashes differ." >&2
    exit 1
  fi

  if [[ "${key_mode}" == "state" ]]; then
    seq 1 "${PHASE2_POST_RESTORE_PER_TOPIC}" \
      | awk -v base=2000000 '{printf "customer-%03d:{\"event\":\"post-restore\",\"seq\":%d,\"tier\":\"t%d\",\"active\":%s}\n", ($1 % 120), (base + $1), ($1 % 5), (($1 % 2) ? "true" : "false")}' \
      | compose_cmd exec -T target-broker-1 bash -lc \
        "kafka-console-producer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --property parse.key=true --property key.separator=: >/dev/null"
  else
    seq 1 "${PHASE2_POST_RESTORE_PER_TOPIC}" \
      | awk -v topic="${topic}" -v base=2000000 '{printf "post-%05d:{\"event\":\"post-restore\",\"topic\":\"%s\",\"id\":%d,\"amount\":%d}\n", $1, topic, (base + $1), (($1 % 11) + 1)}' \
      | compose_cmd exec -T target-broker-1 bash -lc \
        "kafka-console-producer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --property parse.key=true --property key.separator=: >/dev/null"
  fi

  group_suffix="$(echo "${topic}" | tr -c '[:alnum:]' '-')"
  group_id="dr.phase2.validation.${group_suffix}"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --group ${group_id} --from-beginning --max-messages 8 >/dev/null"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --describe --group ${group_id}" \
    > "${target_topic_dir}/consumer_group_describe.txt"

  if ! grep -q "${topic}" "${target_topic_dir}/consumer_group_describe.txt"; then
    echo "Expected group ${group_id} to have offsets for ${topic}." >&2
    exit 1
  fi

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${expected_final_count} --property print.key=true --property key.separator=:" \
    > "${target_topic_dir}/topic_dump_after_smoke.txt"

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

echo "Phase 2 validation succeeded:"
echo "- cluster.id parity: OK"
echo "- per-topic end offsets parity: OK"
echo "- per-topic canonical payload parity before smoke: OK"
echo "- per-topic post-restore produce/consume smoke: OK"
