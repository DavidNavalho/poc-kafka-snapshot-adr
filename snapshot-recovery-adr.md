# Kafka Snapshot Recovery: Architecture Decision Record

## Overview

This ADR explores what happens when a **point-in-time disk snapshot** of a running Kafka cluster is taken and migrated to a new cluster deployment. It covers all failure modes, inconsistencies, and error conditions that can arise—from cluster startup to leader elections to data visibility—and provides designs for building a test harness that can reproduce each scenario.

This is distinct from but related to a **simultaneous crash scenario** (all nodes powered off instantaneously), which is explored in parallel as a companion case with similar but subtly different characteristics.

---

# PART 1: FOUNDATIONS

## What Is a Disk Snapshot in This Context?

A disk snapshot is a **point-in-time image** of the underlying block device (e.g., EBS snapshot, LVM snapshot, ZFS snapshot) taken while the cluster is running. Because Kafka is actively writing to disk when the snapshot is taken:

- Some writes may be **in-flight** (in OS page cache, not yet flushed to block device)
- Some files may be **partially written** (the snapshot captures mid-write)
- The snapshot is **not globally consistent** across all nodes—each disk snapshotted at a slightly different instant
- Multiple disks on the same node may not be atomic (unless the snapshot tool guarantees it)

### Snapshot vs. Simultaneous Crash

These two scenarios are very similar in **outcome** but differ in one important way:

| | Disk Snapshot | Simultaneous Crash |
|---|---|---|
| All writes visible | No (page cache lost) | No (page cache lost) |
| OS fsync honoured | No (snapshot pre-fsync possible) | No (power loss) |
| Cross-node consistency | No (each node at different instant) | No (each node at its own instant) |
| Data in transit | May be partially captured | Lost |
| Clean shutdown marker | Absent | Absent |
| OS file system integrity | Possibly inconsistent (depends on snapshot mechanism) | Possibly inconsistent (fsck needed) |

**Key difference**: A snapshot of a running system may capture OS buffer cache partially flushed to disk. A simultaneous crash (power loss) loses everything in-memory definitively. For the purposes of Kafka recovery logic, both scenarios are treated identically—Kafka sees: no `.kafka_cleanshutdown` file, and must perform full recovery.

---

# PART 2: WHAT KAFKA HAS ON DISK

Understanding what files exist and what they mean is essential before examining what can go wrong.

## Directory Structure Per Broker

```
{log.dir}/                               ← One per configured log directory
├── meta.properties                      ← Node identity (cluster.id, node.id, directory.id)
├── .kafka_cleanshutdown                 ← ABSENT after crash/snapshot
├── recovery-point-offset-checkpoint     ← Per-partition flush point
├── replication-offset-checkpoint        ← Per-partition HWM (High Watermark)
├── log-start-offset-checkpoint          ← Per-partition log start (after compaction)
├── __cluster_metadata-0/                ← KRaft only: metadata log partition
│   ├── 00000000000000000000.log
│   ├── 00000000000000000000.index
│   ├── 00000000000000000000.timeindex
│   └── quorum-state                     ← KRaft election state (JSON)
└── {topic}-{partition}/                 ← One per hosted partition
    ├── 00000000000000000000.log          ← Log segment (base_offset=0)
    ├── 00000000000000000000.index        ← Offset index
    ├── 00000000000000000000.timeindex    ← Timestamp index
    ├── 00000000000000000000.txnindex     ← Transaction index (aborted txns)
    ├── 00000000000000000100.log          ← Next segment
    ├── 00000000000000000100.index
    ├── 00000000000000000100.timeindex
    ├── 00000000000000000100.txnindex
    ├── 00000000000000000200.snapshot     ← Producer state snapshot
    ├── leader-epoch-checkpoint           ← Leader epoch → first offset mapping
    └── partition.metadata               ← Topic ID (UUID)
```

## Key File Descriptions

### `meta.properties`
- **Format**: Java Properties
- **Content**: `version`, `cluster.id`, `node.id` (KRaft) or `broker.id` (ZK), `directory.id` (per-disk UUID)
- **Critical**: If `cluster.id` doesn't match across all nodes → startup failure
- **Critical**: If `node.id` mismatches → startup failure

### `quorum-state` (KRaft only)
- **Format**: JSON, Version 0 or 1
- **Content (V1)**:
  ```json
  {
    "leaderId": 1,
    "leaderEpoch": 5,
    "votedId": -1,
    "votedDirectoryId": "abc123...",
    "data_version": 1
  }
  ```
- **Written**: Atomically (write-to-tmp, fsync, rename) on every election state change
- **Critical**: If this file is missing or corrupted → node cannot recover Raft state → must re-join as learner

### `replication-offset-checkpoint`
- **Format**: Plain text
- **Content**: `0\n2\nmy-topic 0 1500\nmy-topic 1 1200\n` (version, count, entries)
- **Meaning**: High Watermark per partition (highest replicated offset)
- **Flushed**: Every 5 seconds (configurable, `replica.high.watermark.checkpoint.interval.ms`)
- **Critical**: May be up to 5 seconds stale on crash

### `recovery-point-offset-checkpoint`
- **Format**: Same as above
- **Meaning**: Highest offset that has been **flushed to disk** per partition
- **Triggers**: Recovery replays all unflushed segments above this point

### `leader-epoch-checkpoint`
- **Format**: Plain text per-partition
- **Content**: `0\n3\n0 0\n1 450\n2 900\n` (version, count, epoch→firstOffset pairs)
- **Meaning**: Maps each leader epoch to the first offset written under that epoch
- **Critical**: Used for truncation decisions on follower recovery

### `.snapshot` files (producer state)
- **Format**: Binary (CRC32C + entries)
- **Content**: Per-producer state: `(producerId, epoch, lastSequence, lastOffset)`
- **Written**: At segment boundaries
- **Critical**: Used to rebuild idempotency/transaction state; may be stale on crash

### `.kafka_cleanshutdown`
- **Format**: JSON `{"version":0,"brokerEpoch":12345}`
- **Meaning**: "I shut down cleanly, skip segment recovery"
- **Absent**: On crash or snapshot → full recovery triggered

---

# PART 3: THE STARTUP SEQUENCE AND WHERE IT FAILS

When the snapshot is restored and brokers started, they execute this sequence:

```
1. Load meta.properties from all log.dirs
2. Verify cluster.id, node.id, directory.id consistency
3. Load quorum-state (KRaft leader election state)
4. Rebuild Raft election state
5. For each partition directory:
   a. Remove temp files (.swap, .tmp)
   b. Load all log segments
   c. Recover segments above recovery-point-offset-checkpoint
   d. Truncate corrupted segments
   e. Load leader-epoch-checkpoint
   f. Rebuild producer state from .snapshot files
   g. Apply log entries above snapshot offset
6. Load replication-offset-checkpoint (High Watermark)
7. Participate in leader election
8. Open network listeners
```

---

# PART 4: FAILURE SCENARIOS

## Scenario 1: Simultaneous Node Startup — Stale quorum-state

### Description

All nodes snapshotted at the same moment. All `quorum-state` files show the same `leaderEpoch`. No node knows who is the real leader, because the KRaft leader election state was captured mid-operation.

### What Happens

