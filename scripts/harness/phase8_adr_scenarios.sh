#!/usr/bin/env bash
set -euo pipefail

# Wave 1 scenarios from snapshot-recovery-adr.md:
# - T7: meta.properties mismatch (cluster.id)
# - T8: simultaneous crash baseline
# - T3: stale HWM checkpoint
# - T5: in-flight transaction (ONGOING → auto-abort path; PREPARE_COMMIT recovery)
# - T6: producer state inconsistency (stale snapshot + truncated log)
# Wave 2 scenarios:
# - T1: stale quorum-state / new leader election (ADR T1, runbook §4.3)
# - T4: truncated log segment standalone (ADR T4, runbook §4.7)
# - T7b: node.id mismatch (ADR T7 variant, runbook §4.2)
# - T10: consumer-group offset re-processing window (ADR T10, runbook §4.10)
PHASE8_ADR_SCENARIOS=(
  "t7-meta-properties-mismatch"
  "t8-simultaneous-crash-baseline"
  "t3-stale-hwm-checkpoint"
  "t5-prepare-commit-recovery"
  "t6-producer-state-inconsistency"
  "t1-stale-quorum-state"
  "t4-truncated-segment"
  "t7b-node-id-mismatch"
  "t10-consumer-group-reprocessing"
)

# Fixed assertion field union used by run summaries.
PHASE8_ADR_ASSERTION_FIELDS=(
  "start_target_rc_zero"
  "cluster_reachable"
  "topics_describe_succeeds"
  "broker2_meta_mismatch_detected"
  "broker2_reachable"
  "all_three_brokers_reachable"
  "base_topic_offsets_readable"
  "target_base_topic_nonzero"
  "no_data_regression_vs_source"
  "group_offsets_readable"
  "t3_mutation_metadata_present"
  "t3_checkpoint_was_staled"
  "t3_checkpoint_recovered"
  "t3_consumer_reads_past_stale_hwm"
  "no_offline_partitions"
  "smoke_produce_consume"
  "t5_txn_metadata_present"
  "t5_uncommitted_visible"
  "t5_read_committed_progress"
  "t5_read_uncommitted_ge_committed"
  "t5_txn_list_contains_id"
  "t6_mutation_metadata_present"
  "t6_snapshot_files_pruned"
  "t6_log_tail_truncated"
  "t6_recovery_log_detected"
  "t6_exception_detected"
  "t6_exception_kind_expected"
  "t6_reinit_produce_succeeds"
  "t1_mutation_metadata_present"
  "t1_quorum_state_mutated"
  "t1_new_leader_elected"
  "t4_mutation_metadata_present"
  "t4_segment_was_truncated"
  "t4_recovery_log_detected"
  "t7b_node_id_mismatch_detected"
  "t7b_rejected_broker_unreachable"
  "t10_mutation_metadata_present"
  "t10_group_offset_regressed"
)

PHASE8_ADR_TOPIC_BASE="${PHASE8_ADR_TOPIC_BASE:-dr.p8.adr.base}"
PHASE8_ADR_TOPIC_T3="${PHASE8_ADR_TOPIC_T3:-dr.p8.adr.hwm}"
PHASE8_ADR_TOPIC_T5="${PHASE8_ADR_TOPIC_T5:-dr.p8.adr.t5.txn}"
PHASE8_ADR_TOPIC_T6="${PHASE8_ADR_TOPIC_T6:-dr.p8.adr.t6.idem}"

PHASE8_ADR_BASE_PARTITIONS="${PHASE8_ADR_BASE_PARTITIONS:-3}"
PHASE8_ADR_BASE_MESSAGES="${PHASE8_ADR_BASE_MESSAGES:-1500}"

PHASE8_ADR_T3_PARTITIONS="${PHASE8_ADR_T3_PARTITIONS:-1}"
PHASE8_ADR_T3_MESSAGES="${PHASE8_ADR_T3_MESSAGES:-1000}"
PHASE8_ADR_T3_STALE_DELTA="${PHASE8_ADR_T3_STALE_DELTA:-300}"

