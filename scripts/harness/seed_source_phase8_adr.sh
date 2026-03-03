#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase8_adr_scenarios.sh
source "${SCRIPT_DIR}/phase8_adr_scenarios.sh"

SOURCE_PHASE8_DIR="${ROOT_DIR}/artifacts/latest/source/phase8_adr"
SOURCE_TOPICS_DIR="${SOURCE_PHASE8_DIR}/topics"
SOURCE_GROUPS_DIR="${SOURCE_PHASE8_DIR}/groups"
SOURCE_RUNTIME_DIR="${SOURCE_PHASE8_DIR}/runtime"
SOURCE_HEALTH_DIR="${SOURCE_PHASE8_DIR}/health"
SOURCE_TXN_DIR="${SOURCE_PHASE8_DIR}/transactions"
SOURCE_RUNTIME_ENV="${SOURCE_RUNTIME_DIR}/phase8_runtime.env"
mkdir -p "${SOURCE_TOPICS_DIR}" "${SOURCE_GROUPS_DIR}" "${SOURCE_RUNTIME_DIR}" "${SOURCE_HEALTH_DIR}" "${SOURCE_TXN_DIR}"

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

sum_end_offsets_file() {
  local file="$1"
  awk -F: 'NF >= 3 && $3 ~ /^[0-9]+$/ {sum += $3} END {print sum + 0}' "${file}"
}

sum_group_topic_offsets() {
  local file="$1"
  local topic="$2"
  awk -F'|' -v topic="${topic}" '$2 == topic && $4 ~ /^[0-9]+$/ {sum += $4} END {print sum + 0}' "${file}"
}

count_lines() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo 0
    return 0
  fi
  wc -l < "${file}" | tr -d ' '
}

consume_with_timeout() {
  local topic="$1"
  local isolation="$2"
  local out_file="$3"

  set +e
  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --from-beginning --isolation-level ${isolation} --timeout-ms 8000 --property print.value=true 2>/dev/null" \
    > "${out_file}"
  set -e
}

find_partition_leader() {
  local describe_file="$1"
  local partition="$2"
  awk -v partition="${partition}" '
    $0 ~ ("Partition:[[:space:]]*" partition) {
      for (i = 1; i <= NF; i++) {
        if ($i == "Leader:") {
          print $(i + 1)
          exit
        }
      }
    }
  ' "${describe_file}"
}

wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90

grep '^cluster.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt"
grep '^node.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/node_id.txt"

for spec in \
  "${PHASE8_ADR_TOPIC_BASE}|${PHASE8_ADR_BASE_PARTITIONS}|${PHASE8_ADR_BASE_MESSAGES}" \
  "${PHASE8_ADR_TOPIC_T3}|${PHASE8_ADR_T3_PARTITIONS}|${PHASE8_ADR_T3_MESSAGES}" \
  "${PHASE8_ADR_TOPIC_T4}|${PHASE8_ADR_T4_PARTITIONS}|${PHASE8_ADR_T4_MESSAGES}" \
  "${PHASE8_ADR_TOPIC_T5}|${PHASE8_ADR_T5_PARTITIONS}|0" \
  "${PHASE8_ADR_TOPIC_T6}|${PHASE8_ADR_T6_PARTITIONS}|0"; do
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

  create_topic_cmd="kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --create --if-not-exists --topic ${topic} --partitions ${partitions} --replication-factor 3"
  if [[ "${topic}" == "${PHASE8_ADR_TOPIC_T6}" ]]; then
    create_topic_cmd="${create_topic_cmd} --config segment.bytes=1048576"
  fi
  compose_cmd exec -T source-broker-1 bash -lc "${create_topic_cmd}"

  if [[ "${message_count}" -gt 0 ]]; then
    seq 1 "${message_count}" \
      | awk -v topic="${topic}" '{printf "%s-%06d:{\"event\":\"phase8-seed\",\"topic\":\"%s\",\"seq\":%d,\"value\":%d}\n", topic, $1, topic, $1, (($1 % 71) + 1)}' \
      | compose_cmd exec -T source-broker-1 bash -lc \
        "kafka-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${topic} --property parse.key=true --property key.separator=: >/dev/null"
  fi
done

# T5 wave-2 input: committed transactional records plus one deliberately unfinished long transaction.
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-producer-perf-test --topic ${PHASE8_ADR_TOPIC_T5} --num-records ${PHASE8_ADR_T5_COMMITTED_MESSAGES} --throughput -1 --payload-monotonic --transactional-id ${PHASE8_ADR_T5_TXID} --transaction-duration-ms 1200 --producer-props bootstrap.servers=${SOURCE_BOOTSTRAP} acks=all linger.ms=0"

