# Migrating Kafka Data from Disk Snapshots into a New Self-Managed Confluent Platform Cluster

## Executive summary

Migrating Kafka topic data “directly” from disk snapshots into a *new* Kafka cluster is only straightforward when you restore **the whole original cluster identity** (broker data *and* metadata) and then either (i) keep running it as-is, or (ii) use it temporarily as a source to replicate into a fresh target cluster. Kafka’s on-disk partition logs are not a portable, standalone dataset: they are tightly coupled to cluster metadata (topic IDs, partition leadership/epochs, broker IDs/node IDs, cluster ID) and to internal topics that carry consumer offsets, transactional state, schemas, and (in Confluent deployments) additional metadata and governance state. citeturn15view0turn0search2turn9search2turn5view0turn2search4

Across modern Kafka/Confluent versions, the **safest and most supportable** path is therefore:

- **Restore the snapshots into an isolated “temporary source cluster” that matches the original cluster identity** (same cluster ID, broker IDs/node IDs, and the correct ZooKeeper or KRaft metadata state), let it recover like a crash-consistent restart, and then
- **Replicate into the new target cluster** using one of:
  - **Cluster Linking (Confluent Platform)** if licensed/available; it is designed for DR/migration and can sync topic structure/configs and (optionally) ACLs and consumer offsets. citeturn0search3turn0search7turn0search35
  - **MirrorMaker 2** (Apache Kafka Connect-based) with `MirrorSourceConnector` + `MirrorCheckpointConnector` to mirror data and optionally translate/sync consumer offsets, acknowledging its operational complexity and cutover semantics. citeturn19search5turn19search18turn19search1
  - **Confluent Replicator** (Kafka Connect connector) when you need Confluent-supported replication that also preserves topic configs and can replicate from a chosen starting point. citeturn0search21turn8search7

By contrast, **copying partition directories into a brand-new cluster and “fixing them up” offline** is high-risk and frequently infeasible on modern Kafka because topics have durable **topic IDs** (KIP-516) and brokers may maintain on-disk `partition.metadata` to bind a partition log directory to a topic ID; recreating topics with the same name in a new cluster typically yields different topic IDs and can cause “inconsistent topic ID” failures. citeturn9search2turn9search6turn9search11

A true **offline import** (reading `.log` segment files from snapshots and re-producing into a new cluster without running the old cluster) is possible only as a *salvage* approach: you can decode logs with tools like `kafka-dump-log`, but you will not preserve original offsets, group state, transactional guarantees, or exactly-once semantics end-to-end, and you must reconstruct topic configuration and security state separately. citeturn0search2turn1search4turn6search28

## Scope and assumptions

This report assumes the following details are currently unknown and must be validated in your environment before executing any procedure:

- **Metadata mode** at snapshot time: ZooKeeper-based or KRaft-based. Confluent Platform 8.0+ uses Kafka’s KRaft controllers for metadata storage and leader elections by default, while earlier Confluent Platform versions commonly used ZooKeeper. citeturn10search5turn8search0turn0search1
- **Kafka/Confluent Platform versions** at snapshot time and target time. Confluent Platform releases embed specific Apache Kafka versions (e.g., Confluent Platform 8.1 provides Apache Kafka 4.1), and compatibility constraints matter for on-disk formats and metadata features (topic IDs, KRaft, tooling availability). citeturn8search1turn8search0turn8search16
- **Snapshot type**: filesystem-consistent per-volume snapshots, crash-consistent VM snapshots, storage-array snapshots, LVM/ZFS snapshots, etc. The “consistency boundary” across brokers (and controllers/ZooKeeper) heavily influences recovery risk. citeturn15view0turn0search2
- **Storage layout**: single `log.dirs` vs JBOD/multiple `log.dirs`, KRaft `metadata.log.dir`, and whether Confluent Tiered Storage was enabled (object storage contains warm segments that are not on local disks). citeturn10search3turn16search21turn0search2
- **Security/governance**: whether you used Kafka ACLs (ZooKeeper or KRaft authoriser), or Confluent RBAC (Metadata Service / Confluent Server Authoriser), and whether Schema Registry, Connect, ksqlDB, Control Center, etc. were in use (and therefore which internal topics must be preserved). citeturn3search23turn3search3turn10search1turn5view0turn19search9

Where this report gives commands and file paths, treat them as **reference patterns**; adjust for your packaging (systemd vs archives), installation prefixes, and your organisation’s operational tooling.

## Kafka storage, replication state, and metadata

Kafka’s durability model centres on an append-only **partition log** stored on broker disks as directories of log segment files. Each partition is a logical ordered sequence; on disk it is split into segment files whose names are derived from the base offset of the first record in the segment (for example `00000000000000000000.log`). citeturn15view0turn0search11

### On-disk log segments and index artefacts

Kafka maintains multiple per-segment/per-partition artefacts to make reads, retention, transactions, and leader failover efficient:

- **Segment `.log` files** hold the record batches for a partition; segment rolling is controlled by broker/topic configs such as `log.segment.bytes`. citeturn15view0turn0search11
- **Offset indexes**: topic-level configs explain that Kafka adds entries to an offset index every `index.interval.bytes`, and that `segment.index.bytes` controls the size of the index mapping offsets to file positions (with preallocation and shrink-on-roll behaviour). citeturn16search20
- **Time indexes** (`.timeindex`) are used for time-based searches/retention lookups. (Kafka’s public docs emphasise time-based retention at the segment level; many operational explanations describe `.timeindex` as the timestamp→offset mapping used to locate data by time.) citeturn15view0turn16search20turn1search0
- **Transactional and exactly-once state**: the active segment may have producer state snapshot files (commonly described as `.snapshot`), and transactional indexes (`.txnindex`) track aborted transactions, which matters when restoring EOS/transactions. citeturn1search0turn16search24
- **Leader epoch tracking**: partitions include `leader-epoch-checkpoint` files mapping leader epochs to start offsets to support correct truncation and replica synchronisation during leader changes. citeturn1search30turn16search24

