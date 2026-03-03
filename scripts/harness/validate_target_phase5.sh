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

TARGET_PHASE5_DIR="${ROOT_DIR}/artifacts/latest/target/phase5"
TARGET_TOPICS_DIR="${TARGET_PHASE5_DIR}/topics"
TARGET_GROUPS_DIR="${TARGET_PHASE5_DIR}/groups"
TARGET_TXN_DIR="${TARGET_PHASE5_DIR}/transactions"
mkdir -p "${TARGET_TOPICS_DIR}" "${TARGET_GROUPS_DIR}" "${TARGET_TXN_DIR}"

capture_group_offsets() {
  local bootstrap="$1"
  local group_id="$2"
  local raw_file="$3"
  local parsed_file="$4"

  compose_cmd exec -T target-broker-1 bash -lc \
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
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --from-beginning --isolation-level ${isolation} --timeout-ms 5000 --property print.value=true 2>/dev/null" \
    > "${out_file}"
  set -e
}

offset_sum_for_topic() {
  local file="$1"
  local topic="$2"

  awk -F'|' -v topic="${topic}" '
    $2 == topic && $4 ~ /^[0-9]+$/ {sum += $4}
    END {print sum + 0}
  ' "${file}"
}

wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 90

source_cluster_id="$(cat "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt")"
target_cluster_id="$(grep '^cluster.id=' "${ROOT_DIR}/data/target/broker1/meta.properties" | cut -d= -f2)"
if [[ "${source_cluster_id}" != "${target_cluster_id}" ]]; then
  echo "Cluster ID mismatch: source=${source_cluster_id} target=${target_cluster_id}" >&2
  exit 1
fi

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-transactions --bootstrap-server ${TARGET_BOOTSTRAP} list" \
  > "${TARGET_TXN_DIR}/transactions.list.txt"

for txid in "${PHASE5_TXID_FULL}" "${PHASE5_TXID_PARTIAL}" "${PHASE5_TXID_ABORTED}" "${PHASE5_TXID_HANGING}"; do
  if ! grep -q "${txid}" "${TARGET_TXN_DIR}/transactions.list.txt"; then
    echo "Expected transactional id ${txid} not found in target transactions list." >&2
    exit 1
  fi
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-transactions --bootstrap-server ${TARGET_BOOTSTRAP} describe --transactional-id ${txid}" \
    > "${TARGET_TXN_DIR}/${txid}.describe.txt"
done

for topic in "${PHASE5_FULL_TOPIC}" "${PHASE5_PARTIAL_TOPIC}" "${PHASE5_ABORTED_TOPIC}" "${PHASE5_HANGING_TOPIC}"; do
  source_topic_dir="${SOURCE_TOPICS_DIR}/${topic}"
  target_topic_dir="${TARGET_TOPICS_DIR}/${topic}"
  mkdir -p "${target_topic_dir}"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe --topic ${topic}" \
    > "${target_topic_dir}/topic_describe.txt"
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --time -1" \
    | sort > "${target_topic_dir}/end_offsets.txt"
done

for topic in "${PHASE5_FULL_TOPIC}" "${PHASE5_PARTIAL_TOPIC}"; do
  source_topic_dir="${SOURCE_TOPICS_DIR}/${topic}"
  target_topic_dir="${TARGET_TOPICS_DIR}/${topic}"
  expected_count="$(cat "${source_topic_dir}/read_committed.count")"

  diff -u "${source_topic_dir}/end_offsets.txt" "${target_topic_dir}/end_offsets.txt"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --from-beginning --isolation-level read_committed --max-messages ${expected_count} --property print.value=true" \
    > "${target_topic_dir}/read_committed.txt"

  LC_ALL=C sort "${target_topic_dir}/read_committed.txt" > "${target_topic_dir}/read_committed.sorted.txt"
  hash_file "${target_topic_dir}/read_committed.sorted.txt" > "${target_topic_dir}/read_committed.sorted.sha256"
  wc -l < "${target_topic_dir}/read_committed.txt" | tr -d ' ' > "${target_topic_dir}/read_committed.count"

  diff -u "${source_topic_dir}/read_committed.sorted.sha256" "${target_topic_dir}/read_committed.sorted.sha256"
  diff -u "${source_topic_dir}/read_committed.count" "${target_topic_dir}/read_committed.count"
done

