#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase9_scenarios.sh
source "${SCRIPT_DIR}/phase9_scenarios.sh"

SCENARIO="${1:-new-identity-direct-import}"
TARGET_START_RC="${PHASE9_TARGET_START_RC:-0}"

is_valid=0
for expected in "${PHASE9_SCENARIOS[@]}"; do
  if [[ "${SCENARIO}" == "${expected}" ]]; then
    is_valid=1
    break
  fi
done
if [[ "${is_valid}" -ne 1 ]]; then
  echo "Unknown phase9 scenario '${SCENARIO}'. Valid: ${PHASE9_SCENARIOS[*]}" >&2
  exit 1
fi

mode="$(phase9_expectation_mode "${SCENARIO}" || true)"
if [[ -z "${mode}" ]]; then
  echo "No expectation profile for phase9 scenario '${SCENARIO}'." >&2
  exit 1
fi

SOURCE_RUNTIME_ENV="${ROOT_DIR}/artifacts/latest/source/phase9/runtime/phase9_runtime.env"
TARGET_SCENARIO_DIR="${ROOT_DIR}/artifacts/latest/target/phase9/${SCENARIO}"
TARGET_HEALTH_DIR="${TARGET_SCENARIO_DIR}/health"
TARGET_ASSERTIONS_FILE="${TARGET_SCENARIO_DIR}/assertions.tsv"
TARGET_ASSERTIONS_ENV="${TARGET_SCENARIO_DIR}/assertions_summary.env"
TARGET_METRICS_FILE="${TARGET_SCENARIO_DIR}/scenario_metrics.env"
TARGET_REPORT_FILE="${TARGET_SCENARIO_DIR}/recovery_report.txt"
TARGET_STATUS_FILE="${TARGET_SCENARIO_DIR}/status.txt"
TARGET_MUTATION_ENV="${TARGET_SCENARIO_DIR}/mutation.env"
mkdir -p "${TARGET_SCENARIO_DIR}" "${TARGET_HEALTH_DIR}"

if [[ ! -f "${SOURCE_RUNTIME_ENV}" ]]; then
  echo "Missing source runtime env: ${SOURCE_RUNTIME_ENV}" >&2
  exit 1
fi
if [[ ! -f "${TARGET_MUTATION_ENV}" ]]; then
  echo "Missing mutation env: ${TARGET_MUTATION_ENV}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${SOURCE_RUNTIME_ENV}"
# shellcheck disable=SC1090
source "${TARGET_MUTATION_ENV}"

status="recovered"
assertions_passed=0
assertions_failed=0
critical_failed=0
printf "assertion\texpected\tactual\tresult\tcritical\tnote\n" > "${TARGET_ASSERTIONS_FILE}"
: > "${TARGET_METRICS_FILE}"

record_assertion() {
  local assertion="$1"
  local expected="$2"
  local actual="$3"
  local critical="$4"
  local note="$5"
  local result="pass"

  if [[ "${actual}" != "${expected}" ]]; then
    result="fail"
    assertions_failed=$((assertions_failed + 1))
    if [[ "${critical}" == "yes" ]]; then
      critical_failed=$((critical_failed + 1))
      status="failed"
    elif [[ "${status}" != "failed" ]]; then
      status="degraded"
    fi
  else
    assertions_passed=$((assertions_passed + 1))
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${assertion}" "${expected}" "${actual}" "${result}" "${critical}" "${note}" \
    >> "${TARGET_ASSERTIONS_FILE}"
}

sum_end_offsets_file() {
  local file="$1"
  awk -F: 'NF >= 3 && $3 ~ /^[0-9]+$/ {sum += $3} END {print sum + 0}' "${file}"
}

