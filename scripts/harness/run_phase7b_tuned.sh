#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase7b_tuning_profiles.sh
source "${SCRIPT_DIR}/phase7b_tuning_profiles.sh"

profile_selector="${1:-all}"
iterations_override="${2:-}"
campaign_id="phase7b-tuned-$(timestamp_utc)"
campaign_root="${ROOT_DIR}/artifacts/phase7b-tuned/${campaign_id}"
campaign_summary_tsv="${campaign_root}/campaign_summary.tsv"
campaign_summary_md="${campaign_root}/campaign_summary.md"
min_free_gb="${PHASE7B_MIN_FREE_GB:-20}"
tuned_prune_after_profile="${PHASE7B_TUNED_PRUNE_AFTER_PROFILE:-true}"
tuned_prune_snapshots="${PHASE7B_TUNED_PRUNE_SNAPSHOTS:-true}"
tuned_prune_latest="${PHASE7B_TUNED_PRUNE_LATEST:-true}"
mkdir -p "${campaign_root}"

declare -a profiles=()
if [[ "${profile_selector}" == "all" ]]; then
  profiles=("${PHASE7B_TUNING_PROFILES[@]}")
else
  profiles=("${profile_selector}")
fi

printf "profile\trun_id\tscenario\tfinal_status\tattempts_executed\tfinal_attempt\tacked_count\trecovered_count\tlost_count\tloss_pct\tstability_status\ttarget_start_rc\tvalidate_rc\tacks_all_throughput\tlive_produce_seconds\tlive_copy_start_delay_seconds\titerations\n" > "${campaign_summary_tsv}"

free_kb() {
  df -Pk "${ROOT_DIR}" | awk 'NR == 2 {print $4}'
}

ensure_min_free_space() {
  local free_kb_now required_kb
  free_kb_now="$(free_kb)"
  required_kb=$((min_free_gb * 1024 * 1024))
  if [[ "${free_kb_now}" -lt "${required_kb}" ]]; then
    echo "Insufficient free disk for tuned phase7b run. Required >= ${min_free_gb} GiB." >&2
    echo "Current free: $((free_kb_now / 1024 / 1024)) GiB" >&2
    echo "Clean old artifacts/snapshots and retry." >&2
    return 1
  fi
  return 0
}

ensure_min_free_space

{
  echo "# Phase 7b Tuned Campaign (${campaign_id})"
  echo ""
  echo "- generated_utc: $(timestamp_utc)"
  echo "- campaign_root: ${campaign_root}"
  echo "- min_free_gb: ${min_free_gb}"
  if [[ -n "${iterations_override}" ]]; then
    echo "- iterations_override: ${iterations_override}"
  fi
  echo ""
} > "${campaign_summary_md}"

