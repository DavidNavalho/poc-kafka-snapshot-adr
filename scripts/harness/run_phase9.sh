#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase9_scenarios.sh
source "${SCRIPT_DIR}/phase9_scenarios.sh"

scenario_selector="${1:-all}"
run_id="${PHASE9_RUN_ID:-phase9-$(timestamp_utc)}"
run_root="${ROOT_DIR}/artifacts/phase9-runs/${run_id}"
summary_file="${run_root}/summary.tsv"
mkdir -p "${run_root}"

append_summary_row() {
  local first=1
  local value=""
  local sanitized=""
  for value in "$@"; do
    sanitized="${value//$'\t'/ }"
    sanitized="${sanitized//$'\n'/ }"
    sanitized="${sanitized//$'\r'/ }"
    if [[ "${first}" -eq 1 ]]; then
      printf "%s" "${sanitized}" >> "${summary_file}"
      first=0
    else
      printf "\t%s" "${sanitized}" >> "${summary_file}"
    fi
  done
  printf "\n" >> "${summary_file}"
}

assertion_result_for() {
  local assertions_file="$1"
  local assertion_name="$2"
  if [[ ! -f "${assertions_file}" ]]; then
    echo "na"
    return 0
  fi
  awk -F'\t' -v assertion_name="${assertion_name}" '
    NR > 1 && $1 == assertion_name {
      print $4
      found = 1
      exit
    }
    END {
      if (!found) {
        print "na"
      }
    }
  ' "${assertions_file}"
}

failed_assertions_for() {
  local assertions_file="$1"
  local critical_only="${2:-no}"
  if [[ ! -f "${assertions_file}" ]]; then
    echo "na"
    return 0
  fi
  awk -F'\t' -v critical_only="${critical_only}" '
    NR > 1 && $4 == "fail" && (critical_only != "yes" || $5 == "yes") {
      if (out != "") {
        out = out ","
      }
      out = out $1
    }
    END {
      if (out == "") {
        print "none"
      } else {
        print out
      }
    }
  ' "${assertions_file}"
}

declare -a scenarios=()
if [[ "${scenario_selector}" == "all" ]]; then
  scenarios=("${PHASE9_SCENARIOS[@]}")
else
  scenarios=("${scenario_selector}")
fi

summary_header=(
  "scenario"
  "status"
  "target_start_rc"
  "validate_rc"
  "assertions_passed"
  "assertions_failed"
  "critical_failed"
  "failed_assertions"
  "critical_failed_assertions"
)
for assertion_name in "${PHASE9_ASSERTION_FIELDS[@]}"; do
  summary_header+=("assert_${assertion_name}")
done
append_summary_row "${summary_header[@]}"

overall_rc=0
for scenario in "${scenarios[@]}"; do
  valid=0
  for expected in "${PHASE9_SCENARIOS[@]}"; do
    if [[ "${scenario}" == "${expected}" ]]; then
      valid=1
      break
    fi
  done
  if [[ "${valid}" -ne 1 ]]; then
    echo "Unknown phase 9 scenario '${scenario}'. Valid: ${PHASE9_SCENARIOS[*]}" >&2
    exit 1
  fi

  echo "==== Phase 9 scenario: ${scenario} ===="
  "${SCRIPT_DIR}/reset_lab.sh"
  "${SCRIPT_DIR}/start_source.sh"
  "${SCRIPT_DIR}/seed_source_phase9.sh"
  "${SCRIPT_DIR}/snapshot_copy_phase9.sh" "${scenario}"

  set +e
  "${SCRIPT_DIR}/start_target_phase9.sh" "${scenario}"
  target_start_rc=$?
  set -e

  set +e
  PHASE9_TARGET_START_RC="${target_start_rc}" "${SCRIPT_DIR}/validate_target_phase9.sh" "${scenario}"
  validate_rc=$?
  set -e

  status="unknown"
  assertions_passed=0
  assertions_failed=0
  critical_failed=0

  status_file="${ROOT_DIR}/artifacts/latest/target/phase9/${scenario}/status.txt"
  summary_env_file="${ROOT_DIR}/artifacts/latest/target/phase9/${scenario}/assertions_summary.env"
  if [[ -f "${status_file}" ]]; then
    status="$(tr -d '\r\n' < "${status_file}")"
  elif [[ "${validate_rc}" -eq 0 ]]; then
    status="recovered"
  else
    status="failed"
  fi

  if [[ -f "${summary_env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${summary_env_file}"
    assertions_passed="${assertions_passed:-0}"
    assertions_failed="${assertions_failed:-0}"
    critical_failed="${critical_failed:-0}"
  fi
  assertions_file="${ROOT_DIR}/artifacts/latest/target/phase9/${scenario}/assertions.tsv"
  failed_assertions="$(failed_assertions_for "${assertions_file}" "no")"
  critical_failed_assertions="$(failed_assertions_for "${assertions_file}" "yes")"

  scenario_dir="${run_root}/${scenario}"
  mkdir -p "${scenario_dir}"
  if [[ -d "${ROOT_DIR}/artifacts/latest/source" ]]; then
    cp -R "${ROOT_DIR}/artifacts/latest/source" "${scenario_dir}/source"
  fi
  if [[ -d "${ROOT_DIR}/artifacts/latest/target" ]]; then
    cp -R "${ROOT_DIR}/artifacts/latest/target" "${scenario_dir}/target"
  fi
  if [[ -f "${ROOT_DIR}/artifacts/latest/snapshot_id.txt" ]]; then
    cp "${ROOT_DIR}/artifacts/latest/snapshot_id.txt" "${scenario_dir}/snapshot_id.txt"
  fi

  summary_row=(
    "${scenario}"
    "${status}"
    "${target_start_rc}"
    "${validate_rc}"
    "${assertions_passed}"
    "${assertions_failed}"
    "${critical_failed}"
    "${failed_assertions}"
    "${critical_failed_assertions}"
  )
  for assertion_name in "${PHASE9_ASSERTION_FIELDS[@]}"; do
    summary_row+=("$(assertion_result_for "${assertions_file}" "${assertion_name}")")
  done
  append_summary_row "${summary_row[@]}"

  if [[ "${validate_rc}" -ne 0 ]]; then
    overall_rc=1
  fi
done

mkdir -p "${ROOT_DIR}/artifacts/latest"
cp "${summary_file}" "${ROOT_DIR}/artifacts/latest/phase9_summary.tsv"

echo "Phase 9 run summary: ${summary_file}"
if [[ "${overall_rc}" -ne 0 ]]; then
  echo "At least one scenario ended in failed state."
  exit 1
fi
echo "Phase 9 scenarios completed (recovered/degraded states accepted)."
