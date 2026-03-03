# Phase 7 Walkthrough (Uncontrolled snapshot capture and recovery grading)

Goal:
- simulate crash-style snapshot capture where node copies are taken at different points in time
- accept that some records/offsets may be missing (RPO effect)
- evaluate if recovered cluster is operational, what is degraded, and what actions can fix it

Phase 7 does not fail only because source and target data differ.
Phase 7 fails when cluster cannot operate (or cannot resume write/read).

## Scenarios

- `hard-stop`: all source brokers are killed abruptly, then copied
- `skewed-stop-copy`: broker1/2/3 are stopped and copied with time skew between nodes
- `isr-skew`: broker3 is killed first (ISR degraded), then broker1/2 are stopped and copied with skew, broker3 copy is stale

## Data seeded on source

Topics:
- `dr.p7.normal` (delete, 6 partitions)
- `dr.p7.state` (compact, 4 partitions)
- `dr.p7.groups` (delete, 6 partitions)
- `dr.p7.txn` (transactional workload topic, 4 partitions)

Groups:
- full: `dr.phase7.group.full` consumes `dr.p7.groups` fully
- partial: `dr.phase7.group.partial` consumes `dr.p7.normal` partially

Transactions:
- committed transactional id: `dr-phase7-tx-committed`
- aborted transactional id: `dr-phase7-tx-aborted` (force-terminated)
- uncommitted/hanging transactional id: `dr-phase7-tx-hanging`
- extra live transactional load during capture: `dr-phase7-live-tx-<scenario>`

## Run command

All scenarios:

```bash
scripts/harness/run_phase7.sh
```

Single scenario:

```bash
scripts/harness/run_phase7.sh hard-stop
```

Valid single-scenario names:
- `hard-stop`
- `skewed-stop-copy`
- `isr-skew`

## Execution flow per scenario

1. `reset_lab.sh`
2. `start_source.sh`
3. `seed_source_phase7.sh`
4. `snapshot_copy_phase7.sh <scenario>`
5. `start_target.sh`
6. `validate_target_phase7.sh <scenario>`

## What is checked on target

Health and metadata:
- bootstrap reachability
- metadata quorum status
- topic describe output for partition health
- broker logs capture

Data continuity (informational/degraded, not auto-fail):
- source vs target end-offset sums per topic
- source vs target group offsets (full + partial)

Transaction continuity:
- transaction list and describe for known tx ids
- hanging transaction scans (`find-hanging`) per broker id

Operational recovery smoke:
- produce post-restore records and confirm end-offset advance
- consume records and confirm read path works

Automatic remediation attempts (when issues are detected):
- unresolved broker-host metadata warnings: restart target brokers and re-check
- offline partitions: restart target brokers, then targeted unclean leader election on remaining offline partitions
- hanging transactions: force-terminate candidate transactional IDs and re-scan
- group-offset regression: reset to latest for configured scenario groups (inactive group requirement still applies)

## Recovery status meanings

- `recovered`: cluster is healthy enough and read/write resumed
- `degraded`: cluster is up and usable, but with findings (for example offset loss, group regressions, URP, hanging tx)
- `failed`: cluster is not operational or read/write smoke cannot be completed

## Output locations

Per run (all scenarios):
- `artifacts/phase7-runs/<run-id>/summary.tsv`
- scenario snapshots of source/target artifacts under `artifacts/phase7-runs/<run-id>/<scenario>/`

Latest run copy:
- `artifacts/latest/phase7_summary.tsv`

Per scenario recovery report:
- `artifacts/latest/target/phase7/<scenario>/recovery_report.txt`
- `artifacts/latest/target/phase7/<scenario>/status.txt`
- `artifacts/latest/target/phase7/<scenario>/remediation_summary.tsv`
- `artifacts/latest/target/phase7/<scenario>/remediations/<nn_issue>/before|after/...`

## Typical fix actions suggested by report

- restart target brokers and re-check leaders/ISR
- inspect broker logs for metadata log inconsistency
- inspect and terminate hanging transactions:
  - `kafka-transactions --bootstrap-server target-broker-1:9092 force-terminate --transactional-id <txid>`
- retry restore from an earlier/more synchronized snapshot if metadata/topic state is missing