run_post_restore_io_smoke() {
  local marker="phase9-smoke-${SCENARIO}"
  local before_raw="${TARGET_HEALTH_DIR}/${marker}.before_offsets.raw"
  local before_sorted="${TARGET_HEALTH_DIR}/${marker}.before_offsets.txt"
  local after_raw="${TARGET_HEALTH_DIR}/${marker}.after_offsets.raw"
  local after_sorted="${TARGET_HEALTH_DIR}/${marker}.after_offsets.txt"
  local consume_file="${TARGET_HEALTH_DIR}/${marker}.consume.txt"
  local consume_err_file="${TARGET_HEALTH_DIR}/${marker}.consume.err"
  local before_sum=0
  local after_sum=0
  local consume_count=0

  set +e
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${source_topic} --time -1" \
    > "${before_raw}" 2> "${TARGET_HEALTH_DIR}/${marker}.before_offsets.err"
  local before_rc=$?
  set -e
  if [[ "${before_rc}" -ne 0 ]]; then
    echo "io_smoke_before_offsets_rc=${before_rc}" >> "${TARGET_METRICS_FILE}"
    return 1
  fi
  LC_ALL=C sort "${before_raw}" > "${before_sorted}"
  before_sum="$(sum_end_offsets_file "${before_sorted}")"

  set +e
  seq 1 "${PHASE9_SMOKE_MESSAGES}" \
    | awk -v scenario="${SCENARIO}" '{printf "%s-smoke-%03d:{\"event\":\"phase9-smoke\",\"seq\":%d}\n", scenario, $1, $1}' \
    | compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-console-producer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${source_topic} --property parse.key=true --property key.separator=: >/dev/null"
  local produce_rc=$?
  set -e
  if [[ "${produce_rc}" -ne 0 ]]; then
    echo "io_smoke_produce_rc=${produce_rc}" >> "${TARGET_METRICS_FILE}"
    return 1
  fi

  set +e
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${source_topic} --time -1" \
    > "${after_raw}" 2> "${TARGET_HEALTH_DIR}/${marker}.after_offsets.err"
  local after_rc=$?
  set -e
  if [[ "${after_rc}" -ne 0 ]]; then
    echo "io_smoke_after_offsets_rc=${after_rc}" >> "${TARGET_METRICS_FILE}"
    return 1
  fi
  LC_ALL=C sort "${after_raw}" > "${after_sorted}"
  after_sum="$(sum_end_offsets_file "${after_sorted}")"

  set +e
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${source_topic} --from-beginning --max-messages ${PHASE9_SMOKE_CONSUME} --timeout-ms 10000 >/tmp/${marker}.consume.txt 2>/tmp/${marker}.consume.err"
  local consume_rc=$?
  set -e
  compose_cmd exec -T target-broker-1 bash -lc "cat /tmp/${marker}.consume.txt || true" > "${consume_file}"
  compose_cmd exec -T target-broker-1 bash -lc "cat /tmp/${marker}.consume.err || true" > "${consume_err_file}"
  consume_count="$(wc -l < "${consume_file}" | tr -d ' ')"

  echo "io_smoke_before_sum=${before_sum}" >> "${TARGET_METRICS_FILE}"
  echo "io_smoke_after_sum=${after_sum}" >> "${TARGET_METRICS_FILE}"
  echo "io_smoke_consume_rc=${consume_rc}" >> "${TARGET_METRICS_FILE}"
  echo "io_smoke_consume_count=${consume_count}" >> "${TARGET_METRICS_FILE}"

  if [[ "${after_sum}" -lt $((before_sum + PHASE9_SMOKE_MESSAGES)) ]]; then
    return 1
  fi
  if [[ "${consume_rc}" -ne 0 || "${consume_count}" -le 0 ]]; then
    return 1
  fi
  return 0
}

if [[ "${mode}" == "blocked" ]]; then
  # direct-import: broker formats fresh (meta.properties and KRaft metadata deleted before boot).
  # The cluster itself becomes reachable, but source-topic partition directories carry old UUIDs
  # that do not match freshly-registered KRaft topics → Kafka renames them to <dir>-stray (§4.13).
  # The source topic is inaccessible (partitions offline / stray) so I/O smoke must fail.
  expected_start_failed="no"
  expected_cluster_unreachable="no"
  expected_invalid_cluster_id_logged="no"
  expected_stray_dirs_found="yes"
  expected_direct_import_blocked="yes"
  expected_post_restore_io="no"
  post_restore_io_critical="no"
  post_restore_io_note="Blocked profile: I/O must fail because source-topic partitions become stray (§4.13)"