set +e
compose_cmd exec -T source-broker-1 bash -lc \
  "timeout --signal=KILL ${PHASE8_ADR_T5_HANG_RUN_SECONDS}s kafka-producer-perf-test --topic ${PHASE8_ADR_TOPIC_T5} --num-records ${PHASE8_ADR_T5_HANG_MAX_RECORDS} --throughput ${PHASE8_ADR_T5_HANG_THROUGHPUT} --payload-monotonic --transactional-id ${PHASE8_ADR_T5_TXID} --transaction-duration-ms ${PHASE8_ADR_T5_LONG_TX_DURATION_MS} --producer-props bootstrap.servers=${SOURCE_BOOTSTRAP} acks=all linger.ms=0 >/tmp/phase8-adr-t5-hanging.log 2>&1"
t5_hanging_rc=$?
set -e
if [[ "${t5_hanging_rc}" -ne 0 && "${t5_hanging_rc}" -ne 124 && "${t5_hanging_rc}" -ne 137 ]]; then
  echo "Unexpected exit code ${t5_hanging_rc} while generating phase8 ADR T5 hanging transaction." >&2
  compose_cmd exec -T source-broker-1 bash -lc "cat /tmp/phase8-adr-t5-hanging.log || true" >&2
  exit 1
fi
compose_cmd exec -T source-broker-1 bash -lc "cat /tmp/phase8-adr-t5-hanging.log || true" > "${SOURCE_TXN_DIR}/t5_hanging.perf.log"

t5_txn_list_ok="no"
for attempt in $(seq 1 6); do
  set +e
  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-transactions --bootstrap-server ${SOURCE_BOOTSTRAP} list" \
    > "${SOURCE_TXN_DIR}/transactions.list.txt" 2>&1
  t5_txn_list_rc=$?
  set -e
  if [[ "${t5_txn_list_rc}" -eq 0 ]]; then
    t5_txn_list_ok="yes"
    break
  fi
  sleep 3
done
if [[ "${t5_txn_list_ok}" != "yes" ]]; then
  echo "Failed to list transactions after retries for T5 seed." >&2
  cat "${SOURCE_TXN_DIR}/transactions.list.txt" >&2 || true
  exit 1
fi

t5_txn_describe_ok="no"
for attempt in $(seq 1 6); do
  set +e
  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-transactions --bootstrap-server ${SOURCE_BOOTSTRAP} describe --transactional-id ${PHASE8_ADR_T5_TXID}" \
    > "${SOURCE_TXN_DIR}/${PHASE8_ADR_T5_TXID}.describe.txt" 2>&1
  t5_txn_describe_rc=$?
  set -e
  if [[ "${t5_txn_describe_rc}" -eq 0 ]]; then
    t5_txn_describe_ok="yes"
    break
  fi
  sleep 3
done
if [[ "${t5_txn_describe_ok}" != "yes" ]]; then
  echo "Failed to describe transactional id ${PHASE8_ADR_T5_TXID} after retries." >&2
  cat "${SOURCE_TXN_DIR}/${PHASE8_ADR_T5_TXID}.describe.txt" >&2 || true
  exit 1
fi

consume_with_timeout "${PHASE8_ADR_TOPIC_T5}" "read_uncommitted" "${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T5}/read_uncommitted.txt"
consume_with_timeout "${PHASE8_ADR_TOPIC_T5}" "read_committed" "${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T5}/read_committed.txt"
t5_uncommitted_count="$(count_lines "${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T5}/read_uncommitted.txt")"
t5_committed_count="$(count_lines "${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T5}/read_committed.txt")"
if [[ "${t5_uncommitted_count}" -le 0 ]]; then
  echo "Expected T5 source topic to have transactional records visible in read_uncommitted mode." >&2
  exit 1
fi

# T6 wave-2 input: idempotent writes before producer-state mutation.
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-producer-perf-test --topic ${PHASE8_ADR_TOPIC_T6} --num-records ${PHASE8_ADR_T6_MESSAGES} --record-size ${PHASE8_ADR_T6_RECORD_SIZE} --throughput -1 --producer-props bootstrap.servers=${SOURCE_BOOTSTRAP} acks=all enable.idempotence=true max.in.flight.requests.per.connection=1 linger.ms=0"

for topic in "${PHASE8_ADR_TOPIC_BASE}" "${PHASE8_ADR_TOPIC_T3}" "${PHASE8_ADR_TOPIC_T4}" "${PHASE8_ADR_TOPIC_T5}" "${PHASE8_ADR_TOPIC_T6}"; do
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
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE8_ADR_TOPIC_BASE} --group ${PHASE8_ADR_T8_GROUP} --from-beginning --max-messages ${PHASE8_ADR_T8_GROUP_MESSAGES} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2

capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE8_ADR_T8_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE8_ADR_T8_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE8_ADR_T8_GROUP}.offsets.txt"

# T10 wave-2 input: distinct consumer group on the base topic with committed offsets.
# This group is separate from T8 so T10 can isolate the offset-reprocessing window assertion.
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE8_ADR_TOPIC_BASE} --group ${PHASE8_ADR_T10_GROUP} --from-beginning --max-messages ${PHASE8_ADR_T10_GROUP_MESSAGES} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=500 >/dev/null"
sleep 2

