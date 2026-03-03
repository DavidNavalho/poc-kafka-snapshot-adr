# Local Experiments Guide

This document is the canonical guide for running local harness experiments.

## 1. Prerequisites

- Docker Desktop/Engine running.
- Sufficient disk space for artifacts/snapshots.
- Run from repo root:

```bash
cd /Users/jinx/gits/kafka-disk-migration-experiments
```

## 2. ADR proof experiments (Phase 8)

Phase 8 runs the scenarios from `snapshot-recovery-adr.md` to prove the failure modes and
recovery paths documented in `snapshot-restore-runbook.md`.

Run all Phase 8 ADR scenarios:

```bash
scripts/harness/run_phase8_adr.sh all
```

Run a single Phase 8 ADR scenario:

```bash
scripts/harness/run_phase8_adr.sh t7-meta-properties-mismatch
scripts/harness/run_phase8_adr.sh t8-simultaneous-crash-baseline
scripts/harness/run_phase8_adr.sh t3-stale-hwm-checkpoint
scripts/harness/run_phase8_adr.sh t5-prepare-commit-recovery
scripts/harness/run_phase8_adr.sh t6-producer-state-inconsistency
scripts/harness/run_phase8_adr.sh t1-stale-quorum-state
scripts/harness/run_phase8_adr.sh t4-truncated-segment
scripts/harness/run_phase8_adr.sh t7b-node-id-mismatch
scripts/harness/run_phase8_adr.sh t10-consumer-group-reprocessing
```

Scenario → ADR / Runbook mapping:

| Scenario | ADR Test Design | Runbook §§ |
|---|---|---|
| `t1-stale-quorum-state` | T1 | §4.3 |
| `t3-stale-hwm-checkpoint` | T3 | §4.6 |
| `t4-truncated-segment` | T4 | §4.7 |
| `t5-prepare-commit-recovery` | T5 (ONGOING → auto-abort) | §4.8 |
| `t6-producer-state-inconsistency` | T6 | §4.9 |
| `t7-meta-properties-mismatch` | T7 (cluster.id) | §4.1 |
| `t7b-node-id-mismatch` | T7 (node.id) | §4.2 |
| `t8-simultaneous-crash-baseline` | T8 | §4.12 |
| `t10-consumer-group-reprocessing` | T10 | §4.10 |

Phase 8 artifacts:
- `artifacts/latest/target/phase8_adr/<scenario>/assertions.tsv`
- `artifacts/latest/target/phase8_adr/<scenario>/recovery_report.txt`
- `artifacts/latest/target/phase8_adr/<scenario>/scenario_metrics.env`

Inspect consolidated summary:

```bash
cat artifacts/latest/phase8_adr_summary.tsv
```

### Verified run results (phase8-adr-20260303T093719Z)

First full end-to-end verification run. All 9 scenarios completed with **0 critical failures**.

| Scenario | Status | Passed | Failed | Critical | Non-critical failures |
|---|---|---|---|---|---|
| `t7-meta-properties-mismatch` | `degraded` | 6 | 1 | 0 | `smoke_produce_consume` (see note 1) |
| `t8-simultaneous-crash-baseline` | `recovered` | 10 | 0 | 0 | — |
| `t3-stale-hwm-checkpoint` | `recovered` | 9 | 0 | 0 | — |
| `t5-prepare-commit-recovery` | `recovered` | 10 | 0 | 0 | — |
| `t6-producer-state-inconsistency` | `degraded` | 11 | 1 | 0 | `t6_recovery_log_detected` (see note 2) |
| `t1-stale-quorum-state` | `recovered` | 8 | 0 | 0 | — |
| `t4-truncated-segment` | `recovered` | 8 | 0 | 0 | — |
| `t7b-node-id-mismatch` | `recovered` | 7 | 0 | 0 | — |
| `t10-consumer-group-reprocessing` | `recovered` | 7 | 0 | 0 | — |