```
Node 0: quorum-state = { leaderId: 0, leaderEpoch: 5, votedId: -1 }
Node 1: quorum-state = { leaderId: 0, leaderEpoch: 5, votedId: -1 }
Node 2: quorum-state = { leaderId: 0, leaderEpoch: 5, votedId: -1 }

All nodes start. Each believes node 0 was the leader at epoch 5.
Node 0 checks its quorum-state: "I was leader at epoch 5."
  → Node 0 tries to resume as leader
Node 1/2: "Node 0 was leader, connecting..."
  → Nodes 1/2 try to connect to Node 0

But: Does the metadata log actually contain all data consistent with Node 0 being leader?
→ Possibly. If Node 0's disk snapshot was consistent with epoch 5.
```

**If Node 0's log is consistent:**
- All nodes detect same epoch 5
- Node 0 asserts leadership, nodes 1 and 2 become followers
- Normal operation resumes
- **Result**: Best case, recovery succeeds

**If Node 0's log is inconsistent (snapshot mid-write):**
- Node 0 starts Raft, begins replicating at epoch 5
- Node 1/2 discover log divergence (their logs don't match Node 0's)
- `divergingEpoch` logic triggers truncation
- Followers truncate their logs to match Node 0's log
- **Result**: Data loss on followers (uncommitted entries after divergence point)

**If `quorum-state` was snapshotted mid-atomic-write:**
- quorum-state file is corrupt or contains zeros
- Node cannot load election state
- Node participates in new election from scratch (epoch 0 or last known epoch + 1)
- **Risk**: Node votes in a new election before discovering existing quorum at epoch 5
- **Result**: Split-brain risk during bootstrap (resolved by majority voting)

### Error Observed

```
WARN KafkaRaftClient - Received VOTE_RESPONSE from node X with leaderId -1
INFO KafkaRaftClient - Beginning new election, bumping epoch to 6
```

Or, on log divergence:

```
INFO ReplicaManager - Truncating partition my-topic-0 from offset 1500 to 1480 due to diverging epoch
```

### Data Loss Exposure

- Records above HWM that were only on the former leader's disk: **Lost** (not replicated before snapshot)
- Records between HWM and LEO on followers: **Truncated** to match leader

---

## Scenario 2: Nodes Snapshotted at Different Instants (Cross-Node Inconsistency)

### Description

In practice, snapshotting disks across a multi-node cluster takes seconds. Node 0 is snapshotted at T=0, Node 1 at T=2s, Node 2 at T=4s. During those 4 seconds, replication continues. This means:

- Node 2 has more data than Node 0
- Some transactions may be partially replicated
- Some offsets exist on Node 2 that don't exist on Node 0

### What Happens

```
Snapshot instants:
  Node 0: T=0 → LEO=1000, HWM=950
  Node 1: T=2 → LEO=1100, HWM=1050
  Node 2: T=4 → LEO=1200, HWM=1150

Checkpoints at snapshot time:
  Node 0: replication-offset-checkpoint = 900  (5s old, typical)
  Node 1: replication-offset-checkpoint = 1000
  Node 2: replication-offset-checkpoint = 1100

Restored cluster starts:
  Leader election: Node 2 has highest LEO and epoch → elected leader
  Node 2: "I have data up to offset 1200"
  Node 0: "I only have up to 1000"
  Node 1: "I have up to 1100"

Node 0/1 fetch from Node 2:
  Node 2 sends divergingEpoch if Node 0/1's log doesn't match
  Node 0: Truncates from offset 1000 to match Node 2's epoch boundary
  Node 1: Truncates from offset 1100 to match Node 2's epoch boundary

Result:
  Data from Node 0 (offsets 1000-1200) is replicated from Node 2 to Node 0
  But what's on Node 2 between 1000 and 1200?
  → Messages written during T=0 to T=4 that were NOT yet replicated to Node 0 at T=0
  → These could be uncommitted (above HWM at T=0)
```

**Result**: Data from after Node 0's snapshot point is replicated from Node 2. The committed/uncommitted boundary is determined by the new leader's state, which may differ from what producers or consumers expected.

### Additional Risk: Different Leader Epochs

If the cluster had a leader change between T=0 and T=4:
- Node 0 might have `leaderEpoch=5` in its `leader-epoch-checkpoint`
- Node 2 might have `leaderEpoch=6` (new leader elected)
- Node 0 has records at epoch 5, some of which were overwritten under epoch 6
- Node 0's log diverges from leader at the epoch boundary

**Truncation cascade**:
```
Node 0 log: [ epoch=5: offsets 0-1000 ]
Node 2 log: [ epoch=5: offsets 0-980 ] [ epoch=6: offsets 981-1200 ]

Node 0 fetches from Node 2:
→ Receives divergingEpoch: { epoch: 5, endOffset: 981 }
→ Truncates all records at offset >= 981
→ Replays from Node 2 starting at 981

Loss: Offsets 981-1000 on Node 0 are gone
Gain: Offsets 981-1200 from Node 2
```

### Error Observed

```
INFO LogLoader - Recovering unflushed segments from partition my-topic-0
INFO Partition - Leader truncating partition from offset 1000 to 981 due to diverging epoch
INFO ReplicaManager - Fetching from leader, divergingEpoch in response
```

### Data Loss Exposure

- Any data exclusive to earlier-snapshotted nodes: **Potentially lost or overwritten**
- Offsets that only existed on one node at snapshot time: **Subject to truncation**

---

## Scenario 3: HWM Checkpoint Stale — Consumers See Earlier Committed Data

### Description

The `replication-offset-checkpoint` (HWM) is flushed every 5 seconds. On snapshot, it can be up to 5 seconds stale. This means consumers will initially see a **lower HWM** than was actually committed before the snapshot.

### What Happens

```
Before snapshot:
  Actual HWM: offset 1500 (acknowledged by all ISR)
  Checkpoint file: offset 1400 (5 seconds stale)
  Messages at offsets 1401-1500: committed to all replicas

After restore:
  Broker loads HWM from checkpoint: 1400
  Consumers with READ_COMMITTED isolation:
    → Can only see up to offset 1400 initially
    → Offsets 1401-1500 exist on disk but look "uncommitted"

Recovery proceeds:
  ISR re-establishes
  Leader re-computes HWM by receiving fetch responses from all ISR members
  HWM advances to 1500 (or higher if more data)

Consumers eventually see 1401-1500 after HWM catches up
```

**Timeline**:
- At startup: Consumers see HWM = 1400
- After ISR converges (seconds to minutes): Consumers see HWM = 1500
- **Window of inconsistency**: Until ISR is fully re-established

### Risk: HWM Checkpoint > Actual LEO

```
After snapshot restore on a DIFFERENT node:
  Checkpoint HWM: 1500 (from old node)
  Actual data on disk: LEO = 1300 (different physical machine, less data)

Consumer fetches offset 1400:
→ LogReadResult: OFFSET_OUT_OF_RANGE
→ Consumer gets exception, must reset offset
```

This can happen if snapshots are used to **restore a single node** from another node's snapshot, or if the snapshot was taken right after a partition reassignment left the disk partially populated.

### Error Observed

```
WARN KafkaConsumer - Received OFFSET_OUT_OF_RANGE for partition my-topic-0, resetting to latest
```

Or consumer-side:

```
org.apache.kafka.clients.consumer.internals.OffsetFetcherUtils$TopicAuthorizationException
→ Actually: OffsetOutOfRangeException: Offsets out of range with no configured reset policy
```

### Data Loss Exposure

- Temporary: Consumers can't see 1401-1500 until ISR re-establishes
- Permanent: None (data is on disk, just HWM not reflecting it yet)

---

## Scenario 4: Incomplete Log Segments — Corrupted Tail

### Description

