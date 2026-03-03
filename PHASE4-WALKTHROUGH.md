# Phase 4 Walkthrough (consumer behavior matrix)

Goal:
- keep same snapshot-copy recovery model
- focus on consumer-group state continuity (`__consumer_offsets`)
- validate fully-consumed vs partially-consumed group behavior after restore

## Topics and groups

From `scripts/harness/phase4_topics.sh`:

- `dr.p4.full-consume` : 4 partitions, 800 records
- `dr.p4.partial-consume` : 4 partitions, 900 records
- `dr.p4.unconsumed` : 3 partitions, 500 records

Groups:
- full group: `dr.phase4.group.full`
- partial group: `dr.phase4.group.partial`

Consumption pattern before snapshot:
- full group reads full topic completely (`max-messages = 800`)
- partial group reads partial topic only partially (`max-messages = 300`)

## Run command

```bash
scripts/harness/run_phase4.sh
```

Execution order:
1. `reset_lab.sh`
2. `start_source.sh`
3. `seed_source_phase4.sh`
4. `snapshot_copy_to_target.sh`
5. `start_target.sh`
6. `validate_target_phase4.sh`

## What source seeding does

For each topic:
- create topic
- produce deterministic keyed JSON
- capture source artifacts under:
  - `artifacts/latest/source/phase4/topics/<topic>/`
  - files: `topic_describe.txt`, `end_offsets.txt`, `topic_dump.txt`, `topic_dump.sorted.txt`, `topic_dump.sorted.sha256`, `topic_dump.count`, `spec.txt`

Then:
- run full-group consumer to fully consume `dr.p4.full-consume`
- run partial-group consumer to partially consume `dr.p4.partial-consume`
- capture group offsets into:
  - `artifacts/latest/source/phase4/groups/<group>.describe.raw.txt`
  - `artifacts/latest/source/phase4/groups/<group>.offsets.txt`

Pre-snapshot assertions:
- full group offsets equal log-end offsets for full topic
- partial group offsets are below log-end offsets for at least one partition of partial topic

## Snapshot method

Same as earlier phases:
- stop source cleanly
- `rsync -a --delete data/source/ artifacts/snapshots/<id>/source-data/`
- `rsync -a --delete artifacts/snapshots/<id>/source-data/ data/target/`

## What target validation checks

1. cluster ID parity
2. per-topic data parity before any new group resume:
   - end offsets match source
   - canonical sorted payload hash matches source
3. group-offset parity at snapshot point:
   - compare source vs target full-group offsets
   - compare source vs target partial-group offsets
4. behavior checks:
   - full group remains fully consumed after restore
   - partial group remains partial after restore
5. resume check:
   - consume additional messages with partial group on target
   - verify partial-group committed offsets advance

## Success criteria

Phase 4 passes only if all data and group-offset continuity checks pass.
