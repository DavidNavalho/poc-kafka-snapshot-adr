#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TOPIC="${1:-dr.basic.orders}"
POST_RESTORE_MESSAGES="${2:-120}"
VALIDATION_GROUP="${3:-dr.phase1.validation.group}"

SOURCE_ARTIFACT_DIR="${ROOT_DIR}/artifacts/latest/source"
TARGET_ARTIFACT_DIR="${ROOT_DIR}/artifacts/latest/target"
mkdir -p "${TARGET_ARTIFACT_DIR}"

wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 90

SOURCE_COUNT="$(cat "${SOURCE_ARTIFACT_DIR}/topic_dump.count")"
EXPECTED_FINAL_COUNT="$((SOURCE_COUNT + POST_RESTORE_MESSAGES))"

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe --topic ${TOPIC}" \
  > "${TARGET_ARTIFACT_DIR}/topic_describe.txt"

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${TOPIC} --time -1" \
  | sort > "${TARGET_ARTIFACT_DIR}/end_offsets.txt"

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${TOPIC} --from-beginning --max-messages ${SOURCE_COUNT} --property print.key=true --property key.separator=:" \
  > "${TARGET_ARTIFACT_DIR}/topic_dump_before_smoke.txt"

LC_ALL=C sort "${TARGET_ARTIFACT_DIR}/topic_dump_before_smoke.txt" > "${TARGET_ARTIFACT_DIR}/topic_dump_before_smoke.sorted.txt"

SOURCE_HASH="$(cat "${SOURCE_ARTIFACT_DIR}/topic_dump.sorted.sha256")"
TARGET_HASH="$(hash_file "${TARGET_ARTIFACT_DIR}/topic_dump_before_smoke.sorted.txt")"
echo "${TARGET_HASH}" > "${TARGET_ARTIFACT_DIR}/topic_dump_before_smoke.sha256"

if [[ "${SOURCE_HASH}" != "${TARGET_HASH}" ]]; then
  echo "Payload mismatch: source and restored target hashes differ." >&2
  exit 1
fi

diff -u "${SOURCE_ARTIFACT_DIR}/end_offsets.txt" "${TARGET_ARTIFACT_DIR}/end_offsets.txt"

SOURCE_CLUSTER_ID="$(cat "${SOURCE_ARTIFACT_DIR}/cluster_id.txt")"
TARGET_CLUSTER_ID="$(grep '^cluster.id=' "${ROOT_DIR}/data/target/broker1/meta.properties" | cut -d= -f2)"
if [[ "${SOURCE_CLUSTER_ID}" != "${TARGET_CLUSTER_ID}" ]]; then
  echo "Cluster ID mismatch: source=${SOURCE_CLUSTER_ID} target=${TARGET_CLUSTER_ID}" >&2
  exit 1
fi

seq 1 "${POST_RESTORE_MESSAGES}" \
  | awk '{printf "post-%03d:{\"event\":\"post-restore\",\"order_id\":%d,\"amount\":%d}\n", $1, (1000000 + $1), (($1 % 11) + 1)}' \
  | compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-console-producer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${TOPIC} --property parse.key=true --property key.separator=: >/dev/null"

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${TOPIC} --group ${VALIDATION_GROUP} --from-beginning --max-messages 10 >/dev/null"

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --describe --group ${VALIDATION_GROUP}" \
  > "${TARGET_ARTIFACT_DIR}/consumer_group_describe.txt"

if ! grep -q "${TOPIC}" "${TARGET_ARTIFACT_DIR}/consumer_group_describe.txt"; then
  echo "Expected group ${VALIDATION_GROUP} to have offsets for ${TOPIC}." >&2
  exit 1
fi

compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${TOPIC} --from-beginning --max-messages ${EXPECTED_FINAL_COUNT} --property print.key=true --property key.separator=:" \
  > "${TARGET_ARTIFACT_DIR}/topic_dump_after_smoke.txt"

BASELINE_COUNT="$(wc -l < "${TARGET_ARTIFACT_DIR}/topic_dump_before_smoke.txt" | tr -d ' ')"
FINAL_COUNT="$(wc -l < "${TARGET_ARTIFACT_DIR}/topic_dump_after_smoke.txt" | tr -d ' ')"

if [[ "${BASELINE_COUNT}" -ne "${SOURCE_COUNT}" ]]; then
  echo "Baseline count mismatch after restore: expected ${SOURCE_COUNT}, got ${BASELINE_COUNT}." >&2
  exit 1
fi

if [[ "${FINAL_COUNT}" -ne "${EXPECTED_FINAL_COUNT}" ]]; then
  echo "Post-restore message count mismatch: expected ${EXPECTED_FINAL_COUNT}, got ${FINAL_COUNT}." >&2
  exit 1
fi

hash_file "${TARGET_ARTIFACT_DIR}/topic_dump_after_smoke.txt" > "${TARGET_ARTIFACT_DIR}/topic_dump_after_smoke.sha256"

echo "Validation succeeded:"
echo "- hash/source-target parity before smoke: OK"
echo "- end offsets parity before smoke: OK"
echo "- cluster.id parity: OK"
echo "- post-restore produce/consume smoke: OK"
