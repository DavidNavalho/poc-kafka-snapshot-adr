#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

run_ref="${1:-all}" # all|latest|<run-id>|<run-root>

PRUNE_PHASE7B_RUN_PAYLOADS="${PRUNE_PHASE7B_RUN_PAYLOADS:-true}"
PRUNE_SNAPSHOTS="${PRUNE_SNAPSHOTS:-true}"
PRUNE_LATEST="${PRUNE_LATEST:-true}"
KEEP_SNAPSHOTS_COUNT="${KEEP_SNAPSHOTS_COUNT:-0}"
FORCE_REGENERATE_COMPACT="${FORCE_REGENERATE_COMPACT:-false}"

proof_root_base="${ROOT_DIR}/artifacts/proof/phase7b"
reports_root="${ROOT_DIR}/artifacts/reports"
phase7b_runs_root="${ROOT_DIR}/artifacts/phase7b-runs"
snapshots_root="${ROOT_DIR}/artifacts/snapshots"
latest_root="${ROOT_DIR}/artifacts/latest"
prune_errors=0

mkdir -p "${proof_root_base}" "${reports_root}"

resolve_run_roots() {
  local ref="$1"
  local latest_run
  shopt -s nullglob

  if [[ "${ref}" == "all" ]]; then
    for d in "${phase7b_runs_root}"/phase7b-*; do
      [[ -d "${d}" ]] && printf "%s\n" "${d}"
    done
    return 0
  fi

  if [[ "${ref}" == "latest" ]]; then
    latest_run="$(ls -td "${phase7b_runs_root}"/phase7b-* 2>/dev/null | head -n 1 || true)"
    [[ -n "${latest_run}" ]] && printf "%s\n" "${latest_run}"
    return 0
  fi

  if [[ -d "${ref}" ]]; then
    printf "%s\n" "${ref}"
    return 0
  fi

  if [[ -d "${phase7b_runs_root}/${ref}" ]]; then
    printf "%s\n" "${phase7b_runs_root}/${ref}"
    return 0
  fi

  return 1
}

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -f "${src}" ]]; then
    mkdir -p "$(dirname "${dst}")"
    cp "${src}" "${dst}"
  fi
}

run_has_attempt_payload() {
  local run_root="$1"
  find "${run_root}" -type d -name 'attempt-*' -print -quit 2>/dev/null | grep -q .
}

