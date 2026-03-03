#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_runtime_env
if [[ -z "${SOURCE_CLUSTER_ID:-}" ]]; then
  SOURCE_CLUSTER_ID="$(
    docker run --rm --entrypoint /bin/bash confluentinc/cp-server:8.1.0 -lc "kafka-storage random-uuid"
  )"
  upsert_runtime_var "SOURCE_CLUSTER_ID" "${SOURCE_CLUSTER_ID}"
fi

compose_cmd up -d "${SOURCE_SERVICES[@]}"
wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90

mkdir -p "${ROOT_DIR}/artifacts/latest/source"
compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-metadata-quorum --bootstrap-server ${SOURCE_BOOTSTRAP} describe --status" \
  > "${ROOT_DIR}/artifacts/latest/source/metadata_quorum_status.txt"
echo "${SOURCE_CLUSTER_ID}" > "${ROOT_DIR}/artifacts/latest/source/source_cluster_id_runtime.txt"

echo "Source cluster is running."
