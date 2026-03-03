#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOPIC="${1:-dr.basic.orders}"
SEED_MESSAGES="${2:-1200}"
POST_RESTORE_MESSAGES="${3:-120}"

"${SCRIPT_DIR}/reset_lab.sh"
"${SCRIPT_DIR}/start_source.sh"
"${SCRIPT_DIR}/seed_source_basic.sh" "${TOPIC}" "${SEED_MESSAGES}" 6
"${SCRIPT_DIR}/snapshot_copy_to_target.sh"
"${SCRIPT_DIR}/start_target.sh"
"${SCRIPT_DIR}/validate_target_basic.sh" "${TOPIC}" "${POST_RESTORE_MESSAGES}"

echo "Phase 1 scenario completed."
