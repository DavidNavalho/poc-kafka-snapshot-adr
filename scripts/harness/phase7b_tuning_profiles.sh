#!/usr/bin/env bash
set -euo pipefail

PHASE7B_TUNING_PROFILES=(
  "mild"
  "balanced"
  "aggressive"
)

apply_phase7b_tuning_profile() {
  local profile="${1:?profile is required}"

  case "${profile}" in
    mild)
      export PHASE7B_ACKS_ALL_THROUGHPUT="${PHASE7B_ACKS_ALL_THROUGHPUT:-800}"
      export PHASE7B_LIVE_PRODUCE_SECONDS="${PHASE7B_LIVE_PRODUCE_SECONDS:-20}"
      export PHASE7B_LIVE_COPY_START_DELAY_SECONDS="${PHASE7B_LIVE_COPY_START_DELAY_SECONDS:-4}"
      export PHASE7B_ITERATIONS="${PHASE7B_ITERATIONS:-3}"
      ;;
    balanced)
      export PHASE7B_ACKS_ALL_THROUGHPUT="${PHASE7B_ACKS_ALL_THROUGHPUT:-1300}"
      export PHASE7B_LIVE_PRODUCE_SECONDS="${PHASE7B_LIVE_PRODUCE_SECONDS:-26}"
      export PHASE7B_LIVE_COPY_START_DELAY_SECONDS="${PHASE7B_LIVE_COPY_START_DELAY_SECONDS:-2}"
      export PHASE7B_ITERATIONS="${PHASE7B_ITERATIONS:-4}"
      ;;
    aggressive)
      export PHASE7B_ACKS_ALL_THROUGHPUT="${PHASE7B_ACKS_ALL_THROUGHPUT:-2200}"
      export PHASE7B_LIVE_PRODUCE_SECONDS="${PHASE7B_LIVE_PRODUCE_SECONDS:-34}"
      export PHASE7B_LIVE_COPY_START_DELAY_SECONDS="${PHASE7B_LIVE_COPY_START_DELAY_SECONDS:-1}"
      export PHASE7B_ITERATIONS="${PHASE7B_ITERATIONS:-5}"
      ;;
    *)
      echo "Unknown phase7b tuning profile '${profile}'." >&2
      echo "Valid profiles: ${PHASE7B_TUNING_PROFILES[*]}" >&2
      return 1
      ;;
  esac
}

