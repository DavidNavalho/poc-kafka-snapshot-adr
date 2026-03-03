#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

run_ref="${1:-latest}"

resolve_run_root() {
  local ref="$1"

  if [[ "${ref}" == "latest" ]]; then
    ls -td "${ROOT_DIR}"/artifacts/phase7b-runs/phase7b-* 2>/dev/null | head -n 1
    return 0
  fi

  if [[ -d "${ref}" ]]; then
    printf "%s\n" "${ref}"
    return 0
  fi

  if [[ -d "${ROOT_DIR}/artifacts/phase7b-runs/${ref}" ]]; then
    printf "%s\n" "${ROOT_DIR}/artifacts/phase7b-runs/${ref}"
    return 0
  fi

  return 1
}

run_root="$(resolve_run_root "${run_ref}" || true)"
if [[ -z "${run_root}" || ! -d "${run_root}" ]]; then
  echo "Unable to resolve phase7b run root from '${run_ref}'." >&2
  exit 1
fi

run_id="$(basename "${run_root}")"
report_root="${ROOT_DIR}/artifacts/reports/${run_id}"
report_md="${report_root}/compact_report.md"
report_tsv="${report_root}/compact_attempts.tsv"
mkdir -p "${report_root}"

read_kv_equals() {
  local file="$1"
  local key="$2"
  awk -F= -v k="${key}" '$1 == k {print $2; exit}' "${file}" 2>/dev/null || true
}

read_kv_colon() {
  local file="$1"
  local key="$2"
  awk -F: -v k="${key}" '$1 == k {gsub(/[[:space:]]/, "", $2); print $2; exit}' "${file}" 2>/dev/null || true
}

read_jmx_value() {
  local file="$1"
  local metric="$2"
  awk -F'\t' -v m="${metric}" '$1 ~ m {v=$2} END {print v}' "${file}" 2>/dev/null || true
}

printf "scenario\tattempt\tstatus\tstability_status\tacked_count\trecovered_count\tlost_count\tloss_pct\toffline_partitions\tunder_replicated_partitions\tmetadata_leader_id\tmetadata_max_follower_lag\tjmx_offline_partitions\tjmx_under_replicated\tconsume_rc\tsmoke_read_count\tremediation_rows\tremediation_command_files\tunclean_preferred_rc\tunclean_election_rc\ttop_finding\n" > "${report_tsv}"

