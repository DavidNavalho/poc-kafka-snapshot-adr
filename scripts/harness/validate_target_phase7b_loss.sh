#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase7b_loss_scenarios.sh
source "${SCRIPT_DIR}/phase7b_loss_scenarios.sh"

SCENARIO="${1:?scenario is required}"
ATTEMPT="${2:-1}"
ATTEMPT_PAD="$(printf '%02d' "${ATTEMPT}")"
TARGET_START_RC="${PHASE7B_TARGET_START_RC:-0}"

SOURCE_CHAOS_DIR="${ROOT_DIR}/artifacts/latest/source/phase7b/${SCENARIO}/attempt-${ATTEMPT_PAD}/chaos"
TARGET_ATTEMPT_DIR="${ROOT_DIR}/artifacts/latest/target/phase7b/${SCENARIO}/attempt-${ATTEMPT_PAD}"
TARGET_CHAOS_DIR="${TARGET_ATTEMPT_DIR}/chaos"
TARGET_STABILITY_DIR="${TARGET_ATTEMPT_DIR}/stability"
mkdir -p "${TARGET_CHAOS_DIR}" "${TARGET_STABILITY_DIR}"

STATUS_FILE="${TARGET_ATTEMPT_DIR}/status.txt"
REPORT_FILE="${TARGET_ATTEMPT_DIR}/recovery_report.txt"
ATTEMPT_RESULT_FILE="${TARGET_ATTEMPT_DIR}/attempt_result.env"
LOSS_METRICS_FILE="${TARGET_ATTEMPT_DIR}/loss_metrics.tsv"

count_lines() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo 0
    return 0
  fi
  wc -l < "${file}" | tr -d ' '
}

inject_unclean_target_loss() {
  local inject_dir="${TARGET_ATTEMPT_DIR}/injection_unclean"
  mkdir -p "${inject_dir}/before" "${inject_dir}/after"

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe --topic ${PHASE7B_CHAOS_TOPIC}" \
    > "${inject_dir}/before/topic_describe.txt" 2>&1 || true

  set +e
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-leader-election --bootstrap-server ${TARGET_BOOTSTRAP} --election-type preferred --topic ${PHASE7B_CHAOS_TOPIC} --partition ${PHASE7B_CHAOS_PARTITION}" \
    > "${inject_dir}/before/preferred_election.txt" 2>&1
  pref_rc=$?
  set -e

  compose_cmd kill target-broker-1 >/dev/null 2>&1 || true
  sleep 3

  set +e
  compose_cmd exec -T target-broker-2 bash -lc \
    "kafka-leader-election --bootstrap-server target-broker-2:9092 --election-type unclean --topic ${PHASE7B_CHAOS_TOPIC} --partition ${PHASE7B_CHAOS_PARTITION}" \
    > "${inject_dir}/after/unclean_election.txt" 2>&1
  unclean_rc=$?
  set -e

  compose_cmd up -d target-broker-1 >/dev/null
  wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 90 || true

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe --topic ${PHASE7B_CHAOS_TOPIC}" \
    > "${inject_dir}/after/topic_describe.txt" 2>&1 || true

  echo "preferred_election_rc=${pref_rc}" > "${inject_dir}/result.env"
  echo "unclean_election_rc=${unclean_rc}" >> "${inject_dir}/result.env"
}

run_stability_validation() {
  local stability_tag="phase7b-${SCENARIO}-a${ATTEMPT_PAD}"
  local stability_source_dir="${ROOT_DIR}/artifacts/latest/target/phase7/${stability_tag}"
  local stability_status="failed"
  local stability_stdout_log="${TARGET_ATTEMPT_DIR}/phase7_validate.stdout.log"

  set +e
  PHASE7_TARGET_START_RC="${TARGET_START_RC}" "${SCRIPT_DIR}/validate_target_phase7.sh" "${stability_tag}" \
    > "${stability_stdout_log}" 2>&1
  stability_rc=$?
  set -e

  if [[ -f "${stability_source_dir}/status.txt" ]]; then
    stability_status="$(tr -d '\r\n' < "${stability_source_dir}/status.txt")"
  elif [[ "${stability_rc}" -eq 0 ]]; then
    stability_status="recovered"
  fi

  rm -rf "${TARGET_STABILITY_DIR}"
  mkdir -p "${TARGET_STABILITY_DIR}"
  if [[ -d "${stability_source_dir}" ]]; then
    cp -R "${stability_source_dir}/." "${TARGET_STABILITY_DIR}/"
  fi

  echo "${stability_status}"
}

if [[ ! -f "${SOURCE_CHAOS_DIR}/acked_ids.txt" ]]; then
  echo "Missing source acked ids file: ${SOURCE_CHAOS_DIR}/acked_ids.txt" >&2
  echo "failed" > "${STATUS_FILE}"
  exit 2
fi

cp "${SOURCE_CHAOS_DIR}/acked_ids.txt" "${TARGET_CHAOS_DIR}/acked_ids.txt"
cp "${SOURCE_CHAOS_DIR}/verifiable_producer.raw.log" "${TARGET_CHAOS_DIR}/source_verifiable_producer.raw.log" 2>/dev/null || true

if [[ "${SCENARIO}" == "loss-acks1-unclean-target" ]]; then
  inject_unclean_target_loss
fi

stability_status="$(run_stability_validation)"

