#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase7b_loss_scenarios.sh
source "${SCRIPT_DIR}/phase7b_loss_scenarios.sh"

scenario_selector="${1:-all}"
run_id="${PHASE7B_RUN_ID:-phase7b-$(timestamp_utc)}"
run_root="${ROOT_DIR}/artifacts/phase7b-runs/${run_id}"
summary_file="${run_root}/summary.tsv"
compact_after_run="${PHASE7B_COMPACT_AFTER_RUN:-true}"
prune_after_run="${PHASE7B_PRUNE_AFTER_RUN:-false}"
mkdir -p "${run_root}"

cat > "${run_root}/run_context.env" <<EOF
run_id=${run_id}
scenario_selector=${scenario_selector}
PHASE7B_PROFILE_NAME=${PHASE7B_PROFILE_NAME:-default}
PHASE7B_CHAOS_TOPIC=${PHASE7B_CHAOS_TOPIC}
PHASE7B_ACKS1_MAX_MESSAGES=${PHASE7B_ACKS1_MAX_MESSAGES}
PHASE7B_ACKS1_THROUGHPUT=${PHASE7B_ACKS1_THROUGHPUT}
PHASE7B_ACKS1_PRODUCE_SECONDS=${PHASE7B_ACKS1_PRODUCE_SECONDS}
PHASE7B_ACKS_ALL_THROUGHPUT=${PHASE7B_ACKS_ALL_THROUGHPUT}
PHASE7B_LIVE_PRODUCE_SECONDS=${PHASE7B_LIVE_PRODUCE_SECONDS}
PHASE7B_LIVE_COPY_START_DELAY_SECONDS=${PHASE7B_LIVE_COPY_START_DELAY_SECONDS}
PHASE7B_SKEW_SECONDS_1=${PHASE7B_SKEW_SECONDS_1}
PHASE7B_SKEW_SECONDS_2=${PHASE7B_SKEW_SECONDS_2}
PHASE7B_ITERATIONS=${PHASE7B_ITERATIONS}
PHASE7B_ABORT_IF_ALL_LOST=${PHASE7B_ABORT_IF_ALL_LOST}
EOF

declare -a scenarios=()
if [[ "${scenario_selector}" == "all" ]]; then
  scenarios=("${PHASE7B_SCENARIOS[@]}")
else
  scenarios=("${scenario_selector}")
fi

printf "scenario\tfinal_status\tattempts_executed\tfinal_attempt\tacked_count\trecovered_count\tlost_count\tloss_pct\tstability_status\ttarget_start_rc\tvalidate_rc\n" > "${summary_file}"

run_attempt() {
  local scenario="$1"
  local attempt="$2"
  local attempt_pad
  local target_start_rc
  local validate_rc
  local attempt_result_file
  local attempt_run_dir

  attempt_pad="$(printf '%02d' "${attempt}")"
  echo "==== Phase 7b scenario: ${scenario} (attempt ${attempt_pad}) ===="

  "${SCRIPT_DIR}/reset_lab.sh"
  "${SCRIPT_DIR}/start_source.sh"
  "${SCRIPT_DIR}/seed_source_phase7b_loss.sh" "${scenario}" "${attempt}"
  "${SCRIPT_DIR}/snapshot_copy_phase7b_loss.sh" "${scenario}" "${attempt}"

  set +e
  "${SCRIPT_DIR}/start_target.sh"
  target_start_rc=$?
  set -e

  set +e
  PHASE7B_TARGET_START_RC="${target_start_rc}" "${SCRIPT_DIR}/validate_target_phase7b_loss.sh" "${scenario}" "${attempt}"
  validate_rc=$?
  set -e

  attempt_result_file="${ROOT_DIR}/artifacts/latest/target/phase7b/${scenario}/attempt-${attempt_pad}/attempt_result.env"
  if [[ ! -f "${attempt_result_file}" ]]; then
    echo "Missing attempt result file for ${scenario} attempt ${attempt_pad}" >&2
    return 2
  fi

  # shellcheck disable=SC1090
  source "${attempt_result_file}"
  {
    echo "target_start_rc=${target_start_rc}"
    echo "validate_rc=${validate_rc}"
  } >> "${attempt_result_file}"

  attempt_run_dir="${run_root}/${scenario}/attempt-${attempt_pad}"
  mkdir -p "${attempt_run_dir}"
  if [[ -d "${ROOT_DIR}/artifacts/latest/source/phase7b/${scenario}/attempt-${attempt_pad}" ]]; then
    cp -R "${ROOT_DIR}/artifacts/latest/source/phase7b/${scenario}/attempt-${attempt_pad}" "${attempt_run_dir}/source"
  fi
  if [[ -d "${ROOT_DIR}/artifacts/latest/target/phase7b/${scenario}/attempt-${attempt_pad}" ]]; then
    cp -R "${ROOT_DIR}/artifacts/latest/target/phase7b/${scenario}/attempt-${attempt_pad}" "${attempt_run_dir}/target"
  fi
  if [[ -f "${ROOT_DIR}/artifacts/latest/snapshot_id.txt" ]]; then
    cp "${ROOT_DIR}/artifacts/latest/snapshot_id.txt" "${attempt_run_dir}/snapshot_id.txt"
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${scenario}" "${status}" "${attempt}" "${attempt_pad}" "${acked_count}" "${recovered_count}" "${lost_count}" "${loss_pct}" "${stability_status}" "${target_start_rc}" "${validate_rc}" \
    >> "${run_root}/${scenario}.attempts.tsv"

  echo "${status}"
  return 0
}

