#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/reset_lab.sh"
"${SCRIPT_DIR}/start_source.sh"
"${SCRIPT_DIR}/seed_source_phase6.sh"
"${SCRIPT_DIR}/snapshot_copy_to_target.sh"
"${SCRIPT_DIR}/start_target.sh"
"${SCRIPT_DIR}/validate_target_phase6.sh"

echo "Phase 6 scenario completed."
