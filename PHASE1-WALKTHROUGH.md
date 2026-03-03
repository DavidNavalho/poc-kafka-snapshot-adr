# Phase 1 Walkthrough (What was done / how / checks)

Goal in this phase:
- prove clean snapshot-style restore by copying full source broker filesystem into target broker filesystem
- no MM2 / no Cluster Linking / no Replicator
- same cluster identity restore (cluster metadata + logs travel together)

## 0. Topology used

- image: `confluentinc/cp-server:8.1.0`
- mode: KRaft, combined `broker,controller`
- source cluster: `source-broker-1..3`
- target cluster: `target-broker-1..3`
- each broker uses one mounted data dir:
  - source: `data/source/broker1..3`
  - target: `data/target/broker1..3`
- source `CLUSTER_ID` generated at runtime by harness (not hardcoded)
- target `CLUSTER_ID` read from copied `meta.properties` and injected at runtime
- node IDs 1/2/3 on both sides
- no host ports needed; scripts run commands inside containers over docker network

Defined in:
- `docker-compose.yml`

## 1. Runner sequence (exact order)

Single command used:

```bash
scripts/harness/run_phase1.sh
```

This calls, in order:
1. `scripts/harness/reset_lab.sh`
2. `scripts/harness/start_source.sh`
3. `scripts/harness/seed_source_basic.sh <topic> <seed_count> 6`
4. `scripts/harness/snapshot_copy_to_target.sh`
5. `scripts/harness/start_target.sh`
6. `scripts/harness/validate_target_basic.sh <topic> <post_restore_count>`

Defaults:
- topic: `dr.basic.orders`
- seed count: `1200`
- post-restore new writes: `120`

## 2. What each step does

### Step A. Reset lab

Script: `scripts/harness/reset_lab.sh`

Actions:
- `docker compose down --remove-orphans`
- delete old runtime state:
  - `data/source/*`
  - `data/target/*`
  - `artifacts/latest/*`
- delete runtime env state:
  - `artifacts/runtime.env`
- recreate clean directories

Reason:
- deterministic run; no old records polluting counts/hashes

---

### Step B. Start source cluster

Script: `scripts/harness/start_source.sh`

Actions:
- if `SOURCE_CLUSTER_ID` is missing, generate one with:
  - `docker run --rm confluentinc/cp-server:8.1.0 kafka-storage random-uuid`
- persist generated value in:
  - `artifacts/runtime.env`
- `docker compose up -d source-broker-1 source-broker-2 source-broker-3`
- readiness loop (`kafka-topics --list`) on `source-broker-1:9092`
- capture quorum status to artifact:
  - `artifacts/latest/source/metadata_quorum_status.txt`
- capture runtime source cluster id:
  - `artifacts/latest/source/source_cluster_id_runtime.txt`

---

### Step C. Seed source data

Script: `scripts/harness/seed_source_basic.sh`

Actions:
1. ensure topic is empty (if exists and has offsets > 0, script fails)
2. create topic:
   - name: `dr.basic.orders` (default)
   - partitions: `6`
   - replication-factor: `3`
3. generate deterministic keyed JSON records:
   - count: 1200 (default)
   - key pattern: `customer-XXX`
   - value pattern: `{"event":"seed","order_id":N,"amount":M}`
4. produce via `kafka-console-producer`
5. collect baseline artifacts:
   - topic describe -> `artifacts/latest/source/topic_describe.txt`
   - end offsets (`kafka-get-offsets`) -> `artifacts/latest/source/end_offsets.txt`
   - consume exactly N records from beginning -> `artifacts/latest/source/topic_dump.txt`
   - canonical sort dump -> `artifacts/latest/source/topic_dump.sorted.txt`
   - hash sorted dump -> `artifacts/latest/source/topic_dump.sorted.sha256`
   - record count -> `artifacts/latest/source/topic_dump.count`
   - cluster id from `meta.properties` -> `artifacts/latest/source/cluster_id.txt`
   - node id from `meta.properties` -> `artifacts/latest/source/node_id.txt`