overall_rc=0
for scenario in "${scenarios[@]}"; do
  valid=0
  for expected in "${PHASE7B_SCENARIOS[@]}"; do
    if [[ "${scenario}" == "${expected}" ]]; then
      valid=1
      break
    fi
  done
  if [[ "${valid}" -ne 1 ]]; then
    echo "Unknown phase 7b scenario '${scenario}'. Valid: ${PHASE7B_SCENARIOS[*]}" >&2
    exit 1
  fi

  : > "${run_root}/${scenario}.attempts.tsv"
  printf "scenario\tstatus\tattempt\tattempt_pad\tacked_count\trecovered_count\tlost_count\tloss_pct\tstability_status\ttarget_start_rc\tvalidate_rc\n" > "${run_root}/${scenario}.attempts.tsv"

  final_status="failed"
  final_attempt="00"
  final_acked_count=0
  final_recovered_count=0
  final_lost_count=0
  final_loss_pct="0.0000"
  final_stability_status="failed"
  final_target_start_rc=1
  final_validate_rc=1
  attempts_executed=0

  max_attempts=1
  if [[ "${scenario}" == "loss-live-copy-flush-window" ]]; then
    max_attempts="${PHASE7B_ITERATIONS}"
  fi

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    attempts_executed="${attempt}"
    run_attempt "${scenario}" "${attempt}"
    attempt_pad="$(printf '%02d' "${attempt}")"
    attempt_result_file="${ROOT_DIR}/artifacts/latest/target/phase7b/${scenario}/attempt-${attempt_pad}/attempt_result.env"
    # shellcheck disable=SC1090
    source "${attempt_result_file}"
    attempt_status="${status}"
    final_status="${status}"
    final_attempt="${attempt_pad}"
    final_acked_count="${acked_count}"
    final_recovered_count="${recovered_count}"
    final_lost_count="${lost_count}"
    final_loss_pct="${loss_pct}"
    final_stability_status="${stability_status}"
    final_target_start_rc="${target_start_rc}"
    final_validate_rc="${validate_rc}"

    if [[ "${attempt_status}" == "failed" ]]; then
      break
    fi
    if [[ "${scenario}" == "loss-live-copy-flush-window" ]]; then
      if [[ "${attempt_status}" == "recovered_with_loss" || "${attempt_status}" == "degraded_with_loss" ]]; then
        break
      fi
    else
      break
    fi
  done

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${scenario}" "${final_status}" "${attempts_executed}" "${final_attempt}" "${final_acked_count}" "${final_recovered_count}" "${final_lost_count}" "${final_loss_pct}" "${final_stability_status}" "${final_target_start_rc}" "${final_validate_rc}" \
    >> "${summary_file}"

  scenario_final_dir="${run_root}/${scenario}/final"
  mkdir -p "${scenario_final_dir}"
  if [[ -d "${ROOT_DIR}/artifacts/latest/target/phase7b/${scenario}/attempt-${final_attempt}" ]]; then
    cp -R "${ROOT_DIR}/artifacts/latest/target/phase7b/${scenario}/attempt-${final_attempt}/." "${scenario_final_dir}/"
  fi

  if [[ "${final_status}" == "failed" ]]; then
    overall_rc=1
  fi
done

mkdir -p "${ROOT_DIR}/artifacts/latest"
cp "${summary_file}" "${ROOT_DIR}/artifacts/latest/phase7b_summary.tsv"
cp "${run_root}/run_context.env" "${ROOT_DIR}/artifacts/latest/phase7b_run_context.env"

echo "Phase 7b run summary: ${summary_file}"

if [[ "${compact_after_run}" == "true" ]]; then
  "${SCRIPT_DIR}/generate_phase7b_compact_report.sh" "${run_root}" || true
fi

if [[ "${prune_after_run}" == "true" ]]; then
  "${SCRIPT_DIR}/prune_artifacts_keep_proof.sh" "${run_root}" || true
fi

if [[ "${overall_rc}" -ne 0 ]]; then
  echo "At least one phase7b scenario failed."
  exit 1
fi
echo "Phase 7b scenarios completed."
