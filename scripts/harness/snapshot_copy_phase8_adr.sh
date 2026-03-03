#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase8_adr_scenarios.sh
source "${SCRIPT_DIR}/phase8_adr_scenarios.sh"

SCENARIO="${1:?phase8 ADR scenario is required}"
SNAPSHOT_ID="${2:-phase8-adr-${SCENARIO}-$(timestamp_utc)}"
SNAPSHOT_DIR="${ROOT_DIR}/artifacts/snapshots/${SNAPSHOT_ID}"
LATEST_DIR="${ROOT_DIR}/artifacts/latest"
SOURCE_PHASE8_RUNTIME_ENV="${LATEST_DIR}/source/phase8_adr/runtime/phase8_runtime.env"
TARGET_SCENARIO_DIR="${LATEST_DIR}/target/phase8_adr/${SCENARIO}"
MUTATION_ENV_FILE="${TARGET_SCENARIO_DIR}/mutation.env"
mkdir -p "${SNAPSHOT_DIR}/source-data" "${LATEST_DIR}" "${TARGET_SCENARIO_DIR}"

declare -a valid_scenarios=("${PHASE8_ADR_SCENARIOS[@]}")
is_valid=0
for expected in "${valid_scenarios[@]}"; do
  if [[ "${SCENARIO}" == "${expected}" ]]; then
    is_valid=1
    break
  fi
done
if [[ "${is_valid}" -ne 1 ]]; then
  echo "Unknown phase8 ADR scenario '${SCENARIO}'. Valid: ${PHASE8_ADR_SCENARIOS[*]}" >&2
  exit 1
fi

if [[ ! -f "${SOURCE_PHASE8_RUNTIME_ENV}" ]]; then
  echo "Missing source runtime env: ${SOURCE_PHASE8_RUNTIME_ENV}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${SOURCE_PHASE8_RUNTIME_ENV}"

for broker in 1 2 3; do
  ensure_broker_data_present "${ROOT_DIR}/data/source" "${broker}"
done

copy_broker_dir() {
  local broker="$1"
  mkdir -p "${SNAPSHOT_DIR}/source-data/broker${broker}"
  rsync -a --delete "${ROOT_DIR}/data/source/broker${broker}/" "${SNAPSHOT_DIR}/source-data/broker${broker}/"
}

capture_hard_stop_snapshot() {
  compose_cmd kill "${SOURCE_SERVICES[@]}" >/dev/null 2>&1 || true
  compose_cmd stop "${SOURCE_SERVICES[@]}" >/dev/null 2>&1 || true

  for broker in 1 2 3; do
    copy_broker_dir "${broker}"
  done
}

toggle_cluster_id() {
  local current="$1"
  local first="${current:0:1}"
  local rest="${current:1}"
  if [[ "${first}" == "A" ]]; then
    printf "B%s\n" "${rest}"
  else
    printf "A%s\n" "${rest}"
  fi
}

read_checkpoint_offset() {
  local file="$1"
  local topic="$2"
  local partition="$3"
  awk -v topic="${topic}" -v partition="${partition}" '
    NR > 2 && $1 == topic && $2 == partition {
      print $3
      found = 1
      exit
    }
    END {
      if (!found) {
        print ""
      }
    }
  ' "${file}"
}

update_checkpoint_offset() {
  local file="$1"
  local topic="$2"
  local partition="$3"
  local offset="$4"
  local tmp_file
  tmp_file="$(mktemp)"

  awk -v topic="${topic}" -v partition="${partition}" -v offset="${offset}" '
    NR == 1 {
      version = $0
      next
    }
    NR == 2 {
      next
    }
    NR > 2 {
      t = $1
      p = $2
      o = $3
      if (t == topic && p == partition) {
        o = offset
        found = 1
      }
      entries[++n] = t " " p " " o
    }
    END {
      if (version == "") {
        version = "0"
      }
      if (!found) {
        entries[++n] = topic " " partition " " offset
      }
      print version
      print n
      for (i = 1; i <= n; i++) {
        print entries[i]
      }
    }
  ' "${file}" > "${tmp_file}"

  mv "${tmp_file}" "${file}"
}