overall_rc=0
for profile in "${profiles[@]}"; do
  ensure_min_free_space

  valid=0
  for expected in "${PHASE7B_TUNING_PROFILES[@]}"; do
    if [[ "${profile}" == "${expected}" ]]; then
      valid=1
      break
    fi
  done
  if [[ "${valid}" -ne 1 ]]; then
    echo "Unknown phase7b tuning profile '${profile}'. Valid: ${PHASE7B_TUNING_PROFILES[*]}" >&2
    exit 1
  fi

  unset PHASE7B_ACKS_ALL_THROUGHPUT PHASE7B_LIVE_PRODUCE_SECONDS PHASE7B_LIVE_COPY_START_DELAY_SECONDS PHASE7B_ITERATIONS
  apply_phase7b_tuning_profile "${profile}"
  if [[ -n "${iterations_override}" ]]; then
    export PHASE7B_ITERATIONS="${iterations_override}"
  fi

  export PHASE7B_PROFILE_NAME="${profile}"
  export PHASE7B_RUN_ID="phase7b-${profile}-$(timestamp_utc)"
  run_root="${ROOT_DIR}/artifacts/phase7b-runs/${PHASE7B_RUN_ID}"

  echo "==== Phase 7b tuned profile: ${profile} (run_id=${PHASE7B_RUN_ID}) ===="
  set +e
  "${SCRIPT_DIR}/run_phase7b_loss.sh" "loss-live-copy-flush-window"
  run_rc=$?
  set -e

  if [[ ! -f "${run_root}/summary.tsv" ]]; then
    echo "Missing summary for tuned profile '${profile}' run '${PHASE7B_RUN_ID}'." >&2
    exit 2
  fi

  "${SCRIPT_DIR}/generate_phase7b_compact_report.sh" "${run_root}" >/dev/null
  report_dir="${ROOT_DIR}/artifacts/reports/${PHASE7B_RUN_ID}"
  profile_dir="${campaign_root}/${profile}"
  mkdir -p "${profile_dir}"
  cp "${run_root}/summary.tsv" "${profile_dir}/summary.tsv"
  cp "${run_root}/run_context.env" "${profile_dir}/run_context.env"
  cp "${run_root}/loss-live-copy-flush-window.attempts.tsv" "${profile_dir}/attempts.tsv"
  cp "${report_dir}/compact_report.md" "${profile_dir}/compact_report.md"
  cp "${report_dir}/compact_attempts.tsv" "${profile_dir}/compact_attempts.tsv"

  summary_row="$(awk 'NR==2 {print $0; exit}' "${run_root}/summary.tsv")"
  if [[ -z "${summary_row}" ]]; then
    scenario="loss-live-copy-flush-window"
    final_status="failed"
    attempts_executed="0"
    final_attempt="00"
    acked_count="0"
    recovered_count="0"
    lost_count="0"
    loss_pct="0.0000"
    stability_status="failed"
    target_start_rc="1"
    validate_rc="1"
    overall_rc=1
  else
    IFS=$'\t' read -r scenario final_status attempts_executed final_attempt acked_count recovered_count lost_count loss_pct stability_status target_start_rc validate_rc <<< "${summary_row}"
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${profile}" "${PHASE7B_RUN_ID}" "${scenario}" "${final_status}" "${attempts_executed}" "${final_attempt}" "${acked_count}" "${recovered_count}" "${lost_count}" "${loss_pct}" "${stability_status}" "${target_start_rc}" "${validate_rc}" "${PHASE7B_ACKS_ALL_THROUGHPUT}" "${PHASE7B_LIVE_PRODUCE_SECONDS}" "${PHASE7B_LIVE_COPY_START_DELAY_SECONDS}" "${PHASE7B_ITERATIONS}" \
    >> "${campaign_summary_tsv}"

  {
    echo "## Profile: ${profile}"
    echo ""
    echo "- run_id: ${PHASE7B_RUN_ID}"
    echo "- result: ${final_status} (attempt=${final_attempt}, loss_pct=${loss_pct})"
    echo "- parameters: throughput=${PHASE7B_ACKS_ALL_THROUGHPUT}, produce_seconds=${PHASE7B_LIVE_PRODUCE_SECONDS}, copy_start_delay_seconds=${PHASE7B_LIVE_COPY_START_DELAY_SECONDS}, iterations=${PHASE7B_ITERATIONS}"
    echo "- summary: \`${run_root}/summary.tsv\`"
    echo "- compact_report: \`${report_dir}/compact_report.md\`"
    echo ""
  } >> "${campaign_summary_md}"

  if [[ "${tuned_prune_after_profile}" == "true" ]]; then
    PRUNE_SNAPSHOTS="${tuned_prune_snapshots}" \
    PRUNE_LATEST="${tuned_prune_latest}" \
    "${SCRIPT_DIR}/prune_artifacts_keep_proof.sh" "${PHASE7B_RUN_ID}" >/dev/null || true
  fi

  if [[ "${run_rc}" -ne 0 ]]; then
    overall_rc=1
  fi
done

mkdir -p "${ROOT_DIR}/artifacts/latest"
cp "${campaign_summary_tsv}" "${ROOT_DIR}/artifacts/latest/phase7b_tuned_campaign_summary.tsv"
cp "${campaign_summary_md}" "${ROOT_DIR}/artifacts/latest/phase7b_tuned_campaign_summary.md"

echo "Phase7b tuned campaign summary:"
echo "  ${campaign_summary_tsv}"
echo "  ${campaign_summary_md}"
if [[ "${overall_rc}" -ne 0 ]]; then
  echo "One or more tuned profile runs returned non-zero rc."
  exit 1
fi