{
  echo "# Phase 7b Compact Report (${run_id})"
  echo ""
  echo "- generated_utc: $(timestamp_utc)"
  echo "- run_root: ${run_root}"
  if [[ -f "${run_root}/run_context.env" ]]; then
    echo "- run_context: \`${run_root}/run_context.env\`"
  fi
  echo "- summary: \`${run_root}/summary.tsv\`"
  echo ""

  if [[ -f "${run_root}/run_context.env" ]]; then
    echo "## Run Context"
    echo ""
    echo '```env'
    cat "${run_root}/run_context.env"
    echo '```'
    echo ""
  fi

  for attempts_file in "${run_root}"/*.attempts.tsv; do
    [[ -f "${attempts_file}" ]] || continue
    scenario_name="$(basename "${attempts_file}" .attempts.tsv)"
    scenario_attempt_rows=0
    echo "## Scenario: ${scenario_name}"
    echo ""

    while IFS=$'\t' read -r scenario status attempt attempt_pad acked_count recovered_count lost_count loss_pct stability_status target_start_rc validate_rc; do
      [[ "${scenario}" == "scenario" ]] && continue
      [[ -z "${scenario}" ]] && continue
      scenario_attempt_rows=$((scenario_attempt_rows + 1))

      target_dir="${run_root}/${scenario_name}/attempt-${attempt_pad}/target"
      stability_dir="${target_dir}/stability"
      health_dir="${stability_dir}/health"
      chaos_dir="${target_dir}/chaos"

      offline_partitions="$(read_kv_equals "${stability_dir}/recovery_report.txt" "offline_partitions")"
      under_replicated_partitions="$(read_kv_equals "${stability_dir}/recovery_report.txt" "under_replicated_partitions")"
      metadata_leader_id="$(read_kv_colon "${health_dir}/metadata_quorum_status.txt" "LeaderId")"
      metadata_max_follower_lag="$(read_kv_colon "${health_dir}/metadata_quorum_status.txt" "MaxFollowerLag")"
      jmx_offline_partitions="$(read_jmx_value "${health_dir}/jmx_metrics_final.txt" "OfflinePartitionsCount:Value")"
      jmx_under_replicated="$(read_jmx_value "${health_dir}/jmx_metrics_final.txt" "UnderReplicatedPartitions:Value")"
      consume_rc="$(read_kv_equals "${chaos_dir}/recover_meta.env" "consume_rc")"

      smoke_read_count="0"
      if [[ -f "${health_dir}/smoke.consume.txt" ]]; then
        smoke_read_count="$(grep -c '.' "${health_dir}/smoke.consume.txt" || true)"
      fi

      remediation_rows="0"
      if [[ -f "${stability_dir}/remediation_summary.tsv" ]]; then
        remediation_rows="$(awk -F'\t' 'NR > 1 && $1 != "" {c++} END {print c + 0}' "${stability_dir}/remediation_summary.tsv")"
      fi

      remediation_command_files="0"
      if [[ -d "${stability_dir}/remediations" ]]; then
        remediation_command_files="$(find "${stability_dir}/remediations" -type f -name commands.txt 2>/dev/null | wc -l | tr -d ' ')"
      fi

      unclean_preferred_rc=""
      unclean_election_rc=""
      if [[ -f "${target_dir}/injection_unclean/result.env" ]]; then
        unclean_preferred_rc="$(read_kv_equals "${target_dir}/injection_unclean/result.env" "preferred_election_rc")"
        unclean_election_rc="$(read_kv_equals "${target_dir}/injection_unclean/result.env" "unclean_election_rc")"
      fi

      top_finding="none"
      if [[ -f "${stability_dir}/findings.txt" ]]; then
        top_finding="$(grep -E '^\[[A-Z]+' "${stability_dir}/findings.txt" | head -n 1 | tr '\t' ' ' || true)"
        [[ -n "${top_finding}" ]] || top_finding="none"
      fi

      [[ -n "${offline_partitions}" ]] || offline_partitions="n/a"
      [[ -n "${under_replicated_partitions}" ]] || under_replicated_partitions="n/a"
      [[ -n "${metadata_leader_id}" ]] || metadata_leader_id="n/a"
      [[ -n "${metadata_max_follower_lag}" ]] || metadata_max_follower_lag="n/a"
      [[ -n "${jmx_offline_partitions}" ]] || jmx_offline_partitions="n/a"
      [[ -n "${jmx_under_replicated}" ]] || jmx_under_replicated="n/a"
      [[ -n "${consume_rc}" ]] || consume_rc="n/a"
      [[ -n "${unclean_preferred_rc}" ]] || unclean_preferred_rc="n/a"
      [[ -n "${unclean_election_rc}" ]] || unclean_election_rc="n/a"

      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "${scenario_name}" "${attempt_pad}" "${status}" "${stability_status}" "${acked_count}" "${recovered_count}" "${lost_count}" "${loss_pct}" \
        "${offline_partitions}" "${under_replicated_partitions}" "${metadata_leader_id}" "${metadata_max_follower_lag}" \
        "${jmx_offline_partitions}" "${jmx_under_replicated}" "${consume_rc}" "${smoke_read_count}" \
        "${remediation_rows}" "${remediation_command_files}" "${unclean_preferred_rc}" "${unclean_election_rc}" "${top_finding}" \
        >> "${report_tsv}"

      echo "### Attempt ${attempt_pad}"
      echo "- status: ${status} (stability=${stability_status}, start_rc=${target_start_rc}, validate_rc=${validate_rc})"
      echo "- loss: acked=${acked_count}, recovered=${recovered_count}, lost=${lost_count}, loss_pct=${loss_pct}"
      echo "- symptoms: offline=${offline_partitions}, urp=${under_replicated_partitions}, jmx_offline=${jmx_offline_partitions}, jmx_urp=${jmx_under_replicated}, top_finding=${top_finding}"
      echo "- remediation: rows=${remediation_rows}, command_files=${remediation_command_files}, unclean_pref_rc=${unclean_preferred_rc}, unclean_rc=${unclean_election_rc}"
      echo "- recovery checks: metadata_leader_id=${metadata_leader_id}, max_follower_lag=${metadata_max_follower_lag}, consume_rc=${consume_rc}, smoke_read_count=${smoke_read_count}"
      echo "- evidence: \`${target_dir}/recovery_report.txt\`"
      echo "- evidence: \`${stability_dir}/recovery_report.txt\`"
      if [[ "${lost_count}" != "0" ]]; then
        echo "- evidence: \`${chaos_dir}/lost_ids.sample.txt\`"
      fi
      if [[ -f "${target_dir}/injection_unclean/after/unclean_election.txt" ]]; then
        echo "- evidence: \`${target_dir}/injection_unclean/after/unclean_election.txt\`"
      fi
      echo ""
    done < "${attempts_file}"

    if [[ "${scenario_attempt_rows}" -eq 0 ]]; then
      echo "- no attempts captured in \`${attempts_file}\` (run likely interrupted before validation)."
      echo ""
    fi
  done
} > "${report_md}"

mkdir -p "${ROOT_DIR}/artifacts/latest"
cp "${report_md}" "${ROOT_DIR}/artifacts/latest/phase7b_compact_report.md"
cp "${report_tsv}" "${ROOT_DIR}/artifacts/latest/phase7b_compact_attempts.tsv"

echo "Phase7b compact report written:"
echo "  ${report_md}"
echo "  ${report_tsv}"