At the time of snapshot, the active (tail) segment of a partition log is being written to. The OS page cache has buffered some writes that haven't been flushed to disk. The snapshot captures the block device state **without** those buffered bytes.

### What Happens

```
Before snapshot:
  Active segment: 00000000000001000.log
  On disk: 512,000 bytes (complete up to offset 1050)
  In page cache (not flushed): Additional 8,000 bytes (offsets 1051-1060)
  LEO: 1060

After snapshot restore:
  Active segment: 00000000000001000.log
  On disk: 512,000 bytes
  Last complete batch: offset 1050 (CRC validates)
  Byte 512,001 onwards: May contain:
    a) Zeros (if disk was pre-allocated)
    b) Garbage (if file was extended but not fully written)
    c) Partial RecordBatch header (partially flushed)

Recovery process:
  LogSegment.recover() iterates batches
  Reads batch header, validates magic byte
  Reads CRC, computes checksum
  Scenario (c): CRC mismatch → InvalidRecordException
    → Truncates log at last valid byte (offset 1050)
    → Logs: "Found invalid messages in log segment"
  Scenario (b): Magic byte invalid → Truncates
  Scenario (a): Size field reads 0 → End-of-segment detected, truncates at 512,000 bytes

Result: LEO drops from 1060 to 1050
  10 messages that were "in-flight" are lost
```

**Additional complication: Index files**

The offset index (`.index`) and time index (`.timeindex`) are also snapshots:
- They may reference offsets up to 1060 (because index was updated while data was in cache)
- But actual log only has up to 1050
- Recovery truncates indexes to match log

### Interplay With HWM

```
If HWM at snapshot time was 1040:
  → 1041-1050 exist on disk, committed, but HWM says 1040
  → After recovery: HWM advances to 1050 (ISR re-establishes)
  → These 10 messages eventually visible to consumers

If HWM at snapshot time was 1055:
  → HWM > actual LEO after recovery (1050)
  → HWM will be reset to LEO by the leader
  → Consumers fetching 1051-1055 get OFFSET_OUT_OF_RANGE
```

### Error Observed

```
WARN LogSegment - Found invalid messages in log segment ... at byte position 512000, discarding invalid messages and tailing this log at offset 1050
INFO LogLoader - Recovering unflushed segments for log my-topic-0
```

### Data Loss Exposure

- In-page-cache writes: **Lost** (never reached disk before snapshot)
- Partially-written records: **Truncated and lost**
- Extent of loss: Up to `log.flush.interval.messages` messages (default: unlimited = all in-page-cache)

---

## Scenario 5: Producer State Snapshot Stale — Idempotency Window Lost

### Description

Producer `.snapshot` files are written at segment roll boundaries. If a producer has been writing to the active segment for hours, its snapshot is hours old. After recovery, producer state is rebuilt by replaying the log from the snapshot point. But if the log itself is truncated (Scenario 4), some producer state is **permanently lost**.

### What Happens

```
Producer state at snapshot time:
  producerId=456, epoch=3, lastSequence=2000, lastOffset=1050

Producer snapshot on disk (.snapshot file):
  producerId=456, epoch=3, lastSequence=1500, lastOffset=900
  (Taken 100,000 messages ago at segment roll)

After recovery (log truncated to 1050):
  ProducerStateManager loads snapshot: producerId=456, lastSequence=1500
  Replays log from offset 900 to 1050
  Rebuilds: producerId=456, lastSequence=1900 (some messages recovered)

But: 100 messages (1901-2000) were in-page-cache, lost
  Producer expects lastSequence=2000

Producer reconnects (from source cluster), sends sequence=2001:
  Broker expects lastSequence=1900 + 1 = 1901
  Received 2001, expected 1901
  → Broker: "Sequence out of order"
  → Exception: OutOfOrderSequenceException
  → All batches in producer's buffer are failed
```

### Additional Risk: Epoch Mismatch

If the producer, after the snapshot was taken, bumped its epoch on the source cluster:
```
Old cluster: Producer(456, epoch=3) → committed
New producer session: Producer(456, epoch=4) → messages written
Source cluster: quorum-state records epoch=4 in metadata
Snapshot: Captures metadata at epoch=3

After restore:
  Destination: knows epoch=3
  Source producer connects: has epoch=4
  → PRODUCER_FENCED: "Epoch 4 is newer than what I know"
  → OR: Destination accepts epoch=4 as "new session" and resets sequence
  → But this means sequences from epoch 3 might be replayed as epoch 4
```

### Error Observed

```
org.apache.kafka.common.errors.OutOfOrderSequenceException:
  Out of order sequence number for producer 456 at offset 1901 in partition my-topic-0:
  5 (incoming seq. number), 1900 (current end sequence number)
```

Or, if producer reconnects:

```
org.apache.kafka.common.errors.ProducerFencedException: Producer attempted an operation with an old epoch
```

### Data Loss Exposure

- Idempotency deduplication window: **Reduced** to what was rebuilt from log
- Duplicates possible if producer retries messages that the broker no longer knows about
- Lost messages: Same as Scenario 4

---

## Scenario 6: In-Flight Transaction Captured in ONGOING State

### Description

A transaction was active at the time of the snapshot. The coordinator had written the ONGOING state to `__transaction_state`, but no COMMIT or ABORT marker had yet been written.

### What Happens

```
Before snapshot:
  Transaction: transactionalId="user-processor-1"
  State: ONGOING (in __transaction_state)
  Messages: Written to my-topic partitions at offsets 200-250
  COMMIT marker: Not yet written (producer hasn't called commitTransaction())

After restore:
  TransactionCoordinator loads __transaction_state
  Transaction "user-processor-1": State=ONGOING
  Messages at 200-250: Present on disk
  No COMMIT/ABORT marker: Transaction is considered "pending"

Consumer behavior (isolation.level=READ_COMMITTED):
  Reads up to HWM
  Encounters offsets 200-250 without COMMIT/ABORT marker
  → Consumer blocks at offset 199 (won't read past an open transaction)
  → Consumer appears "stuck" even though data exists

Transaction timeout:
  TransactionCoordinator.abortTimedOutTransactions() runs
  Finds "user-processor-1" in ONGOING state beyond transaction.timeout.ms
  Coordinator sends ABORT marker to all partitions
  Messages 200-250 now marked as aborted
  Consumer skips 200-250 (reads next committed data)

Result: Messages 200-250 are ABORTED and effectively lost
```

### If Transaction Was in PREPARE_COMMIT

```
Before snapshot:
  State: PREPARE_COMMIT (coordinator wrote end-of-txn marker to __transaction_state)
  Partition A: COMMIT marker written (offset 251)
  Partition B: COMMIT marker NOT written (in-flight)

After restore:
  Coordinator: State=PREPARE_COMMIT
  Partition A: Has COMMIT marker → "transaction committed here"
  Partition B: No marker → "transaction unknown here"

Consumer on Partition A: Can see messages 200-250 (committed)
Consumer on Partition B: BLOCKED at start of transaction

Coordinator re-sends COMMIT markers (completes the PREPARE_COMMIT)
  → Eventually Partition B gets COMMIT marker
  → Both partitions consistent

If coordinator crashes before re-sending Partition B marker:
  → Partition B stays blocked until new coordinator loads and retries
  → Eventually resolved (coordinator always retries pending PREPARE_COMMIT)
```

**This is the most dangerous scenario**: Partitions can be in **different states** relative to the same transaction, causing consumer-visible inconsistency until the coordinator completes recovery.

### Error Observed

Consumer appears stuck; no exception but no progress:

