#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase7_scenarios.sh
source "${SCRIPT_DIR}/phase7_scenarios.sh"

scenario_selector="${1:-all}"
run_id="phase7-$(timestamp_utc)"
run_root="${ROOT_DIR}/artifacts/phase7-runs/${run_id}"
summary_file="${run_root}/summary.tsv"
mkdir -p "${run_root}"

declare -a scenarios=()
if [[ "${scenario_selector}" == "all" ]]; then
  scenarios=("${PHASE7_SCENARIOS[@]}")
else
  scenarios=("${scenario_selector}")
fi

printf "scenario\tstatus\ttarget_start_rc\tvalidate_rc\n" > "${summary_file}"

overall_rc=0
for scenario in "${scenarios[@]}"; do
  valid=0
  for expected in "${PHASE7_SCENARIOS[@]}"; do
    if [[ "${scenario}" == "${expected}" ]]; then
      valid=1
      break
    fi
  done
  if [[ "${valid}" -ne 1 ]]; then
    echo "Unknown phase 7 scenario '${scenario}'. Valid: ${PHASE7_SCENARIOS[*]}" >&2
    exit 1
  fi

  echo "==== Phase 7 scenario: ${scenario} ===="
  "${SCRIPT_DIR}/reset_lab.sh"
  "${SCRIPT_DIR}/start_source.sh"
  "${SCRIPT_DIR}/seed_source_phase7.sh"
  "${SCRIPT_DIR}/snapshot_copy_phase7.sh" "${scenario}"

  set +e
  "${SCRIPT_DIR}/start_target.sh"
  target_start_rc=$?
  set -e

  set +e
  PHASE7_TARGET_START_RC="${target_start_rc}" "${SCRIPT_DIR}/validate_target_phase7.sh" "${scenario}"
  validate_rc=$?
  set -e

  status="unknown"
  if [[ -f "${ROOT_DIR}/artifacts/latest/target/phase7/${scenario}/status.txt" ]]; then
    status="$(cat "${ROOT_DIR}/artifacts/latest/target/phase7/${scenario}/status.txt")"
  elif [[ "${validate_rc}" -eq 0 ]]; then
    status="recovered"
  else
    status="failed"
  fi

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

  printf "%s\t%s\t%s\t%s\n" "${scenario}" "${status}" "${target_start_rc}" "${validate_rc}" >> "${summary_file}"

  if [[ "${validate_rc}" -ne 0 ]]; then
    overall_rc=1
  fi
done

mkdir -p "${ROOT_DIR}/artifacts/latest"
cp "${summary_file}" "${ROOT_DIR}/artifacts/latest/phase7_summary.tsv"

echo "Phase 7 run summary: ${summary_file}"
if [[ "${overall_rc}" -ne 0 ]]; then
  echo "At least one scenario ended in failed state."
  exit 1
fi
echo "Phase 7 scenarios completed (recovered/degraded states accepted)."
