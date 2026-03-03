# Phase 5 Walkthrough (transactions)

Goal:
- validate transactional semantics across snapshot restore
- include committed, aborted, and hanging/uncommitted transactional records
- include full and partial consumer-group behavior with `read_committed`

## Topics and groups

Transactional topics:
- `dr.p5.txn.full` (committed transactions, 4 partitions)
- `dr.p5.txn.partial` (committed transactions, 4 partitions)
- `dr.p5.txn.aborted` (aborted transactions, 4 partitions)
- `dr.p5.txn.hanging` (ongoing/uncommitted transactions, 4 partitions)

Groups:
- full group: `dr.phase5.group.full`
- partial group: `dr.phase5.group.partial`

## Transaction patterns created

1. Committed transactions:
   - produced with `kafka-producer-perf-test --transactional-id ... --transaction-duration-ms 1500`
   - one flow for `dr.p5.txn.full`, one for `dr.p5.txn.partial`
2. Aborted transactions:
   - start long transaction producer, kill by timeout before commit
   - force abort with `kafka-transactions force-terminate --transactional-id dr-phase5-tx-aborted`
3. Hanging/uncommitted transactions:
   - start long transaction producer, kill by timeout before commit
   - do not force-terminate before snapshot

## Run command

```bash
scripts/harness/run_phase5.sh
```

Order:
1. `reset_lab.sh`
2. `start_source.sh`
3. `seed_source_phase5.sh`
4. `snapshot_copy_to_target.sh`
5. `start_target.sh`
6. `validate_target_phase5.sh`

## Source-side capture

Per topic:
- `topic_describe.txt`
- `end_offsets.txt`

Committed topics:
- `read_committed.txt`
- sorted hash + count artifacts

Aborted/hanging topics:
- `read_uncommitted.txt` + hash + count
- `read_committed.txt` + hash + count

Transaction metadata:
- `transactions.list.txt`
- per transactional id: `<txid>.describe.txt`

Consumer groups:
- offset snapshots for full/partial groups before snapshot

## Target-side validation

1. `cluster.id` parity
2. transactional IDs still present in `kafka-transactions list`
3. committed topic parity:
   - end offsets parity
   - `read_committed` payload parity
4. aborted/hanging parity:
   - `read_uncommitted` counts + hashes match source snapshot
   - `read_committed` counts + hashes match source snapshot
5. consumer groups:
   - full/partial group offsets equal source snapshot offsets
   - full remains fully consumed
   - partial remains partial
   - partial resumes post-restore and offsets advance

## Success criteria

Phase 5 passes only if all transactional visibility checks and group offset continuity checks pass.
