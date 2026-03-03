# Phase 7b Walkthrough (Bounded-loss injection + recovery)

Goal:
- reproduce bounded data loss (acked-only accounting)
- recover cluster to stable read/write state
- keep full evidence of issue detection and remediation

Scope:
- chaos is isolated to one dedicated topic (`dr.p7b.chaos.loss`)
- loss metric is based on producer-acked records only
- combined broker/controller KRaft quorum is preserved during source-side chaos steps

## Scenarios

- `loss-acks1-unclean-target` (deterministic):
  - produce on source chaos topic with `acks=1`
  - stop brokers in skewed order while producing (`broker-3` -> `broker-2` -> `broker-1`)
  - snapshot/copy after skewed stop
  - on target: kill leader and run targeted unclean election
  - compare acked ids vs recovered ids

- `loss-live-copy-flush-window` (semi-deterministic, up to 10 attempts by default):
  - produce with `acks=-1` while source is running
  - copy source disks live (no source stop before copy)
  - kill source, restore target, compare acked ids vs recovered ids

## Run commands

Run both scenarios:

```bash
scripts/harness/run_phase7b_loss.sh
```

Run deterministic scenario only:

```bash
scripts/harness/run_phase7b_loss.sh loss-acks1-unclean-target
```

Run live-copy scenario only:

```bash
scripts/harness/run_phase7b_loss.sh loss-live-copy-flush-window
```

Run tuned profile sweep:

```bash
scripts/harness/run_phase7b_tuned.sh
```

Run one profile with fixed iterations:

```bash
scripts/harness/run_phase7b_tuned.sh balanced 5
```

## Execution flow per attempt

1. `reset_lab.sh`
2. `start_source.sh`
3. `seed_source_phase7b_loss.sh <scenario> <attempt>`
4. `snapshot_copy_phase7b_loss.sh <scenario> <attempt>`
5. `start_target.sh`
6. `validate_target_phase7b_loss.sh <scenario> <attempt>`

Phase 7b validation reuses Phase 7 stability validator internally and stores its outputs under `stability/`.

## Status semantics

- `recovered_with_loss`: bounded non-zero loss reproduced, cluster stable
- `recovered_no_loss`: stable but no loss reproduced (expected possible outcome for live-copy scenario)
- `degraded_with_loss`: loss reproduced but stability remained degraded
- `degraded_no_loss`: deterministic path did not reproduce expected loss
- `failed`: cluster not recoverable for attempt or catastrophic loss condition

## Artifacts

Latest summary:
- `artifacts/latest/phase7b_summary.tsv`

Per run:
- `artifacts/phase7b-runs/<run-id>/summary.tsv`
- `artifacts/phase7b-runs/<run-id>/<scenario>/attempt-<nn>/...`

Per attempt (latest):
- `artifacts/latest/source/phase7b/<scenario>/attempt-<nn>/chaos/`
- `artifacts/latest/target/phase7b/<scenario>/attempt-<nn>/`

Key files per attempt:
- `attempt_result.env`
- `recovery_report.txt`
- `loss_metrics.tsv`
- `chaos/acked_ids.txt`
- `chaos/recovered_ids.txt`
- `chaos/lost_ids.txt`
- `stability/recovery_report.txt`

Compact report generator:
- `scripts/harness/generate_phase7b_compact_report.sh <run-id|run-root|latest>`
- output markdown: `artifacts/reports/<run-id>/compact_report.md`
- output tsv: `artifacts/reports/<run-id>/compact_attempts.tsv`

Space cleanup (keep proof, drop heavy payloads):
- `scripts/harness/prune_artifacts_keep_proof.sh all`
- keeps proof under `artifacts/proof/phase7b/<run-id>/`
- removes snapshot payloads and per-attempt heavy data/log trees

## JMX evidence

Brokers run with explicit JMX enabled in compose (`KAFKA_JMX_PORT=9999` + localhost RMI settings).

Stability evidence captures JMX snapshots (best effort) for:
- `UnderReplicatedPartitions`
- `OfflinePartitionsCount`
- `BytesInPerSec`
- `BytesOutPerSec`

## Capacity note

Live-copy scenarios can consume large snapshot space quickly.
- tuned runner enforces minimum free disk guard (`PHASE7B_MIN_FREE_GB`, default `20`)
- tuned runner can auto-prune after each profile (`PHASE7B_TUNED_PRUNE_AFTER_PROFILE=true`)
