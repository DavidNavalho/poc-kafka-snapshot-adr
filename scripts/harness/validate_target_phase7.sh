#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase7_scenarios.sh
source "${SCRIPT_DIR}/phase7_scenarios.sh"

SCENARIO="${1:-hard-stop}"
TARGET_START_RC="${PHASE7_TARGET_START_RC:-0}"

SOURCE_PHASE7_DIR="${ROOT_DIR}/artifacts/latest/source/phase7"
SOURCE_TOPICS_DIR="${SOURCE_PHASE7_DIR}/topics"
SOURCE_GROUPS_DIR="${SOURCE_PHASE7_DIR}/groups"

TARGET_PHASE7_DIR="${ROOT_DIR}/artifacts/latest/target/phase7/${SCENARIO}"
TARGET_TOPICS_DIR="${TARGET_PHASE7_DIR}/topics"
TARGET_GROUPS_DIR="${TARGET_PHASE7_DIR}/groups"
TARGET_TXN_DIR="${TARGET_PHASE7_DIR}/transactions"
TARGET_HEALTH_DIR="${TARGET_PHASE7_DIR}/health"
REMEDIATIONS_DIR="${TARGET_PHASE7_DIR}/remediations"
mkdir -p "${TARGET_TOPICS_DIR}" "${TARGET_GROUPS_DIR}" "${TARGET_TXN_DIR}" "${TARGET_HEALTH_DIR}" "${REMEDIATIONS_DIR}"

REPORT_FILE="${TARGET_PHASE7_DIR}/recovery_report.txt"
STATUS_FILE="${TARGET_PHASE7_DIR}/status.txt"
TOPIC_METRICS_FILE="${TARGET_PHASE7_DIR}/topic_metrics.tsv"
GROUP_METRICS_FILE="${TARGET_PHASE7_DIR}/group_metrics.tsv"
REMEDIATION_SUMMARY_FILE="${TARGET_PHASE7_DIR}/remediation_summary.tsv"

status="recovered"
degraded_issue_count=0
issue_counter=0
findings_file="${TARGET_PHASE7_DIR}/findings.txt"
fixes_file="${TARGET_PHASE7_DIR}/fixes.txt"
: > "${findings_file}"
: > "${fixes_file}"
printf "topic\tsource_end_offset_sum\ttarget_end_offset_sum\tdelta_target_minus_source\n" > "${TOPIC_METRICS_FILE}"
printf "group\ttopic\tsource_committed_sum\ttarget_committed_sum\tdelta_target_minus_source\n" > "${GROUP_METRICS_FILE}"
printf "issue\tresult\tnote\n" > "${REMEDIATION_SUMMARY_FILE}"

register_degraded_issue() {
  degraded_issue_count=$((degraded_issue_count + 1))
  if [[ "${status}" != "failed" ]]; then
    status="degraded"
  fi
}

set_failed() {
  status="failed"
}

add_finding() {
  local level="$1"
  local message="$2"
  echo "[${level}] ${message}" >> "${findings_file}"
}

add_fix() {
  local message="$1"
  echo "- ${message}" >> "${fixes_file}"
}

create_issue_dir() {
  local key="$1"
  local safe_key
  local issue_dir
  issue_counter=$((issue_counter + 1))
  safe_key="$(echo "${key}" | tr -cs 'A-Za-z0-9._-' '_')"
  issue_dir="${REMEDIATIONS_DIR}/$(printf '%02d_%s' "${issue_counter}" "${safe_key}")"
  mkdir -p "${issue_dir}/before" "${issue_dir}/after"
  echo "${issue_dir}"
}

record_issue_result() {
  local issue_dir="$1"
  local result="$2"
  local note="$3"
  printf "%s\t%s\t%s\n" "$(basename "${issue_dir}")" "${result}" "${note}" >> "${REMEDIATION_SUMMARY_FILE}"
}

capture_group_offsets() {
  local group_id="$1"
  local raw_file="$2"
  local parsed_file="$3"

  set +e
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --describe --group ${group_id}" \
    > "${raw_file}" 2>&1
  local rc=$?
  set -e

  if [[ "${rc}" -ne 0 ]]; then
    return 1
  fi

  awk '
    NF >= 5 && $3 ~ /^[0-9]+$/ && $4 ~ /^[-0-9]+$/ && $5 ~ /^[-0-9]+$/ {
      print $1 "|" $2 "|" $3 "|" $4 "|" $5
    }
  ' "${raw_file}" | LC_ALL=C sort > "${parsed_file}"
}