```
INFO KafkaConsumer - Waiting for transaction coordinator to resolve transaction for partition my-topic-1
```

Or from coordinator:

```
INFO TransactionCoordinator - Transaction user-processor-1 timed out in state ONGOING, aborting
INFO TransactionMarkerChannelManager - Writing ABORT marker for user-processor-1 to partition my-topic-1
```

### Data Loss Exposure

- ONGOING transactions at snapshot time: **All data aborted** after timeout
- PREPARE_COMMIT transactions: **Data is eventually committed** (coordinator completes)
- Duration of inconsistency: `transaction.timeout.ms` (default 60 seconds for ONGOING)

---

## Scenario 7: Leader-Epoch Checkpoint Inconsistency — Log Truncation Cascade

### Description

The `leader-epoch-checkpoint` file per partition maps each leader epoch to the first offset in that epoch. This is used to detect log divergence and determine truncation boundaries on followers. If this file is stale or inconsistent with the actual log content, truncations may happen at wrong boundaries.

### What Happens

```
leader-epoch-checkpoint (on disk):
  Epoch 3: first offset = 0
  Epoch 4: first offset = 500
  Epoch 5: first offset = 900

Log segments on disk:
  Epoch 3: offsets 0-499 (in segment files)
  Epoch 4: offsets 500-899 (in segment files)
  Epoch 5: offsets 900-1050 (truncated by crash, ended at 950 on disk)

Checkpoint says: Epoch 5 starts at 900 ✓

But: New leader had epoch 5 starting at 880 (not 900)
  → This happened because: Leader changed between checkpoint flush and snapshot

Follower fetches from new leader at offset 1050:
  New leader: "At offset 880 I was in epoch 5, you said 900. Diverging."
  → divergingEpoch = { epoch: 4, endOffset: 880 }
  → Follower: Must truncate from offset 880 to match leader's epoch 5 start
  → But follower's epoch checkpoint says epoch 4 ended at 500 and epoch 5 at 900
  → Follower truncates from 880 (leader-epoch boundary)

Lost: Offsets 880-899 on this follower (written under epoch 4 on follower, epoch 5 on leader)
```

**Epoch checkpoint ahead of actual log**:

```
Checkpoint says: Epoch 6: first offset = 1500
But actual log only has up to offset 1200 (crash truncated it)

Recovery truncates epoch 6 entry from checkpoint (as it points past LEO)
→ Checkpoint becomes: Epoch 5 ends where log ends
→ This is correct behavior, handled by LeaderEpochFileCache.truncateFromEnd()
```

### Error Observed

```
INFO Partition - Truncating leader epoch file for partition my-topic-0 from epoch 6 (stale, beyond log)
INFO ReplicaManager - Leader told follower to truncate from offset 1050 to 880 (divergingEpoch response)
```

### Data Loss Exposure

- Offsets at epoch boundaries that differ between nodes: **Truncated on the follower**
- Extent: Typically small (a few hundred messages at epoch transition boundaries)

---

## Scenario 8: meta.properties Cluster ID Mismatch — Hard Startup Failure

### Description

The restored cluster uses a different `cluster.id` than expected—either because the snapshot is from a different cluster, or because a node's `meta.properties` wasn't captured consistently.

### What Happens

```
Node 0: meta.properties = { cluster.id: "ABC123", node.id: 0 }
Node 1: meta.properties = { cluster.id: "ABC123", node.id: 1 }
Node 2: meta.properties = { cluster.id: "XYZ789", node.id: 2 }  ← Inconsistent!

Node 2 starts:
  MetaPropertiesEnsemble.verify() runs
  Compares cluster.id across all nodes (via metadata log)
  Node 2's cluster.id: XYZ789
  Controller's cluster.id: ABC123

→ RuntimeException: "Invalid cluster.id in /data/kafka. Expected ABC123 but read XYZ789"
→ Broker refuses to start
```

**Within a single node with multiple log.dirs**:

```
Node 0:
  /disk1/meta.properties: { cluster.id: "ABC123", directory.id: "dir1-uuid" }
  /disk2/meta.properties: { cluster.id: "ABC123", directory.id: "dir1-uuid" }  ← Duplicate!

→ RuntimeException: "Duplicate directory ID found: dir1-uuid"
```

### Error Observed

```
FATAL KafkaServer - Exiting Kafka due to fatal exception during startup:
RuntimeException: Invalid cluster.id in path /data/kafka. Expected ABC123 but read XYZ789
```

### Data Loss Exposure

- None (broker refuses to start)
- **Operational impact**: Node cannot join cluster until meta.properties is corrected

---

## Scenario 9: KRaft Split-Brain During Bootstrap — Multiple Nodes Claim Leadership

### Description

If the snapshot captures nodes at different points of an ongoing leader election, it's possible that multiple nodes believe they have a valid claim to leadership and both try to assert it.

### What Happens

```
Before snapshot (during election):
  Node 0: quorum-state = { leaderId: 0, leaderEpoch: 5 }  ← Believed it won
  Node 1: quorum-state = { leaderId: 1, leaderEpoch: 5 }  ← Believed it won (concurrent vote)
  Node 2: quorum-state = { leaderId: 0, leaderEpoch: 5 }  ← Voted for Node 0

After restore:
  Node 0 starts: "I was leader at epoch 5, resuming"
  Node 1 starts: "I was leader at epoch 5, resuming"

  Both attempt to write to metadata log:
    Node 0: Writes metadata record, sends AppendEntries to Node 1, 2
    Node 1: Writes metadata record, sends AppendEntries to Node 0, 2

  Node 2 receives AppendEntries from both:
    From Node 0 at epoch 5: Node 2's log diverges (last entry from epoch 5 = Node 0's data)
    From Node 1 at epoch 5: Epoch same, but log content differs

  Raft resolution:
    Both Node 0 and Node 1 try to get quorum of 3 (need 2 of 3)
    Node 2 can only vote for one
    If Node 2 votes Node 0: Node 1 loses quorum → steps down
    Node 1 bumps epoch to 6, requests election
    Node 0 accepts: "Epoch 6 > 5, stepping down"
    Node 1 wins at epoch 6

  Final result: One leader at epoch 6 (not 5)
  Metadata log from Node 0's epoch 5 leadership: May be truncated
```

This is **handled correctly by Raft** but causes:
- A new election round (adding startup delay)
- Potential metadata log truncation
- Any metadata records written during the ambiguous epoch are discarded

### Error Observed

```
WARN KafkaRaftClient - Received AppendEntries from two different leaders at same epoch, bumping epoch
INFO KafkaRaftClient - Resigned leadership due to higher epoch from node 1 (epoch 6 > 5)
INFO KafkaRaftClient - Starting new election as candidate for epoch 7
INFO KafkaRaftClient - Elected leader for epoch 7
```

### Data Loss Exposure

- KRaft metadata log entries during ambiguous election: **Discarded** (safe—they were never applied)
- User data: Not directly lost (metadata changes like topic creation may need retry)

---

## Scenario 10: Consumer Group Offset State Lost

### Description

Consumer group offsets are stored in `__consumer_offsets` topic, which is treated like any other topic partition for recovery. The same truncation/corruption issues apply, but the impact is on consumer position.

### What Happens