Kafka can rebuild some structures (notably indexes) during recovery. Operational logs such as “recovering segment and rebuilding index files” are a common symptom of missing/corrupt index files and indicate brokers can regenerate them by scanning log segments. citeturn9search12turn15view0

### Broker-local checkpoint files and crash recovery

In each log directory, Kafka maintains checkpoint files that record per-partition offsets for recovery and maintenance (for example, `replication-offset-checkpoint`, `recovery-point-offset-checkpoint`, `cleaner-offset-checkpoint`). citeturn3search29

Kafka’s implementation documentation also describes a crash-recovery model: on startup, log recovery iterates over messages in the newest segment, validates entries (including CRC), and truncates to the last valid offset if corruption is detected. citeturn15view0

This behaviour is a key reason why **crash-consistent disk snapshots are often *recoverable***: a snapshot resembles an abrupt stop, and Kafka’s log recovery procedure is designed to handle truncation/corruption at the tail. citeturn15view0

### Offsets, consumer state, and internal topics

Kafka offsets are monotonically increasing identifiers within a partition log, used for reads and consumer progress. citeturn15view0

Consumer group committed offsets are stored in the internal topic `__consumer_offsets`. Confluent’s consumer offsets guide explicitly states committed offsets are stored there. citeturn2search4

Exactly-once semantics and transactions rely on coordinator state stored in Kafka internal topics (such as `__transaction_state` for transaction state), and the on-disk per-partition transactional artefacts noted earlier interact with that state. citeturn2search1turn1search0

### Cluster metadata: ZooKeeper vs KRaft

Kafka’s “data logs” are only half the picture: the cluster must also maintain **metadata** about brokers, topics, partitions, ISR, leadership, configs, and (depending on mode) ACLs.

- **ZooKeeper-based metadata**: Kafka historically stored broker metadata, controller election state, cluster ID, and ACLs in ZooKeeper znodes. Documentation describing ZooKeeper hardening for Kafka lists key znodes such as `/controller`, `/cluster` (unique cluster id), `/brokers`, and `/kafka-acl` (ACL storage for ZooKeeper-based authorisers). citeturn3search31turn3search23
- **KRaft-based metadata**: Kafka’s KRaft mode stores cluster metadata in a dedicated metadata log (`__cluster_metadata`) replicated by the controller quorum; producers/consumers and brokers interact through this internalised controller system. Red Hat’s KRaft explanation describes controllers storing cluster state in the metadata log, including brokers, replicas, ISR, and partition leadership. citeturn0search20turn0search2  
  Kafka’s own KRaft operations documentation describes bootstrapping and formatting nodes with `kafka-storage.sh format`, creation of `meta.properties`, and metadata snapshots/checkpoints in the metadata log directory. citeturn0search1turn0search2  
  Kafka tooling can decode the metadata log and snapshots offline using `kafka-dump-log.sh --cluster-metadata-decoder`, which is relevant for forensic inspection of snapshot contents. citeturn0search2

## Confluent Platform components and storage/metadata differences

Self-managed Confluent Platform is built on Apache Kafka but introduces additional components, features, and metadata patterns that change what must be preserved during recovery.

### Versioning and metadata mode in Confluent Platform

Confluent’s interoperability guidance notes that Confluent Platform 8.0 onwards tracks Kafka releases more closely and that support windows vary by licensing. citeturn8search0  
Confluent’s release notes for Confluent Platform 8.1 state that it provides Apache Kafka 4.1, highlighting that “Kafka version” and “Confluent Platform version” are inseparable in planning a snapshot restore/migration. citeturn8search1  
Confluent’s “Metadata Management of Kafka in Confluent Platform” states that as of Confluent Platform 8.0, metadata storage and leader elections are handled by Kafka using KRaft controllers. citeturn10search5

### Confluent replication options that affect migration strategy

Confluent Platform offers multiple replication/mirroring technologies that are often *preferable* to filesystem-level “log copying”:

- **Cluster Linking** is explicitly positioned for disaster recovery and migration, keeping a DR cluster in sync with data, metadata, topic structure/configurations, and consumer offsets. citeturn0search3turn0search35  
  Mirror topics can sync ACLs and consumer group offsets when enabled. citeturn0search7
- **Confluent Replicator** is a Kafka Connect connector that replicates topic data and can create topics while preserving key topic properties (partition count, replication factor, and per-topic overrides). citeturn0search21
- **MirrorMaker 2** remains available as Apache tooling; Confluent documentation notes support as a stand-alone executable (but “not supported as a connector” in Confluent Replicator context). citeturn8search30turn19search5

These matter because a disk snapshot restore is often best treated as a **means to resurrect a readable source cluster**, after which you switch to replication technology for migration into the target.

### Confluent Schema Registry storage

Schema Registry stores schema data in Kafka. The Schema Registry configuration reference defines `kafkastore.topic` as the durable topic used for schema data with default `_schemas` and notes it must be compacted to avoid data loss via retention. citeturn5view0  
Schema Registry uses Kafka brokers (`kafkastore.bootstrap.servers`) both to coordinate instances (leader election) and to store schema data. citeturn5view2

Implication: if you want a faithful migration, you typically must migrate the `_schemas` topic (or export/import via API) alongside application topics. citeturn5view0turn2search14

### Confluent RBAC and authorisation metadata

