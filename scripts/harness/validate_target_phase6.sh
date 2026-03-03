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

TARGET_PHASE6_DIR="${ROOT_DIR}/artifacts/latest/target/phase6"
TARGET_TOPICS_DIR="${TARGET_PHASE6_DIR}/topics"
TARGET_GROUPS_DIR="${TARGET_PHASE6_DIR}/groups"
TARGET_ACLS_DIR="${TARGET_PHASE6_DIR}/acls"
mkdir -p "${TARGET_TOPICS_DIR}" "${TARGET_GROUPS_DIR}" "${TARGET_ACLS_DIR}"

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

normalize_acl_list() {
  local in_file="$1"
  local out_file="$2"

  sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' "${in_file}" \
    | sed '/^$/d' \
    | LC_ALL=C sort -u > "${out_file}"
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

for spec in "${PHASE6_TOPIC_SPECS[@]}"; do
  IFS="|" read -r topic _ _ _ <<< "${spec}"
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
    > "${target_topic_dir}/topic_dump_before_resume.txt"
  LC_ALL=C sort "${target_topic_dir}/topic_dump_before_resume.txt" > "${target_topic_dir}/topic_dump_before_resume.sorted.txt"
  hash_file "${target_topic_dir}/topic_dump_before_resume.sorted.txt" > "${target_topic_dir}/topic_dump_before_resume.sorted.sha256"

  diff -u "${source_topic_dir}/topic_dump.sorted.sha256" "${target_topic_dir}/topic_dump_before_resume.sorted.sha256"
done

capture_group_offsets "${TARGET_BOOTSTRAP}" "${PHASE6_FULL_GROUP}" \
  "${TARGET_GROUPS_DIR}/${PHASE6_FULL_GROUP}.before_resume.raw.txt" \
  "${TARGET_GROUPS_DIR}/${PHASE6_FULL_GROUP}.before_resume.offsets.txt"
capture_group_offsets "${TARGET_BOOTSTRAP}" "${PHASE6_PARTIAL_GROUP}" \
  "${TARGET_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.before_resume.raw.txt" \
  "${TARGET_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.before_resume.offsets.txt"

diff -u "${SOURCE_GROUPS_DIR}/${PHASE6_FULL_GROUP}.offsets.txt" "${TARGET_GROUPS_DIR}/${PHASE6_FULL_GROUP}.before_resume.offsets.txt"
diff -u "${SOURCE_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.offsets.txt" "${TARGET_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.before_resume.offsets.txt"

if ! awk -F'|' -v topic="${PHASE6_FULL_TOPIC}" '$2 == topic {if ($4 != $5) bad=1; seen=1} END {exit (seen && !bad) ? 0 : 1}' \
  "${TARGET_GROUPS_DIR}/${PHASE6_FULL_GROUP}.before_resume.offsets.txt"; then
  echo "Expected ${PHASE6_FULL_GROUP} to remain fully consumed after restore." >&2
  exit 1
fi

if ! awk -F'|' -v topic="${PHASE6_PARTIAL_TOPIC}" '
  $2 == topic {
    if ($4 + 0 > $5 + 0) bad=1
    if ($4 + 0 < $5 + 0) partial=1
    seen=1
  }
  END {exit (seen && !bad && partial) ? 0 : 1}
' "${TARGET_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.before_resume.offsets.txt"; then
  echo "Expected ${PHASE6_PARTIAL_GROUP} to remain partial after restore." >&2
  exit 1
fi

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-acls --bootstrap-server ${TARGET_BOOTSTRAP} --list" \
  > "${TARGET_ACLS_DIR}/acls.list.raw.txt"
normalize_acl_list "${TARGET_ACLS_DIR}/acls.list.raw.txt" "${TARGET_ACLS_DIR}/acls.list.normalized.txt"
diff -u "${SOURCE_ACLS_DIR}/acls.list.normalized.txt" "${TARGET_ACLS_DIR}/acls.list.normalized.txt"

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
  if ! grep -q "${marker}" "${TARGET_ACLS_DIR}/acls.list.normalized.txt"; then
    echo "Expected ACL marker '${marker}' not found in target ACL snapshot." >&2
    exit 1
  fi
done

before_partial_sum="$(offset_sum_for_topic "${TARGET_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.before_resume.offsets.txt" "${PHASE6_PARTIAL_TOPIC}")"
compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${PHASE6_PARTIAL_TOPIC} --group ${PHASE6_PARTIAL_GROUP} --max-messages ${PHASE6_PARTIAL_RESUME_MESSAGES} --consumer-property enable.auto.commit=true --consumer-property auto.commit.interval.ms=1000 >/dev/null"
sleep 2

capture_group_offsets "${TARGET_BOOTSTRAP}" "${PHASE6_PARTIAL_GROUP}" \
  "${TARGET_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.after_resume.raw.txt" \
  "${TARGET_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.after_resume.offsets.txt"
after_partial_sum="$(offset_sum_for_topic "${TARGET_GROUPS_DIR}/${PHASE6_PARTIAL_GROUP}.after_resume.offsets.txt" "${PHASE6_PARTIAL_TOPIC}")"
if [[ "${after_partial_sum}" -le "${before_partial_sum}" ]]; then
  echo "Partial group offsets did not advance after resume on target." >&2
  exit 1
fi

echo "Phase 6 validation succeeded:"
echo "- cluster.id parity: OK"
echo "- per-topic data and offset parity: OK"
echo "- consumer group offset parity and resume behavior: OK"
echo "- ACL metadata parity (source vs target): OK"