set +e
compose_cmd exec -T target-broker-1 bash -lc \
  "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${PHASE7B_CHAOS_TOPIC} --from-beginning --timeout-ms 10000 2>/dev/null" \
  > "${TARGET_CHAOS_DIR}/recovered.raw.txt"
consume_rc=$?
set -e
echo "consume_rc=${consume_rc}" > "${TARGET_CHAOS_DIR}/recover_meta.env"

grep -E '^[0-9]+$' "${TARGET_CHAOS_DIR}/recovered.raw.txt" | LC_ALL=C sort -n -u > "${TARGET_CHAOS_DIR}/recovered_ids.txt" || true

LC_ALL=C sort -n "${TARGET_CHAOS_DIR}/acked_ids.txt" > "${TARGET_CHAOS_DIR}/acked_ids.sorted.txt"
LC_ALL=C sort -n "${TARGET_CHAOS_DIR}/recovered_ids.txt" > "${TARGET_CHAOS_DIR}/recovered_ids.sorted.txt"

comm -23 "${TARGET_CHAOS_DIR}/acked_ids.sorted.txt" "${TARGET_CHAOS_DIR}/recovered_ids.sorted.txt" > "${TARGET_CHAOS_DIR}/lost_ids.txt"
comm -13 "${TARGET_CHAOS_DIR}/acked_ids.sorted.txt" "${TARGET_CHAOS_DIR}/recovered_ids.sorted.txt" > "${TARGET_CHAOS_DIR}/unexpected_ids.txt"
head -n 200 "${TARGET_CHAOS_DIR}/lost_ids.txt" > "${TARGET_CHAOS_DIR}/lost_ids.sample.txt"

acked_count="$(count_lines "${TARGET_CHAOS_DIR}/acked_ids.sorted.txt")"
recovered_count="$(count_lines "${TARGET_CHAOS_DIR}/recovered_ids.sorted.txt")"
lost_count="$(count_lines "${TARGET_CHAOS_DIR}/lost_ids.txt")"
unexpected_count="$(count_lines "${TARGET_CHAOS_DIR}/unexpected_ids.txt")"

if [[ "${acked_count}" -gt 0 ]]; then
  loss_pct="$(awk -v a="${acked_count}" -v l="${lost_count}" 'BEGIN {printf "%.4f", (l / a) * 100.0}')"
else
  loss_pct="0.0000"
fi

printf "metric\tvalue\n" > "${LOSS_METRICS_FILE}"
printf "acked_count\t%s\n" "${acked_count}" >> "${LOSS_METRICS_FILE}"
printf "recovered_count\t%s\n" "${recovered_count}" >> "${LOSS_METRICS_FILE}"
printf "lost_count\t%s\n" "${lost_count}" >> "${LOSS_METRICS_FILE}"
printf "unexpected_count\t%s\n" "${unexpected_count}" >> "${LOSS_METRICS_FILE}"
printf "loss_pct\t%s\n" "${loss_pct}" >> "${LOSS_METRICS_FILE}"
printf "stability_status\t%s\n" "${stability_status}" >> "${LOSS_METRICS_FILE}"

status="recovered_no_loss"
if [[ "${stability_status}" == "failed" ]]; then
  status="failed"
elif [[ "${acked_count}" -eq 0 ]]; then
  status="failed"
elif [[ "${recovered_count}" -eq 0 && "${PHASE7B_ABORT_IF_ALL_LOST}" == "true" ]]; then
  status="failed"
elif [[ "${lost_count}" -gt 0 ]]; then
  if [[ "${stability_status}" == "degraded" ]]; then
    status="degraded_with_loss"
  else
    status="recovered_with_loss"
  fi
elif [[ "${SCENARIO}" == "loss-acks1-unclean-target" ]]; then
  status="degraded_no_loss"
elif [[ "${stability_status}" == "degraded" ]]; then
  status="degraded"
fi

{
  echo "scenario=${SCENARIO}"
  echo "attempt=${ATTEMPT_PAD}"
  echo "status=${status}"
  echo "stability_status=${stability_status}"
  echo "acked_count=${acked_count}"
  echo "recovered_count=${recovered_count}"
  echo "lost_count=${lost_count}"
  echo "unexpected_count=${unexpected_count}"
  echo "loss_pct=${loss_pct}"
} > "${ATTEMPT_RESULT_FILE}"

{
  echo "scenario=${SCENARIO}"
  echo "attempt=${ATTEMPT_PAD}"
  echo "status=${status}"
  echo "stability_status=${stability_status}"
  echo "acked_count=${acked_count}"
  echo "recovered_count=${recovered_count}"
  echo "lost_count=${lost_count}"
  echo "unexpected_count=${unexpected_count}"
  echo "loss_pct=${loss_pct}"
  echo ""
  echo "loss_metrics:"
  cat "${LOSS_METRICS_FILE}"
  echo ""
  echo "stability_report:"
  if [[ -f "${TARGET_STABILITY_DIR}/recovery_report.txt" ]]; then
    cat "${TARGET_STABILITY_DIR}/recovery_report.txt"
  else
    echo "missing"
  fi
} > "${REPORT_FILE}"

echo "${status}" > "${STATUS_FILE}"
echo "Phase7b validation (${SCENARIO}, attempt ${ATTEMPT_PAD}) status: ${status}"
echo "Report: ${REPORT_FILE}"

if [[ "${status}" == "failed" ]]; then
  exit 2
fi