```
Before snapshot:
  __consumer_offsets partition 0:
    - Consumer group "my-app" committed offset 5000 for my-topic-0
  Checkpoint HWM: 4800 (5 seconds stale)

After restore:
  __consumer_offsets HWM = 4800
  Offset commit record for "my-app" at 5000 is above HWM:
  → Invisible to coordinator (looks uncommitted)
  → Coordinator reads: "my-app last committed offset = 4200" (200 records earlier)

Consumer "my-app" starts:
  Fetches committed offset from coordinator: 4200
  Begins reading from 4200 (not 5000)
  Re-processes messages 4200-5000
  → 800 message duplicates processed
```

**If the segment containing the offset commit was truncated**:
```
Commit record at offset 5000 in __consumer_offsets:
  Physically truncated from disk (page cache loss)

Coordinator: "No record for my-app in my-topic-0 after offset 3500"
Consumer starts: from offset 3500 → 1500 duplicate messages processed
```

### Additional Risk: Incomplete Compaction

`__consumer_offsets` uses log compaction. If compaction was in-progress at snapshot time:

```
Compaction state:
  Cleaned offset 0-3000 (old commits removed)
  .cleaned files: In-progress for 3001-5000
  .swap files: Partially renamed

After restore:
  LogLoader finds .cleaned and .swap files
  Attempts to recover compaction:
    If .swap is complete: Replaces old segment
    If .swap is incomplete: Old segment retained, .cleaned deleted

Compaction starts fresh from beginning
→ Old uncommitted offset commits may be visible again temporarily
→ Eventually cleaned by fresh compaction
```

### Error Observed

No error—consumers silently re-process:

```
INFO GroupCoordinator - Loaded group my-app with committed offset my-topic-0: 4200 (expected 5000)
INFO KafkaConsumer - Starting consumer from offset 4200 for partition my-topic-0
```

### Data Loss Exposure

- Consumer offset loss: **Duplicate message processing** (not data loss, but at-least-once instead of exactly-once)
- Extent: Up to `replica.high.watermark.checkpoint.interval.ms` (default 5s) of committed messages

---

## Scenario 11: Simultaneous Crash — All Nodes Power Off

This is the companion scenario mentioned in the introduction. It differs from the snapshot in one key way: **all data in OS page cache is definitively lost**.

### What Makes This Different

| | Disk Snapshot | Simultaneous Crash |
|---|---|---|
| Page cache fate | Captured (if snapshot is at device level) | Lost |
| Partial writes | Possibly captured | Not captured |
| Checkpoint accuracy | ≤5s stale | ≤5s stale |
| Clean shutdown marker | Absent | Absent |
| Filesystem integrity | Depends on snapshot mechanism | May need fsck |

### The Critical Difference: Replay Window

With a disk snapshot at the device level:
- OS buffer cache IS on the device (mostly—depends on when cache was flushed)
- A LVM/EBS snapshot captures in-flight I/Os that had reached the block device
- But: Application-level writes that hadn't issued `write()` yet are lost

With simultaneous crash:
- OS buffer cache is in RAM → **all lost**
- Only explicitly fsync'd data survives
- Recovery point checkpoint is authoritative: **Replay from recovery-point-offset**
- Everything above recovery-point: **Replayed from disk**
- Everything above LEO at snapshot time: **Gone**

### What Survives a Simultaneous Crash

Only data that was explicitly `fsync()`'d:
- Records below `recovery-point-offset-checkpoint` (flushed before checkpoint written)
- The checkpoint files themselves (written atomically with fsync)
- Leader epoch checkpoint (written on leadership changes with fsync)
- Producer snapshots (written at segment rolls with fsync)
- quorum-state (written with fsync on every election change)

### Data Loss Formula

```
Data lost per partition = LEO - recovery_point_offset
Data visible to consumers = min(HWM_checkpoint, actual_replayed_LEO)
```

### Error Observed

Identical to snapshot scenario, but with more consistent data loss:

```
INFO LogLoader - Recovering unflushed segments for partition my-topic-0 from recovery point 1000
INFO LogLoader - Recovering segment 00000000000001000.log
INFO LogSegment - Recovering segment, rebuilding offset and time indexes
```

---

# PART 5: SUMMARY OF ERROR CONDITIONS

| Scenario | Error/Exception | Root Cause | Data Loss Level |
|----------|----------------|------------|-----------------|
| S1: Stale quorum-state | `KafkaRaftClient: Beginning new election` | Raft state from mid-election | Low (metadata only) |
| S2: Cross-node snapshot skew | `Truncating partition to offset X due to diverging epoch` | Different nodes at different instants | Medium |
| S3: Stale HWM checkpoint | `OffsetOutOfRangeException` | HWM checkpoint ≤5s stale | Low (temporary) |
| S4: Incomplete log segment | `Found invalid messages, discarding tail` | Page cache writes lost | Medium (tail of log) |
| S5: Producer state stale | `OutOfOrderSequenceException`, `ProducerFencedException` | .snapshot taken at segment boundary | Low-Medium |
| S6a: ONGOING transaction | Consumer stuck, then aborted | Coordinator auto-aborts after timeout | High (full transaction) |
| S6b: PREPARE_COMMIT transaction | Consumer inconsistency (partition A committed, B not) | Partial marker write | Low (coordinator completes) |
| S7: Epoch checkpoint skew | `Truncating leader epoch file` | Checkpoint flush timing | Low |
| S8: meta.properties mismatch | `RuntimeException: Invalid cluster.id` | Inconsistent snapshot capture | None (startup failure) |
| S9: KRaft split-brain | `Resigned leadership, new election` | Concurrent leader claims | Very Low |
| S10: Consumer offset loss | Silent re-processing | __consumer_offsets HWM stale | None (duplicate processing) |
| S11: Simultaneous crash | Same as S1-S7, more consistent | Power loss, no page cache | Medium-High |

---

# PART 6: DESIGN FOR TEST HARNESS SCENARIOS

The following are designs (not implementations) for a test harness that can reproduce each scenario. Each design specifies what state to force on disk, what to start, and what to observe.

---

## Test Design T1: Stale quorum-state / New Leader Election

### Goal

Force a cluster to start with `quorum-state` files that do not reflect recent state, triggering a full leader election.

### Setup Design

```
Cluster: 3 KRaft nodes (combined broker+controller mode)
Steps:
  1. Start cluster, write some metadata (create topics)
  2. Wait for cluster to stabilize (leader at epoch E)
  3. Stop all brokers (SIGKILL, not graceful shutdown)
  4. MODIFY quorum-state on each node:
     - Set leaderEpoch to E-2 (two epochs behind)
     - Set leaderId to -1 (no known leader)
     - Leave votedId as -1
  5. Start all brokers simultaneously

Observe:
  - Brokers must hold a new election (epoch E+1 or higher)
  - Which node wins? (Should be one with highest log offset)
  - How long does election take?
  - Are any metadata records truncated?
```

### Key Forcing Mechanism

Directly edit `{metadata-log-dir}/__cluster_metadata-0/quorum-state`:
```json
{
  "leaderId": -1,
  "leaderEpoch": 2,
  "votedId": -1,
  "votedDirectoryId": "",
  "data_version": 1
}
```

### Observations to Assert

- [ ] All nodes start (no startup failure)
- [ ] Exactly one leader elected within `election.timeout.ms` × 2
- [ ] Leader epoch > stale epoch in modified file
- [ ] All metadata topics consistent after election
- [ ] No metadata records lost (topic list unchanged)

---

## Test Design T2: Cross-Node Log Divergence (Epoch Boundary)

### Goal

Force two replicas to have logs that diverge at a leader epoch boundary, triggering the truncation/replay mechanism.

### Setup Design

