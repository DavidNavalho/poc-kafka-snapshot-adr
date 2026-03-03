#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

run_ref="${1:-latest}"

resolve_run_root() {
  local ref="$1"

  if [[ "${ref}" == "latest" ]]; then
    ls -td "${ROOT_DIR}"/artifacts/phase9-runs/phase9-* 2>/dev/null | head -n 1
    return 0
  fi

  if [[ -d "${ref}" ]]; then
    printf "%s\n" "${ref}"
    return 0
  fi

  if [[ -d "${ROOT_DIR}/artifacts/phase9-runs/${ref}" ]]; then
    printf "%s\n" "${ROOT_DIR}/artifacts/phase9-runs/${ref}"
    return 0
  fi

  return 1
}

read_kv_equals() {
  local file="$1"
  local key="$2"
  awk -F= -v k="${key}" '$1 == k {print $2; exit}' "${file}" 2>/dev/null || true
}

assertion_field() {
  local assertions_file="$1"
  local assertion_name="$2"
  local field_name="$3"
  local field_idx=4

  case "${field_name}" in
    expected) field_idx=2 ;;
    actual) field_idx=3 ;;
    result) field_idx=4 ;;
    critical) field_idx=5 ;;
    note) field_idx=6 ;;
  esac

  awk -F'\t' -v name="${assertion_name}" -v idx="${field_idx}" '
    NR > 1 && $1 == name {print $idx; found = 1; exit}
    END {if (!found) print "na"}
  ' "${assertions_file}" 2>/dev/null || true
}

failed_assertions_from_file() {
  local assertions_file="$1"
  local critical_only="${2:-no}"
  awk -F'\t' -v critical_only="${critical_only}" '
    NR > 1 && $4 == "fail" && (critical_only != "yes" || $5 == "yes") {
      if (out != "") out = out ","
      out = out $1
    }
    END {
      if (out == "") print "none"; else print out
    }
  ' "${assertions_file}" 2>/dev/null || true
}

first_log_signal() {
  local health_dir="$1"
  local signal
  signal="$(grep -Ehi 'Invalid cluster.id|inconsistent clusterId|OutOfOrderSequenceException|ProducerFencedException|InvalidProducerEpochException|CorruptRecordException|recovering segment|Leader: -1' "${health_dir}"/target-broker-*.log 2>/dev/null | head -n 1 | tr '\t' ' ' || true)"
  if [[ -z "${signal}" ]]; then
    echo "none"
  else
    echo "${signal}"
  fi
}

run_root="$(resolve_run_root "${run_ref}" || true)"
if [[ -z "${run_root}" || ! -d "${run_root}" ]]; then
  echo "Unable to resolve phase9 run root from '${run_ref}'." >&2
  exit 1
fi

summary_file="${run_root}/summary.tsv"
if [[ ! -f "${summary_file}" ]]; then
  echo "Missing summary file: ${summary_file}" >&2
  exit 1
fi

run_id="$(basename "${run_root}")"
report_root="${ROOT_DIR}/artifacts/reports/${run_id}"
report_md="${report_root}/phase9_compact_report.md"
report_tsv="${report_root}/phase9_compact_scenarios.tsv"
mkdir -p "${report_root}"

printf "scenario\tstatus\ttarget_start_rc\tvalidate_rc\tassertions_passed\tassertions_failed\tcritical_failed\tfailed_assertions\tcritical_failed_assertions\texpectation_mode\ttarget_ready\tobserved_outcome\tio_smoke_before_sum\tio_smoke_after_sum\tio_smoke_consume_count\tassert_post_restore_io_succeeds\tfirst_log_signal\n" > "${report_tsv}"