Reason for sorted hash:
- cross-partition consume order can vary; sorted hash checks record-set parity, not fetch order

---

### Step D. Snapshot copy source -> target

Script: `scripts/harness/snapshot_copy_to_target.sh`

Actions:
1. verify each source broker has `meta.properties` (basic completeness guard)
2. stop target brokers if running
3. stop source brokers (clean-stop snapshot baseline)
4. copy source data into snapshot folder:
   - `rsync -a --delete data/source/ artifacts/snapshots/<timestamp>/source-data/`
5. copy snapshot folder into target data:
   - `rsync -a --delete artifacts/snapshots/<timestamp>/source-data/ data/target/`
6. verify each target broker now has `meta.properties`
7. extract cluster id from copied data and persist runtime target ID:
   - read `data/target/broker1/meta.properties`
   - write `TARGET_CLUSTER_ID=...` into `artifacts/runtime.env`
8. write snapshot id marker:
   - `artifacts/latest/snapshot_id.txt`

Copy methodology used:
- filesystem-level recursive copy with `rsync -a --delete`
- includes all Kafka files in mounted dir (`meta.properties`, log segments, indexes, checkpoints, metadata log files)

---

### Step E. Start target cluster from copied data

Script: `scripts/harness/start_target.sh`

Actions:
- verify target broker data presence
- if `TARGET_CLUSTER_ID` missing in runtime env, extract from copied `meta.properties` and persist
- start `target-broker-1..3`
- wait for readiness
- capture target quorum status:
  - `artifacts/latest/target/metadata_quorum_status.txt`
- capture runtime target cluster id:
  - `artifacts/latest/target/target_cluster_id_runtime.txt`

---

### Step F. Validate restored state + smoke test

Script: `scripts/harness/validate_target_basic.sh`

Checks done before new writes:
1. topic describe on target -> `artifacts/latest/target/topic_describe.txt`
2. end offsets on target -> `artifacts/latest/target/end_offsets.txt`
3. consume exactly source_count from beginning -> `artifacts/latest/target/topic_dump_before_smoke.txt`
4. canonical sort + hash target dump
5. compare source hash vs target hash (must match)
6. `diff` source and target end-offset files (must match)
7. compare source cluster id vs target `meta.properties` cluster id (must match)

Post-restore activity checks:
8. produce additional records (default 120) on target
9. consume 10 messages using group `dr.phase1.validation.group`
10. `kafka-consumer-groups --describe` and verify topic appears
11. consume exactly expected final count and verify:
   - baseline count == source count
   - final count == source count + post-restore count
12. write final dump hash:
   - `artifacts/latest/target/topic_dump_after_smoke.sha256`

If any check fails:
- script exits non-zero, run stops

## 3. What was used to check correctness

Primary invariants checked in phase 1:
- metadata/quorum is reachable on source and target
- topic metadata exists post-restore
- per-partition end offsets unchanged by copy/restore
- canonical full-record-set hash unchanged by copy/restore
- `cluster.id` unchanged
- cluster remains writable/readable after restore
- consumer group offset commits work after restore

Tools used:
- `kafka-metadata-quorum`
- `kafka-topics`
- `kafka-get-offsets`
- `kafka-console-producer`
- `kafka-console-consumer`
- `kafka-consumer-groups`
- `rsync`
- `sha256sum`/`shasum`
- `diff`

## 4. Notes from implementation/debug

Changes made to make phase-1 stable:
- removed host port bindings from compose (avoids local port conflicts)
- switched from old `GetOffsetShell` to `kafka-get-offsets` (Kafka 4 toolset in cp-server image)
- changed hash logic to sorted canonical dump (order-insensitive across partitions)
- added guard to prevent reseeding non-empty topic

## 5. One-line mental model

source cluster up -> deterministic writes -> source clean stop -> rsync source data -> rsync into target data -> target up -> prove same data/offsets/cluster-id -> prove new writes + new consumer commits still work.