```
Cluster: 3 brokers
Steps:
  1. Create topic with RF=3, produce 1000 messages
  2. Identify current leader for partition 0
  3. Stop the leader (SIGKILL)
  4. New leader elected (epoch bumps)
  5. Produce 100 more messages under new leader
  6. Stop ALL remaining brokers (SIGKILL)
  7. Modify old leader's log:
     - Truncate replication-offset-checkpoint to offset 900
     - Copy old leader's log segment (from step 2) to restore it
     - Update leader-epoch-checkpoint to show only epoch N (not N+1)
  8. Start all brokers

Observe:
  - Old leader's log is detected as diverged at epoch boundary
  - Old leader truncates to epoch N boundary
  - Old leader replicates from new leader at epoch N+1 data
```

### Key Forcing Mechanism

To simulate a node that "missed" the epoch change:
1. Backup partition directory before killing old leader
2. After cluster stops, restore backed-up directory
3. Remove `leader-epoch-checkpoint` entries for the new epoch

### Alternative (Simpler): Inject a Future-Epoch Record

Append a raw RecordBatch with `leaderEpoch = currentEpoch + 2` into a log segment file. This simulates a node that has records from a future, unknown leader. Kafka will detect this as diverged and truncate.

### Observations to Assert

- [ ] Diverged node logs: `Truncating partition to offset X due to diverging epoch`
- [ ] Data after truncation matches leader
- [ ] No data loss for committed messages (below HWM)
- [ ] Uncommitted messages at epoch boundary: truncated

---

## Test Design T3: Stale HWM Checkpoint

### Goal

Force the `replication-offset-checkpoint` to be behind the actual committed data, simulating a stale checkpoint on recovery.

### Setup Design

```
Cluster: 3 brokers
Steps:
  1. Create topic, produce 1000 messages, wait for replication
  2. Stop all brokers with SIGKILL
  3. On the leader's disk:
     - Edit replication-offset-checkpoint
     - Set HWM for test-topic-0 to offset 500 (was 1000)
  4. Start all brokers

Observe:
  - At startup, HWM appears as 500
  - Consumers with READ_COMMITTED see only up to offset 500
  - As ISR re-establishes, HWM advances back to 1000
  - How long until HWM is correct?
  - What happens to a consumer that fetches offset 600 before HWM advances?
```

### Key Forcing Mechanism

Edit `replication-offset-checkpoint` file directly:
```
0
1
test-topic 0 500
```

(The actual committed data extends to 1000, but checkpoint says 500)

### Inverse: Set HWM Too High

```
  3b. On a FOLLOWER's disk:
      - Edit replication-offset-checkpoint
      - Set HWM for test-topic-0 to offset 1500 (actual LEO is 1000)
  4. Start all brokers, this follower becomes leader (manipulate election)

Observe:
  - Consumer fetches at offset 1200 → OFFSET_OUT_OF_RANGE
  - Leader resets HWM to actual LEO
  - How does leader detect and correct HWM > LEO?
```

### Observations to Assert

- [ ] Initial consumer sees HWM = 500 (stale)
- [ ] After ISR re-establishes: HWM = 1000
- [ ] Consumers retry and see 600-1000 after HWM advances
- [ ] High HWM case: OFFSET_OUT_OF_RANGE exception, then HWM corrected

---

## Test Design T4: Truncated Log Segment (Corrupted Tail)

### Goal

Simulate page-cache data loss by truncating the active log segment to a byte position that produces a partial/corrupt record at the tail.

### Setup Design

```
Cluster: 3 brokers, or just 1 broker for isolation
Steps:
  1. Produce 1000 messages to a topic
  2. Stop broker with SIGKILL
  3. Identify the active (last) log segment: 00000000000000XXXXX.log
  4. Method A: Truncate file at byte position mid-batch:
       truncate -s <midpoint-bytes> 00000000000000XXXXX.log
       (Use last valid batch boundary minus 100 bytes)
  5. Method B: Overwrite last 100 bytes with random data:
       dd if=/dev/urandom bs=1 count=100 seek=<position> of=segment.log
  6. Optionally: Update recovery-point-offset-checkpoint to offset < truncation point
  7. Start broker

Observe:
  - LogLoader detects corruption at truncated position
  - Segment truncated to last valid byte
  - LEO drops to last valid message offset
  - How much data was lost?
```

### Key Forcing Mechanism

To find the right truncation point:
- Run a Kafka tool to read the segment and print batch sizes
- `kafka-dump-log.sh --files 00000...log --print-data-log`
- Identify last complete batch end byte position
- Truncate at that position + some bytes (to create partial record)

### Observations to Assert

- [ ] LogLoader log: "Found invalid messages, discarding tail"
- [ ] Segment size reduced to last valid batch
- [ ] LEO = last valid offset (not original)
- [ ] No exception thrown to users (recovery is transparent)
- [ ] Producer that retries: May get OutOfOrderSequenceException if sequence was in truncated range

---

## Test Design T5: In-Flight Transaction on Snapshot — Consumer Stuck

### Goal

Force a topic to have an open (uncommitted) transaction, simulating what happens when a snapshot is taken mid-transaction.

### Setup Design

```
Cluster: 3 brokers
Steps:
  1. Create a transactional producer with:
     - transactional.id = "test-txn-1"
     - transaction.timeout.ms = 300000 (5 minutes, so it doesn't auto-timeout)
  2. Producer.initTransactions()
  3. Producer.beginTransaction()
  4. Produce 100 messages to test-topic-0
  5. DO NOT call commitTransaction() or abortTransaction()
  6. Stop all brokers with SIGKILL (transaction is now "frozen" in ONGOING state)
  7. Start all brokers (snapshot simulation starts here)

Observe: Phase A (within transaction.timeout.ms):
  - __transaction_state shows "test-txn-1" in ONGOING state
  - Consumer with isolation.level=READ_COMMITTED:
    → Blocked at offset before the open transaction
    → Does not progress (no error, just no data)
  - Consumer with isolation.level=READ_UNCOMMITTED:
    → Can read the transactional messages (not committed)
    → Will eventually see them aborted

Observe: Phase B (after transaction.timeout.ms):
  - TransactionCoordinator auto-aborts "test-txn-1"
  - ABORT marker written to test-topic-0
  - Consumer READ_COMMITTED: Skips the aborted messages, continues
  - Consumer READ_UNCOMMITTED: Sees abort marker, can skip if desired
```

### Additional Dimension: PREPARE_COMMIT State

```
Steps 1-4: Same as above
Step 5: commitTransaction() called (EndTxn request sent)
Step 6: STOP brokers immediately AFTER coordinator writes PREPARE_COMMIT
        but BEFORE WriteTxnMarkersRequest completes for all partitions

Observe:
  - __transaction_state: PREPARE_COMMIT state
  - Some partitions: Have COMMIT marker (recovered OK)
  - Other partitions: No marker (blocked consumers)
  - Coordinator recovery: Detects PREPARE_COMMIT, re-sends markers to remaining partitions
  - Eventually all partitions: COMMIT marker
  - Consumers: Resume normally
```

### Key Forcing Mechanism

To control the exact moment of the crash:
- Use a custom `KafkaProducer` or intercept at the network level
- Alternatively: Use `iptables`/`tc` to block `WriteTxnMarkersRequest` to specific brokers
- Then kill the coordinator broker

### Observations to Assert

- [ ] Consumer blocked when transaction ONGOING
- [ ] After timeout: ABORT marker written, consumer unblocks
- [ ] PREPARE_COMMIT: Eventually resolved (all partitions get COMMIT)
- [ ] No deadlock (coordinator always recovers and completes)
- [ ] Duration of consumer blockage = `transaction.timeout.ms` for ONGOING