collect_run_proof() {
  local run_root="$1"
  local run_id proof_root report_dir
  run_id="$(basename "${run_root}")"
  proof_root="${proof_root_base}/${run_id}"
  report_dir="${reports_root}/${run_id}"

  mkdir -p "${proof_root}" "${report_dir}"

  if [[ "${FORCE_REGENERATE_COMPACT}" == "true" || ! -f "${report_dir}/compact_report.md" || ! -f "${report_dir}/compact_attempts.tsv" ]]; then
    if run_has_attempt_payload "${run_root}"; then
      "${SCRIPT_DIR}/generate_phase7b_compact_report.sh" "${run_root}" >/dev/null || true
    fi
  fi

  copy_if_exists "${run_root}/summary.tsv" "${proof_root}/summary.tsv"
  copy_if_exists "${run_root}/run_context.env" "${proof_root}/run_context.env"
  for attempts_file in "${run_root}"/*.attempts.tsv; do
    [[ -f "${attempts_file}" ]] || continue
    copy_if_exists "${attempts_file}" "${proof_root}/$(basename "${attempts_file}")"
  done

  copy_if_exists "${report_dir}/compact_report.md" "${proof_root}/compact_report.md"
  copy_if_exists "${report_dir}/compact_attempts.tsv" "${proof_root}/compact_attempts.tsv"

  shopt -s nullglob
  for scenario_dir in "${run_root}"/*; do
    [[ -d "${scenario_dir}" ]] || continue
    scenario_name="$(basename "${scenario_dir}")"
    for attempt_dir in "${scenario_dir}"/attempt-*; do
      [[ -d "${attempt_dir}" ]] || continue
      attempt_name="$(basename "${attempt_dir}")"
      attempt_proof="${proof_root}/attempts/${scenario_name}/${attempt_name}"
      mkdir -p "${attempt_proof}"

      copy_if_exists "${attempt_dir}/snapshot_id.txt" "${attempt_proof}/snapshot_id.txt"

      copy_if_exists "${attempt_dir}/target/attempt_result.env" "${attempt_proof}/target/attempt_result.env"
      copy_if_exists "${attempt_dir}/target/loss_metrics.tsv" "${attempt_proof}/target/loss_metrics.tsv"
      copy_if_exists "${attempt_dir}/target/recovery_report.txt" "${attempt_proof}/target/recovery_report.txt"
      copy_if_exists "${attempt_dir}/target/status.txt" "${attempt_proof}/target/status.txt"
      copy_if_exists "${attempt_dir}/target/chaos/lost_ids.sample.txt" "${attempt_proof}/target/chaos/lost_ids.sample.txt"
      copy_if_exists "${attempt_dir}/target/chaos/recover_meta.env" "${attempt_proof}/target/chaos/recover_meta.env"
      copy_if_exists "${attempt_dir}/target/injection_unclean/result.env" "${attempt_proof}/target/injection_unclean/result.env"

      copy_if_exists "${attempt_dir}/target/stability/recovery_report.txt" "${attempt_proof}/target/stability/recovery_report.txt"
      copy_if_exists "${attempt_dir}/target/stability/findings.txt" "${attempt_proof}/target/stability/findings.txt"
      copy_if_exists "${attempt_dir}/target/stability/fixes.txt" "${attempt_proof}/target/stability/fixes.txt"
      copy_if_exists "${attempt_dir}/target/stability/remediation_summary.tsv" "${attempt_proof}/target/stability/remediation_summary.tsv"
      copy_if_exists "${attempt_dir}/target/stability/health/metadata_quorum_status.txt" "${attempt_proof}/target/stability/health/metadata_quorum_status.txt"
      copy_if_exists "${attempt_dir}/target/stability/health/jmx_metrics_final.txt" "${attempt_proof}/target/stability/health/jmx_metrics_final.txt"
      copy_if_exists "${attempt_dir}/target/stability/health/smoke.before_offsets.txt" "${attempt_proof}/target/stability/health/smoke.before_offsets.txt"
      copy_if_exists "${attempt_dir}/target/stability/health/smoke.after_offsets.txt" "${attempt_proof}/target/stability/health/smoke.after_offsets.txt"
      copy_if_exists "${attempt_dir}/target/stability/health/smoke.consume.err" "${attempt_proof}/target/stability/health/smoke.consume.err"
    done
  done

  {
    echo "run_id=${run_id}"
    echo "proof_generated_utc=$(timestamp_utc)"
    echo "source_run_root=${run_root}"
    echo "proof_root=${proof_root}"
    echo "report_dir=${report_dir}"
  } > "${proof_root}/manifest.env"
}

prune_run_payload() {
  local run_root="$1"
  shopt -s nullglob
  for d in "${run_root}"/*; do
    [[ -d "${d}" ]] || continue
    if ! safe_rm_tree "${d}"; then
      prune_errors=$((prune_errors + 1))
    fi
  done
}

safe_rm_tree() {
  local path="$1"
  local i
  if [[ ! -e "${path}" ]]; then
    return 0
  fi

  for i in 1 2 3; do
    set +e
    rm -rf "${path}" 2>/dev/null
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 && ! -e "${path}" ]]; then
      return 0
    fi
    sleep 1
  done

  set +e
  chmod -R u+w "${path}" 2>/dev/null
  find "${path}" -depth -type f -exec rm -f {} + 2>/dev/null
  find "${path}" -depth -type d -exec rmdir {} + 2>/dev/null
  rm -rf "${path}" 2>/dev/null
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 && ! -e "${path}" ]]; then
    return 0
  fi

  echo "WARN: unable to fully delete ${path}" >&2
  return 1
}

prune_snapshots() {
  local keep_count="$1"
  local idx=0
  shopt -s nullglob
  local snapshots=("${snapshots_root}"/*)
  if [[ "${#snapshots[@]}" -eq 0 ]]; then
    return 0
  fi

  IFS=$'\n' snapshots=($(ls -1dt "${snapshots_root}"/* 2>/dev/null))
  for snap in "${snapshots[@]}"; do
    idx=$((idx + 1))
    if [[ "${idx}" -le "${keep_count}" ]]; then
      continue
    fi
    if ! safe_rm_tree "${snap}"; then
      prune_errors=$((prune_errors + 1))
    fi
  done
}

prune_latest_payload() {
  rm -rf "${latest_root}/source" "${latest_root}/target"
}

before_total_kb="$(du -sk "${ROOT_DIR}/artifacts" 2>/dev/null | awk '{print $1}')"

runs_found=0
while IFS= read -r run_root; do
  [[ -d "${run_root}" ]] || continue
  runs_found=$((runs_found + 1))
  collect_run_proof "${run_root}"
  if [[ "${PRUNE_PHASE7B_RUN_PAYLOADS}" == "true" ]]; then
    prune_run_payload "${run_root}"
  fi
done < <(resolve_run_roots "${run_ref}" || true)

if [[ "${PRUNE_SNAPSHOTS}" == "true" ]]; then
  prune_snapshots "${KEEP_SNAPSHOTS_COUNT}"
fi

if [[ "${PRUNE_LATEST}" == "true" ]]; then
  set +e
  prune_latest_payload
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    prune_errors=$((prune_errors + 1))
  fi
fi

mkdir -p "${latest_root}"
latest_prune_summary="${latest_root}/prune_summary.txt"
after_total_kb="$(du -sk "${ROOT_DIR}/artifacts" 2>/dev/null | awk '{print $1}')"
freed_kb=$((before_total_kb - after_total_kb))

{
  echo "run_ref=${run_ref}"
  echo "runs_processed=${runs_found}"
  echo "PRUNE_PHASE7B_RUN_PAYLOADS=${PRUNE_PHASE7B_RUN_PAYLOADS}"
  echo "PRUNE_SNAPSHOTS=${PRUNE_SNAPSHOTS}"
  echo "PRUNE_LATEST=${PRUNE_LATEST}"
  echo "KEEP_SNAPSHOTS_COUNT=${KEEP_SNAPSHOTS_COUNT}"
  echo "before_kb=${before_total_kb}"
  echo "after_kb=${after_total_kb}"
  echo "freed_kb=${freed_kb}"
  echo "freed_gb=$(awk -v kb="${freed_kb}" 'BEGIN {printf "%.2f", kb/1024/1024}')"
  echo "prune_errors=${prune_errors}"
} | tee "${latest_prune_summary}"

echo "Proof bundles: ${proof_root_base}"
echo "Prune summary: ${latest_prune_summary}"

if [[ "${prune_errors}" -ne 0 ]]; then
  exit 1
fi