sum_end_offsets_file() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo 0
    return 0
  fi
  awk -F: 'NF >= 3 && $3 ~ /^[0-9]+$/ {sum += $3} END {print sum + 0}' "${file}"
}

sum_group_topic_offsets() {
  local file="$1"
  local topic="$2"
  if [[ ! -f "${file}" ]]; then
    echo 0
    return 0
  fi
  awk -F'|' -v topic="${topic}" '$2 == topic && $4 ~ /^[0-9]+$/ {sum += $4} END {print sum + 0}' "${file}"
}

count_offline_partitions() {
  local file="$1"
  awk '/Leader: -1/ {count++} END {print count + 0}' "${file}"
}

count_under_replicated() {
  local file="$1"
  awk '
    /Partition:/ {
      replicas=""
      isr=""
      for (i = 1; i <= NF; i++) {
        if ($i == "Replicas:") replicas = $(i + 1)
        if ($i == "Isr:") isr = $(i + 1)
      }
      gsub(/,/, " ", replicas)
      gsub(/,/, " ", isr)
      rep_n = split(replicas, rep_arr, /[[:space:]]+/)
      isr_n = split(isr, isr_arr, /[[:space:]]+/)
      if (rep_n > isr_n) count++
    }
    END {print count + 0}
  ' "${file}"
}

extract_offline_partitions() {
  local describe_file="$1"
  local out_file="$2"
  awk '
    /Partition:/ && /Leader: -1/ {
      topic=""
      partition=""
      for (i = 1; i <= NF; i++) {
        if ($i == "Topic:") topic = $(i + 1)
        if ($i == "Partition:") partition = $(i + 1)
      }
      if (topic != "" && partition != "") {
        print topic "|" partition
      }
    }
  ' "${describe_file}" | LC_ALL=C sort -u > "${out_file}"
}

capture_jmx_snapshot() {
  local out_file="$1"
  set +e
  compose_cmd exec -T target-broker-1 bash -lc '
objs=(
"kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions"
"kafka.controller:type=KafkaController,name=OfflinePartitionsCount"
"kafka.server:type=BrokerTopicMetrics,name=BytesInPerSec"
"kafka.server:type=BrokerTopicMetrics,name=BytesOutPerSec"
)
for obj in "${objs[@]}"; do
  echo "### ${obj}"
  timeout --signal=KILL 8s kafka-run-class org.apache.kafka.tools.JmxTool \
    --jmx-url service:jmx:rmi:///jndi/rmi://localhost:9999/jmxrmi \
    --object-name "${obj}" \
    --one-time \
    --report-format tsv 2>&1 || true
done
' > "${out_file}" 2>&1
  set -e
}

capture_issue_snapshot() {
  local stage_dir="$1"
  mkdir -p "${stage_dir}"

  set +e
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-metadata-quorum --bootstrap-server ${TARGET_BOOTSTRAP} describe --status" \
    > "${stage_dir}/metadata_quorum_status.txt" 2>&1
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe" \
    > "${stage_dir}/topics_describe_all.txt" 2>&1
  local describe_rc=$?
  set -e

  if [[ "${describe_rc}" -eq 0 ]]; then
    echo "offline_partitions=$(count_offline_partitions "${stage_dir}/topics_describe_all.txt")" > "${stage_dir}/partition_health.txt"
    echo "under_replicated_partitions=$(count_under_replicated "${stage_dir}/topics_describe_all.txt")" >> "${stage_dir}/partition_health.txt"
  else
    echo "offline_partitions=unknown" > "${stage_dir}/partition_health.txt"
    echo "under_replicated_partitions=unknown" >> "${stage_dir}/partition_health.txt"
  fi

  capture_jmx_snapshot "${stage_dir}/jmx_metrics.txt"
  for broker in 1 2 3; do
    compose_cmd logs --no-color --tail=250 "target-broker-${broker}" > "${stage_dir}/target-broker-${broker}.log" || true
  done
}

detect_hanging_hits() {
  local file_prefix="$1"
  local hits=0
  for broker_id in 1 2 3; do
    if [[ -f "${file_prefix}${broker_id}.txt" ]]; then
      rows="$(awk 'NR > 1 && NF > 0 {count++} END {print count + 0}' "${file_prefix}${broker_id}.txt")"
      if [[ "${rows}" -gt 0 ]]; then
        hits=$((hits + rows))
      fi
    fi
  done
  echo "${hits}"
}

target_ready=1
if [[ "${TARGET_START_RC}" -ne 0 ]]; then
  register_degraded_issue
  add_finding "DEGRADED" "target start script returned rc=${TARGET_START_RC}; continuing with diagnostics"