Confluent’s Metadata Service (MDS) is the “system of record” for cross-cluster authorisation data (RBAC, centralised ACLs) in Confluent Platform. citeturn10search0turn10search7  
Enabling Confluent Server Authoriser uses `authorizer.class.name=io.confluent.kafka.security.authorizer.ConfluentServerAuthorizer`. citeturn10search1turn11view0  
The MDS configuration reference notes that RBAC uses Kafka “security metadata topics” configurable via the `confluent.metadata.topic.` prefix. citeturn12view2

Implication: a “Kafka data-only” restore may be incomplete if your security/governance relies on MDS metadata topics; you must plan to migrate or recreate that state.

### Tiered storage and additional internal topics

If Confluent Tiered Storage is enabled, warm data may reside in object storage rather than local broker disks; local snapshots may not contain your full history. Confluent’s tiered storage overview describes separation of storage from compute by sending warm data to object storage. citeturn10search3  
Apache Kafka’s tiered storage design (KIP-405) describes internal topics/metadata managers and local caching of remote index files under broker log directories. citeturn10search28turn16search21

Implication: snapshot-based recovery must include not just broker volumes but also object storage state and tiered-storage metadata topics/configs, otherwise you may restore only a partial dataset.

## Snapshot capture semantics for Kafka

A disk snapshot captures **broker-local state at a point in time**: partition logs, indexes, checkpoints, and `meta.properties` metadata on each volume, as well as controller metadata logs (KRaft) or ZooKeeper data (if included). The key question is whether the snapshot is *crash-consistent* or *application-consistent* across the cluster.

### What Kafka itself guarantees after a crash-like capture

Kafka’s implementation documentation describes that log flush configuration bounds the amount of data loss in an OS crash: it flushes every *M* messages or *S* seconds, providing a durability guarantee of losing at most *M* messages or *S* seconds of data in a system crash scenario. citeturn15view0  
On startup, Kafka runs log recovery, validates records, and truncates to the last valid offset when corruption/truncation is detected. citeturn15view0

Therefore, if a single broker’s log directory snapshot is internally consistent at the filesystem level, Kafka can often recover it similarly to an unclean shutdown.

### Where snapshots go wrong in distributed clusters

Even if each broker snapshot is locally recoverable, migrations fail when you cannot restore a **consistent cluster identity**:

- In ZooKeeper mode, cluster identity and state are encoded in ZooKeeper znodes (including `/cluster` for cluster ID and `/brokers` for broker metadata). citeturn3search31turn3search23
- In KRaft mode, the controller quorum’s metadata log is authoritative; Kafka describes formatting nodes with a specific cluster ID and writing metadata snapshots into the metadata log directory. citeturn0search1turn0search2
- Kafka nodes store IDs in `meta.properties`. Kafka KRaft-oriented operational material shows `meta.properties` contains at least `node.id`, `directory.id`, and `cluster.id`. citeturn1search24turn0search1

If you attempt to attach broker log directories to a different metadata store (a different cluster ID), brokers can refuse to start due to cluster ID mismatch (a common operational failure mode when persistent volumes are reused across clusters). citeturn1search13

### Practical snapshot guidance for future captures

If you can influence snapshot creation going forward, the safest pattern is “treat the snapshot like a planned crash”:

- Quiesce producers (or route them away), wait for ISR to stabilise, then take snapshots as close to simultaneously as possible.
- Prefer capturing the metadata store (ZooKeeper data dirs or KRaft metadata dirs) *and* all broker `log.dirs`.
- Use Kafka’s graceful shutdown mechanisms when possible to reduce recovery time on restart. citeturn1search23

## Recovery and migration approaches from disk snapshots

The approaches below correspond to your requested categories (A–E). In practice, the decision hinges on whether you have (and can safely restore) authoritative metadata, and whether your end goal is “recover the old cluster” or “migrate into an entirely new cluster identity”.

### Comparative overview

| Dimension | Reattach and start original cluster identity | Copy log dirs into fresh cluster | Temporary restore + replicate | Confluent offline import | Rebuild by offline replay |
|---|---|---|---|---|---|
| Intended outcome | Recovery of the original cluster (or a faithful clone) | “Direct import” into new metadata | Migration into a new cluster identity via replication | Not generally available for raw Kafka logs | Salvage import as new data |
| Practicality (modern Kafka) | High **if metadata is included** | Low / often infeasible due to topic IDs and cluster ID coupling | High (common migration/DR pattern) | Low (mostly replication-focused tools) | Medium but labour-intensive |
| Data integrity risk | Medium (snapshot-time divergence + crash recovery) | High (metadata mismatch, topic ID mismatch) | Low–medium (replication lag/cutover) | N/A | High (offset/txn semantics lost) |
| Preserves offsets | Yes (same cluster) | Only if actually same cluster identity | No, but can sync/translate consumer group offsets | N/A | No |
| Best use | Disaster recovery and forensics | Rare edge cases | Recommended for controlled migrations | — | Last resort |

This comparison follows from (i) Kafka’s tight coupling of logs to metadata (cluster ID, topic IDs, leader epochs), and (ii) the existence of purpose-built replication/mirroring features in Apache Kafka and Confluent Platform. citeturn9search2turn9search6turn0search3turn19search18turn0search21

### Workflow diagram for a recommended migration pattern

```mermaid
flowchart TD
  S[Disk snapshots available] --> Q{Do snapshots include\nmetadata store?}
  Q -->|Yes: ZK data or KRaft metadata dirs| R[Restore isolated source cluster\n(same cluster ID & node IDs)]
  Q -->|No| X[Cannot start original cluster identity]
  R --> V[Validate recovery:\nISR, offsets, internal topics]
  V --> M{Choose replication method}
  M --> CL[Cluster Linking (Confluent)\nmirror topics + offset/ACL sync]
  M --> MM2[MirrorMaker 2\nSource + Checkpoint + Heartbeat]
  M --> REP[Confluent Replicator\n(Connect connector)]
  CL --> T[Target cluster ready]
  MM2 --> T
  REP --> T
  X --> O[Offline replay salvage:\nextract logs -> re-produce]
  O --> T
```