else
  expected_start_failed="no"
  expected_cluster_unreachable="no"
  expected_invalid_cluster_id_logged="no"
  expected_stray_dirs_found="no"
  expected_direct_import_blocked="no"
  expected_post_restore_io="yes"
  post_restore_io_critical="yes"
  post_restore_io_note="Allowed profile safety gate: post-restore produce/consume must work"
fi

target_ready="no"
if wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 3; then
  target_ready="yes"
fi

start_failed_actual="$([[ "${TARGET_START_RC}" -ne 0 ]] && echo yes || echo no)"
cluster_unreachable_actual="$([[ "${target_ready}" == "no" ]] && echo yes || echo no)"
record_assertion "start_target_expected_failure" "${expected_start_failed}" "${start_failed_actual}" "no" "ADR expectation profile (${mode}) for target startup return code"
record_assertion "cluster_unreachable" "${expected_cluster_unreachable}" "${cluster_unreachable_actual}" "no" "ADR expectation profile (${mode}) for target bootstrap reachability"

invalid_cluster_id_logged="no"
if grep -Eiq 'Invalid cluster.id|Expected .* but read|inconsistent clusterId|cluster id mismatch' "${TARGET_HEALTH_DIR}"/target-broker-*.log; then
  invalid_cluster_id_logged="yes"
fi
record_assertion "invalid_cluster_id_logged" "${expected_invalid_cluster_id_logged}" "${invalid_cluster_id_logged}" "no" "§4.1: cluster-id mismatch log; absent for fresh-format import (§4.13 path)"

rewritten_ok="yes"
for broker in 1 2 3; do
  meta_file="${ROOT_DIR}/data/target/broker${broker}/meta.properties"
  current_id="$(grep '^cluster.id=' "${meta_file}" 2>/dev/null | cut -d= -f2 || true)"
  if [[ "${current_id}" != "${phase9_target_cluster_id}" ]]; then
    rewritten_ok="no"
  fi
done
record_assertion "rewritten_cluster_id_applied" "yes" "${rewritten_ok}" "yes" "target meta.properties carry new cluster.id (rewritten or fresh-formatted)"

# §4.13: look for partition directories that Kafka renamed to <name>-stray because their
# partition.metadata UUID did not match any topic registered in the freshly-formatted
# KRaft metadata log.
stray_dirs_found="no"
stray_count="$(find "${ROOT_DIR}/data/target" -maxdepth 4 -name "*-stray" -type d 2>/dev/null | wc -l | tr -d ' ')"
echo "stray_dirs_count=${stray_count}" >> "${TARGET_METRICS_FILE}"
if [[ "${stray_count}" -gt 0 ]]; then
  stray_dirs_found="yes"
fi
record_assertion "stray_dirs_found" "${expected_stray_dirs_found}" "${stray_dirs_found}" "no" "§4.13: <partition>-stray dirs appear when partition.metadata UUID mismatches KRaft"

snapshot_data_present="no"
# Search all broker data dirs for any partition of the source topic (live or stray-renamed).
# After §4.13 the directory name is <topic>-<partition>-stray; we accept any partition number
# and check all three brokers since partition assignment varies between runs.
source_topic_dir_count="$(find "${ROOT_DIR}/data/target" -maxdepth 3 \
  \( -name "${source_topic}-*" -o -name "${source_topic}-*-stray" \) \
  -type d 2>/dev/null | wc -l | tr -d ' ')"
echo "source_topic_dir_count=${source_topic_dir_count}" >> "${TARGET_METRICS_FILE}"
if [[ "${source_topic_dir_count}" -gt 0 ]]; then
  snapshot_data_present="yes"
