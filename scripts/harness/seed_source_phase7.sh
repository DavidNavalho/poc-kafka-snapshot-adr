#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase7_scenarios.sh
source "${SCRIPT_DIR}/phase7_scenarios.sh"

SOURCE_PHASE7_DIR="${ROOT_DIR}/artifacts/latest/source/phase7"
SOURCE_TOPICS_DIR="${SOURCE_PHASE7_DIR}/topics"
SOURCE_GROUPS_DIR="${SOURCE_PHASE7_DIR}/groups"
SOURCE_TXN_DIR="${SOURCE_PHASE7_DIR}/transactions"
SOURCE_HEALTH_DIR="${SOURCE_PHASE7_DIR}/health"
mkdir -p "${SOURCE_TOPICS_DIR}" "${SOURCE_GROUPS_DIR}" "${SOURCE_TXN_DIR}" "${SOURCE_HEALTH_DIR}"

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

consume_with_timeout() {
  local topic="$1"
  local isolation="$2"
  local out_file="$3"

  set +e
  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --from-beginning --isolation-level ${isolation} --timeout-ms 5000 --property print.key=true --property key.separator=: 2>/dev/null" \
    > "${out_file}"
  set -e
}

run_committed_perf() {
  local topic="$1"
  local txid="$2"
  local num_records="$3"

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-producer-perf-test --topic ${topic} --num-records ${num_records} --throughput -1 --payload-monotonic --transactional-id ${txid} --transaction-duration-ms 1500 --producer-props bootstrap.servers=${SOURCE_BOOTSTRAP} acks=all linger.ms=0"
}

run_timeout_perf() {
  local topic="$1"
  local txid="$2"
  local run_seconds="$3"
  local duration_ms="$4"
  local log_file="$5"

  set +e
  compose_cmd exec -T source-broker-1 bash -lc \
    "timeout --signal=KILL ${run_seconds}s kafka-producer-perf-test --topic ${topic} --num-records ${PHASE7_BG_NUM_RECORDS} --throughput ${PHASE7_BG_THROUGHPUT} --payload-monotonic --transactional-id ${txid} --transaction-duration-ms ${duration_ms} --producer-props bootstrap.servers=${SOURCE_BOOTSTRAP} acks=all linger.ms=0 >/tmp/${txid}.log 2>&1"
  rc=$?
  set -e

  if [[ "${rc}" -ne 124 && "${rc}" -ne 137 ]]; then
    echo "Unexpected exit code ${rc} while generating timeout transaction for ${txid}." >&2
    compose_cmd exec -T source-broker-1 bash -lc "cat /tmp/${txid}.log || true" >&2
    exit 1
  fi

  compose_cmd exec -T source-broker-1 bash -lc "cat /tmp/${txid}.log || true" > "${log_file}"
}

wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90

grep '^cluster.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt"
grep '^node.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/node_id.txt"

for spec in "${PHASE7_TOPICS[@]}"; do
  IFS="|" read -r topic partitions message_count kind <<< "${spec}"
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
  if [[ "${kind}" == "compact" ]]; then
    create_cmd="${create_cmd} --config cleanup.policy=compact"
  fi
  compose_cmd exec -T source-broker-1 bash -lc "${create_cmd}"

  if [[ "${kind}" == "delete" ]]; then
    seq 1 "${message_count}" \
      | awk -v topic="${topic}" '{printf "entity-%06d:{\"event\":\"seed\",\"topic\":\"%s\",\"id\":%d,\"amount\":%d}\n", $1, topic, $1, (($1 % 41) + 1)}' \
      | compose_cmd exec -T source-broker-1 bash -lc \
        "kafka-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --property parse.key=true --property key.separator=: >/dev/null"
  elif [[ "${kind}" == "compact" ]]; then
    seq 1 "${message_count}" \
      | awk -v topic="${topic}" '{printf "acct-%03d:{\"event\":\"state\",\"topic\":\"%s\",\"seq\":%d,\"status\":\"s%d\"}\n", ($1 % 180), topic, $1, ($1 % 9)}' \
      | compose_cmd exec -T source-broker-1 bash -lc \
        "kafka-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --property parse.key=true --property key.separator=: >/dev/null"
  fi

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --topic ${topic}" \
    > "${topic_dir}/topic_describe.txt"
  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --time -1" \
    | sort > "${topic_dir}/end_offsets.txt"
done

run_committed_perf "${PHASE7_TXN_TOPIC}" "${PHASE7_TXID_COMMITTED}" "${PHASE7_TXN_COMMITTED_RECORDS}"
run_timeout_perf "${PHASE7_TXN_TOPIC}" "${PHASE7_TXID_ABORTED}" "${PHASE7_TXN_ABORT_RUN_SECONDS}" \
  "${PHASE7_TXN_ABORT_DURATION_MS}" "${SOURCE_TXN_DIR}/${PHASE7_TXID_ABORTED}.perf.log"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-transactions --bootstrap-server ${SOURCE_BOOTSTRAP} force-terminate --transactional-id ${PHASE7_TXID_ABORTED}"