### Approach A: Reattach disks and start with the same broker IDs/node IDs and metadata

**When it works best**

This is the “faithful restore” approach: you restore all brokers’ `log.dirs` *and* the authoritative metadata (ZooKeeper data directories, or KRaft controllers’ `metadata.log.dir`), and you start the cluster as the same logical cluster identity (same cluster ID, same broker/node IDs). Kafka’s design expects this pattern for disaster recovery and crash recovery. citeturn15view0turn3search31turn0search2turn0search1

**Prerequisites**

- Snapshots include:
  - All broker log directories (`log.dirs`), including `meta.properties` and partition directories. citeturn15view0turn1search24
  - Plus either:
    - ZooKeeper **data** directories (not just ZooKeeper logs), because broker metadata, controller election, cluster ID, and ACLs live in znodes such as `/brokers`, `/controller`, `/cluster`, `/kafka-acl`. citeturn3search31turn3search23  
    - Or KRaft metadata directories containing the `__cluster_metadata` log and snapshots. citeturn0search2turn0search1
- You can preserve or intentionally map:
  - `broker.id` (ZooKeeper mode) or `node.id` (KRaft mode). citeturn13view0turn0search2
  - Cluster ID consistency (`cluster.id`) as recorded in `meta.properties` and the metadata store. citeturn0search1turn1search24turn1search13
- You can run restoration in a controlled network segment to avoid accidental client writes while validating.

**Step-by-step procedure (high-level)**

The exact commands vary by packaging, but the critical sequence is consistent.

1. **Inventory snapshot contents (offline)**
   - Identify all log directories (from your saved `server.properties` or from inspecting the restored mounts).
   - Check for `meta.properties` presence in each log directory. In KRaft contexts, `meta.properties` includes `cluster.id` and `node.id`. citeturn1search24turn0search1

2. **Restore and start metadata layer**
   - **ZooKeeper mode**:
     - Restore ZooKeeper data directories for all ensemble members.
     - Start ZooKeeper quorum first.
     - Confirm expected znodes exist (e.g., `/brokers`, `/cluster`, `/kafka-acl`). citeturn3search31turn3search23
   - **KRaft mode**:
     - Restore controller nodes’ `metadata.log.dir`.
     - Ensure `controller.quorum.voters` and `node.id` match the restored controller identities; Kafka’s KRaft documentation requires unique IDs and formatting per cluster ID. citeturn0search2turn0search1turn0search6

3. **Restore broker volumes and configuration**
   - Mount log volumes to the expected `log.dirs` paths (or adjust `log.dirs` to match restored mount points).
   - Ensure `broker.id`/`node.id` matches what is recorded in metadata and on disk.
   - Set `listeners`/`advertised.listeners` to values appropriate for the restored environment; in KRaft mode, Confluent notes controllers are also Kafka brokers processing metadata records, so configuration symmetry matters. citeturn13view0turn10search5

4. **Start brokers (and controllers if combined-role)**
   - Start controllers first (KRaft), then brokers.
   - Expect log recovery to run; Kafka scans and truncates corrupt tails if needed. citeturn15view0turn3search0
   - If you see missing-index messages, Kafka can rebuild index files by recovering segments. citeturn9search12turn15view0

**Reference commands and tools**

Use these for validation and inspection rather than as a rigid script:

```bash
# KRaft: inspect metadata log directory (offline)
kafka-dump-log.sh --cluster-metadata-decoder \
  --files /path/to/metadata_log_dir/__cluster_metadata-0/00000000000000000000.log

# KRaft: interactive metadata inspection (offline or online)
kafka-metadata-shell.sh --directory /path/to/metadata_log_dir/__cluster_metadata-0/
```

These capabilities are described in Kafka’s KRaft operations docs and Confluent’s Kafka tools documentation. citeturn0search2turn0search26

**Risks and failure modes**

- **Cluster ID mismatch**: brokers may refuse to start if `cluster.id` differs between `meta.properties` and the metadata store (common when “reusing” persistent disks). citeturn1search13turn0search1
- **Topic ID mismatch** (Kafka 2.8+): if `partition.metadata` contains a topic ID that differs from the metadata store’s topic ID, brokers can error with inconsistent topic ID; topic IDs exist to prevent stale-topic-name aliasing. citeturn9search2turn9search11turn9search6
- **Cross-broker snapshot skew**: if snapshots were taken at materially different times, replicas may have diverging tails; recovery can trigger truncation and may expose data loss depending on ISR/leader election choices.
- **Tiered storage partial restore**: warm segments in object storage will not appear in local snapshots; restore may be incomplete. citeturn10search3turn16search21

**Data consistency and ordering guarantees**

If you restore the full cluster identity and avoid introducing unclean leadership changes, you preserve **per-partition ordering** inherent in the log. Kafka’s log model is ordered by append offset within each partition. citeturn15view0turn16search0  
However, crash-consistent snapshots can still lose the most recent unflushed/unreplicated tail, bounded by flush configuration as described in Kafka’s log implementation docs. citeturn15view0

**Validation checks**

- Verify the cluster metadata layer is healthy:
  - ZooKeeper: confirm `/brokers` is populated.
  - KRaft: check metadata quorum state (use `kafka-metadata-quorum` or metadata inspection tooling). citeturn0search2
