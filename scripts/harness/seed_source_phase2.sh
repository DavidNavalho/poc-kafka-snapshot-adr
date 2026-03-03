#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase2_topics.sh
source "${SCRIPT_DIR}/phase2_topics.sh"

SOURCE_PHASE2_DIR="${ROOT_DIR}/artifacts/latest/source/phase2"
mkdir -p "${SOURCE_PHASE2_DIR}"

wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90

grep '^cluster.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt"
grep '^node.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/node_id.txt"

for spec in "${PHASE2_TOPIC_SPECS[@]}"; do
  IFS="|" read -r topic cleanup partitions message_count key_mode <<< "${spec}"
  topic_dir="${SOURCE_PHASE2_DIR}/${topic}"
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

  if [[ "${key_mode}" == "state" ]]; then
    seq 1 "${message_count}" \
      | awk '{printf "customer-%03d:{\"event\":\"state\",\"seq\":%d,\"tier\":\"t%d\",\"active\":%s}\n", ($1 % 120), $1, ($1 % 5), (($1 % 2) ? "true" : "false")}' \
      | compose_cmd exec -T source-broker-1 bash -lc \
        "kafka-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --property parse.key=true --property key.separator=: >/dev/null"
  else
    seq 1 "${message_count}" \
      | awk -v topic="${topic}" '{printf "acct-%05d:{\"event\":\"seed\",\"topic\":\"%s\",\"id\":%d,\"amount\":%d}\n", $1, topic, $1, (($1 % 17) + 1)}' \
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
  topic_hash="$(hash_file "${topic_dir}/topic_dump.sorted.txt")"
  echo "${topic_hash}" > "${topic_dir}/topic_dump.sorted.sha256"

  topic_count="$(wc -l < "${topic_dir}/topic_dump.txt" | tr -d ' ')"
  echo "${topic_count}" > "${topic_dir}/topic_dump.count"
  printf 'topic=%s\ncleanup=%s\npartitions=%s\nseed_messages=%s\nkey_mode=%s\n' \
    "${topic}" "${cleanup}" "${partitions}" "${message_count}" "${key_mode}" > "${topic_dir}/spec.txt"

  if [[ "${topic_count}" -ne "${message_count}" ]]; then
    echo "Expected ${message_count} records, consumed ${topic_count} records from ${topic}." >&2
    exit 1
  fi
done

echo "Phase 2 source seeding complete."
