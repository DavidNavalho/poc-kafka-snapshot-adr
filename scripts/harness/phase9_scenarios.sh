#!/usr/bin/env bash
set -euo pipefail

PHASE9_SCENARIOS=(
  "new-identity-direct-import"
  "new-identity-reachable-allowed"
)

PHASE9_ASSERTION_FIELDS=(
  "start_target_expected_failure"
  "cluster_unreachable"
  "invalid_cluster_id_logged"
  "rewritten_cluster_id_applied"
  "snapshot_data_present"
  "stray_dirs_found"
  "direct_import_blocked"
  "post_restore_io_succeeds"
)

PHASE9_TOPIC="${PHASE9_TOPIC:-dr.p9.identity}"
PHASE9_PARTITIONS="${PHASE9_PARTITIONS:-3}"
PHASE9_SEED_MESSAGES="${PHASE9_SEED_MESSAGES:-900}"
PHASE9_START_WAIT_RETRIES="${PHASE9_START_WAIT_RETRIES:-12}"
PHASE9_SMOKE_MESSAGES="${PHASE9_SMOKE_MESSAGES:-18}"
PHASE9_SMOKE_CONSUME="${PHASE9_SMOKE_CONSUME:-12}"

phase9_expectation_mode() {
  local scenario="$1"
  case "${scenario}" in
    new-identity-direct-import)
      echo "blocked"
      ;;
    new-identity-reachable-allowed)
      echo "allowed"
      ;;
    *)
      return 1
      ;;
  esac
}