- Verify partition health and replica placement:
  - `kafka-log-dirs --describe ...` to inspect replicas per broker/log directory. citeturn1search20
  - `kafka-replica-verification.sh` (wrapper for `ReplicaVerificationTool`) to validate replica consistency. citeturn6search13turn6search4
- Verify internal topics exist and are readable (`__consumer_offsets`, `_schemas`, `__transaction_state` as applicable). citeturn2search4turn5view0turn2search1

### Approach B: Copy partition log directories into new brokers and “fix up” offsets/leader epochs

**Executive reality check**

This approach is frequently misunderstood. Copying partition directories between hosts is a *known operational pattern within the same cluster identity* (e.g., replacing a failed broker within the same cluster), but attempting to copy logs into a brand-new cluster identity is usually unsupported and fails due to:

- **Cluster ID coupling** in `meta.properties` and metadata store. citeturn1search13turn0search1
- **Topic ID coupling** (Kafka 2.8+), via topic IDs and `partition.metadata`. citeturn9search2turn9search6turn9search11

If you truly create a fresh new cluster (new cluster ID + new topic IDs), raw directory copying tends to be a dead end.

**Where it *is* applicable**

1) **Broker migration within the same cluster** (host replacement / disk move), not a new cluster. A Cloudera Kafka administration guide explicitly describes migrating brokers between hosts by modifying `broker.id` in `meta.properties`, and using `rsync` to copy broker data directories. citeturn17view2

2) **Very old Kafka versions without topic IDs** (pre-KIP-516), in environments where topic identity is purely name-based. Even then, mismatches in offsets/ISR/leadership metadata can create inconsistency.

**Prerequisites (same-cluster broker move variant)**

- Cluster metadata remains intact (same ZooKeeper/KRaft metadata).
- You are replacing one broker host with another but keeping the broker identity consistent.
- You have the same directory structure or can map it (one `meta.properties` per data directory). citeturn17view2

**Procedure (same-cluster broker move variant)**

Following the documented “move broker” approach:

1. Start the new broker as part of the old cluster to initialise expected directories.
2. Stop both the new broker and the old broker it replaces.
3. Change the new broker’s `broker.id` to match the old broker, including in `DATA_DIRECTORY/meta.properties`.
4. Optionally use `rsync` to copy broker data from old to new host (preserving files). citeturn17view2

Example command pattern shown in the guide:

```bash
rsync -avz SRC_BROKER:SRC_DATA_DIR DEST_DATA_DIR
```

citeturn17view2

**About “tools to fix offsets/leader epoch”**

There is no mainstream supported tool that “rewrites” partition log directories to match a new cluster’s metadata. Kafka can **rebuild indexes** by recovery scanning (useful if `.index` / `.timeindex` are missing). citeturn9search12turn15view0  
For leader-epoch issues, community guidance sometimes suggests removing `leader-epoch-checkpoint` to force recovery, but this is a sharp tool and can cause data loss or inconsistencies if misused. citeturn1search16turn1search30

**Risks and guarantees**

- High risk of broker refusing to start due to cluster/topic ID mismatch. citeturn1search13turn9search11
- Even when brokers start, you can violate transactional correctness (EOS) if transactional indices/snapshots and coordinator topics are inconsistent. citeturn1search0turn2search1
- Per-partition ordering can be preserved only if the partition log is accepted as-is; in “copy into new cluster” scenarios, that acceptance is exactly what usually fails.

**Validation checks**

- Confirm `meta.properties` coherence across directories and metadata store. citeturn0search1turn1search24
- Confirm no “inconsistent topic ID” errors. citeturn9search11turn9search2
- Run replica consistency checks (`kafka-replica-verification`). citeturn6search4turn6search13

### Approach C: Mount snapshot as a temporary cluster and use replication into the new cluster

This is the most operationally robust “migration from snapshots” pattern because it reduces the problem to two supported operations:

1) restore a readable source cluster (even if isolated), then  
2) replicate into the target using supported replication software.

#### Option: Cluster Linking on Confluent Platform

**Why choose it**

Cluster Linking is designed for DR/migration use cases and aims to sync data plus topic structure/config and consumer offsets, often with low RPO/RTO. citeturn0search3turn0search35  
Mirror topics can also sync ACLs and consumer group offsets when enabled. citeturn0search7

**Prerequisites**

- Confluent Platform licensing/feature availability for Cluster Linking in your deployment.
- Network connectivity between temporary source cluster and target cluster (or equivalent secure routed connectivity).
- Proper security set-up for inter-cluster linking.

**Procedure (conceptual)**

1. Restore snapshots as an isolated source cluster (Approach A) and **block writes** from production clients.
2. Create/validate a new target cluster with desired topology.
3. Configure a **cluster link** and create **mirror topics**.
4. Enable syncing features as needed (topic config sync, ACL sync, consumer offset sync). citeturn0search7turn0search25
5. Monitor lag and catch-up; then execute cutover:
   - Pause writes to source (or stop producers).
   - Wait for replication catch-up.
   - Switch consumers/producers to the target.

Cluster Linking configuration docs describe options such as `mirror.start.offset.spec` and topic config sync intervals, which matter for deciding whether you replicate “from beginning” vs “from a point”. citeturn0search25

**Risks/failure modes**

- Misconfigured security can block ACL/offset sync.
- If consumers are active on the destination with the same group IDs, offset sync semantics can be impacted (similar conceptual constraint to MM2’s “no active consumers in target group” rule).

**Validation checks**

- Confirm mirror topics have the expected configurations and records.
- Validate consumer offsets and ACL mirroring if enabled. citeturn0search7turn0search3

#### Option: MirrorMaker 2

**Why choose it**

Apache Kafka’s geo-replication documentation describes MirrorMaker replication flows as capable of replicating topics, topic configurations, consumer groups and offsets, and ACLs across clusters. citeturn19search5

