#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

compose_cmd up -d "${TARGET_SCHEMA_SERVICE}"
wait_for_schema_registry "${TARGET_SCHEMA_SERVICE}" "${TARGET_SCHEMA_URL}" 90

mkdir -p "${ROOT_DIR}/artifacts/latest/target"
compose_cmd exec -T "${TARGET_SCHEMA_SERVICE}" bash -lc "curl -fsS ${TARGET_SCHEMA_URL}/subjects | tr -d '\n'" \
  > "${ROOT_DIR}/artifacts/latest/target/schema_subjects_after_start.json"

echo "Target Schema Registry is running."