fi
record_assertion "snapshot_data_present" "yes" "${snapshot_data_present}" "yes" "copied topic data should exist on target disk (live or stray)"

direct_import_blocked="no"
if [[ "${mode}" == "blocked" ]]; then
  # For direct-import: 'blocked' means stray dirs found → source topic data inaccessible (§4.13)
  if [[ "${stray_dirs_found}" == "yes" ]]; then
    direct_import_blocked="yes"
  fi
else
  # For allowed: no stray dirs means import succeeded; stray dirs would be unexpected
  if [[ "${stray_dirs_found}" == "yes" ]]; then
    direct_import_blocked="yes"
  fi
fi
record_assertion "direct_import_blocked" "${expected_direct_import_blocked}" "${direct_import_blocked}" "no" "§4.13: stray dirs indicate direct data import is blocked (source-topic partitions unavailable)"

post_restore_io_succeeds="skip"
if [[ "${target_ready}" == "yes" ]]; then
  # The broker may briefly restart (Docker IP reassignment) after start_target exits.
  # Re-anchor to ensure it is fully accepting connections before running I/O smoke.
  wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 120 || true

  smoke_ok="no"
  for _smoke_attempt in 1 2 3 4 5 6; do
    if run_post_restore_io_smoke; then
      smoke_ok="yes"
      echo "io_smoke_attempt=${_smoke_attempt}" >> "${TARGET_METRICS_FILE}"
      break
    fi
    echo "io_smoke_attempt_${_smoke_attempt}=failed" >> "${TARGET_METRICS_FILE}"
    sleep 10
  done
  post_restore_io_succeeds="${smoke_ok}"
fi
# For blocked mode: smoke runs (cluster is reachable) but is expected to fail ("no") because
# the source topic partitions are stray/offline. For allowed mode: expected to succeed ("yes").
record_assertion "post_restore_io_succeeds" "${expected_post_restore_io}" "${post_restore_io_succeeds}" "${post_restore_io_critical}" "${post_restore_io_note}"

echo "target_start_rc=${TARGET_START_RC}" >> "${TARGET_METRICS_FILE}"
echo "target_ready=${target_ready}" >> "${TARGET_METRICS_FILE}"
echo "expectation_mode=${mode}" >> "${TARGET_METRICS_FILE}"
echo "observed_outcome=$([[ "${target_ready}" == "yes" ]] && echo reachable_or_allowed || echo blocked_or_unreachable)" >> "${TARGET_METRICS_FILE}"
echo "phase9_source_cluster_id=${phase9_source_cluster_id}" >> "${TARGET_METRICS_FILE}"
echo "phase9_target_cluster_id=${phase9_target_cluster_id}" >> "${TARGET_METRICS_FILE}"
echo "phase9_topic=${source_topic}" >> "${TARGET_METRICS_FILE}"
echo "phase9_source_end_sum=${source_end_sum}" >> "${TARGET_METRICS_FILE}"

cat > "${TARGET_ASSERTIONS_ENV}" <<EOF
scenario=${SCENARIO}
status=${status}
assertions_passed=${assertions_passed}
assertions_failed=${assertions_failed}
critical_failed=${critical_failed}
EOF

{
  echo "scenario=${SCENARIO}"
  echo "target_start_rc=${TARGET_START_RC}"
  echo "status=${status}"
  echo "assertions_passed=${assertions_passed}"
  echo "assertions_failed=${assertions_failed}"
  echo "critical_failed=${critical_failed}"
  echo ""
  echo "scenario_metrics:"
  cat "${TARGET_METRICS_FILE}" || true
  echo ""
  echo "assertions:"
  cat "${TARGET_ASSERTIONS_FILE}" || true
} > "${TARGET_REPORT_FILE}"

echo "${status}" > "${TARGET_STATUS_FILE}"
echo "Phase 9 validation (${SCENARIO}) status: ${status}"
echo "Report: ${TARGET_REPORT_FILE}"

if [[ "${status}" == "failed" ]]; then
  exit 2
fi
