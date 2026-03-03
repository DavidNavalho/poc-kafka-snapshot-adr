#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase7_scenarios.sh
source "${SCRIPT_DIR}/phase7_scenarios.sh"

SCENARIO="${1:-hard-stop}"
SNAPSHOT_ID="${2:-phase7-${SCENARIO}-$(timestamp_utc)}"
SNAPSHOT_DIR="${ROOT_DIR}/artifacts/snapshots/${SNAPSHOT_ID}"
LATEST_DIR="${ROOT_DIR}/artifacts/latest"
SOURCE_PHASE7_RUNTIME_DIR="${LATEST_DIR}/source/phase7/runtime"
mkdir -p "${SNAPSHOT_DIR}/source-data" "${LATEST_DIR}" "${SOURCE_PHASE7_RUNTIME_DIR}"

for broker in 1 2 3; do
  ensure_broker_data_present "${ROOT_DIR}/data/source" "${broker}"
done

start_background_load() {
  local live_txid="${PHASE7_BG_TXID}-${SCENARIO}"

  compose_cmd exec -T source-broker-1 bash -lc \
    "nohup timeout --signal=KILL ${PHASE7_BG_RUN_SECONDS}s kafka-producer-perf-test --topic ${PHASE7_NORMAL_TOPIC} --num-records ${PHASE7_BG_NUM_RECORDS} --throughput ${PHASE7_BG_THROUGHPUT} --payload-monotonic --producer-props bootstrap.servers=${SOURCE_BOOTSTRAP} acks=all linger.ms=0 >/tmp/phase7-bg-normal.log 2>&1 & echo \$! >/tmp/phase7-bg-normal.pid"
  compose_cmd exec -T source-broker-1 bash -lc \
    "nohup timeout --signal=KILL ${PHASE7_BG_RUN_SECONDS}s kafka-producer-perf-test --topic ${PHASE7_TXN_TOPIC} --num-records ${PHASE7_BG_NUM_RECORDS} --throughput ${PHASE7_BG_THROUGHPUT} --payload-monotonic --transactional-id ${live_txid} --transaction-duration-ms ${PHASE7_BG_TX_DURATION_MS} --producer-props bootstrap.servers=${SOURCE_BOOTSTRAP} acks=all linger.ms=0 >/tmp/phase7-bg-txn.log 2>&1 & echo \$! >/tmp/phase7-bg-txn.pid"

  echo "${live_txid}" > "${SOURCE_PHASE7_RUNTIME_DIR}/background_txid.txt"
}

copy_broker_dir() {
  local broker="$1"
  mkdir -p "${SNAPSHOT_DIR}/source-data/broker${broker}"
  rsync -a --delete "${ROOT_DIR}/data/source/broker${broker}/" "${SNAPSHOT_DIR}/source-data/broker${broker}/"
}

capture_hard_stop() {
  start_background_load
  sleep 5

  compose_cmd kill "${SOURCE_SERVICES[@]}" >/dev/null 2>&1 || true
  compose_cmd stop "${SOURCE_SERVICES[@]}" >/dev/null 2>&1 || true

  for broker in 1 2 3; do
    copy_broker_dir "${broker}"
  done
}

capture_skewed_stop_copy() {
  start_background_load
  sleep 5

  compose_cmd stop source-broker-1
  copy_broker_dir 1
  sleep "${PHASE7_SKEW_SECONDS_1}"

  compose_cmd stop source-broker-2
  copy_broker_dir 2
  sleep "${PHASE7_SKEW_SECONDS_2}"

  compose_cmd stop source-broker-3
  copy_broker_dir 3
}

capture_isr_skew() {
  start_background_load
  sleep 4

  compose_cmd kill source-broker-3 >/dev/null 2>&1 || true
  sleep 8

  compose_cmd stop source-broker-1
  copy_broker_dir 1
  sleep "${PHASE7_SKEW_SECONDS_1}"

  compose_cmd stop source-broker-2
  copy_broker_dir 2
  sleep "${PHASE7_SKEW_SECONDS_2}"

  copy_broker_dir 3
}

case "${SCENARIO}" in
  hard-stop)
    capture_hard_stop
    ;;
  skewed-stop-copy)
    capture_skewed_stop_copy
    ;;
  isr-skew)
    capture_isr_skew
    ;;
  *)
    echo "Unknown phase 7 scenario '${SCENARIO}'. Use one of: hard-stop, skewed-stop-copy, isr-skew." >&2
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
echo "${SCENARIO}" > "${LATEST_DIR}/phase7_scenario.txt"
echo "Snapshot ${SNAPSHOT_ID} (${SCENARIO}) copied from source -> target."
