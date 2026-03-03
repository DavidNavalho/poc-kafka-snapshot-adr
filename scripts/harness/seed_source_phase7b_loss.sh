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

SOURCE_PHASE7B_ATTEMPT_DIR="${ROOT_DIR}/artifacts/latest/source/phase7b/${SCENARIO}/attempt-${ATTEMPT_PAD}"
SOURCE_CHAOS_DIR="${SOURCE_PHASE7B_ATTEMPT_DIR}/chaos"
mkdir -p "${SOURCE_CHAOS_DIR}"

wait_for_bootstrap "source-broker-1" "${SOURCE_BOOTSTRAP}" 90

# Reuse phase 7 seed to keep realistic mixed datasets while adding a dedicated chaos topic.
"${SCRIPT_DIR}/seed_source_phase7.sh"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --create --if-not-exists --topic ${PHASE7B_CHAOS_TOPIC} --replica-assignment ${PHASE7B_CHAOS_REPLICA_ASSIGNMENT}"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-configs --bootstrap-server ${SOURCE_BOOTSTRAP} --alter --entity-type topics --entity-name ${PHASE7B_CHAOS_TOPIC} --add-config min.insync.replicas=1,unclean.leader.election.enable=true"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-topics --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --topic ${PHASE7B_CHAOS_TOPIC}" \
  > "${SOURCE_CHAOS_DIR}/topic_describe.txt"

compose_cmd exec -T source-broker-1 bash -lc \
  "kafka-configs --bootstrap-server ${SOURCE_BOOTSTRAP} --describe --entity-type topics --entity-name ${PHASE7B_CHAOS_TOPIC}" \
  > "${SOURCE_CHAOS_DIR}/topic_configs.txt"

echo "Scenario=${SCENARIO}" > "${SOURCE_CHAOS_DIR}/seed_meta.txt"
echo "Attempt=${ATTEMPT_PAD}" >> "${SOURCE_CHAOS_DIR}/seed_meta.txt"
echo "Chaos topic=${PHASE7B_CHAOS_TOPIC}" >> "${SOURCE_CHAOS_DIR}/seed_meta.txt"
echo "Chaos topic prepared on source."
