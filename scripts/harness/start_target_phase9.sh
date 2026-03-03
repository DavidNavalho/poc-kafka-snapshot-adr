#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=phase9_scenarios.sh
source "${SCRIPT_DIR}/phase9_scenarios.sh"

SCENARIO="${1:-new-identity-direct-import}"
TARGET_PHASE9_DIR="${ROOT_DIR}/artifacts/latest/target/phase9/${SCENARIO}"
TARGET_HEALTH_DIR="${TARGET_PHASE9_DIR}/health"
mkdir -p "${TARGET_HEALTH_DIR}"

mode="$(phase9_expectation_mode "${SCENARIO}" || true)"
if [[ -z "${mode}" ]]; then
  echo "Unknown phase9 scenario '${SCENARIO}'. Valid: ${PHASE9_SCENARIOS[*]}" >&2
  exit 1
fi

if [[ "${mode}" == "blocked" ]]; then
  # new-identity-direct-import: meta.properties was intentionally deleted so the Confluent
  # image formats the target cluster fresh from TARGET_CLUSTER_ID on first boot.
  # Skip the meta.properties presence check and rely on the runtime env for TARGET_CLUSTER_ID.
  :
else
  for broker in 1 2 3; do
    ensure_broker_data_present "${ROOT_DIR}/data/target" "${broker}"
  done
fi

load_runtime_env
if [[ -z "${TARGET_CLUSTER_ID:-}" ]]; then
  if [[ "${mode}" == "blocked" ]]; then
    echo "TARGET_CLUSTER_ID must be set in runtime.env for blocked (direct-import) mode" >&2
    exit 1
  fi
  TARGET_CLUSTER_ID="$(grep '^cluster.id=' "${ROOT_DIR}/data/target/broker1/meta.properties" | cut -d= -f2)"
  upsert_runtime_var "TARGET_CLUSTER_ID" "${TARGET_CLUSTER_ID}"
fi

compose_cmd up -d "${TARGET_SERVICES[@]}"

target_ready="no"
if wait_for_bootstrap "target-broker-1" "${TARGET_BOOTSTRAP}" "${PHASE9_START_WAIT_RETRIES}"; then
  target_ready="yes"
fi

for broker in 1 2 3; do
  compose_cmd logs --no-color --tail=400 "target-broker-${broker}" > "${TARGET_HEALTH_DIR}/target-broker-${broker}.log" || true
done
compose_cmd ps > "${TARGET_HEALTH_DIR}/compose_ps.txt" || true

if [[ "${target_ready}" == "yes" ]]; then
  compose_cmd exec -T target-broker-1 bash -lc \
    "kafka-metadata-quorum --bootstrap-server ${TARGET_BOOTSTRAP} describe --status" \
    > "${TARGET_HEALTH_DIR}/metadata_quorum_status.txt" 2>&1 || true
  # Both profiles expect the cluster to be reachable after boot.
  # For 'blocked' (direct-import): broker formats fresh; source topic partitions become
  # stray (§4.13) so data is blocked, but the cluster itself is up.
  # For 'allowed': broker starts with full consistent state; all data accessible.
  echo "Target cluster is reachable (expected for phase9 ${mode} profile)."
  exit 0
fi

echo "Target cluster is not reachable (unexpected for phase9 ${mode} profile)."
exit 1