capture_group_offsets "${SOURCE_BOOTSTRAP}" "${PHASE8_ADR_T10_GROUP}" \
  "${SOURCE_GROUPS_DIR}/${PHASE8_ADR_T10_GROUP}.describe.raw.txt" \
  "${SOURCE_GROUPS_DIR}/${PHASE8_ADR_T10_GROUP}.offsets.txt"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-metadata-quorum --bootstrap-server ${SOURCE_BOOTSTRAP} describe --status" \
  > "${SOURCE_HEALTH_DIR}/metadata_quorum_status.txt"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe" \
  > "${SOURCE_HEALTH_DIR}/topics_describe_all.txt"

t3_describe_file="${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T3}/topic_describe.txt"
t3_leader_broker="$(find_partition_leader "${t3_describe_file}" 0)"
if [[ -z "${t3_leader_broker}" ]]; then
  echo "Unable to determine leader broker for ${PHASE8_ADR_TOPIC_T3} partition 0." >&2
  exit 1
fi

t4_describe_file="${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T4}/topic_describe.txt"
t4_leader_broker="$(find_partition_leader "${t4_describe_file}" 0)"
if [[ -z "${t4_leader_broker}" ]]; then
  echo "Unable to determine leader broker for ${PHASE8_ADR_TOPIC_T4} partition 0." >&2
  exit 1
fi

t6_describe_file="${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T6}/topic_describe.txt"
t6_leader_broker="$(find_partition_leader "${t6_describe_file}" 0)"
if [[ -z "${t6_leader_broker}" ]]; then
  echo "Unable to determine leader broker for ${PHASE8_ADR_TOPIC_T6} partition 0." >&2
  exit 1
fi

source_base_end_sum="$(sum_end_offsets_file "${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_BASE}/end_offsets.txt")"
source_t3_end_offset="$(awk -F: '$2 == "0" && $3 ~ /^[0-9]+$/ {print $3; exit}' "${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T3}/end_offsets.txt")"
if [[ -z "${source_t3_end_offset}" ]]; then
  echo "Unable to determine source end offset for ${PHASE8_ADR_TOPIC_T3} partition 0." >&2
  exit 1
fi
source_t4_end_offset="$(awk -F: '$2 == "0" && $3 ~ /^[0-9]+$/ {print $3; exit}' "${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T4}/end_offsets.txt")"
if [[ -z "${source_t4_end_offset}" ]]; then
  echo "Unable to determine source end offset for ${PHASE8_ADR_TOPIC_T4} partition 0." >&2
  exit 1
fi
source_t6_end_offset="$(awk -F: '$2 == "0" && $3 ~ /^[0-9]+$/ {print $3; exit}' "${SOURCE_TOPICS_DIR}/${PHASE8_ADR_TOPIC_T6}/end_offsets.txt")"
if [[ -z "${source_t6_end_offset}" ]]; then
  echo "Unable to determine source end offset for ${PHASE8_ADR_TOPIC_T6} partition 0." >&2
  exit 1
fi
source_t8_committed_sum="$(sum_group_topic_offsets "${SOURCE_GROUPS_DIR}/${PHASE8_ADR_T8_GROUP}.offsets.txt" "${PHASE8_ADR_TOPIC_BASE}")"
source_t10_committed_sum="$(sum_group_topic_offsets "${SOURCE_GROUPS_DIR}/${PHASE8_ADR_T10_GROUP}.offsets.txt" "${PHASE8_ADR_TOPIC_BASE}")"

cat > "${SOURCE_RUNTIME_ENV}" <<EOF
source_base_topic=${PHASE8_ADR_TOPIC_BASE}
source_t3_topic=${PHASE8_ADR_TOPIC_T3}
source_t3_partition=0
source_t3_leader_broker=${t3_leader_broker}
source_base_end_sum=${source_base_end_sum}
source_t3_end_offset=${source_t3_end_offset}
source_t4_topic=${PHASE8_ADR_TOPIC_T4}
source_t4_partition=0
source_t4_leader_broker=${t4_leader_broker}
source_t4_end_offset=${source_t4_end_offset}
source_t8_group=${PHASE8_ADR_T8_GROUP}
source_t8_committed_sum=${source_t8_committed_sum}
source_t5_topic=${PHASE8_ADR_TOPIC_T5}
source_t5_txid=${PHASE8_ADR_T5_TXID}
source_t5_read_uncommitted_count=${t5_uncommitted_count}
source_t5_read_committed_count=${t5_committed_count}
source_t6_topic=${PHASE8_ADR_TOPIC_T6}
source_t6_partition=0
source_t6_leader_broker=${t6_leader_broker}
source_t6_end_offset=${source_t6_end_offset}
source_t6_txid=${PHASE8_ADR_T6_TXID}
source_t10_group=${PHASE8_ADR_T10_GROUP}
source_t10_committed_sum=${source_t10_committed_sum}
EOF

echo "Phase 8 ADR source seeding complete."
