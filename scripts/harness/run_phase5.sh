#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/reset_lab.sh"
"${SCRIPT_DIR}/start_source.sh"
"${SCRIPT_DIR}/seed_source_phase5.sh"
"${SCRIPT_DIR}/snapshot_copy_to_target.sh"
"${SCRIPT_DIR}/start_target.sh"
"${SCRIPT_DIR}/validate_target_phase5.sh"

echo "Phase 5 scenario completed."
