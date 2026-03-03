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
SNAPSHOT_ID="${3:-phase7b-${SCENARIO}-a${ATTEMPT_PAD}-$(timestamp_utc)}"
SNAPSHOT_DIR="${ROOT_DIR}/artifacts/snapshots/${SNAPSHOT_ID}"
LATEST_DIR="${ROOT_DIR}/artifacts/latest"
SOURCE_ATTEMPT_DIR="${LATEST_DIR}/source/phase7b/${SCENARIO}/attempt-${ATTEMPT_PAD}"
SOURCE_CHAOS_DIR="${SOURCE_ATTEMPT_DIR}/chaos"
mkdir -p "${SNAPSHOT_DIR}/source-data" "${SOURCE_CHAOS_DIR}" "${LATEST_DIR}"

for broker in 1 2 3; do
  ensure_broker_data_present "${ROOT_DIR}/data/source" "${broker}"
done

parse_acked_ids() {
  local in_file="$1"
  local out_file="$2"

  grep '"name":"producer_send_success"' "${in_file}" \
    | sed -En 's/.*"value":"?([0-9]+)"?.*/\1/p' \
    | LC_ALL=C sort -n -u > "${out_file}" || true
}

safe_rsync_source_to_snapshot() {
  local from="$1"
  local to="$2"

  set +e
  rsync -a --delete "${from}" "${to}"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 && "${rc}" -ne 24 ]]; then
    echo "rsync failed with rc=${rc} while copying ${from} -> ${to}" >&2
    exit 1
  fi
}

produce_acks1_with_skewed_stops() {
  # Combined KRaft broker/controller nodes cannot lose 2/3 nodes without quorum loss.
  # Instead, keep quorum while producing and stop brokers in skewed order to snapshot
  # out-of-sync replicas for bounded-loss recovery testing on the target cluster.
  compose_cmd exec -T source-broker-1 bash -lc \
    "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --topic ${PHASE7B_CHAOS_TOPIC}" \
    > "${SOURCE_CHAOS_DIR}/topic_describe_before_pause.txt"

  set +e
  compose_cmd exec -T source-broker-1 bash -lc \
    "timeout --signal=KILL ${PHASE7B_ACKS1_PRODUCE_SECONDS}s kafka-verifiable-producer --topic ${PHASE7B_CHAOS_TOPIC} --bootstrap-server ${SOURCE_BOOTSTRAP} --acks 1 --max-messages ${PHASE7B_ACKS1_MAX_MESSAGES} --throughput ${PHASE7B_ACKS1_THROUGHPUT}" \
    > "${SOURCE_CHAOS_DIR}/verifiable_producer.raw.log" 2>&1 &
  producer_pid=$!
  set -e

  sleep 4
  compose_cmd stop source-broker-3 >/dev/null
  sleep "${PHASE7B_SKEW_SECONDS_1}"
  compose_cmd stop source-broker-2 >/dev/null
  sleep "${PHASE7B_SKEW_SECONDS_2}"
  compose_cmd stop source-broker-1 >/dev/null

  set +e
  wait "${producer_pid}"
  producer_rc=$?
  set -e
  # `timeout`/container stop can return 124/137/143 and are expected in this flow.
  if [[ "${producer_rc}" -ne 0 && "${producer_rc}" -ne 124 && "${producer_rc}" -ne 137 && "${producer_rc}" -ne 143 ]]; then
    echo "Verifiable producer failed for deterministic scenario (rc=${producer_rc})." >&2
    exit 1
  fi

  parse_acked_ids "${SOURCE_CHAOS_DIR}/verifiable_producer.raw.log" "${SOURCE_CHAOS_DIR}/acked_ids.txt"
  wc -l < "${SOURCE_CHAOS_DIR}/acked_ids.txt" | tr -d ' ' > "${SOURCE_CHAOS_DIR}/acked_count.txt"

  cp "${SOURCE_CHAOS_DIR}/topic_describe_before_pause.txt" "${SOURCE_CHAOS_DIR}/topic_describe_after_pause.txt"
}

