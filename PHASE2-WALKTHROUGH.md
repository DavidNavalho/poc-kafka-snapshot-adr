# Phase 2 Walkthrough (multi-topic + compacted)

Goal:
- keep same snapshot-copy recovery model from phase 1
- increase variability with multiple topics
- include compacted + regular topics
- include mixed partition counts
- run parity checks per topic before post-restore writes

## Topics used

From `scripts/harness/phase2_topics.sh`:

- `dr.p2.orders` : regular (`cleanup.policy=delete`), 6 partitions, 900 seed messages
- `dr.p2.audit` : regular (`cleanup.policy=delete`), 3 partitions, 450 seed messages
- `dr.p2.customer-state` : compacted (`cleanup.policy=compact`), 5 partitions, 700 seed messages

Post-restore writes:
- 60 additional records per topic (configurable by `PHASE2_POST_RESTORE_PER_TOPIC`)

## Run command

```bash
scripts/harness/run_phase2.sh
```

Execution order:
1. `reset_lab.sh`
2. `start_source.sh`
3. `seed_source_phase2.sh`
4. `snapshot_copy_to_target.sh`
5. `start_target.sh`
6. `validate_target_phase2.sh`

## What seeding does

For each topic:
- create topic with requested partitions / cleanup policy
- produce deterministic records
  - regular topics: high-cardinality keys
  - compacted topic: repeated customer keys (state-style updates)
- capture source artifacts under:
  - `artifacts/latest/source/phase2/<topic>/`
  - files: `topic_describe.txt`, `end_offsets.txt`, `topic_dump.txt`, `topic_dump.sorted.txt`, `topic_dump.sorted.sha256`, `topic_dump.count`, `spec.txt`

Also captures:
- `artifacts/latest/source/cluster_id.txt`

## How snapshot copy is done

Same copy model as phase 1:
- stop source cleanly
- `rsync -a --delete data/source/ artifacts/snapshots/<id>/source-data/`
- `rsync -a --delete artifacts/snapshots/<id>/source-data/ data/target/`
- target cluster id extracted from copied `meta.properties` and stored in `artifacts/runtime.env`

## Validation checks on target

For each topic:
1. topic is describable on target
2. compacted topic check: `cleanup.policy=compact` exists in describe output
3. end offsets match source (`diff` source vs target offset files)
4. consume exactly source count and compare canonical sorted hash to source
5. produce +60 post-restore records to same topic
6. consume with a dedicated validation group and verify committed offsets exist
7. re-consume expected final count and assert:
   - baseline count = source seed count
   - final count = source seed count + 60

Global check:
- `cluster.id` parity source vs target

## Success criteria

Phase 2 passes only if all topics pass all checks. Any mismatch fails fast with non-zero exit.
