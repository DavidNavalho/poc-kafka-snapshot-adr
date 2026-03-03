#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase9_scenarios.sh
source "${SCRIPT_DIR}/phase9_scenarios.sh"

SOURCE_PHASE9_DIR="${ROOT_DIR}/artifacts/latest/source/phase9"
SOURCE_TOPICS_DIR="${SOURCE_PHASE9_DIR}/topics"
SOURCE_RUNTIME_DIR="${SOURCE_PHASE9_DIR}/runtime"
SOURCE_RUNTIME_ENV="${SOURCE_RUNTIME_DIR}/phase9_runtime.env"
mkdir -p "${SOURCE_TOPICS_DIR}" "${SOURCE_RUNTIME_DIR}"

sum_end_offsets_file() {
  local file="$1"
  awk -F: 'NF >= 3 && $3 ~ /^[0-9]+$/ {sum += $3} END {print sum + 0}' "${file}"
}

wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90

source_cluster_id="$(grep '^cluster.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2)"
echo "${source_cluster_id}" > "${ROOT_DIR}/artifacts/latest/source/cluster_id.txt"
grep '^node.id=' "${ROOT_DIR}/data/source/broker1/meta.properties" | cut -d= -f2 > "${ROOT_DIR}/artifacts/latest/source/node_id.txt"

if compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --list | grep -Fx '${PHASE9_TOPIC}' >/dev/null"; then
  existing_count="$(compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE9_TOPIC} --time -1 2>/dev/null | awk -F: '{sum += \$3} END {print sum + 0}'")"
  if [[ "${existing_count}" -gt 0 ]]; then
    echo "Topic ${PHASE9_TOPIC} already contains ${existing_count} records. Use reset_lab.sh or a fresh topic name." >&2
    exit 1
  fi
fi

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --create --if-not-exists --topic ${PHASE9_TOPIC} --partitions ${PHASE9_PARTITIONS} --replication-factor 3"

seq 1 "${PHASE9_SEED_MESSAGES}" \
  | awk -v topic="${PHASE9_TOPIC}" '{printf "%s-%06d:{\"event\":\"phase9-seed\",\"topic\":\"%s\",\"seq\":%d,\"value\":%d}\n", topic, $1, topic, $1, (($1 % 43) + 1)}' \
  | compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-console-producer --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE9_TOPIC} --property parse.key=true --property key.separator=: >/dev/null"

topic_dir="${SOURCE_TOPICS_DIR}/${PHASE9_TOPIC}"
mkdir -p "${topic_dir}"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --topic ${PHASE9_TOPIC}" \
  > "${topic_dir}/topic_describe.txt"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-get-offsets --bootstrap-server ${SOURCE_BOOTSTRAP} --topic ${PHASE9_TOPIC} --time -1" \
  | sort > "${topic_dir}/end_offsets.txt"

source_end_sum="$(sum_end_offsets_file "${topic_dir}/end_offsets.txt")"

cat > "${SOURCE_RUNTIME_ENV}" <<EOF
source_cluster_id=${source_cluster_id}
source_topic=${PHASE9_TOPIC}
source_end_sum=${source_end_sum}
EOF

echo "Phase 9 source seeding complete."