produce_acks_all_during_live_copy() {
  set +e
  compose_cmd exec -T source-broker-1 bash -lc \
    "timeout --signal=KILL ${PHASE7B_LIVE_PRODUCE_SECONDS}s kafka-verifiable-producer --topic ${PHASE7B_CHAOS_TOPIC} --bootstrap-server ${SOURCE_BOOTSTRAP} --acks -1 --max-messages -1 --throughput ${PHASE7B_ACKS_ALL_THROUGHPUT}" \
    > "${SOURCE_CHAOS_DIR}/verifiable_producer.raw.log" 2>&1 &
  producer_pid=$!
  set -e

  sleep "${PHASE7B_LIVE_COPY_START_DELAY_SECONDS}"
  safe_rsync_source_to_snapshot "${ROOT_DIR}/data/source/" "${SNAPSHOT_DIR}/source-data/"

  set +e
  wait "${producer_pid}"
  producer_rc=$?
  set -e
  # `timeout` on verifiable producer is expected to exit 124/137.
  if [[ "${producer_rc}" -ne 0 && "${producer_rc}" -ne 124 && "${producer_rc}" -ne 137 ]]; then
    echo "Live-copy producer exited unexpectedly (rc=${producer_rc})." >&2
    exit 1
  fi

  parse_acked_ids "${SOURCE_CHAOS_DIR}/verifiable_producer.raw.log" "${SOURCE_CHAOS_DIR}/acked_ids.txt"
  wc -l < "${SOURCE_CHAOS_DIR}/acked_ids.txt" | tr -d ' ' > "${SOURCE_CHAOS_DIR}/acked_count.txt"
}

case "${SCENARIO}" in
  loss-acks1-unclean-target)
    produce_acks1_with_skewed_stops
    safe_rsync_source_to_snapshot "${ROOT_DIR}/data/source/" "${SNAPSHOT_DIR}/source-data/"
    ;;
  loss-live-copy-flush-window)
    produce_acks_all_during_live_copy
    compose_cmd kill "${SOURCE_SERVICES[@]}" >/dev/null 2>&1 || true
    compose_cmd stop "${SOURCE_SERVICES[@]}" >/dev/null 2>&1 || true
    ;;
  *)
    echo "Unknown phase 7b scenario '${SCENARIO}'." >&2
    exit 1
    ;;
esac

compose_cmd stop "${SOURCE_SCHEMA_SERVICE}" >/dev/null 2>&1 || true
compose_cmd stop "${TARGET_SCHEMA_SERVICE}" >/dev/null 2>&1 || true
compose_cmd stop "${TARGET_SERVICES[@]}" >/dev/null 2>&1 || true
compose_cmd stop "${SOURCE_SERVICES[@]}" >/dev/null 2>&1 || true

rsync -a --delete "${SNAPSHOT_DIR}/source-data/" "${ROOT_DIR}/data/target/"

for broker in 1 2 3; do
  ensure_broker_data_present "${ROOT_DIR}/data/target" "${broker}"
done

TARGET_CLUSTER_ID="$(grep '^cluster.id=' "${ROOT_DIR}/data/target/broker1/meta.properties" | cut -d= -f2)"
upsert_runtime_var "TARGET_CLUSTER_ID" "${TARGET_CLUSTER_ID}"

echo "${SNAPSHOT_ID}" > "${LATEST_DIR}/snapshot_id.txt"
echo "${SCENARIO}" > "${LATEST_DIR}/phase7b_scenario.txt"
echo "${ATTEMPT_PAD}" > "${LATEST_DIR}/phase7b_attempt.txt"
echo "Phase7b snapshot ${SNAPSHOT_ID} (${SCENARIO}, attempt ${ATTEMPT_PAD}) copied source -> target."
