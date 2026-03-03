# Phase 3 Walkthrough (Schema Registry + Protobuf)

Goal:
- keep snapshot-copy recovery model
- add Schema Registry + Protobuf payloads
- verify `_schemas` and schema-subject parity after restore

## Topics used

From `scripts/harness/phase3_topics.sh`:

- `dr.p3.orders.proto` : regular (`cleanup.policy=delete`), 6 partitions, 500 seed messages
- `dr.p3.customer-state.proto` : compacted (`cleanup.policy=compact`), 4 partitions, 650 seed messages

Post-restore writes:
- 50 additional records per topic (configurable via `PHASE3_POST_RESTORE_PER_TOPIC`)

## Schema files used

- `schemas/order_event.proto`
- `schemas/customer_state.proto`

These are mounted read-only into Schema Registry containers at `/opt/schemas`.
Compacted topic key schema:
- `schemas/customer_key.proto`

## Run command

```bash
scripts/harness/run_phase3.sh
```

Execution order:
1. `reset_lab.sh`
2. `start_source.sh`
3. `start_source_schema_registry.sh`
4. `seed_source_phase3.sh`
5. `snapshot_copy_to_target.sh`
6. `start_target.sh`
7. `start_target_schema_registry.sh`
8. `validate_target_phase3.sh`

## What seeding does

For each topic:
- create topic with configured partitions and cleanup policy
- produce deterministic Protobuf records via `kafka-protobuf-console-producer`
  - compacted topic writes use Protobuf key + Protobuf value (`parse.key=true`, `key.schema.file=customer_key.proto`)
- auto-register schema subjects in source Schema Registry
- capture source artifacts under:
  - `artifacts/latest/source/phase3/<topic>/`
  - files: `topic_describe.txt`, `end_offsets.txt`, `topic_dump.txt`, `topic_dump.sorted.txt`, `topic_dump.sorted.sha256`, `topic_dump.count`, `spec.txt`

Schema artifacts captured:
- `artifacts/latest/source/phase3/schemas/subjects.txt`
- `artifacts/latest/source/phase3/schemas/<subject>.latest.json`
- `artifacts/latest/source/phase3/schemas/_schemas_topic_describe.txt`

## Snapshot copy model

Same method as previous phases:
- stop schema registries + brokers cleanly
- `rsync -a --delete data/source/ artifacts/snapshots/<id>/source-data/`
- `rsync -a --delete artifacts/snapshots/<id>/source-data/ data/target/`
- target cluster id read from copied `meta.properties`

## Validation checks on target

Global checks:
1. `cluster.id` parity source vs target
2. `_schemas` topic exists and is compacted (`cleanup.policy=compact`)
3. Schema subject list parity (`subjects.txt` diff)
4. Per-subject latest-version JSON parity (`<subject>.latest.json` diff)

Per-topic checks:
1. topic describe succeeds
2. compacted topic retains compact policy
3. end offsets match source before post-restore writes
4. Protobuf payload canonical hash matches source before smoke writes
5. post-restore Protobuf writes succeed
6. consumer-group offsets commit successfully
7. final count = baseline + post-restore records

## Success criteria

Phase 3 passes only when schema-level and data-level parity checks all pass.