fi

if ! wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 60; then
  target_ready=0
  set_failed
  add_finding "FAILED" "target bootstrap is not reachable after restore"
  add_fix "Check broker logs: docker compose -f docker-compose.yml logs target-broker-1 target-broker-2 target-broker-3"
  add_fix "If metadata quorum cannot stabilize, restore an older snapshot set."
fi

for broker in 1 2 3; do
  compose_cmd logs --no-color --tail=400 "target-broker-${broker}" > "${TARGET_HEALTH_DIR}/target-broker-${broker}.log" || true
done

if [[ "${target_ready}" -eq 1 ]]; then
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-metadata-quorum --bootstrap-server ${TARGET_BOOTSTRAP} describe --status" \
    > "${TARGET_HEALTH_DIR}/metadata_quorum_status.txt"

  unresolved_host_topics=()
  for spec in "${PHASE7_TOPICS[@]}"; do
    IFS="|" read -r topic _ _ _ <<< "${spec}"
    topic_dir="${TARGET_TOPICS_DIR}/${topic}"
    mkdir -p "${topic_dir}"

    set +e
    compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe --topic ${topic}" \
      > "${topic_dir}/topic_describe.txt" 2>&1
    describe_rc=$?
    set -e
    if [[ "${describe_rc}" -ne 0 ]]; then
      set_failed
      add_finding "FAILED" "topic describe failed on target for ${topic}"
      add_fix "If topic metadata is missing, restore from an older snapshot set and retry."
      continue
    fi

    set +e
    compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --time -1" \
      > "${topic_dir}/end_offsets.raw.txt" 2> "${topic_dir}/end_offsets.stderr.txt"
    offsets_rc=$?
    set -e
    if [[ "${offsets_rc}" -ne 0 ]]; then
      register_degraded_issue
      add_finding "DEGRADED" "offset retrieval failed for ${topic}"
      continue
    fi

    LC_ALL=C sort "${topic_dir}/end_offsets.raw.txt" > "${topic_dir}/end_offsets.txt"
    if grep -qi "UnknownHostException" "${topic_dir}/end_offsets.stderr.txt"; then
      unresolved_host_topics+=("${topic}")
    fi

    source_sum="$(sum_end_offsets_file "${SOURCE_TOPICS_DIR}/${topic}/end_offsets.txt")"
    target_sum="$(sum_end_offsets_file "${topic_dir}/end_offsets.txt")"
    delta_sum=$((target_sum - source_sum))
    printf "%s\t%s\t%s\t%s\n" "${topic}" "${source_sum}" "${target_sum}" "${delta_sum}" >> "${TOPIC_METRICS_FILE}"
    if [[ "${target_sum}" -lt "${source_sum}" ]]; then
      add_finding "INFO" "topic ${topic} has lower end-offset sum on target (source=${source_sum}, target=${target_sum})"
      if [[ "${target_sum}" -eq 0 && "${source_sum}" -gt 0 ]]; then
        register_degraded_issue
        add_finding "DEGRADED" "topic ${topic} appears fully lost on target while source had data"
      fi
    elif [[ "${target_sum}" -gt "${source_sum}" ]]; then
      add_finding "INFO" "topic ${topic} has higher end-offset sum on target (source=${source_sum}, target=${target_sum})"
    fi
  done

  if [[ "${#unresolved_host_topics[@]}" -gt 0 ]]; then
    issue_dir="$(create_issue_dir "unresolved_host_metadata")"
    printf "%s\n" "${unresolved_host_topics[@]}" > "${issue_dir}/before/unresolved_topics.txt"
    capture_issue_snapshot "${issue_dir}/before"
    {
      echo "docker compose restart target-broker-1 target-broker-2 target-broker-3"
    } > "${issue_dir}/commands.txt"

    compose_cmd restart "${TARGET_SERVICES[@]}" >> "${issue_dir}/commands.txt" 2>&1 || true
    if wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 90; then
      unresolved_after=0
      for topic in "${unresolved_host_topics[@]}"; do
        topic_file_safe="$(echo "${topic}" | tr -cs 'A-Za-z0-9._-' '_')"
        set +e
        compose_cmd exec -T target-broker-1 bash -lc \
          "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${topic} --time -1" \
          > "${issue_dir}/after/${topic_file_safe}.offsets.txt" 2> "${issue_dir}/after/${topic_file_safe}.stderr.txt"
        check_rc=$?
        set -e
        if [[ "${check_rc}" -ne 0 ]] || grep -qi "UnknownHostException" "${issue_dir}/after/${topic_file_safe}.stderr.txt"; then
          unresolved_after=1
        fi
      done
      capture_issue_snapshot "${issue_dir}/after"
      if [[ "${unresolved_after}" -eq 0 ]]; then
        add_finding "INFO" "resolved unresolved-host metadata warnings after broker restart"
        record_issue_result "${issue_dir}" "resolved" "broker restart cleared unresolved host references"
      else
        register_degraded_issue
        add_finding "DEGRADED" "metadata unresolved-host warnings persist after broker restart"
        add_fix "If unresolved-host warnings persist, inspect broker registration/listener metadata and restart with corrected endpoints."
        record_issue_result "${issue_dir}" "degraded" "warnings persisted after restart"
      fi
    else
      set_failed
      add_finding "FAILED" "target bootstrap unavailable after unresolved-host remediation restart"
      add_fix "Cluster failed to restart during unresolved-host remediation; restore an older snapshot set."
      capture_issue_snapshot "${issue_dir}/after"
      record_issue_result "${issue_dir}" "failed" "bootstrap unavailable after restart"
    fi
  fi

  set +e
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe" \
    > "${TARGET_HEALTH_DIR}/topics_describe_all.txt" 2>&1
  describe_all_rc=$?
  set -e
  if [[ "${describe_all_rc}" -ne 0 ]]; then
    set_failed
    add_finding "FAILED" "unable to describe topics cluster-wide on target"
    add_fix "Check controller/quorum health and broker logs; if unresolved restore older snapshot."
  fi

  if [[ "${describe_all_rc}" -eq 0 ]]; then
    offline_count="$(count_offline_partitions "${TARGET_HEALTH_DIR}/topics_describe_all.txt")"
    if [[ "${offline_count}" -gt 0 ]]; then
      issue_dir="$(create_issue_dir "offline_partitions")"
      cp "${TARGET_HEALTH_DIR}/topics_describe_all.txt" "${issue_dir}/before/topics_describe_all.txt"
      extract_offline_partitions "${issue_dir}/before/topics_describe_all.txt" "${issue_dir}/before/offline_partitions.tsv"
      capture_issue_snapshot "${issue_dir}/before"

      {
        echo "docker compose restart target-broker-1 target-broker-2 target-broker-3"
      } > "${issue_dir}/commands.txt"
      compose_cmd restart "${TARGET_SERVICES[@]}" >> "${issue_dir}/commands.txt" 2>&1 || true

      offline_after=999
      if wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" 90; then
        compose_cmd exec -T target-broker-1 bash -lc \
          "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe" \
          > "${issue_dir}/after/topics_describe_after_restart.txt" 2>&1 || true
        offline_after="$(count_offline_partitions "${issue_dir}/after/topics_describe_after_restart.txt")"

        if [[ "${offline_after}" -gt 0 ]]; then
          extract_offline_partitions "${issue_dir}/after/topics_describe_after_restart.txt" "${issue_dir}/after/offline_partitions_for_election.tsv"
          while IFS='|' read -r topic partition; do
            [[ -z "${topic}" || -z "${partition}" ]] && continue
            {
              echo "kafka-leader-election --bootstrap-server ${TARGET_BOOTSTRAP} --election-type unclean --topic ${topic} --partition ${partition}"
            } >> "${issue_dir}/commands.txt"
            compose_cmd exec -T target-broker-1 bash -lc \
              "kafka-leader-election --bootstrap-server ${TARGET_BOOTSTRAP} --election-type unclean --topic ${topic} --partition ${partition}" \
              >> "${issue_dir}/after/leader_election_output.txt" 2>&1 || true
          done < "${issue_dir}/after/offline_partitions_for_election.tsv"

          compose_cmd exec -T target-broker-1 bash -lc \
            "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe" \
            > "${issue_dir}/after/topics_describe_after_election.txt" 2>&1 || true
          offline_after="$(count_offline_partitions "${issue_dir}/after/topics_describe_after_election.txt")"
        fi
      fi

      capture_issue_snapshot "${issue_dir}/after"
      if [[ "${offline_after}" -eq 0 ]]; then
        add_finding "INFO" "offline partitions resolved by restart/targeted unclean leader election"
        record_issue_result "${issue_dir}" "resolved" "offline partitions cleared"
      else
        register_degraded_issue
        add_finding "DEGRADED" "offline partitions remain after restart and targeted unclean election"
        add_fix "If offline partitions persist, restore an older snapshot set or inspect topic-level unclean-leader eligibility."
        record_issue_result "${issue_dir}" "degraded" "offline partitions persisted"
      fi

      compose_cmd exec -T target-broker-1 bash -lc \
        "kafka-topics --bootstrap-server ${TARGET_BOOTSTRAP} --describe" \
        > "${TARGET_HEALTH_DIR}/topics_describe_all.txt" 2>&1 || true
    fi
  fi

  if [[ -f "${TARGET_HEALTH_DIR}/topics_describe_all.txt" ]]; then
    offline_count="$(count_offline_partitions "${TARGET_HEALTH_DIR}/topics_describe_all.txt")"
    urp_count="$(count_under_replicated "${TARGET_HEALTH_DIR}/topics_describe_all.txt")"
    if [[ "${offline_count}" -gt 0 ]]; then
      register_degraded_issue
      add_finding "DEGRADED" "offline partitions still present at validation end (${offline_count})"
    fi
    if [[ "${urp_count}" -gt 0 ]]; then
      register_degraded_issue
      add_finding "DEGRADED" "under-replicated partitions present at validation end (${urp_count})"
      add_fix "Keep brokers running for ISR catch-up; if persistent inspect broker logs and replica disks."
    fi
  fi

  full_group_regressed=0
  partial_group_regressed=0
  source_full_sum=0
  target_full_sum=0
  source_partial_sum=0
  target_partial_sum=0

  if capture_group_offsets "${PHASE7_FULL_GROUP}" \
    "${TARGET_GROUPS_DIR}/${PHASE7_FULL_GROUP}.before.raw.txt" \
    "${TARGET_GROUPS_DIR}/${PHASE7_FULL_GROUP}.before.offsets.txt"; then
    source_full_sum="$(sum_group_topic_offsets "${SOURCE_GROUPS_DIR}/${PHASE7_FULL_GROUP}.offsets.txt" "${PHASE7_GROUPS_TOPIC}")"
    target_full_sum="$(sum_group_topic_offsets "${TARGET_GROUPS_DIR}/${PHASE7_FULL_GROUP}.before.offsets.txt" "${PHASE7_GROUPS_TOPIC}")"
    printf "%s\t%s\t%s\t%s\t%s\n" "${PHASE7_FULL_GROUP}" "${PHASE7_GROUPS_TOPIC}" "${source_full_sum}" "${target_full_sum}" "$((target_full_sum - source_full_sum))" >> "${GROUP_METRICS_FILE}"
    if [[ "${target_full_sum}" -lt "${source_full_sum}" ]]; then
      full_group_regressed=1
      add_finding "INFO" "full group offsets are lower than source baseline on ${PHASE7_GROUPS_TOPIC} (source=${source_full_sum}, target=${target_full_sum})"
    fi
  else
    register_degraded_issue
    add_finding "DEGRADED" "group ${PHASE7_FULL_GROUP} is not readable on target"
  fi

  if capture_group_offsets "${PHASE7_PARTIAL_GROUP}" \
    "${TARGET_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.before.raw.txt" \
    "${TARGET_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.before.offsets.txt"; then
    source_partial_sum="$(sum_group_topic_offsets "${SOURCE_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.offsets.txt" "${PHASE7_NORMAL_TOPIC}")"
    target_partial_sum="$(sum_group_topic_offsets "${TARGET_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.before.offsets.txt" "${PHASE7_NORMAL_TOPIC}")"
    printf "%s\t%s\t%s\t%s\t%s\n" "${PHASE7_PARTIAL_GROUP}" "${PHASE7_NORMAL_TOPIC}" "${source_partial_sum}" "${target_partial_sum}" "$((target_partial_sum - source_partial_sum))" >> "${GROUP_METRICS_FILE}"
    if [[ "${target_partial_sum}" -lt "${source_partial_sum}" ]]; then
      partial_group_regressed=1
      add_finding "INFO" "partial group offsets are lower than source baseline on ${PHASE7_NORMAL_TOPIC} (source=${source_partial_sum}, target=${target_partial_sum})"
    fi
  else
    register_degraded_issue
    add_finding "DEGRADED" "group ${PHASE7_PARTIAL_GROUP} is not readable on target"
  fi

  if [[ "${full_group_regressed}" -eq 1 ]]; then
    issue_dir="$(create_issue_dir "reset_offsets_${PHASE7_FULL_GROUP}")"
    capture_issue_snapshot "${issue_dir}/before"
    {
      echo "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --group ${PHASE7_FULL_GROUP} --topic ${PHASE7_GROUPS_TOPIC} --reset-offsets --to-latest --dry-run"
      echo "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --group ${PHASE7_FULL_GROUP} --topic ${PHASE7_GROUPS_TOPIC} --reset-offsets --to-latest --execute"
    } > "${issue_dir}/commands.txt"
    set +e
    compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --group ${PHASE7_FULL_GROUP} --topic ${PHASE7_GROUPS_TOPIC} --reset-offsets --to-latest --dry-run" \
      > "${issue_dir}/before/reset_dry_run.txt" 2>&1
    dry_rc=$?
    compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --group ${PHASE7_FULL_GROUP} --topic ${PHASE7_GROUPS_TOPIC} --reset-offsets --to-latest --execute" \
      > "${issue_dir}/after/reset_execute.txt" 2>&1
    exec_rc=$?
    set -e
    sleep 2
    after_full_sum="${target_full_sum}"
    if capture_group_offsets "${PHASE7_FULL_GROUP}" \
      "${TARGET_GROUPS_DIR}/${PHASE7_FULL_GROUP}.after.raw.txt" \
      "${TARGET_GROUPS_DIR}/${PHASE7_FULL_GROUP}.after.offsets.txt"; then
      after_full_sum="$(sum_group_topic_offsets "${TARGET_GROUPS_DIR}/${PHASE7_FULL_GROUP}.after.offsets.txt" "${PHASE7_GROUPS_TOPIC}")"
    fi
    capture_issue_snapshot "${issue_dir}/after"
    if [[ "${dry_rc}" -eq 0 && "${exec_rc}" -eq 0 && "${after_full_sum}" -gt "${target_full_sum}" ]]; then
      add_finding "INFO" "offset remediation applied to ${PHASE7_FULL_GROUP} on ${PHASE7_GROUPS_TOPIC} (to-latest)"
      record_issue_result "${issue_dir}" "resolved" "offsets reset to latest"
    else
      register_degraded_issue
      add_finding "DEGRADED" "offset remediation failed for ${PHASE7_FULL_GROUP} on ${PHASE7_GROUPS_TOPIC}"
      add_fix "Ensure group is inactive and rerun reset-offsets with --to-latest or manual --to-offset/--to-datetime."
      record_issue_result "${issue_dir}" "degraded" "offset reset command failed or no advancement"
    fi
  fi

  if [[ "${partial_group_regressed}" -eq 1 ]]; then
    issue_dir="$(create_issue_dir "reset_offsets_${PHASE7_PARTIAL_GROUP}")"
    capture_issue_snapshot "${issue_dir}/before"
    {
      echo "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --group ${PHASE7_PARTIAL_GROUP} --topic ${PHASE7_NORMAL_TOPIC} --reset-offsets --to-latest --dry-run"
      echo "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --group ${PHASE7_PARTIAL_GROUP} --topic ${PHASE7_NORMAL_TOPIC} --reset-offsets --to-latest --execute"
    } > "${issue_dir}/commands.txt"
    set +e
    compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --group ${PHASE7_PARTIAL_GROUP} --topic ${PHASE7_NORMAL_TOPIC} --reset-offsets --to-latest --dry-run" \
      > "${issue_dir}/before/reset_dry_run.txt" 2>&1
    dry_rc=$?
    compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-consumer-groups --bootstrap-server ${TARGET_BOOTSTRAP} --group ${PHASE7_PARTIAL_GROUP} --topic ${PHASE7_NORMAL_TOPIC} --reset-offsets --to-latest --execute" \
      > "${issue_dir}/after/reset_execute.txt" 2>&1
    exec_rc=$?
    set -e
    sleep 2
    after_partial_sum="${target_partial_sum}"
    if capture_group_offsets "${PHASE7_PARTIAL_GROUP}" \
      "${TARGET_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.after.raw.txt" \
      "${TARGET_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.after.offsets.txt"; then
      after_partial_sum="$(sum_group_topic_offsets "${TARGET_GROUPS_DIR}/${PHASE7_PARTIAL_GROUP}.after.offsets.txt" "${PHASE7_NORMAL_TOPIC}")"
    fi
    capture_issue_snapshot "${issue_dir}/after"
    if [[ "${dry_rc}" -eq 0 && "${exec_rc}" -eq 0 && "${after_partial_sum}" -gt "${target_partial_sum}" ]]; then
      add_finding "INFO" "offset remediation applied to ${PHASE7_PARTIAL_GROUP} on ${PHASE7_NORMAL_TOPIC} (to-latest)"
      record_issue_result "${issue_dir}" "resolved" "offsets reset to latest"
    else
      register_degraded_issue
      add_finding "DEGRADED" "offset remediation failed for ${PHASE7_PARTIAL_GROUP} on ${PHASE7_NORMAL_TOPIC}"
      add_fix "Ensure group is inactive and rerun reset-offsets with --to-latest or manual --to-offset/--to-datetime."
      record_issue_result "${issue_dir}" "degraded" "offset reset command failed or no advancement"
    fi
  fi

  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-transactions --bootstrap-server ${TARGET_BOOTSTRAP} list" \
    > "${TARGET_TXN_DIR}/transactions.list.txt"

  for txid in "${PHASE7_TXID_COMMITTED}" "${PHASE7_TXID_ABORTED}" "${PHASE7_TXID_HANGING}"; do
    set +e
    compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-transactions --bootstrap-server ${TARGET_BOOTSTRAP} describe --transactional-id ${txid}" \
      > "${TARGET_TXN_DIR}/${txid}.describe.txt" 2>&1
    tx_rc=$?
    set -e
    if [[ "${tx_rc}" -ne 0 ]]; then
      register_degraded_issue
      add_finding "DEGRADED" "transactional id ${txid} cannot be described on target"
    fi
  done

  for broker_id in 1 2 3; do
    compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-transactions --bootstrap-server ${TARGET_BOOTSTRAP} find-hanging --broker-id ${broker_id}" \
      > "${TARGET_TXN_DIR}/find_hanging_broker${broker_id}.txt" 2>&1 || true
  done

  hanging_hits="$(detect_hanging_hits "${TARGET_TXN_DIR}/find_hanging_broker")"
  if [[ "${hanging_hits}" -gt 0 ]]; then
    issue_dir="$(create_issue_dir "hanging_transactions")"
    cp "${TARGET_TXN_DIR}"/find_hanging_broker*.txt "${issue_dir}/before/" 2>/dev/null || true
    capture_issue_snapshot "${issue_dir}/before"

    declare -a candidate_txids=("${PHASE7_TXID_HANGING}" "${PHASE7_TXID_ABORTED}")
    runtime_txid_file="${ROOT_DIR}/artifacts/latest/source/phase7/runtime/background_txid.txt"
    if [[ -f "${runtime_txid_file}" ]]; then
      candidate_txids+=("$(cat "${runtime_txid_file}")")
    fi
    mapfile -t unique_txids < <(printf '%s\n' "${candidate_txids[@]}" | awk 'NF && !seen[$0]++')
    : > "${issue_dir}/commands.txt"
    for txid in "${unique_txids[@]}"; do
      echo "kafka-transactions --bootstrap-server ${TARGET_BOOTSTRAP} force-terminate --transactional-id ${txid}" >> "${issue_dir}/commands.txt"
      compose_cmd exec -T target-broker-1 bash -lc \
        "kafka-transactions --bootstrap-server ${TARGET_BOOTSTRAP} force-terminate --transactional-id ${txid}" \
        >> "${issue_dir}/after/force_terminate_output.txt" 2>&1 || true
    done

    for broker_id in 1 2 3; do
      compose_cmd exec -T target-broker-1 bash -lc \
        "kafka-transactions --bootstrap-server ${TARGET_BOOTSTRAP} find-hanging --broker-id ${broker_id}" \
        > "${issue_dir}/after/find_hanging_broker${broker_id}.txt" 2>&1 || true
      cp "${issue_dir}/after/find_hanging_broker${broker_id}.txt" "${TARGET_TXN_DIR}/find_hanging_broker${broker_id}.txt"
    done
    hanging_hits_after="$(detect_hanging_hits "${issue_dir}/after/find_hanging_broker")"
    capture_issue_snapshot "${issue_dir}/after"
    if [[ "${hanging_hits_after}" -eq 0 ]]; then
      add_finding "INFO" "hanging transactions cleared by force-terminate remediation"
      record_issue_result "${issue_dir}" "resolved" "force-terminate cleared hanging transactions"
    else
      register_degraded_issue
      add_finding "DEGRADED" "hanging transactions remain after force-terminate attempts (rows=${hanging_hits_after})"
      add_fix "Inspect hanging transaction output and terminate specific txids manually if needed."
      record_issue_result "${issue_dir}" "degraded" "hanging transactions persisted"
    fi
  fi

  smoke_marker="phase7-smoke-${SCENARIO}-$(date +%s)"
  before_smoke_offsets_file="${TARGET_HEALTH_DIR}/smoke.before_offsets.txt"
  after_smoke_offsets_file="${TARGET_HEALTH_DIR}/smoke.after_offsets.txt"

  set +e
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${PHASE7_SMOKE_TOPIC} --time -1" \
    | sort > "${before_smoke_offsets_file}"
  smoke_offsets_rc=$?
  set -e
  if [[ "${smoke_offsets_rc}" -ne 0 ]]; then
    set_failed
    add_finding "FAILED" "unable to read smoke topic offsets before produce test"
  else
    before_smoke_sum="$(sum_end_offsets_file "${before_smoke_offsets_file}")"
    seq 1 "${PHASE7_SMOKE_MESSAGES}" \
      | awk -v marker="${smoke_marker}" '{printf "%s-%03d:{\"event\":\"post-restore-smoke\",\"seq\":%d}\n", marker, $1, $1}' \
      | compose_cmd exec -T target-broker-1 bash -lc \
        "kafka-console-producer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${PHASE7_SMOKE_TOPIC} --property parse.key=true --property key.separator=: >/dev/null"

    compose_cmd exec -T target-broker-1 bash -lc \
      "kafka-get-offsets --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${PHASE7_SMOKE_TOPIC} --time -1" \
      | sort > "${after_smoke_offsets_file}"
    after_smoke_sum="$(sum_end_offsets_file "${after_smoke_offsets_file}")"
    if [[ "${after_smoke_sum}" -lt $((before_smoke_sum + PHASE7_SMOKE_MESSAGES)) ]]; then
      set_failed
      add_finding "FAILED" "post-restore produce smoke did not advance offsets as expected"
    fi
  fi

  set +e
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-console-consumer --bootstrap-server ${TARGET_BOOTSTRAP} --topic ${PHASE7_SMOKE_TOPIC} --from-beginning --max-messages ${PHASE7_SMOKE_CONSUME} --timeout-ms 10000 >/tmp/phase7-smoke-consume.txt 2>/tmp/phase7-smoke-consume.err"
  smoke_consume_rc=$?
  set -e
  compose_cmd exec -T target-broker-1 bash -lc "cat /tmp/phase7-smoke-consume.txt || true" > "${TARGET_HEALTH_DIR}/smoke.consume.txt"
  compose_cmd exec -T target-broker-1 bash -lc "cat /tmp/phase7-smoke-consume.err || true" > "${TARGET_HEALTH_DIR}/smoke.consume.err"
  smoke_read_count="$(wc -l < "${TARGET_HEALTH_DIR}/smoke.consume.txt" | tr -d ' ')"
  if [[ "${smoke_consume_rc}" -ne 0 || "${smoke_read_count}" -le 0 ]]; then
    set_failed
    add_finding "FAILED" "post-restore consume smoke failed (rc=${smoke_consume_rc}, lines=${smoke_read_count})"
    add_fix "If reads fail, inspect partition leadership and transaction state before allowing client traffic."
  fi

  capture_jmx_snapshot "${TARGET_HEALTH_DIR}/jmx_metrics_final.txt"
fi

if [[ "${target_ready}" -eq 0 ]]; then
  add_finding "FAILED" "cluster is not operational; read/write smoke checks were skipped"
fi

{
  echo "scenario=${SCENARIO}"
  echo "target_start_rc=${TARGET_START_RC}"
  echo "target_ready=${target_ready}"
  echo "status=${status}"
  echo "degraded_issue_count=${degraded_issue_count}"
  if [[ -f "${TARGET_HEALTH_DIR}/topics_describe_all.txt" ]]; then
    echo "offline_partitions=$(count_offline_partitions "${TARGET_HEALTH_DIR}/topics_describe_all.txt")"
    echo "under_replicated_partitions=$(count_under_replicated "${TARGET_HEALTH_DIR}/topics_describe_all.txt")"
  else
    echo "offline_partitions=unknown"
    echo "under_replicated_partitions=unknown"
  fi
  echo ""
  echo "findings:"
  cat "${findings_file}" || true
  echo ""
  echo "topic_metrics:"
  cat "${TOPIC_METRICS_FILE}" || true
  echo ""
  echo "group_metrics:"
  cat "${GROUP_METRICS_FILE}" || true
  echo ""
  echo "remediation_summary:"
  cat "${REMEDIATION_SUMMARY_FILE}" || true
  echo ""
  echo "fix_hints:"
  if [[ -s "${fixes_file}" ]]; then
    cat "${fixes_file}"
  else
    echo "- none"
  fi
} > "${REPORT_FILE}"

echo "${status}" > "${STATUS_FILE}"
echo "Phase 7 validation (${SCENARIO}) status: ${status}"
echo "Report: ${REPORT_FILE}"

if [[ "${status}" == "failed" ]]; then
  exit 2
fi