capture_hard_stop_snapshot

compose_cmd stop "${SOURCE_SCHEMA_SERVICE}" >/dev/null 2>&1 || true
compose_cmd stop "${TARGET_SCHEMA_SERVICE}" >/dev/null 2>&1 || true
compose_cmd stop "${TARGET_SERVICES[@]}" >/dev/null 2>&1 || true
compose_cmd stop "${SOURCE_SERVICES[@]}" >/dev/null 2>&1 || true

rsync -a --delete "${SNAPSHOT_DIR}/source-data/" "${ROOT_DIR}/data/target/"

for broker in 1 2 3; do
  ensure_broker_data_present "${ROOT_DIR}/data/target" "${broker}"
done

cat > "${MUTATION_ENV_FILE}" <<EOF
scenario=${SCENARIO}
EOF

case "${SCENARIO}" in
  t7-meta-properties-mismatch)
    meta_file="${ROOT_DIR}/data/target/broker2/meta.properties"
    old_cluster_id="$(grep '^cluster.id=' "${meta_file}" | cut -d= -f2)"
    new_cluster_id="$(toggle_cluster_id "${old_cluster_id}")"
    tmp_meta="$(mktemp)"
    awk -F= -v new_cluster_id="${new_cluster_id}" '
      BEGIN {OFS = "="}
      $1 == "cluster.id" {$2 = new_cluster_id}
      {print $1, $2}
    ' "${meta_file}" > "${tmp_meta}"
    mv "${tmp_meta}" "${meta_file}"
    {
      echo "t7_mutated_broker=2"
      echo "t7_cluster_id_old=${old_cluster_id}"
      echo "t7_cluster_id_new=${new_cluster_id}"
    } >> "${MUTATION_ENV_FILE}"
    ;;
  t3-stale-hwm-checkpoint)
    t3_topic="${source_t3_topic}"
    t3_partition="${source_t3_partition}"
    t3_leader_broker="${source_t3_leader_broker}"
    t3_source_end_offset="${source_t3_end_offset}"
    t3_checkpoint_file="${ROOT_DIR}/data/target/broker${t3_leader_broker}/replication-offset-checkpoint"
    if [[ ! -f "${t3_checkpoint_file}" ]]; then
      echo "Missing checkpoint file for stale HWM scenario: ${t3_checkpoint_file}" >&2
      exit 1
    fi

    stale_target_offset=$((t3_source_end_offset - PHASE8_ADR_T3_STALE_DELTA))
    if [[ "${stale_target_offset}" -lt 0 ]]; then
      stale_target_offset=0
    fi

    original_offset="$(read_checkpoint_offset "${t3_checkpoint_file}" "${t3_topic}" "${t3_partition}")"
    if [[ -z "${original_offset}" ]]; then
      original_offset="${t3_source_end_offset}"
    fi
    update_checkpoint_offset "${t3_checkpoint_file}" "${t3_topic}" "${t3_partition}" "${stale_target_offset}"
    new_offset="$(read_checkpoint_offset "${t3_checkpoint_file}" "${t3_topic}" "${t3_partition}")"

    {
      echo "t3_topic=${t3_topic}"
      echo "t3_partition=${t3_partition}"
      echo "t3_leader_broker=${t3_leader_broker}"
      echo "t3_hwm_before=${original_offset}"
      echo "t3_hwm_after=${new_offset}"
      echo "t3_checkpoint_file=${t3_checkpoint_file}"
    } >> "${MUTATION_ENV_FILE}"
    ;;
  t8-simultaneous-crash-baseline)
    {
      echo "t8_source_base_end_sum=${source_base_end_sum}"
      echo "t8_source_group=${source_t8_group}"
      echo "t8_source_group_committed_sum=${source_t8_committed_sum}"
    } >> "${MUTATION_ENV_FILE}"
    ;;
  t5-prepare-commit-recovery)
    {
      echo "t5_topic=${source_t5_topic}"
      echo "t5_txid=${source_t5_txid}"
      echo "t5_source_read_uncommitted_count=${source_t5_read_uncommitted_count:-0}"
      echo "t5_source_read_committed_count=${source_t5_read_committed_count:-0}"
    } >> "${MUTATION_ENV_FILE}"
    ;;
  t1-stale-quorum-state)
    # Lower leaderEpoch to 0 and clear votedId in every broker's quorum-state file.
    # This forces KRaft to run a fresh leader election on next start rather than trusting
    # the stale in-memory state — exactly the scenario described in ADR T1 / runbook §4.3.
    #
    # We extract the original leaderEpoch as a plain integer before mutation rather than
    # storing the full JSON string.  The quorum-state JSON contains commas inside braces,
    # which bash interprets as brace expansion when the file is sourced — mangling the
    # value.  Storing only the integer avoids that hazard entirely.
    t1_brokers_mutated=0
    t1_original_epoch=""
    for broker in 1 2 3; do
      quorum_file="${ROOT_DIR}/data/target/broker${broker}/__cluster_metadata-0/quorum-state"
      if [[ ! -f "${quorum_file}" ]]; then
        continue
      fi
      if [[ -z "${t1_original_epoch}" ]]; then
        t1_original_epoch="$(awk -F'"leaderEpoch":' 'NF>1{split($2,a,/[^0-9]/); print a[1]; exit}' "${quorum_file}")"
      fi
      tmp_q="$(mktemp)"
      awk '
        {
          gsub(/"leaderEpoch":[[:space:]]*[0-9]+/, "\"leaderEpoch\":0")
          gsub(/"votedId":[[:space:]]*[0-9-]+/, "\"votedId\":-1")
          print
        }
      ' "${quorum_file}" > "${tmp_q}"
      mv "${tmp_q}" "${quorum_file}"
      t1_brokers_mutated=$((t1_brokers_mutated + 1))
    done
    {
      echo "t1_original_epoch=${t1_original_epoch:-0}"
      echo "t1_brokers_mutated=${t1_brokers_mutated}"
    } >> "${MUTATION_ENV_FILE}"
    ;;

  t4-truncated-segment)
    # Find the active log segment for T4 topic partition 0 on the leader broker and
    # truncate the last T4_TRUNCATE_BYTES bytes — simulating a crash mid-write.
    # This is the standalone test of ADR T4 / runbook §4.7 log recovery.
    t4_topic="${source_t4_topic}"
    t4_partition="${source_t4_partition}"
    t4_leader_broker="${source_t4_leader_broker}"
    t4_partition_dir="${ROOT_DIR}/data/target/broker${t4_leader_broker}/${t4_topic}-${t4_partition}"
    if [[ ! -d "${t4_partition_dir}" ]]; then
      echo "Missing T4 partition dir on target snapshot: ${t4_partition_dir}" >&2
      exit 1
    fi

    active_log="$(ls -1 "${t4_partition_dir}"/*.log 2>/dev/null | LC_ALL=C sort | tail -n 1 || true)"
    if [[ -z "${active_log}" ]]; then
      echo "Unable to locate active log segment for T4 mutation in ${t4_partition_dir}" >&2
      exit 1
    fi
    t4_log_bytes_before="$(wc -c < "${active_log}" | tr -d ' ')"
    truncate_bytes="${PHASE8_ADR_T4_TRUNCATE_BYTES}"
    t4_log_bytes_after=$((t4_log_bytes_before - truncate_bytes))
    if [[ "${t4_log_bytes_after}" -lt 1 ]]; then
      t4_log_bytes_after=$((t4_log_bytes_before / 2))
    fi
    if [[ "${t4_log_bytes_after}" -lt 1 ]]; then
      t4_log_bytes_after=1
    fi
    tmp_log="$(mktemp)"
    head -c "${t4_log_bytes_after}" "${active_log}" > "${tmp_log}"
    mv "${tmp_log}" "${active_log}"
    t4_log_bytes_after="$(wc -c < "${active_log}" | tr -d ' ')"

    {
      echo "t4_topic=${t4_topic}"
      echo "t4_partition=${t4_partition}"
      echo "t4_leader_broker=${t4_leader_broker}"
      echo "t4_partition_dir=${t4_partition_dir}"
      echo "t4_truncated_log_file=${active_log}"
      echo "t4_log_bytes_before=${t4_log_bytes_before}"
      echo "t4_log_bytes_after=${t4_log_bytes_after}"
      echo "t4_source_end_offset=${source_t4_end_offset}"
    } >> "${MUTATION_ENV_FILE}"
    ;;

  t7b-node-id-mismatch)
    # Change node.id in broker2's meta.properties to a non-existent node ID.
    # server.properties keeps node.id=2 but meta.properties will say node.id=T7B_STALE_NODE_ID.
    # Kafka checks these on startup and refuses to bring that broker online —
    # proving runbook §4.2 guidance (cordon the broker, do not force-restore).
    meta_file="${ROOT_DIR}/data/target/broker2/meta.properties"
    old_node_id="$(grep '^node.id=' "${meta_file}" | cut -d= -f2)"
    new_node_id="${PHASE8_ADR_T7B_STALE_NODE_ID}"
    tmp_meta="$(mktemp)"
    awk -F= -v new_node_id="${new_node_id}" '
      BEGIN {OFS = "="}
      $1 == "node.id" {$2 = new_node_id}
      {print $1, $2}
    ' "${meta_file}" > "${tmp_meta}"
    mv "${tmp_meta}" "${meta_file}"
    {
      echo "t7b_mutated_broker=2"
      echo "t7b_node_id_old=${old_node_id}"
      echo "t7b_node_id_new=${new_node_id}"
    } >> "${MUTATION_ENV_FILE}"
    ;;

  t10-consumer-group-reprocessing)
    # Simulate §4.10 consumer-group offset reprocessing: remove all __consumer_offsets
    # partition directories from the target snapshot.
    #
    # This models the most common snapshot-restore gap: the raw topic data is captured
    # but __consumer_offsets is excluded (e.g. the snapshot tool skips internal topics).
    # Without __consumer_offsets the broker creates a fresh empty partition on first boot,
    # so all consumer groups lose their committed offsets.  The reprocessing window equals
    # the full committed offset sum that was present on the source.
    #
    # The earlier approach of lowering replication-offset-checkpoint by a delta did NOT
    # produce observable offset regression: all three replicas have the full
    # __consumer_offsets data, the ISR forms immediately on restart, and the HWM catches
    # up to the log end before the validation query runs.  Deleting the dirs is the only
    # reliable way to force zero committed offsets on the target.
    t10_dirs_removed=0
    for broker in 1 2 3; do
      for cg_dir in "${ROOT_DIR}/data/target/broker${broker}"/__consumer_offsets-*; do
        if [[ -d "${cg_dir}" ]]; then
          rm -rf "${cg_dir}"
          t10_dirs_removed=$((t10_dirs_removed + 1))
        fi
      done
    done
    {
      echo "t10_group=${source_t10_group}"
      echo "t10_source_committed_sum=${source_t10_committed_sum}"
      echo "t10_dirs_removed=${t10_dirs_removed}"
    } >> "${MUTATION_ENV_FILE}"
    ;;

  t6-producer-state-inconsistency)
    t6_topic="${source_t6_topic}"
    t6_partition="${source_t6_partition}"
    t6_leader_broker="${source_t6_leader_broker}"
    t6_partition_dir="${ROOT_DIR}/data/target/broker${t6_leader_broker}/${t6_topic}-${t6_partition}"
    if [[ ! -d "${t6_partition_dir}" ]]; then
      echo "Missing T6 partition dir on target snapshot: ${t6_partition_dir}" >&2
      exit 1
    fi

    snapshot_files="$(ls -1 "${t6_partition_dir}"/*.snapshot 2>/dev/null | LC_ALL=C sort || true)"
    snapshot_count_before="$(printf '%s\n' "${snapshot_files}" | sed '/^$/d' | wc -l | tr -d ' ')"
    prune_newest="${PHASE8_ADR_T6_PRUNE_NEWEST_SNAPSHOTS}"
    pruned_count=0
    pruned_files=""
    if [[ "${snapshot_count_before}" -gt 1 && "${prune_newest}" -gt 0 ]]; then
      keep_count=$((snapshot_count_before - prune_newest))
      if [[ "${keep_count}" -lt 1 ]]; then
        keep_count=1
      fi
      prune_start=$((keep_count + 1))
      snapshots_to_prune="$(printf '%s\n' "${snapshot_files}" | sed '/^$/d' | tail -n +"${prune_start}")"
      while IFS= read -r snapshot_file; do
        [[ -z "${snapshot_file}" ]] && continue
        rm -f "${snapshot_file}"
        pruned_count=$((pruned_count + 1))
        snapshot_name="$(basename "${snapshot_file}")"
        if [[ -z "${pruned_files}" ]]; then
          pruned_files="${snapshot_name}"
        else
          pruned_files="${pruned_files},${snapshot_name}"
        fi
      done <<< "${snapshots_to_prune}"
    fi
    snapshot_count_after="$(find "${t6_partition_dir}" -maxdepth 1 -type f -name '*.snapshot' | wc -l | tr -d ' ')"

    active_log="$(ls -1 "${t6_partition_dir}"/*.log 2>/dev/null | LC_ALL=C sort | tail -n 1 || true)"
    if [[ -z "${active_log}" ]]; then
      echo "Unable to locate active log segment for T6 mutation in ${t6_partition_dir}" >&2
      exit 1
    fi
    log_bytes_before="$(wc -c < "${active_log}" | tr -d ' ')"
    truncate_bytes="${PHASE8_ADR_T6_TRUNCATE_BYTES}"
    log_bytes_after=$((log_bytes_before - truncate_bytes))
    if [[ "${log_bytes_after}" -lt 1 ]]; then
      log_bytes_after=$((log_bytes_before / 2))
    fi
    if [[ "${log_bytes_after}" -lt 1 ]]; then
      log_bytes_after=1
    fi
    tmp_log="$(mktemp)"
    head -c "${log_bytes_after}" "${active_log}" > "${tmp_log}"
    mv "${tmp_log}" "${active_log}"
    log_bytes_after="$(wc -c < "${active_log}" | tr -d ' ')"

    {
      echo "t6_topic=${t6_topic}"
      echo "t6_partition=${t6_partition}"
      echo "t6_leader_broker=${t6_leader_broker}"
      echo "t6_txid=${source_t6_txid}"
      echo "t6_partition_dir=${t6_partition_dir}"
      echo "t6_snapshot_count_before=${snapshot_count_before}"
      echo "t6_snapshot_count_after=${snapshot_count_after}"
      echo "t6_pruned_count=${pruned_count}"
      echo "t6_pruned_files=${pruned_files:-none}"
      echo "t6_truncated_log_file=${active_log}"
      echo "t6_log_bytes_before=${log_bytes_before}"
      echo "t6_log_bytes_after=${log_bytes_after}"
      echo "t6_source_end_offset=${source_t6_end_offset}"
    } >> "${MUTATION_ENV_FILE}"
    ;;
esac

TARGET_CLUSTER_ID="$(grep '^cluster.id=' "${ROOT_DIR}/data/target/broker1/meta.properties" | cut -d= -f2)"
upsert_runtime_var "TARGET_CLUSTER_ID" "${TARGET_CLUSTER_ID}"

echo "${SNAPSHOT_ID}" > "${LATEST_DIR}/snapshot_id.txt"
echo "${SCENARIO}" > "${LATEST_DIR}/phase8_adr_scenario.txt"
echo "Phase8 ADR snapshot ${SNAPSHOT_ID} (${SCENARIO}) copied source -> target."
