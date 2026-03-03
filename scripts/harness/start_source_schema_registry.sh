#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

compose_cmd up -d "${SOURCE_SCHEMA_SERVICE}"
wait_for_schema_registry "${SOURCE_SCHEMA_SERVICE}" "${SOURCE_SCHEMA_URL}" 90

mkdir -p "${ROOT_DIR}/artifacts/latest/source"
compose_cmd exec -T "${SOURCE_SCHEMA_SERVICE}" bash -lc "curl -fsS ${SOURCE_SCHEMA_URL}/subjects | tr -d '\n'" \
  > "${ROOT_DIR}/artifacts/latest/source/schema_subjects_initial.json"

echo "Source Schema Registry is running."
