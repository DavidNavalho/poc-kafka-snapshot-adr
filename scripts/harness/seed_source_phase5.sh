#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase5_topics.sh
source "${SCRIPT_DIR}/phase5_topics.sh"

SOURCE_PHASE5_DIR="${ROOT_DIR}/artifacts/latest/source/phase5"
SOURCE_TOPICS_DIR="${SOURCE_PHASE5_DIR}/topics"
SOURCE_GROUPS_DIR="${SOURCE_PHASE5_DIR}/groups"
SOURCE_TXN_DIR="${SOURCE_PHASE5_DIR}/transactions"
mkdir -p "${SOURCE_TOPICS_DIR}" "${SOURCE_GROUPS_DIR}" "${SOURCE_TXN_DIR}"

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
    "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --from-beginning --isolation-level ${isolation} --timeout-ms 5000 --property print.value=true 2>/dev/null" \
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
  local log_file="$4"

  set +e
  compose_cmd exec -T source-broker-1 bash -lc \
    "timeout --signal=KILL ${run_seconds}s kafka-producer-perf-test --topic ${topic} --num-records ${PHASE5_ABORT_HANG_MAX_RECORDS} --throughput ${PHASE5_ABORT_HANG_THROUGHPUT} --payload-monotonic --transactional-id ${txid} --transaction-duration-ms ${PHASE5_LONG_TX_DURATION_MS} --producer-props bootstrap.servers=${SOURCE_BOOTSTRAP} acks=all linger.ms=0 >/tmp/${txid}.log 2>&1"
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

for spec in "${PHASE5_TOPIC_SPECS[@]}"; do
  IFS="|" read -r topic partitions <<< "${spec}"
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
done

run_committed_perf "${PHASE5_FULL_TOPIC}" "${PHASE5_TXID_FULL}" "${PHASE5_FULL_COMMITTED_RECORDS}"
run_committed_perf "${PHASE5_PARTIAL_TOPIC}" "${PHASE5_TXID_PARTIAL}" "${PHASE5_PARTIAL_COMMITTED_RECORDS}"

run_timeout_perf "${PHASE5_ABORTED_TOPIC}" "${PHASE5_TXID_ABORTED}" "${PHASE5_ABORT_RUN_SECONDS}" \
  "${SOURCE_TXN_DIR}/${PHASE5_TXID_ABORTED}.perf.log"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-transactions --bootstrap-server ${SOURCE_BOOTSTRAP} force-terminate --transactional-id ${PHASE5_TXID_ABORTED}"

run_timeout_perf "${PHASE5_HANGING_TOPIC}" "${PHASE5_TXID_HANGING}" "${PHASE5_HANG_RUN_SECONDS}" \
  "${SOURCE_TXN_DIR}/${PHASE5_TXID_HANGING}.perf.log"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-transactions --bootstrap-server ${SOURCE_BOOTSTRAP} list" \
  > "${SOURCE_TXN_DIR}/transactions.list.txt"

for txid in "${PHASE5_TXID_FULL}" "${PHASE5_TXID_PARTIAL}" "${PHASE5_TXID_ABORTED}" "${PHASE5_TXID_HANGING}"; do
  if ! grep -q "${txid}" "${SOURCE_TXN_DIR}/transactions.list.txt"; then
    echo "Expected transactional id ${txid} not found in transactions list." >&2
    exit 1
  fi

  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-transactions --bootstrap-server ${SOURCE_BOOTSTRAP} describe --transactional-id ${txid}" \
    > "${SOURCE_TXN_DIR}/${txid}.describe.txt"
done

for topic in "${PHASE5_FULL_TOPIC}" "${PHASE5_PARTIAL_TOPIC}" "${PHASE5_ABORTED_TOPIC}" "${PHASE5_HANGING_TOPIC}"; do
  topic_dir="${SOURCE_TOPICS_DIR}/${topic}"
  mkdir -p "${topic_dir}"
  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --topic ${topic}" \
    > "${topic_dir}/topic_describe.txt"
  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --time -1" \
    | sort > "${topic_dir}/end_offsets.txt"
done

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE5_FULL_TOPIC} --from-beginning --isolation-level read_committed --max-messages ${PHASE5_FULL_COMMITTED_RECORDS} --property print.value=true" \
  > "${SOURCE_TOPICS_DIR}/${PHASE5_FULL_TOPIC}/read_committed.txt"
LC_ALL=C sort "${SOURCE_TOPICS_DIR}/${PHASE5_FULL_TOPIC}/read_committed.txt" > "${SOURCE_TOPICS_DIR}/${PHASE5_FULL_TOPIC}/read_committed.sorted.txt"
hash_file "${SOURCE_TOPICS_DIR}/${PHASE5_FULL_TOPIC}/read_committed.sorted.txt" > "${SOURCE_TOPICS_DIR}/${PHASE5_FULL_TOPIC}/read_committed.sorted.sha256"
echo "${PHASE5_FULL_COMMITTED_RECORDS}" > "${SOURCE_TOPICS_DIR}/${PHASE5_FULL_TOPIC}/read_committed.count"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE5_PARTIAL_TOPIC} --from-beginning --isolation-level read_committed --max-messages ${PHASE5_PARTIAL_COMMITTED_RECORDS} --property print.value=true" \
  > "${SOURCE_TOPICS_DIR}/${PHASE5_PARTIAL_TOPIC}/read_committed.txt"
