#!/usr/bin/env bash
set -euo pipefail

# topic|cleanup_policy|partitions|seed_messages|key_mode
PHASE2_TOPIC_SPECS=(
  "dr.p2.orders|delete|6|900|event"
  "dr.p2.audit|delete|3|450|event"
  "dr.p2.customer-state|compact|5|700|state"
)

PHASE2_POST_RESTORE_PER_TOPIC="${PHASE2_POST_RESTORE_PER_TOPIC:-60}"
