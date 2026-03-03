#!/usr/bin/env bash
set -euo pipefail

# topic|cleanup_policy|partitions|seed_messages|value_schema_file|record_mode|key_schema_file
PHASE3_TOPIC_SPECS=(
  "dr.p3.orders.proto|delete|6|500|/opt/schemas/order_event.proto|orders|"
  "dr.p3.customer-state.proto|compact|4|650|/opt/schemas/customer_state.proto|state|/opt/schemas/customer_key.proto"
)

PHASE3_POST_RESTORE_PER_TOPIC="${PHASE3_POST_RESTORE_PER_TOPIC:-50}"