LC_ALL=C sort "${SOURCE_TOPICS_DIR}/${PHASE5_PARTIAL_TOPIC}/read_committed.txt" > "${SOURCE_TOPICS_DIR}/${PHASE5_PARTIAL_TOPIC}/read_committed.sorted.txt"
hash_file "${SOURCE_TOPICS_DIR}/${PHASE5_PARTIAL_TOPIC}/read_committed.sorted.txt" > "${SOURCE_TOPICS_DIR}/${PHASE5_PARTIAL_TOPIC}/read_committed.sorted.sha256"
echo "${PHASE5_PARTIAL_COMMITTED_RECORDS}" > "${SOURCE_TOPICS_DIR}/${PHASE5_PARTIAL_TOPIC}/read_committed.count"

for topic in "${PHASE5_ABORTED_TOPIC}" "${PHASE5_HANGING_TOPIC}"; do
  topic_dir="${SOURCE_TOPICS_DIR}/${topic}"
  consume_with_timeout "${topic}" "read_uncommitted" "${topic_dir}/read_uncommitted.txt"
  consume_with_timeout "${topic}" "read_committed" "${topic_dir}/read_committed.txt"

  LC_ALL=C sort "${topic_dir}/read_uncommitted.txt" > "${topic_dir}/read_uncommitted.sorted.txt"
  LC_ALL=C sort "${topic_dir}/read_committed.txt" > "${topic_dir}/read_committed.sorted.txt"
  hash_file "${topic_dir}/read_uncommitted.sorted.txt" > "${topic_dir}/read_uncommitted.sorted.sha256"
  hash_file "${topic_dir}/read_committed.sorted.txt" > "${topic_dir}/read_committed.sorted.sha256"
  wc -l < "${topic_dir}/read_uncommitted.txt" | tr -d ' ' > "${topic_dir}/read_uncommitted.count"
  wc -l < "${topic_dir}/read_committed.txt" | tr -d ' ' > "${topic_dir}/read_committed.count"
done

aborted_uncommitted_count="$(cat "${SOURCE_TOPICS_DIR}/${PHASE5_ABORTED_TOPIC}/read_uncommitted.count")"
aborted_committed_count="$(cat "${SOURCE_TOPICS_DIR}/${PHASE5_ABORTED_TOPIC}/read_committed.count")"
hanging_uncommitted_count="$(cat "${SOURCE_TOPICS_DIR}/${PHASE5_HANGING_TOPIC}/read_uncommitted.count")"
hanging_committed_count="$(cat "${SOURCE_TOPICS_DIR}/${PHASE5_HANGING_TOPIC}/read_committed.count")"

if [[ "${aborted_uncommitted_count}" -le 0 ]]; then
  echo "Expected aborted transactional topic to have read_uncommitted records." >&2
  exit 1
fi
if [[ "${aborted_committed_count}" -ne 0 ]]; then
  echo "Expected aborted transactional topic to have no read_committed records." >&2
  exit 1
fi
if [[ "${hanging_uncommitted_count}" -le 0 ]]; then
  echo "Expected hanging transactional topic to have read_uncommitted records." >&2
  exit 1
fi
if [[ "${hanging_committed_count}" -ne 0 ]]; then
  echo "Expected hanging transactional topic to have no read_committed records." >&2
  exit 1
fi

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE5_FULL_TOPIC} --group ${PHASE5_FULL_GROUP} --from-beginning --isolation-level read_committed --max-messages ${PHASE5_FULL_COMMITTED_RECORDS} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE5_PARTIAL_TOPIC} --group ${PHASE5_PARTIAL_GROUP} --from-beginning --isolation-level read_committed --max-messages ${PHASE5_PARTIAL_INITIAL_MESSAGES} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2

capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE5_FULL_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE5_FULL_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE5_FULL_GROUP}.offsets.txt"
capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE5_PARTIAL_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.offsets.txt"

if ! awk -F'|' -v topic="${PHASE5_FULL_TOPIC}" '$2 == topic {if ($4 != $5) bad=1; seen=1} END {exit (seen && !bad) ? 0 : 1}' \
  "${SOURCE_GROUPS_DIR}/${PHASE5_FULL_GROUP}.offsets.txt"; then
  echo "Expected ${PHASE5_FULL_GROUP} to be fully caught up on ${PHASE5_FULL_TOPIC} before snapshot." >&2
  exit 1
fi

if ! awk -F'|' -v topic="${PHASE5_PARTIAL_TOPIC}" '
  $2 == topic {
    if ($4 + 0 > $5 + 0) bad=1
    if ($4 + 0 < $5 + 0) partial=1
    seen=1
  }
  END {exit (seen && !bad && partial) ? 0 : 1}
' "${SOURCE_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.offsets.txt"; then
  echo "Expected ${PHASE5_PARTIAL_GROUP} to be partially consumed on ${PHASE5_PARTIAL_TOPIC} before snapshot." >&2
  exit 1
fi

echo "Phase 5 source seeding complete."