{
  echo "# Phase 9 Compact Report (${run_id})"
  echo ""
  echo "- generated_utc: $(timestamp_utc)"
  echo "- run_root: ${run_root}"
  echo "- summary: \`${summary_file}\`"
  echo ""
  echo "## Scenario Summary TSV"
  echo ""
  echo '```tsv'
  cat "${summary_file}"
  echo '```'
  echo ""

  while IFS=$'\t' read -r scenario status target_start_rc validate_rc assertions_passed assertions_failed critical_failed failed_assertions critical_failed_assertions _; do
    [[ "${scenario}" == "scenario" ]] && continue
    [[ -z "${scenario}" ]] && continue

    scenario_root="${run_root}/${scenario}/target/phase9/${scenario}"
    assertions_file="${scenario_root}/assertions.tsv"
    metrics_file="${scenario_root}/scenario_metrics.env"
    report_file="${scenario_root}/recovery_report.txt"
    health_dir="${scenario_root}/health"

    expectation_mode="$(read_kv_equals "${metrics_file}" "expectation_mode")"
    target_ready="$(read_kv_equals "${metrics_file}" "target_ready")"
    observed_outcome="$(read_kv_equals "${metrics_file}" "observed_outcome")"
    io_before="$(read_kv_equals "${metrics_file}" "io_smoke_before_sum")"
    io_after="$(read_kv_equals "${metrics_file}" "io_smoke_after_sum")"
    io_consume_count="$(read_kv_equals "${metrics_file}" "io_smoke_consume_count")"
    post_restore_io_result="$(assertion_field "${assertions_file}" "post_restore_io_succeeds" "result")"
    first_signal="$(first_log_signal "${health_dir}")"
    failed_assertions_from_table="$(failed_assertions_from_file "${assertions_file}" "no")"
    critical_failed_from_table="$(failed_assertions_from_file "${assertions_file}" "yes")"

    [[ -n "${expectation_mode}" ]] || expectation_mode="na"
    [[ -n "${target_ready}" ]] || target_ready="na"
    [[ -n "${observed_outcome}" ]] || observed_outcome="na"
    [[ -n "${io_before}" ]] || io_before="na"
    [[ -n "${io_after}" ]] || io_after="na"
    [[ -n "${io_consume_count}" ]] || io_consume_count="na"
    [[ -n "${post_restore_io_result}" ]] || post_restore_io_result="na"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "${scenario}" "${status}" "${target_start_rc}" "${validate_rc}" "${assertions_passed}" "${assertions_failed}" "${critical_failed}" \
      "${failed_assertions_from_table}" "${critical_failed_from_table}" "${expectation_mode}" "${target_ready}" "${observed_outcome}" \
      "${io_before}" "${io_after}" "${io_consume_count}" "${post_restore_io_result}" "${first_signal}" \
      >> "${report_tsv}"

    echo "## Scenario: ${scenario}"
    echo ""
    echo "- status: ${status} (start_rc=${target_start_rc}, validate_rc=${validate_rc})"
    echo "- assertions: passed=${assertions_passed}, failed=${assertions_failed}, critical_failed=${critical_failed}"
    echo "- failed_assertions: ${failed_assertions_from_table}"
    echo "- expectation_mode: ${expectation_mode}, target_ready=${target_ready}, observed_outcome=${observed_outcome}"
    echo "- io_smoke: before=${io_before}, after=${io_after}, consume_count=${io_consume_count}, assert_post_restore_io_succeeds=${post_restore_io_result}"
    echo "- first_log_signal: ${first_signal}"
    echo ""
    echo "Evidence:"
    echo "- \`${assertions_file}\`"
    echo "- \`${metrics_file}\`"
    echo "- \`${report_file}\`"
    echo "- \`${health_dir}/compose_ps.txt\`"
    echo ""
    echo "Quick checks:"
    echo '```bash'
    echo "awk -F'\t' 'NR==1 || \$4==\"fail\"' \"${assertions_file}\""
    echo "grep -Ehi 'Invalid cluster.id|OutOfOrderSequenceException|ProducerFencedException|InvalidProducerEpochException|CorruptRecordException' \"${health_dir}\"/target-broker-*.log | head -n 20"
    echo "cat \"${metrics_file}\""
    echo '```'
    echo ""
  done < "${summary_file}"
} > "${report_md}"

mkdir -p "${ROOT_DIR}/artifacts/latest"
cp "${report_md}" "${ROOT_DIR}/artifacts/latest/phase9_compact_report.md"
cp "${report_tsv}" "${ROOT_DIR}/artifacts/latest/phase9_compact_scenarios.tsv"

echo "Phase9 compact report written:"
echo "  ${report_md}"
echo "  ${report_tsv}"