for topic in "${PHASE5_ABORTED_TOPIC}" "${PHASE5_HANGING_TOPIC}"; do
  source_topic_dir="${SOURCE_TOPICS_DIR}/${topic}"
  target_topic_dir="${TARGET_TOPICS_DIR}/${topic}"

  consume_with_timeout "${topic}" "read_uncommitted" "${target_topic_dir}/read_uncommitted.txt"
  consume_with_timeout "${topic}" "read_committed" "${target_topic_dir}/read_committed.txt"

  LC_ALL=C sort "${target_topic_dir}/read_uncommitted.txt" > "${target_topic_dir}/read_uncommitted.sorted.txt"
  LC_ALL=C sort "${target_topic_dir}/read_committed.txt" > "${target_topic_dir}/read_committed.sorted.txt"
  hash_file "${target_topic_dir}/read_uncommitted.sorted.txt" > "${target_topic_dir}/read_uncommitted.sorted.sha256"
  hash_file "${target_topic_dir}/read_committed.sorted.txt" > "${target_topic_dir}/read_committed.sorted.sha256"
  wc -l < "${target_topic_dir}/read_uncommitted.txt" | tr -d ' ' > "${target_topic_dir}/read_uncommitted.count"
  wc -l < "${target_topic_dir}/read_committed.txt" | tr -d ' ' > "${target_topic_dir}/read_committed.count"

  diff -u "${source_topic_dir}/read_uncommitted.sorted.sha256" "${target_topic_dir}/read_uncommitted.sorted.sha256"
  diff -u "${source_topic_dir}/read_uncommitted.count" "${target_topic_dir}/read_uncommitted.count"
  diff -u "${source_topic_dir}/read_committed.sorted.sha256" "${target_topic_dir}/read_committed.sorted.sha256"
  diff -u "${source_topic_dir}/read_committed.count" "${target_topic_dir}/read_committed.count"
done

capture_group_offsets "${TARGET_BOOTSTRAP}" "${PHASE5_FULL_GROUP}" \
  "${TARGET_GROUPS_DIR}/${PHASE5_FULL_GROUP}.before_resume.raw.txt" \
  "${TARGET_GROUPS_DIR}/${PHASE5_FULL_GROUP}.before_resume.offsets.txt"
capture_group_offsets "${TARGET_BOOTSTRAP}" "${PHASE5_PARTIAL_GROUP}" \
  "${TARGET_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.before_resume.raw.txt" \
  "${TARGET_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.before_resume.offsets.txt"

diff -u "${SOURCE_GROUPS_DIR}/${PHASE5_FULL_GROUP}.offsets.txt" "${TARGET_GROUPS_DIR}/${PHASE5_FULL_GROUP}.before_resume.offsets.txt"
diff -u "${SOURCE_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.offsets.txt" "${TARGET_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.before_resume.offsets.txt"

if ! awk -F'|' -v topic="${PHASE5_FULL_TOPIC}" '$2 == topic {if ($4 != $5) bad=1; seen=1} END {exit (seen && !bad) ? 0 : 1}' \
  "${TARGET_GROUPS_DIR}/${PHASE5_FULL_GROUP}.before_resume.offsets.txt"; then
  echo "Expected ${PHASE5_FULL_GROUP} to remain fully consumed after restore." >&2
  exit 1
fi

if ! awk -F'|' -v topic="${PHASE5_PARTIAL_TOPIC}" '
  $2 == topic {
    if ($4 + 0 > $5 + 0) bad=1
    if ($4 + 0 < $5 + 0) partial=1
    seen=1
  }
  END {exit (seen && !bad && partial) ? 0 : 1}
' "${TARGET_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.before_resume.offsets.txt"; then
  echo "Expected ${PHASE5_PARTIAL_GROUP} to remain partial after restore." >&2
  exit 1
fi

before_partial_sum="$(offset_sum_for_topic "${TARGET_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.before_resume.offsets.txt" "${PHASE5_PARTIAL_TOPIC}")"

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${PHASE5_PARTIAL_TOPIC} --group ${PHASE5_PARTIAL_GROUP} --isolation-level read_committed --max-messages ${PHASE5_PARTIAL_RESUME_MESSAGES} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2

capture_group_offsets "${TARGET_BOOTSTRAP}" "${PHASE5_PARTIAL_GROUP}" \
  "${TARGET_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.after_resume.raw.txt" \
  "${TARGET_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.after_resume.offsets.txt"

after_partial_sum="$(offset_sum_for_topic "${TARGET_GROUPS_DIR}/${PHASE5_PARTIAL_GROUP}.after_resume.offsets.txt" "${PHASE5_PARTIAL_TOPIC}")"
if [[ "${after_partial_sum}" -le "${before_partial_sum}" ]]; then
  echo "Partial transactional group offsets did not advance after resume." >&2
  exit 1
fi

echo "Phase 5 validation succeeded:"
echo "- cluster.id parity: OK"
echo "- transaction IDs/state entries present after restore: OK"
echo "- committed transactional topic parity: OK"
echo "- aborted and hanging transactional visibility parity (read_uncommitted/read_committed): OK"
echo "- consumer-group offset parity and resume behavior: OK"