run_timeout_perf "${PHASE7_TXN_TOPIC}" "${PHASE7_TXID_HANGING}" "${PHASE7_TXN_HANG_RUN_SECONDS}" \
  "${PHASE7_TXN_HANG_DURATION_MS}" "${SOURCE_TXN_DIR}/${PHASE7_TXID_HANGING}.perf.log"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-transactions --bootstrap-server ${SOURCE_BOOTSTRAP} list" \
  > "${SOURCE_TXN_DIR}/transactions.list.txt"
for txid in "${PHASE7_TXID_COMMITTED}" "${PHASE7_TXID_ABORTED}" "${PHASE7_TXID_HANGING}"; do
  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-transactions --bootstrap-server ${SOURCE_BOOTSTRAP} describe --transactional-id ${txid}" \
    > "${SOURCE_TXN_DIR}/${txid}.describe.txt"
done

for spec in "${PHASE7_TOPICS[@]}"; do
  IFS="|" read -r topic _ message_count kind <<< "${spec}"
  topic_dir="${SOURCE_TOPICS_DIR}/${topic}"

  if [[ "${kind}" == "transactional" ]]; then
    consume_with_timeout "${topic}" "read_committed" "${topic_dir}/read_committed.txt"
    consume_with_timeout "${topic}" "read_uncommitted" "${topic_dir}/read_uncommitted.txt"
    LC_ALL=C sort "${topic_dir}/read_committed.txt" > "${topic_dir}/read_committed.sorted.txt"
    LC_ALL=C sort "${topic_dir}/read_uncommitted.txt" > "${topic_dir}/read_uncommitted.sorted.txt"
    hash_file "${topic_dir}/read_committed.sorted.txt" > "${topic_dir}/read_committed.sorted.sha256"
    hash_file "${topic_dir}/read_uncommitted.sorted.txt" > "${topic_dir}/read_uncommitted.sorted.sha256"
    wc -l < "${topic_dir}/read_committed.txt" | tr -d ' ' > "${topic_dir}/read_committed.count"
    wc -l < "${topic_dir}/read_uncommitted.txt" | tr -d ' ' > "${topic_dir}/read_uncommitted.count"
  else
    compose_cmd exec -T source-broker-1 bash -lc \
      "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${message_count} --property print.key=true --property key.separator=:" \
      > "${topic_dir}/topic_dump.txt"
    LC_ALL=C sort "${topic_dir}/topic_dump.txt" > "${topic_dir}/topic_dump.sorted.txt"
    hash_file "${topic_dir}/topic_dump.sorted.txt" > "${topic_dir}/topic_dump.sorted.sha256"
    wc -l < "${topic_dir}/topic_dump.txt" | tr -d ' ' > "${topic_dir}/topic_dump.count"
  fi
done

groups_topic_count="$(cat "${SOURCE_TOPICS_DIR}/${PHASE7_GROUPS_TOPIC}/topic_dump.count")"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE7_GROUPS_TOPIC} --group ${PHASE7_FULL_GROUP} --from-beginning --max-messages ${groups_topic_count} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE7_NORMAL_TOPIC} --group ${PHASE7_PARTIAL_GROUP} --from-beginning --max-messages ${PHASE7_PARTIAL_INITIAL_MESSAGES} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2

capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE7_FULL_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE7_FULL_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE7_FULL_GROUP}.offsets.txt"
capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE7_PARTIAL_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.offsets.txt"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-metadata-quorum --bootstrap-server ${SOURCE_BOOTSTRAP} describe --status" \
  > "${SOURCE_HEALTH_DIR}/metadata_quorum_status.txt"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe" \
  > "${SOURCE_HEALTH_DIR}/topics_describe_all.txt"

if ! awk -F'|' -v topic="${PHASE7_GROUPS_TOPIC}" '$2 == topic {if ($4 != $5) bad=1; seen=1} END {exit (seen && !bad) ? 0 : 1}' \
  "${SOURCE_GROUPS_DIR}/${PHASE7_FULL_GROUP}.offsets.txt"; then
  echo "Expected ${PHASE7_FULL_GROUP} to be fully consumed before snapshot." >&2
  exit 1
fi

if ! awk -F'|' -v topic="${PHASE7_NORMAL_TOPIC}" '
  $2 == topic {
    if ($4 + 0 > $5 + 0) bad=1
    if ($4 + 0 < $5 + 0) partial=1
    seen=1
  }
  END {exit (seen && !bad && partial) ? 0 : 1}
' "${SOURCE_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.offsets.txt"; then
  echo "Expected ${PHASE7_PARTIAL_GROUP} to be partial before snapshot." >&2
  exit 1
fi

echo "Phase 7 source seeding complete."