---

## Test Design T6: Producer State Inconsistency — OutOfOrderSequenceException

### Goal

Simulate a stale producer `.snapshot` file causing sequence number mismatch on reconnection.

### Setup Design

```
Cluster: 3 brokers
Steps:
  1. Create an idempotent producer (enable.idempotence=true)
  2. Produce 500 messages (ensure at least one segment roll to create .snapshot)
  3. Produce 100 more messages (now in new segment, snapshot is 500 messages old)
  4. Stop all brokers with SIGKILL
  5. On broker disk:
     - Find .snapshot file for the producer: 00000000000000NNNNN.snapshot
     - Rename/delete all .snapshot files newer than offset 500
     - (Simulating snapshot capture at an old point)
  6. Truncate the active log segment to offset 550 (simulate page-cache loss)
     (So log has 550 messages, but producer thought it sent 600)
  7. Start brokers
  8. Reconnect producer (new connection, same producer ID if possible via transactionalId)
  9. Producer retries from sequence 551

Observe:
  - Broker rebuilt producer state from snapshot (offset 500)
  - Broker replayed log from 500 to 550: lastSequence = 549
  - Producer sends sequence 551: Broker expected 550 → mismatch?
    (Actually 551 might be accepted if it's nextSequence = lastSequence+1 = 550+1 = 551)
    So this case works... but if producer retries sequence 495 (before snapshot):
  - Producer sends sequence 495: Broker says "duplicate" (below lastSequence=549)
  - OR if log was truncated MORE aggressively to 300:
    Broker rebuilt state to lastSequence=299
    Producer sends sequence 400: broker expects 300 → OutOfOrderSequenceException
```

### Key Forcing Mechanism

- Use a transactional producer to get a stable `producerId` across sessions
- Manually truncate both the log and the `.snapshot` files
- Reconnect producer expecting specific sequence numbers

### Observations to Assert

- [ ] `OutOfOrderSequenceException` when sequence gap detected
- [ ] `ProducerFencedException` if epoch also advanced on source
- [ ] Producer recovery: After exception, must call `initTransactions()` again
- [ ] Subsequent transactions succeed with new epoch

---

## Test Design T7: meta.properties Mismatch — Startup Failure

### Goal

Force a broker to fail startup due to `cluster.id` mismatch, simulating a snapshot from a different cluster being mixed in.

### Setup Design

```
Cluster: 3 brokers
Steps:
  1. Start cluster, note cluster.id from meta.properties
  2. Stop broker 2
  3. On broker 2's disk:
     - Edit meta.properties
     - Change cluster.id to a different UUID
  4. Start broker 2

Observe:
  - Broker 2 fails to start
  - Error: "Invalid cluster.id in /data/kafka. Expected ABC123 but read XYZ789"
  - Brokers 0 and 1: Unaffected, continue operating
  - Cluster: Functions with 2 of 3 brokers
```

### Variant: node.id Mismatch

```
  3b. Change node.id in meta.properties to a different value
  4. Start broker
  Observe: "Stored node id 99 doesn't match previous node id 2. If you moved your data, please re-format."
```

### Observations to Assert

- [ ] Broker fails with specific RuntimeException
- [ ] Other brokers unaffected
- [ ] Fix: Correct meta.properties → broker starts
- [ ] Alternative fix: Re-format disk (wipes data)

---

## Test Design T8: Simultaneous Crash — All Nodes SIGKILL Simultaneously

### Goal

The closest simulation to "all nodes powered off with no flush". Test what Kafka recovers from vs. loses.

### Setup Design

```
Cluster: 3 brokers
Steps:
  1. Create topic with RF=3, ISR=[0,1,2]
  2. Start a continuous producer (1000 msg/sec)
  3. Start a continuous consumer (READ_COMMITTED, tracking offsets)
  4. Run for 30 seconds (establish baseline)
  5. Simultaneously kill all 3 brokers: kill -9 <pid0> <pid1> <pid2>
     (Or: use a script that kills all three in the same second)
  6. Note: Last committed consumer offset before kill
  7. Start all 3 brokers simultaneously

Observe at startup:
  - No .kafka_cleanshutdown files → full recovery on all
  - LogLoader: Recovering segments from recovery-point-offset-checkpoint
  - Recovery time: Function of data size above recovery point
  - Election: New KRaft leader elected

Observe post-startup:
  - Consumer resumes from its last committed offset
  - How many messages are re-processed (duplicate)?
  - How many messages are permanently lost?
  - Are there any OutOfOrderSequenceException from producers?
  - Do any transactions get aborted that were committed before kill?
```

### Key Metrics to Capture

- `last_committed_offset_before_kill` (from consumer)
- `first_available_offset_after_recovery` (HWM after recovery)
- `loss = last_committed_offset_before_kill - first_available_offset_after_recovery`
  - Should be near zero for RF=3 cluster (committed = replicated to all ISR)
  - May be non-zero if ISR shrank before kill

### Observations to Assert

- [ ] No data loss for messages acknowledged by all RF=3 replicas before kill
- [ ] Possible small loss for messages above HWM checkpoint (ISR timing)
- [ ] All three nodes start successfully (no meta.properties issues)
- [ ] Consumer duplicates bounded by: `replica.high.watermark.checkpoint.interval.ms`
- [ ] Producer reconnects and resumes (new epoch issued)

---

## Test Design T9: Partial Segment File — Mid-Write Snapshot Simulation

### Goal

Simulate snapshotting a broker at the exact moment a RecordBatch is being written to disk.

### Setup Design

```
Broker: Single broker (for isolation)
Steps:
  1. Create topic, partition 0
  2. Produce messages until segment is ~1MB (near log.segment.bytes threshold)
  3. Find the active segment file path
  4. Use dd or truncate to create a partial file:
     a. Copy segment file
     b. Append a partial RecordBatch (write only the first half of a valid batch)
     c. Append random bytes to simulate in-flight data
  5. Stop broker (SIGKILL)
  6. Replace segment file with the modified version
  7. Start broker

Observe:
  - LogSegment.recover() identifies the partial batch
  - Truncation happens at last valid batch boundary
  - Indexes rebuilt from valid portion
  - LEO = last valid offset
```

### Crafting a Partial RecordBatch

A RecordBatch header is 61 bytes. Appending only 30 bytes of the header simulates a partial write:

```
[Valid segment data: offsets 0-999]
[Valid batch 1000: 200 bytes total]
[Partial batch 1001: first 30 bytes only] ← Truncation point
```

Recovery should truncate to end of batch 1000.

### Observations to Assert

- [ ] Recovery truncates at offset 1000 (not 1001)
- [ ] Log: "Found invalid messages, discarding X bytes"
- [ ] No corruption propagated to index files
- [ ] Broker starts successfully after truncation

---

## Test Design T10: Consumer Group Offset Re-Processing Test

### Goal

Verify the extent of consumer re-processing after a crash, and test that consumer applications can handle this gracefully.

### Setup Design

```
Cluster: 3 brokers
Consumer: Application with at-least-once semantics
Steps:
  1. Create topic, start producer, start consumer
  2. Consumer commits offsets every 5 seconds (auto.commit.interval.ms=5000)
  3. Producer: 1000 msg/sec for 60 seconds
  4. Note: Consumer's last auto-committed offset at T=55s
  5. Kill all brokers at T=60s
  6. On consumer_offsets partition:
     - Edit replication-offset-checkpoint to be 10 seconds behind
     (Simulating stale HWM: committed offsets before T=50s visible)
  7. Start cluster
  8. Start consumer from the same group

Observe:
  - Consumer sees committed offset = T=50s position (not T=55s)
  - Consumer re-reads T=50s to T=55s window
  - How does application handle duplicates?
```