MirrorMaker 2’s configuration includes explicit offset sync features. Kafka’s MirrorMaker configs reference states:

- `sync.group.offsets.enabled`: writes *translated offsets* periodically to `__consumer_offsets` in the target cluster *as long as no active consumers in that group are connected to the target cluster*; default `false`. citeturn19search18

This is central to planning cutover and avoiding offset conflicts.

**Prerequisites**

- A restored source cluster you can read from (Approach A).
- A Kafka Connect runtime to run MM2 (since MirrorMaker 2 “uses Connectors to consume from source clusters and produce to target clusters”). citeturn19search5turn8search9
- Capacity sized for replication throughput plus retention windows.

**Procedure (operator-focused)**

1. Restore source cluster; lock it down to read-only for clients.
2. Build the target cluster.
3. Deploy a Kafka Connect worker (distributed recommended) near the target cluster.
4. Deploy MM2 connectors:
   - `MirrorSourceConnector` (replicate topics and optionally ACLs; required for checkpoints). citeturn8search2turn19search5
   - `MirrorCheckpointConnector` (emit checkpoints and optionally synchronise consumer offsets). citeturn8search2turn19search18
   - `MirrorHeartbeatConnector` (connectivity heartbeats). citeturn8search2turn19search5

Reference configuration properties to decide up front:
- Enable offset sync: `sync.group.offsets.enabled=true` and choose `sync.group.offsets.interval.seconds`. citeturn19search18turn19search14
- Ensure your replication policy (topic naming) matches your intended cutover plan.

Example conceptual invocation (from common MM2 usage patterns):

```bash
bin/connect-mirror-maker.sh config/connect-mirror-maker.properties
```

citeturn19search25turn19search5

**Data consistency and ordering**

- MM2 preserves **record order within each partition** when consuming and producing sequentially, but the destination offsets are not the same as the source offsets.
- Consumer group offset sync/translation is a best-effort operational feature with explicit constraints (no active consumers in the target group during sync). citeturn19search18turn19search1

**Risks/failure modes**

- Offset sync/tracking edge cases are documented in community threads; operationally, you must validate that the “final” offsets were synchronised before cutover. citeturn19search7turn19search18
- Running MM2 at scale adds Connect operational complexity.

**Validation**

- Compare end offsets and lag between source and target per topic/partition as part of cutover readiness.
- Validate `__consumer_offsets` behaviour for a small set of representative groups before full cutover. citeturn2search4turn19search18

#### Option: Confluent Replicator

**Why choose it**

Replicator is a supported Confluent connector designed to replicate topics between clusters; importantly, it will create topics as needed while preserving topic configuration such as partition count, replication factor, and configuration overrides. citeturn0search21  
Confluent also documents migrating from MirrorMaker to Replicator and replicating from a specific point in time (useful when legacy history is large). citeturn8search7

**Prerequisites**

- Kafka Connect with Replicator connector installed/licensed.
- Source cluster restored and reachable.

**Procedure sketch**

1. Restore source cluster (Approach A).
2. Deploy Connect+Replicator.
3. Configure Replicator to:
   - select topic set,
   - choose starting point,
   - create topics with preserved configs (as supported). citeturn0search21turn8search7
4. Monitor and cut over.

### Approach D: Confluent tools for offline import

For self-managed Confluent Platform, Confluent provides tools aimed at **metadata-mode migration** and **replication**, but public documentation does not describe an “offline import of raw broker log directories into a fresh cluster” as a supported workflow.

Relevant tools and what they do (and do not do):

- `kafka-migration-check` is provided to assess readiness/status when migrating from ZooKeeper to KRaft; it does not act as a data import tool. citeturn7search24
- Cluster Linking and Replicator are online replication technologies rather than offline bulk import. citeturn0search3turn0search21

If your requirement is strictly “no temporary cluster may be started”, you typically fall into Approach E (salvage replay). If your requirement allows “start the snapshot in an isolated network”, Approach C is the Confluent-aligned operational strategy.

### Approach E: Rebuild metadata from logs and/or offline replay into a new cluster

This category splits into two very different cases.

#### Case: You have metadata logs (KRaft) but want a new cluster identity

If you possess the KRaft metadata log directory in the snapshot, you can inspect it offline using `kafka-dump-log --cluster-metadata-decoder` (log segments and snapshots) and `kafka-metadata-shell`. citeturn0search2turn0search26  
However, Kafka’s documented flows for KRaft treat that metadata log as the authoritative state *of that cluster*; the supported way to “use it” is to start the cluster with it (Approach A), not to transplant it into a different cluster ID.

In other words, “rebuilding” metadata from KRaft logs generally leads back to “restore the original cluster identity, then replicate”.

#### Case: You only have broker data logs and must salvage data into a new cluster

If authoritative metadata is missing (no ZooKeeper data, no viable KRaft metadata directory), you can still recover *records* by replaying partition logs as an offline dataset, but it becomes a data engineering reconstruction problem:

- Partition directories are named by topic and partition (e.g., `my-topic-0`, `my-topic-1`). Kafka’s implementation docs describe this mapping. citeturn15view0
- Segment files can be decoded with `kafka-dump-log.sh` / `DumpLogSegments`, which is intended for debugging (printing/verifying log segments, including cluster metadata in KRaft contexts). citeturn1search4turn0search2

**Tooling caveat: ReplayLogProducer and legacy tools**

Older “system tools” documentation lists `kafka.tools.ReplayLogProducer` as a replay mechanism, but Kafka’s JIRA history indicates tool removals (including mention that `kafka.tools.ReplayLogProducer` has been removed). citeturn6search2turn6search28  
Therefore, on modern Kafka/Confluent Platform you should not assume an off-the-shelf “replay segments into a new cluster” tool exists; plan for custom tooling (consumer/producer code) after decoding.

