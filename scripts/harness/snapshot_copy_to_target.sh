#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

SNAPSHOT_ID="${1:-$(timestamp_utc)}"
SNAPSHOT_DIR="${ROOT_DIR}/artifacts/snapshots/${SNAPSHOT_ID}"
LATEST_DIR="${ROOT_DIR}/artifacts/latest"

mkdir -p "${SNAPSHOT_DIR}/source-data" "${LATEST_DIR}"

for broker in 1 2 3; do
  ensure_broker_data_present "${ROOT_DIR}/data/source" "${broker}"
done

compose_cmd stop "${TARGET_SCHEMA_SERVICE}" >/dev/null 2>&1 || true
compose_cmd stop "${SOURCE_SCHEMA_SERVICE}" >/dev/null 2>&1 || true
compose_cmd stop "${TARGET_SERVICES[@]}" >/dev/null 2>&1 || true
compose_cmd stop "${SOURCE_SERVICES[@]}"

rsync -a --delete "${ROOT_DIR}/data/source/" "${SNAPSHOT_DIR}/source-data/"
rsync -a --delete "${SNAPSHOT_DIR}/source-data/" "${ROOT_DIR}/data/target/"

for broker in 1 2 3; do
  ensure_broker_data_present "${ROOT_DIR}/data/target" "${broker}"
done

TARGET_CLUSTER_ID="$(grep '^cluster.id=' "${ROOT_DIR}/data/target/broker1/meta.properties" | cut -d= -f2)"
upsert_runtime_var "TARGET_CLUSTER_ID" "${TARGET_CLUSTER_ID}"

echo "${SNAPSHOT_ID}" > "${LATEST_DIR}/snapshot_id.txt"
echo "Snapshot ${SNAPSHOT_ID} copied from source -> target."
