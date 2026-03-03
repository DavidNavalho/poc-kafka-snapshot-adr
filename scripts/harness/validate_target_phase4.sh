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

TARGET_PHASE4_DIR="${ROOT_DIR}/artifacts/latest/target/phase4"
TARGET_TOPICS_DIR="${TARGET_PHASE4_DIR}/topics"
TARGET_GROUPS_DIR="${TARGET_PHASE4_DIR}/groups"
mkdir -p "${TARGET_TOPICS_DIR}" "${TARGET_GROUPS_DIR}"

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

for spec in "${PHASE4_TOPIC_SPECS[@]}"; do
  IFS="|" read -r topic _ _ <<< "${spec}"
  source_topic_dir="${SOURCE_TOPICS_DIR}/${topic}"
  target_topic_dir="${TARGET_TOPICS_DIR}/${topic}"
  mkdir -p "${target_topic_dir}"

  source_count="$(cat "${source_topic_dir}/topic_dump.count")"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe --topic ${topic}" \
    > "${target_topic_dir}/topic_describe.txt"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --time -1" \
    | sort > "${target_topic_dir}/end_offsets.txt"

  diff -u "${source_topic_dir}/end_offsets.txt" "${target_topic_dir}/end_offsets.txt"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --from-beginning --max-messages ${source_count} --property print.key=true --property key.separator=:" \
    > "${target_topic_dir}/topic_dump_before_group_resume.txt"

  LC_ALL=C sort "${target_topic_dir}/topic_dump_before_group_resume.txt" > "${target_topic_dir}/topic_dump_before_group_resume.sorted.txt"
  target_hash="$(hash_file "${target_topic_dir}/topic_dump_before_group_resume.sorted.txt")"
  source_hash="$(cat "${source_topic_dir}/topic_dump.sorted.sha256")"
  echo "${target_hash}" > "${target_topic_dir}/topic_dump_before_group_resume.sha256"

  if [[ "${source_hash}" != "${target_hash}" ]]; then
    echo "Payload mismatch for ${topic}: source/target hashes differ." >&2
    exit 1
  fi
done

capture_group_offsets "${TARGET_BOOTSTRAP}" "${PHASE4_FULL_GROUP}" \
  "${TARGET_GROUPS_DIR}/${PHASE4_FULL_GROUP}.before_resume.raw.txt" \
  "${TARGET_GROUPS_DIR}/${PHASE4_FULL_GROUP}.before_resume.offsets.txt"
capture_group_offsets "${TARGET_BOOTSTRAP}" "${PHASE4_PARTIAL_GROUP}" \
  "${TARGET_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.before_resume.raw.txt" \
  "${TARGET_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.before_resume.offsets.txt"

diff -u "${SOURCE_GROUPS_DIR}/${PHASE4_FULL_GROUP}.offsets.txt" "${TARGET_GROUPS_DIR}/${PHASE4_FULL_GROUP}.before_resume.offsets.txt"
diff -u "${SOURCE_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.offsets.txt" "${TARGET_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.before_resume.offsets.txt"

if ! awk -F'|' -v topic="${PHASE4_FULL_TOPIC}" '$2 == topic {if ($4 != $5) bad=1; seen=1} END {exit (seen && !bad) ? 0 : 1}' \
  "${TARGET_GROUPS_DIR}/${PHASE4_FULL_GROUP}.before_resume.offsets.txt"; then
  echo "Expected ${PHASE4_FULL_GROUP} to remain fully caught up on ${PHASE4_FULL_TOPIC} after restore." >&2
  exit 1
fi

if ! awk -F'|' -v topic="${PHASE4_PARTIAL_TOPIC}" '
  $2 == topic {
    if ($4 + 0 > $5 + 0) bad=1
    if ($4 + 0 < $5 + 0) partial=1
    seen=1
  }
  END {exit (seen && !bad && partial) ? 0 : 1}
' "${TARGET_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.before_resume.offsets.txt"; then
  echo "Expected ${PHASE4_PARTIAL_GROUP} to remain partial on ${PHASE4_PARTIAL_TOPIC} after restore." >&2
  exit 1
fi

before_partial_sum="$(offset_sum_for_topic "${TARGET_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.before_resume.offsets.txt" "${PHASE4_PARTIAL_TOPIC}")"

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${PHASE4_PARTIAL_TOPIC} --group ${PHASE4_PARTIAL_GROUP} --max-messages ${PHASE4_PARTIAL_RESUME_MESSAGES} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2

capture_group_offsets "${TARGET_BOOTSTRAP}" "${PHASE4_PARTIAL_GROUP}" \
  "${TARGET_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.after_resume.raw.txt" \
  "${TARGET_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.after_resume.offsets.txt"

after_partial_sum="$(offset_sum_for_topic "${TARGET_GROUPS_DIR}/${PHASE4_PARTIAL_GROUP}.after_resume.offsets.txt" "${PHASE4_PARTIAL_TOPIC}")"
if [[ "${after_partial_sum}" -le "${before_partial_sum}" ]]; then
  echo "Partial group offsets did not advance after resume on target." >&2
  exit 1
fi

echo "Phase 4 validation succeeded:"
echo "- cluster.id parity: OK"
echo "- per-topic end offsets and payload parity: OK"
echo "- source/target consumer-group offset parity at snapshot point: OK"
echo "- full group remains fully consumed after restore: OK"
echo "- partial group resumes and advances offsets after restore: OK"
