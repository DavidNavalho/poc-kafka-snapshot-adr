#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

for broker in 1 2 3; do
  ensure_broker_data_present "${ROOT_DIR}/data/target" "${broker}"
done

load_runtime_env
if [[ -z "${TARGET_CLUSTER_ID:-}" ]]; then
  TARGET_CLUSTER_ID="$(grep '^cluster.id=' "${ROOT_DIR}/data/target/broker1/meta.properties" | cut -d= -f2)"
  upsert_runtime_var "TARGET_CLUSTER_ID" "${TARGET_CLUSTER_ID}"
fi

compose_cmd up -d "${TARGET_SERVICES[@]}"
wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 90

mkdir -p "${ROOT_DIR}/artifacts/latest/target"
compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-metadata-quorum --bootstrap-server ${TARGET_BOOTSTRAP} describe --status" \
  > "${ROOT_DIR}/artifacts/latest/target/metadata_quorum_status.txt"
echo "${TARGET_CLUSTER_ID}" > "${ROOT_DIR}/artifacts/latest/target/target_cluster_id_runtime.txt"

echo "Target cluster is running from copied snapshot data."
