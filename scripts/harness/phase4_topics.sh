#!/usr/bin/env bash
set -euo pipefail

# topic|partitions|seed_messages
PHASE4_TOPIC_SPECS=(
  "dr.p4.full-consume|4|800"
  "dr.p4.partial-consume|4|900"
  "dr.p4.unconsumed|3|500"
)

PHASE4_FULL_TOPIC="dr.p4.full-consume"
PHASE4_PARTIAL_TOPIC="dr.p4.partial-consume"

PHASE4_FULL_GROUP="${PHASE4_FULL_GROUP:-dr.phase4.group.full}"
PHASE4_PARTIAL_GROUP="${PHASE4_PARTIAL_GROUP:-dr.phase4.group.partial}"

PHASE4_PARTIAL_INITIAL_MESSAGES="${PHASE4_PARTIAL_INITIAL_MESSAGES:-300}"
PHASE4_PARTIAL_RESUME_MESSAGES="${PHASE4_PARTIAL_RESUME_MESSAGES:-120}"