### Observations to Assert

- [ ] Consumer starts from stale committed offset
- [ ] Re-processes messages in the stale window
- [ ] No exception (at-least-once is expected behavior)
- [ ] Application idempotency layer (if any) correctly deduplicates

---

# PART 7: TEST HARNESS ARCHITECTURE (NO IMPLEMENTATION)

## Overall Design

```
TestHarness
├── ClusterManager
│   ├── startBroker(nodeId)
│   ├── stopBroker(nodeId, mode: GRACEFUL | SIGKILL | SIGSTOP)
│   ├── killAllSimultaneously()
│   └── waitForLeaderElection(partition, timeout)
│
├── DiskManipulator
│   ├── truncateSegment(topic, partition, byteOffset)
│   ├── corruptSegmentTail(topic, partition, byteCount)
│   ├── editQuorumState(nodeId, leaderId, leaderEpoch)
│   ├── editHwmCheckpoint(nodeId, topic, partition, offset)
│   ├── editRecoveryPointCheckpoint(nodeId, topic, partition, offset)
│   ├── editLeaderEpochCheckpoint(nodeId, topic, partition, epochs)
│   ├── editMetaProperties(nodeId, clusterId, nodeId)
│   ├── deleteProducerSnapshot(topic, partition, snapshotOffset)
│   └── captureSnapshot() → returns DiskSnapshot object
│
├── ProducerHarness
│   ├── produceMessages(topic, count, withTransaction)
│   ├── beginTransactionAndHold(topic)   ← keeps txn open
│   ├── forceEpochBump(transactionalId)  ← calls initTransactions()
│   └── getLastSequenceNumbers()
│
├── ConsumerHarness
│   ├── startConsumer(group, topic, isolationLevel)
│   ├── getCommittedOffset(group, topic, partition)
│   ├── getFirstUnavailableOffset(topic, partition)
│   └── collectMessages(timeout) → list of received messages
│
└── AssertionHelper
    ├── assertNoDivergence(topic, partition, allNodeIds)
    ├── assertHwmConsistency(topic, partition, allNodeIds)
    ├── assertProducerStateConsistency(topic, partition, producerId)
    ├── assertTransactionResolved(transactionalId, expectedState)
    └── assertConsumerCanProgress(group, topic, partition, timeout)
```

## Scenario Driver Interface

Each test scenario (T1-T10) is driven by a **ScenarioDriver**:

```
ScenarioDriver {
  setup(): void               // Prepare cluster state
  trigger(): void             // Apply disk manipulation
  start(): void               // Start cluster
  collect(duration): Metrics  // Observe behavior
  assert(): void              // Verify expected conditions
  cleanup(): void             // Reset for next test
}
```

## Key Dependencies for Implementation

1. **Kafka broker control**: `kafka.server.KafkaServer` or shell scripts
2. **File manipulation**: Direct Java File I/O for checkpoint editing
3. **Log segment tools**: `kafka-dump-log.sh` for inspection; custom binary writer for corruption
4. **KRaft tools**: JSON parser for `quorum-state` editing
5. **Admin API**: `AdminClient` for describing cluster state post-recovery
6. **Process coordination**: Something like `ProcessBuilder` or `docker` / `k8s` exec

## Recommended Test Ordering

Run in this order (simpler to more complex):

1. T7: meta.properties mismatch (startup failure—fast, clear)
2. T8: Simultaneous crash (baseline behavior)
3. T3: Stale HWM checkpoint (single file edit)
4. T4: Truncated segment (file truncation)
5. T9: Partial segment (byte-level corruption)
6. T1: Stale quorum-state (leader election)
7. T5: In-flight transaction (transaction protocol)
8. T6: Producer state inconsistency (idempotency)
9. T2: Cross-node log divergence (epoch boundaries)
10. T10: Consumer offset re-processing (end-to-end)

---

# APPENDIX: Key Code References

## Recovery Path

| File | Method | Purpose |
|------|--------|---------|
| `storage/src/main/java/org/apache/kafka/storage/internals/log/LogLoader.java` | `load()` | Entry point for log recovery |
| `storage/src/main/java/org/apache/kafka/storage/internals/log/LogSegment.java` | `recover()` | Per-segment recovery, index rebuild |
| `storage/src/main/java/org/apache/kafka/storage/internals/log/ProducerStateManager.java` | `rebuildProducerState()` | Rebuild idempotency state |
| `core/src/main/scala/kafka/coordinator/transaction/TransactionCoordinator.scala` | `onElection()` | Transaction coordinator recovery |
| `raft/src/main/java/org/apache/kafka/raft/FileQuorumStateStore.java` | `readElectionState()` | Load KRaft election state |

## Checkpoint Files

| File | Class | Location |
|------|-------|---------|
| `replication-offset-checkpoint` | `OffsetCheckpointFile` | `storage/src/main/java/org/apache/kafka/storage/internals/checkpoint/OffsetCheckpointFile.java` |
| `recovery-point-offset-checkpoint` | `OffsetCheckpointFile` | Same class, different filename |
| `leader-epoch-checkpoint` | `LeaderEpochCheckpointFile` | `storage/src/main/java/org/apache/kafka/storage/internals/checkpoint/LeaderEpochCheckpointFile.java` |
| `meta.properties` | `MetaProperties` | `metadata/src/main/java/org/apache/kafka/metadata/properties/MetaProperties.java` |
| `quorum-state` | `FileQuorumStateStore` | `raft/src/main/java/org/apache/kafka/raft/FileQuorumStateStore.java` |
| `.kafka_cleanshutdown` | `CleanShutdownFileHandler` | `server/src/main/java/org/apache/kafka/server/util/CleanShutdownFileHandler.java` |

## Transaction Recovery

| File | Class | Purpose |
|------|-------|---------|
| `core/src/main/scala/kafka/coordinator/transaction/TransactionStateManager.scala` | `TransactionStateManager` | Load txn state from __transaction_state |
| `transaction-coordinator/src/main/java/org/apache/kafka/coordinator/transaction/TransactionMetadata.java` | `TransactionMetadata` | Transaction state model |
| `storage/src/main/java/org/apache/kafka/storage/internals/log/AbortedTxn.java` | `AbortedTxn` | Aborted transaction index entry |
| `clients/src/main/java/org/apache/kafka/common/record/internal/EndTransactionMarker.java` | `EndTransactionMarker` | COMMIT/ABORT control record |

## Testing Utilities (Existing)

| File | Purpose |
|------|---------|
| `raft/src/test/java/org/apache/kafka/raft/MockLog.java` | In-memory Raft log for testing |
| `raft/src/test/java/org/apache/kafka/raft/RaftClientTestContext.java` | Test harness for KRaft |
| `storage/src/test/java/org/apache/kafka/storage/internals/log/LogLoaderTest.java` | Tests for log recovery |
| `core/src/test/scala/unit/kafka/log/LogTest.scala` | Integration log tests |

---

## Document End

This ADR covers all major scenarios arising from disk snapshot recovery and simultaneous crash recovery. The test designs provide a concrete blueprint for building a test harness that can reproduce each scenario on demand, allowing measurement of data loss, recovery time, and error conditions in a controlled environment.