**Note 1 — `t7` smoke non-critical**: broker-2 is intentionally rejected (cluster.id mismatch) and
its crash loop causes transient ISR churn on broker-1. The smoke assertion is non-critical because
the cluster is expected to operate with 2 of 3 brokers; all critical assertions (`cluster_reachable`,
`broker2_meta_mismatch_detected`, `broker2_reachable=no`) pass.

**Note 2 — `t6` recovery log non-critical**: the legacy `Found invalid messages` Kafka log line does
not appear in Confluent Platform's JVM under this scenario; the broker instead raises
`InvalidTxnStateException` / `TransactionAbortableException` directly. The critical
`t6_exception_detected` and `t6_exception_kind_expected` assertions (which accept this broader set
of producer-state exceptions) both pass, as does `t6_reinit_produce_succeeds`.

## 3. Identity migration experiments (Phase 9)

Phase 9 covers cluster identity migration scenarios — importing snapshot data into a cluster
with a different identity (new `cluster.id`). It includes the §4.13 partition UUID mismatch
path (stray directories) as the "blocked" profile.

Run all Phase 9 scenarios:

```bash
scripts/harness/run_phase9.sh all
```

Run a single scenario:

```bash
scripts/harness/run_phase9.sh new-identity-direct-import
scripts/harness/run_phase9.sh new-identity-reachable-allowed
```

| Scenario | Description | Expected outcome |
|---|---|---|
| `new-identity-direct-import` | Delete meta + KRaft log; force fresh format; source partition dirs remain with old UUIDs | `degraded`: stray dirs appear (§4.13), topic I/O blocked |
| `new-identity-reachable-allowed` | Rewrite cluster.id in meta.properties consistently across all brokers | `recovered`: cluster starts, I/O works |

Generate compact report:

```bash
scripts/harness/generate_phase9_compact_report.sh latest
```

Inspect latest outputs:

```bash
cat artifacts/latest/phase9_summary.tsv
sed -n '1,200p' artifacts/latest/phase9_compact_report.md
```

Phase 9 artifacts:
- `artifacts/phase9-runs/<run_id>/summary.tsv`
- `artifacts/phase9-runs/<run_id>/<scenario>/target/phase9/<scenario>/assertions.tsv`
- `artifacts/phase9-runs/<run_id>/<scenario>/target/phase9/<scenario>/scenario_metrics.env`
- `artifacts/reports/<run_id>/phase9_compact_report.md`
- `artifacts/latest/phase9_summary.tsv`
- `artifacts/latest/phase9_compact_report.md`

## 4. Typical local workflow

### Full ADR proof run (Phase 8)

1. Reset lab:
```bash
scripts/harness/reset_lab.sh
```
2. Execute all ADR scenarios:
```bash
scripts/harness/run_phase8_adr.sh all
```
3. Inspect results:
```bash
for s in t1-stale-quorum-state t3-stale-hwm-checkpoint t4-truncated-segment \
          t5-prepare-commit-recovery t6-producer-state-inconsistency \
          t7-meta-properties-mismatch t7b-node-id-mismatch \
          t8-simultaneous-crash-baseline t10-consumer-group-reprocessing; do
  echo "--- ${s} ---"
  cat artifacts/latest/target/phase8_adr/${s}/status.txt 2>/dev/null || echo "not run"
done
```

### Full identity migration run (Phase 9)

1. Reset lab:
```bash
scripts/harness/reset_lab.sh
```
2. Execute scenarios:
```bash
scripts/harness/run_phase9.sh all
```
3. Generate report:
```bash
scripts/harness/generate_phase9_compact_report.sh latest
```
4. Inspect latest outputs:
```bash
cat artifacts/latest/phase9_summary.tsv
sed -n '1,200p' artifacts/latest/phase9_compact_report.md
```

## 5. Legacy experiments (Phase 1-7)

Use:
- `HARNESS-LEGACY-PHASES.md`

That document contains historical run commands and walkthrough pointers for older phases.