PHASE8_ADR_T5_PARTITIONS="${PHASE8_ADR_T5_PARTITIONS:-2}"
PHASE8_ADR_T5_COMMITTED_MESSAGES="${PHASE8_ADR_T5_COMMITTED_MESSAGES:-300}"
PHASE8_ADR_T5_HANG_MAX_RECORDS="${PHASE8_ADR_T5_HANG_MAX_RECORDS:-120000}"
PHASE8_ADR_T5_HANG_THROUGHPUT="${PHASE8_ADR_T5_HANG_THROUGHPUT:-400}"
PHASE8_ADR_T5_HANG_RUN_SECONDS="${PHASE8_ADR_T5_HANG_RUN_SECONDS:-8}"
PHASE8_ADR_T5_LONG_TX_DURATION_MS="${PHASE8_ADR_T5_LONG_TX_DURATION_MS:-300000}"
PHASE8_ADR_T5_TXID="${PHASE8_ADR_T5_TXID:-dr.phase8.adr.t5.txn}"

PHASE8_ADR_T6_PARTITIONS="${PHASE8_ADR_T6_PARTITIONS:-1}"
PHASE8_ADR_T6_MESSAGES="${PHASE8_ADR_T6_MESSAGES:-4000}"
PHASE8_ADR_T6_RECORD_SIZE="${PHASE8_ADR_T6_RECORD_SIZE:-1024}"
PHASE8_ADR_T6_TXID="${PHASE8_ADR_T6_TXID:-dr.phase8.adr.t6.txn}"
PHASE8_ADR_T6_PROBE_TIMEOUT_SECONDS="${PHASE8_ADR_T6_PROBE_TIMEOUT_SECONDS:-20}"
PHASE8_ADR_T6_PROBE_RECORDS_A="${PHASE8_ADR_T6_PROBE_RECORDS_A:-40000}"
PHASE8_ADR_T6_PROBE_RECORDS_B="${PHASE8_ADR_T6_PROBE_RECORDS_B:-200}"
PHASE8_ADR_T6_PROBE_THROUGHPUT="${PHASE8_ADR_T6_PROBE_THROUGHPUT:-400}"
PHASE8_ADR_T6_TRUNCATE_BYTES="${PHASE8_ADR_T6_TRUNCATE_BYTES:-1024}"
PHASE8_ADR_T6_PRUNE_NEWEST_SNAPSHOTS="${PHASE8_ADR_T6_PRUNE_NEWEST_SNAPSHOTS:-1}"

PHASE8_ADR_T8_GROUP="${PHASE8_ADR_T8_GROUP:-dr.phase8.adr.t8.group}"
PHASE8_ADR_T8_GROUP_MESSAGES="${PHASE8_ADR_T8_GROUP_MESSAGES:-800}"

PHASE8_ADR_TOPIC_T4="${PHASE8_ADR_TOPIC_T4:-dr.p8.adr.t4.seg}"
PHASE8_ADR_T4_PARTITIONS="${PHASE8_ADR_T4_PARTITIONS:-1}"
PHASE8_ADR_T4_MESSAGES="${PHASE8_ADR_T4_MESSAGES:-800}"
PHASE8_ADR_T4_TRUNCATE_BYTES="${PHASE8_ADR_T4_TRUNCATE_BYTES:-1024}"

PHASE8_ADR_T7B_STALE_NODE_ID="${PHASE8_ADR_T7B_STALE_NODE_ID:-99}"

PHASE8_ADR_T10_GROUP="${PHASE8_ADR_T10_GROUP:-dr.phase8.adr.t10.group}"
PHASE8_ADR_T10_GROUP_MESSAGES="${PHASE8_ADR_T10_GROUP_MESSAGES:-500}"
PHASE8_ADR_T10_STALE_DELTA="${PHASE8_ADR_T10_STALE_DELTA:-200}"

PHASE8_ADR_SMOKE_TOPIC="${PHASE8_ADR_SMOKE_TOPIC:-dr.p8.adr.base}"
PHASE8_ADR_SMOKE_MESSAGES="${PHASE8_ADR_SMOKE_MESSAGES:-30}"
PHASE8_ADR_SMOKE_CONSUME="${PHASE8_ADR_SMOKE_CONSUME:-20}"