**Salvage procedure sketch (offline replay)**

1. For each partition directory in the snapshot:
   - Iterate segment `.log` files in base-offset order.
2. Decode record batches:
   - Use `kafka-dump-log.sh --print-data-log` for inspection or to validate parsability. citeturn1search22turn1search4
3. Reproduce decoded records into a newly created topic/partition in the target cluster using a producer.
4. Preserve original record timestamps and keys/values; accept new offsets in target.

**What you lose (or must explicitly rebuild)**

- **Original offsets** and thus clean consumer group continuity. Consumer committed offsets live in `__consumer_offsets` and won’t map 1:1 once you reassign offsets. citeturn2search4turn19search18
- **Transactional semantics / EOS correctness** across clusters: transactional state is more than raw records; it depends on `__transaction_state` and per-partition transactional indices/snapshots. citeturn2search1turn1search0
- **Topic config fidelity** (retention, compaction policy, min ISR, etc.) unless you exported it earlier.
- **ACLs/RBAC** unless exported and recreated (ZooKeeper ACLs vs KRaft ACLs differ in storage). citeturn3search23turn3search3turn10search1
- **Schemas** unless you migrate Schema Registry state (typically `_schemas`). citeturn5view0turn2search14

This is why offline replay is best viewed as a last resort for partial recovery, not a clean migration.

## Porting topic configurations, security, schemas, and consumer state

Even if you can move *records*, a functional Kafka platform depends on replicating or reconstructing “everything around the data”.

### Topic configurations and internal topics

Replication tools differ in how much metadata they preserve:

- Replicator preserves topic configurations including partitions and replication factor and per-topic overrides. citeturn0search21
- MirrorMaker can replicate topic configurations and ACLs as part of replication flows (per Kafka geo-replication docs), but operational details depend on configuration. citeturn19search5turn19search18
- Cluster Linking is explicitly described as keeping topic structure and configurations in sync for DR/migration. citeturn0search3turn0search7

For platform components:

- Kafka Connect can create its internal topics automatically on startup and enforces compaction policy requirements. citeturn19search9  
  If your migration includes Connect state (connector configs, offsets, status), plan to replicate its internal topics or redeploy connectors and accept re-snapshotting semantics.
- Control Center’s data directory is described as recomputable but expensive; it is not Kafka data, but losing it can affect monitoring availability until it rebuilds. citeturn10search20

### ACLs vs RBAC, and where authorisation state lives

**Kafka ACLs (ZooKeeper mode)**  
Kafka’s security docs note an out-of-box authoriser that stores ACLs in ZooKeeper, configured via `authorizer.class.name=kafka.security.authorizer.AclAuthorizer`. citeturn3search23turn3search6  
If you restore from snapshots but omit ZooKeeper, you omit ACLs.

**Kafka ACLs (KRaft mode)**  
Kafka’s newer security docs describe the default KRaft authoriser storing ACLs in the cluster metadata log. citeturn3search3turn3search14  
Confluent’s ACL overview similarly states that for KRaft-based clusters, ACLs are stored in KRaft-based Kafka cluster metadata and use `StandardAuthorizer`. citeturn3search27

**Confluent RBAC (MDS / Confluent Server Authoriser)**  
MDS is the system of record for RBAC and centralised ACLs across Confluent components. citeturn10search0turn10search7  
Enabling Confluent Server Authoriser requires the `io.confluent.kafka.security.authorizer.ConfluentServerAuthorizer` class setting. citeturn10search1turn11view0  
RBAC relies on “security metadata topics” configurable via `confluent.metadata.topic.` prefix. citeturn12view2

**Migration implication**: If you rely on RBAC, validate whether your chosen replication method can migrate the necessary metadata topics and role bindings, or plan to recreate them via Confluent CLI / Metadata API in the target cluster. citeturn10search14turn10search15

### Schema Registry schemas and schema IDs

Schema Registry stores its schema history in Kafka topic `_schemas` (default), configured by `kafkastore.topic`, and the topic must be compacted. citeturn5view0  
Export/import via Schema Registry API is an alternative when topic-level migration is difficult (Schema Registry provides an HTTP API reference). citeturn2search14turn5view0

**Migration implications**

- If you replicate `_schemas` via Cluster Linking/MM2/Replicator, you likely preserve schema history.
- If you reconstruct topics by offline replay and do not migrate `_schemas`, you may render historical data undecodable by consumers expecting schema IDs, unless you also reconstruct schema state.

### Consumer offsets and cutover behaviour

Committed consumer offsets are in `__consumer_offsets`. citeturn2search4

Options:

- **Cluster Linking**: can sync consumer offsets as part of mirroring if enabled. citeturn0search7turn0search35
- **MirrorMaker 2**: supports consumer offset synchronisation/translation through `MirrorCheckpointConnector`:
  - `sync.group.offsets.enabled` writes translated offsets to `__consumer_offsets` on the target, only when no active consumers in that group are connected to the target. citeturn19search18turn19search14
- **Offline replay**: cannot preserve offsets; you must decide a new starting policy (earliest, timestamp-based, or a computed mapping), and you should document the expected reprocessing impact.

## Experimental test plan, validation checklist, and source map

### Environment setup and safety measures

Build a controlled lab that mirrors production topology closely enough to expose metadata and storage coupling:

- Use **isolated networking**: restore snapshots into a fenced VLAN/VPC/security group so no production client can connect and produce.
- Treat snapshots as evidence: always operate on **clones** of the snapshots; keep the originals immutable.
- If you will run file-level tooling (`kafka-dump-log`) on snapshot contents, mount volumes read-only initially and copy out files for inspection. citeturn0search2turn15view0
- If tiered storage is in play, include a test of object-store connectivity and remote log metadata availability. citeturn10search3turn16search21

### Experiment design and verification steps

Run experiments in increasing-risk order.

**Experiment: Can the snapshot boot as the original cluster identity? (Approach A feasibility)**

1. Restore ZooKeeper data (if ZooKeeper mode) and confirm znodes exist (`/cluster`, `/brokers`, `/kafka-acl`). citeturn3search31turn3search23
2. Restore controller metadata dirs (if KRaft) and inspect with:
   - `kafka-dump-log --cluster-metadata-decoder` for sanity. citeturn0search2
3. Start cluster components in correct order (controllers/ZooKeeper first).
4. Record:
   - time to become “ready”,
   - number of partitions requiring recovery/rebuild,
   - any cluster ID or topic ID mismatch errors. citeturn1search13turn9search11

**Experiment: Validate partition integrity and internal topic completeness**

- Validate replica placement using `kafka-log-dirs`. citeturn1search20
- Run `kafka-replica-verification.sh` for a representative topic set. citeturn6search13turn6search4
- Confirm internal topics:
  - `__consumer_offsets` contains data; expected if consumers committed offsets. citeturn2search4
  - `_schemas` exists and has compaction policy (Schema Registry depends on it). citeturn5view0

**Experiment: Replicate into a new cluster (Approach C)**

Choose one replication tool to trial end-to-end (often Cluster Linking if available, else MM2, else Replicator):

- For MM2, explicitly test:
  - `sync.group.offsets.enabled=true`,
  - the “no active consumers in target group” constraint by running/pausing consumers. citeturn19search18turn19search14
- For Cluster Linking, test:
  - mirror topics creation,
  - config sync behaviour (`mirror.start.offset.spec`, topic config sync). citeturn0search25turn0search7

### Metrics to collect

Collect metrics that let you compare approaches and detect silent divergence:

- Replication throughput and lag at topic/partition level.
- Controller/metadata health (KRaft quorum stability or ZooKeeper ensemble health). citeturn0search2turn3search31
- Partition recovery statistics (number of recovered segments, index rebuild events). citeturn15view0turn9search12
- Consumer group offset sync success rate (for MM2/Cluster Linking where enabled). citeturn19search18turn0search35

### Rollback strategies

- For “restore source + replicate target” migrations, rollback is typically “switch clients back to source” provided the source cluster remains intact and you have not advanced irreversible state.
- For cutover, use a staged plan:
  1. freeze producer writes (or dual-write, if your semantics allow),
  2. wait for replication catch-up,
  3. cut over consumers first (validate), then producers,
  4. retain the source cluster snapshot/restore for a defined rollback window.

### Authoritative source map to prioritise

The following sources are particularly high-value when planning and validating a snapshot-based migration:

- **Apache Kafka official documentation**
  - Log implementation, crash recovery, segment naming, flush guarantees. citeturn15view0
  - KRaft operations, formatting, metadata log tooling (`kafka-storage`, `kafka-dump-log`). citeturn0search1turn0search2
  - MirrorMaker 2 geo-replication overview and MirrorMaker configs (`sync.group.offsets.enabled`). citeturn19search5turn19search18
  - Authorisation and ACLs for ZooKeeper and KRaft authorisers. citeturn3search23turn3search3
  - Topic-level configs for index behaviour (`index.interval.bytes`, `segment.index.bytes`). citeturn16search20
- **Kafka Improvement Proposals and issues**
  - KIP-516 Topic Identifiers (topic IDs; prevents stale topic name collisions). citeturn9search2
  - KIP-545 offset sync across clusters in MM2. citeturn19search1turn19search18
  - JIRA issues referencing `partition.metadata` creation and topic ID mismatches. citeturn9search6turn9search11
- **Original design papers**
  - *Kafka: a Distributed Messaging System for Log Processing* (Kreps, Narkhede, Rao), listed by Kafka itself and available as a PDF; useful for foundational storage/throughput rationale. citeturn16search15turn16search0  
    (Authors were at entity["company","LinkedIn","social network company"] when the system was developed, and Kafka is now a project of the entity["organization","Apache Software Foundation","open-source foundation"].) citeturn16search0
- **Confluent documentation (self-managed)**
  - Version interoperability and major-version behavioural changes (8.x release cycle and embedded Kafka versions). citeturn8search0turn8search1
  - Metadata management in Confluent Platform (KRaft adoption in 8.0). citeturn10search5
  - Cluster Linking overview and mirror topic behaviours (offset + ACL sync). citeturn0search3turn0search7
  - Replicator overview and topic config preservation. citeturn0search21
  - Schema Registry config reference (`kafkastore.topic=_schemas`). citeturn5view0
  - Metadata Service (MDS) and Confluent Server Authoriser configuration for RBAC. citeturn10search0turn11view0
  (These are maintained by entity["company","Confluent","data streaming company"].) citeturn8search1turn10search5
- **Operational, vendor and community resources (useful but secondary)**
  - Broker migration procedures that involve `meta.properties` edits and rsync copying (illustrates same-cluster disk moves). citeturn17view2
  - Cluster ID mismatch operational symptoms and remediation patterns. citeturn1search13
  - Community reports on topic ID mismatches and the role of `partition.metadata`. citeturn9search11turn9search6

This source map should be used to drive a requirements checklist: confirm metadata mode; confirm internal topics and governance components; confirm the replication tool best aligned with your licensing and RPO/RTO goals; then design a rehearsal migration in a lab before a production cutover. citeturn0search3turn19search18turn5view0turn8search0