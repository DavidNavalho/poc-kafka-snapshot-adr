# Kafka Snapshot Restore Runbook (Standalone)

## 1. Overview

Objective: boot a Kafka snapshot in a new environment, verify data/control-plane integrity, detect error conditions early, and recover with deterministic filesystem + cluster commands.

Scope:
- KRaft-based clusters.
- Filesystem snapshot restore.
- Operator actions only (no dependency on any specific automation framework).

Assumed variables:
```bash
TARGET_BOOTSTRAP="target-broker-1:9092"
TARGET_DATA_ROOT="/var/lib/kafka/data"   # adjust to your deployment
BROKERS="1 2 3"
TOPIC_RESTORE_CHECK="<restored_topic_with_known_baseline>"
TOPIC_SMOKE_WRITE="<dedicated_canary_topic>"
TXN_ID_CRITICAL="<transactional_id_if_used>"
```

Topic intent:
- `TOPIC_RESTORE_CHECK`: restored topic used to verify snapshot parity/continuity (read checks).
- `TOPIC_SMOKE_WRITE`: low-risk canary topic used for post-restore write/read probe.
- Do not use internal topics (`__consumer_offsets`, `__transaction_state`) for smoke writes.

Assumptions:
- Broker logs are always available and queryable without traversing the full log volume.
  Examples: centralised log aggregation (Elasticsearch, Splunk, CloudWatch Logs), or direct
  access to the broker log file with the ability to tail/search a bounded recent window.
  Steps that reference log searches are written assuming such access; if logs are only
  available as raw files on large disks, treat those steps as `🚫 Defer` until the system
  is running and log forwarding is active.
- Filesystem commands operate on mounted, readable data directories.
- All Kafka CLI tools are available on the operator's path.

---

## 2. Phased rollout for large client fleets

Design goal:
- Use cheap, low-impact checks first.
- Avoid full-topic/full-filesystem scans during initial cutover.
- Trigger heavy recovery actions only when specific gates fail.

### 2.1 Ordered phases (must run in order)

Phase 1: pre-boot disk identity gate
- Check `cluster.id` uniformity and `node.id` correctness across brokers before startup.
- Check required broker data directories exist.
- Stop here if any mismatch is detected.

Phase 2: control-plane bootstrap gate
- Start brokers.
- Validate stable quorum and leader election.
- Validate no offline partitions in critical topic set.

Phase 3: minimal data-plane gate
- Read continuity checks on `TOPIC_RESTORE_CHECK`.
- Write/read canary checks on `TOPIC_SMOKE_WRITE`.
- Validate no critical broker exceptions.

Phase 4: controlled client ramp
- Ramp clients in cohorts (example: 1% -> 10% -> 25% -> 50% -> 100%).
- Hold each cohort long enough to observe lag, error rate, and group-progress stability.
- Advance only if all gates remain green.

Phase 5: low-impact broad verification
- Expand checks to all topics/groups in throttled batches.
- Run off-peak; avoid expensive all-at-once describe/consume operations.
- Continue serving traffic; abort broad scan if cluster load rises beyond policy.

Phase 6: deep recovery only on trigger
- Perform heavy Kafka-side recovery actions (segment-level diagnostics, partition/node stabilization, coordinator/producer recovery) only when gated checks fail.
- Keep these actions targeted to affected partitions/nodes first, then widen if unresolved.

### 2.2 Likelihood-first handling

Default high-likelihood conditions (handle early):
- metadata identity mismatch (`cluster.id`, `node.id`)
- quorum instability
- offline leadership on critical partitions
- consumer-group reprocessing window drift

Medium-likelihood conditions:
- stale HWM/checkpoint drift
- transaction coordinator delayed resolution

Lower-likelihood but high-impact conditions:
- truncated/partial segment corruption
- persistent cross-node divergence loops
- producer epoch/sequence mismatch that does not self-heal after producer reinit

Policy:
- High-likelihood checks are mandatory before and during ramp.
- Medium checks are mandatory before 50%+ client ramp.
- Lower-likelihood checks are trigger-driven unless error signals appear.

### 2.3 Scan scope and impact guidance

Do by default:
- Read small metadata files (`meta.properties`, checkpoints) only.
- Query critical topic set + critical consumer groups.
- Query quorum status repeatedly (cheap and high value).

Do later in throttled mode:
- All-topic describes in batches.
- All-group offset audits in batches.
- Background broker log scans with bounded windows.

Avoid as default:
- Full filesystem/segment scans across all partitions.
- Unbounded log greps over entire broker log history.
- Cluster-wide heavy admin operations during peak traffic.

### 2.4 Phase-to-method linkage (explicit)

Use this mapping so phases and recovery methods stay connected:

Phase 1 (pre-boot disk identity gate):
- Primary method bundles: `A`
- Primary error sections: `4.1`, `4.2`
- Gate: do not start brokers until pass.

Phase 2 (control-plane bootstrap gate):
- Primary method bundles: `B`
- Primary error sections: `4.3`, `4.4`, `4.5`
- Gate: no client ramp until quorum and critical partition leadership are stable.

Phase 3 (minimal data-plane gate):
- Primary method bundles: `C` (C1/C2 at minimum)
- Primary error sections: `4.6`, `4.7`, `4.11`, `4.13`
- Gate: no client ramp until read continuity + canary write/read both pass.

Phase 4 (controlled client ramp):
- Primary method bundles: `C` (C3/C4/C5 as applicable)
- Primary error sections: `4.8`, `4.9`, `4.10`, `4.12`
- Gate: advance cohort only if current cohort stays within policy thresholds.

Phase 5 (low-impact broad verification):
- Primary method bundles: `B` + `C` in throttled broad scope
- Primary error sections: all `4.x` as detection expansion
- Gate: keep cluster impact bounded; stop broad scans if health degrades.

Phase 6 (deep remediation on trigger):
- Primary method bundles: `D`
- Primary error sections: whichever gate failed in earlier phases
- Gate: start with targeted Kafka-side remediation and keep snapshot-artifact decisions outside normal recovery flow.

---

## 3. Baseline health checks after snapshot boot

### 3.1 Filesystem integrity

```bash
for b in $BROKERS; do
  test -f "${TARGET_DATA_ROOT}/broker${b}/meta.properties" \
    || echo "MISSING meta.properties on broker${b}"
  grep '^cluster.id=' "${TARGET_DATA_ROOT}/broker${b}/meta.properties"
  grep '^node.id='    "${TARGET_DATA_ROOT}/broker${b}/meta.properties"
  # Clean shutdown marker: absence means unclean shutdown — expect full log recovery
  test -f "${TARGET_DATA_ROOT}/broker${b}/.kafka_cleanshutdown" \
    && echo "broker${b}: clean shutdown marker present (no recovery replay expected)" \
    || echo "broker${b}: NO clean shutdown marker — full log segment recovery will run on start"
done
```

Expected:
- `meta.properties` exists on every broker.
- `cluster.id` identical across brokers.
- `node.id` matches broker identity.
- Note the clean-shutdown status per broker: brokers without `.kafka_cleanshutdown` will
  replay all unflushed log segments above `recovery-point-offset-checkpoint` on startup.
  This is normal but increases startup time and creates a small duplicate-processing window.

### 3.2 Quorum and partition health

```bash
kafka-metadata-quorum --bootstrap-server "$TARGET_BOOTSTRAP" describe --status

# Efficient: only show partitions with no available leader (avoids unbounded output on large clusters)
kafka-topics --bootstrap-server "$TARGET_BOOTSTRAP" --describe --unavailable-partitions

# Full describe for critical topics only (do NOT run --describe without --topic on large clusters
# during Phase 2; defer to Phase 5 throttled batch scan)
kafka-topics --bootstrap-server "$TARGET_BOOTSTRAP" --describe --topic "$TOPIC_RESTORE_CHECK"
```

Signals:
- Healthy quorum has a valid leader and active voters.
- No `Leader: -1` partitions in critical topic set.

### 3.3 Data-path smoke

```bash
# read continuity on restored topic
kafka-get-offsets --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" --time -1

# ensure canary topic exists for write probe
kafka-topics --bootstrap-server "$TARGET_BOOTSTRAP" --create --if-not-exists \
  --topic "$TOPIC_SMOKE_WRITE" --partitions 3 --replication-factor 3

seq 1 20 | awk '{printf "smoke-%03d:{\"probe\":%d}\n",$1,$1}' | \
kafka-console-producer --bootstrap-server "$TARGET_BOOTSTRAP" \
  --topic "$TOPIC_SMOKE_WRITE" --property parse.key=true --property key.separator=:

kafka-console-consumer --bootstrap-server "$TARGET_BOOTSTRAP" \
  --topic "$TOPIC_SMOKE_WRITE" --from-beginning --max-messages 20 --timeout-ms 10000
```

Signals:
- End offsets readable.
- Post-restore writes accepted.
- Reads return data, not timeout-only.

---

## 4. Error conditions: observe, diagnose, recover

For each condition:
- What to observe.
- How to verify quickly.
- Recovery actions.
- What to automate later.

---

### Low-likelihood: identity mismatch conditions (§4.1, §4.2, §4.13)

Sections §4.1, §4.2, and §4.13 cover conditions that should **not** arise in a well-executed
full snapshot restore of the same cluster — if the snapshot is consistent and all broker
directories are correctly assigned, identity values will match by construction.

They are documented here because:
- They have high diagnostic impact if they *do* appear (broker refuses to start, or partitions
  silently go offline).
- They can arise in hybrid or migration scenarios where snapshot sources are mixed.
- They share a common secondary effect: the failing broker's crash loop destabilises otherwise
  healthy brokers via ISR churn.

Unless you have reason to suspect a mixed-source snapshot, do a quick pass on these checks
as part of the pre-boot gate (Phase 1), then move on. Do not spend time on deep
investigation of these conditions unless brokers refuse to start or partitions go stray.

---

### 4.1 Cluster identity mismatch (`cluster.id`)

> **Likelihood in a full snapshot restore: LOW.** A complete snapshot of all broker data
> directories from the same cluster will carry a consistent `cluster.id` everywhere. This
> condition is most likely to appear when snapshots are assembled from multiple sources, or
> when a broker directory is accidentally taken from a different cluster. Document here for
> completeness and for hybrid/migration scenarios.

Observe:
- Broker refuses startup.
- Logs contain mismatch text.
- **Secondary effect**: the mismatched broker enters a crash loop, which causes ISR churn on
  the working brokers (the crash loop disrupts the ISR of topics the broken broker was a
  replica for, and can trigger transient restarts on otherwise-healthy brokers). If a
  seemingly-healthy broker is unstable, check whether a *different* broker is the root cause.

Common log shape:
```text
Invalid cluster.id in .../meta.properties. Expected <X>, but read <Y>
```

Verify:
```bash
for b in $BROKERS; do grep '^cluster.id=' "${TARGET_DATA_ROOT}/broker${b}/meta.properties"; done
```
Search logs for: `Invalid cluster.id`, `Expected .* but read`, `inconsistent clusterId`

Recover:

> **WARNING**: Never blanket-rewrite `cluster.id` on all brokers. The correct cluster.id is
> the value that the majority of your brokers (and specifically the KRaft controller quorum)
> already agree on. Overwriting all nodes with an externally sourced ID risks misidentifying
> which node holds the divergent copy, and can corrupt a valid cluster.

Steps:
1. From the output above, identify which broker(s) show a **different** `cluster.id` from the
   majority.
2. Treat the majority value as authoritative (it is what the controller quorum was formed with).
3. Fix **only the mismatched broker(s)**:

```bash
EXPECTED_ID="<cluster_id_from_majority_brokers>"
BAD_BROKER="<broker_number_with_wrong_cluster_id>"

awk -F= -v id="$EXPECTED_ID" \
  'BEGIN{OFS="="} $1=="cluster.id"{$2=id} {print $1,$2}' \
  "${TARGET_DATA_ROOT}/broker${BAD_BROKER}/meta.properties" \
  > /tmp/meta.${BAD_BROKER}

mv /tmp/meta.${BAD_BROKER} "${TARGET_DATA_ROOT}/broker${BAD_BROKER}/meta.properties"
# Restart only the corrected broker, then rerun quorum and partition checks.
```

4. Once the broken broker is corrected and restarted, working brokers that were experiencing
   ISR churn should stabilise on their own within a few election cycles.

Automate later:
- Pre-start uniformity gate on `cluster.id` across all target brokers.
- Majority-vote logic to identify the outlier rather than requiring manual identification.

### 4.2 Node identity mismatch (`node.id`)

> **Likelihood in a full snapshot restore: LOW.** As with `cluster.id`, a full snapshot of
> correctly provisioned brokers will carry the right `node.id` in each data directory. This
> condition is most likely to appear when broker directories are reassigned or remounted to
> different hosts during the restore process.

Observe:
- Broker startup errors; quorum instability.
- **Secondary effect**: same ISR churn pattern as §4.1 — a broker stuck in a crash loop due
  to a `node.id` mismatch disrupts the ISR of its assigned partitions, causing instability on
  otherwise-healthy brokers. Diagnose all brokers' `meta.properties` before assuming the
  unstable broker is itself misconfigured.

Verify:
```bash
for b in $BROKERS; do
  echo "broker${b}:"
  grep '^node.id=' "${TARGET_DATA_ROOT}/broker${b}/meta.properties"
done
```

Recover:
- Correct `node.id` in each affected `meta.properties` to match the broker's expected identity.
- Restart corrected brokers.
- Re-run quorum + partition checks; ISR churn on working brokers should clear once the
  mismatched broker restarts cleanly.

Automate later:
- Static mapping check: directory/broker name → expected `node.id`.

### 4.3 Stale quorum-state / election instability

Observe:
- Repeated leader elections after boot.
- Cluster is reachable intermittently or never stabilizes.

Typical log patterns:
```text
Beginning new election, bumping epoch ...
Resigned leadership ...
```

Verify:
```bash
kafka-metadata-quorum --bootstrap-server "$TARGET_BOOTSTRAP" describe --status
grep -Ehi 'Beginning new election|Resigned leadership|leaderEpoch' <broker-log-files>
```

Recover:

> **IMPORTANT — startup ordering**: For quorum to form after a snapshot restore, all voter
> nodes should be started **close to simultaneously** (within a few seconds of each other).
> A rolling start (one broker at a time with waits between) risks a quorum of 1 forming on
> the first node with stale state; when the second and third nodes join with a different
> epoch, repeated re-elections follow. If quorum is already unstable, stop all brokers and
> restart them together.

1. Validate controller listener reachability and voter configuration consistency across all
   nodes (`controller.quorum.voters` in `server.properties`).
2. Stop all brokers.
3. Start all voter nodes within a few seconds of each other.
4. If quorum still does not form, inspect `quorum-state` on each node:
   ```bash
   cat "${TARGET_DATA_ROOT}/broker<id>/__cluster_metadata-0/quorum-state"
   ```
   A corrupt or inconsistent `quorum-state` (wrong voter set, epoch 0 on one node vs.
   high epoch on another) can be manually corrected before restart:
   - Determine the correct epoch and voter set from the broker logs of the node that most
     recently held leadership.
   - Edit `quorum-state` on divergent nodes to match, then start all nodes together.
5. If one node has persistently invalid metadata state after the above steps, rebuild only
   that node from a known-good metadata source, then rejoin.

Automate later:
- Bounded election-stability check: fail if leader changes repeatedly within a short window.

### 4.4 Cross-node log divergence at epoch boundary

Observe:
- Followers truncate and replay from leader.
- Logs mention diverging epoch or truncation boundary.

Typical log patterns:
```text
Truncating partition ... due to diverging epoch
divergingEpoch in fetch response
```

> **NOTE — cross-node snapshot skew**: If snapshots were taken from different nodes at
> different wall-clock times (even seconds apart), each node's HWM checkpoint, producer
> state snapshots, and log segments reflect different logical moments. The leader may have
> written records after the follower's snapshot time but before the leader's snapshot time
> — or vice versa. Kafka's epoch-based truncation is designed to resolve these divergences
> automatically, but the initial ISR rebuild may take longer than expected with large skew
> windows. Skew is expected in snapshot restores; it does not indicate a broken cluster.

Verify:
```bash
grep -Ehi 'diverging epoch|Truncating partition' <broker-log-files>
kafka-topics --bootstrap-server "$TARGET_BOOTSTRAP" --describe --topic "$TOPIC_RESTORE_CHECK"
```

Recover:
1. Treat the elected leader as source of truth for that epoch.
2. Allow followers to truncate and replay automatically. This is the designed behavior
   and will self-heal given time and network connectivity — no operator action required.
3. **Do NOT manually rehydrate a partition directory from a snapshot** to "fix" a diverging
   follower. Replacing segment files mid-recovery introduces a different epoch boundary and
   typically causes another round of divergence or a persistent truncation loop. Let Kafka's
   native truncation handle it.
4. If a follower fails to converge after a reasonable wait (not just slow catch-up, but
   repeated back-and-forth truncation with no progress), investigate network connectivity
   first. If the node is genuinely broken, remove it from the ISR with
   `--force-unsync-replicas` and replace the node entirely rather than filesystem surgery.

Automate later:
- Detect repeated truncation loops on the same partition (no progress over N minutes) and
  alert for node-replacement rather than snapshot-rehydration.

### 4.5 Offline partitions / broken leadership

Observe:
- `Leader: -1` in topic describe.
- Consumers/producers hang or fail on specific partitions.

Verify:
```bash
kafka-topics --bootstrap-server "$TARGET_BOOTSTRAP" --describe --unavailable-partitions
```

Recover:
1. Ensure replicas for affected partitions are online.
2. Trigger preferred leader election if available.
3. Restart impacted brokers and re-check ISR/leader state.

Automate later:
- Fail fast when any `Leader: -1` exists in the critical topic set.

### 4.6 Stale checkpoint / high-watermark drift

Observe:
- Consumer cannot read expected offsets even though data exists.
- End-offset/consumer progress mismatch.
- Inverse case: `HWM > LEO` leads to `OFFSET_OUT_OF_RANGE`.

> **NOTE — self-healing behavior**: The HWM is a computed property that Kafka advances
> automatically as ISR replicas exchange fetch requests. It does **not** require a broker
> restart to correct. Restarting a broker or moving leadership to resolve HWM staleness
> is unnecessary and may delay recovery by triggering new leader elections and additional
> re-fetch cycles.
>
> The maximum HWM staleness window is controlled by
> `replica.high.watermark.checkpoint.interval.ms` (default: **5000ms**). In the worst
> case (all brokers crashed simultaneously, page cache lost, last checkpoint was 5s before
> crash), the HWM may be stale by up to this interval. This directly bounds the consumer
> re-processing window per partition.

Verify:
```bash
# Checkpoint content (path may vary by deployment)
cat "${TARGET_DATA_ROOT}/broker<id>/replication-offset-checkpoint"
# Runtime end offsets
kafka-get-offsets --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" --time -1
```

Recover:
1. Wait for ISR convergence: once all ISR replicas reconnect and exchange fetch requests,
   the HWM advances to the correct value without any operator action.
2. Monitor convergence:
   ```bash
   watch -n 2 "kafka-topics --bootstrap-server $TARGET_BOOTSTRAP \
     --describe --topic $TOPIC_RESTORE_CHECK"
   ```
   Wait until the ISR set equals the full replica set and `Leader` is stable.
3. `OFFSET_OUT_OF_RANGE` (HWM > LEO): this indicates one broker started with an older
   snapshot than its ISR peers. The follower will truncate to match the leader's LEO.
   This is normal and self-resolves; no operator action needed.

Automate later:
- Post-ISR-convergence check: compare checkpoint value vs. runtime end offset and alert
  if delta exceeds policy after a defined wait window.

### 4.7 Truncated or partial segment tail corruption

Observe:
- Startup recovery logs mention invalid messages or discarded tail.
- LEO drops after recovery.

Typical log patterns:
```text
Found invalid messages ... discarding tail ...
Recovering unflushed segments ...
```

Verify:
```bash
grep -Ehi 'Found invalid messages|discarding tail|Recovering unflushed segments|CorruptRecordException' \
  <broker-log-files>
kafka-get-offsets --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" --time -1
```

Recover:
1. Let broker recovery truncate to the last valid batch boundary. This is normal behavior
   on unclean shutdown and produces a correct, consistent log end.
2. If broker does not recover cleanly:
   - Stop broker.
   - Back up affected partition directory.
   - Remove corrupted index sidecars (`*.index`, `*.timeindex`, `*.txnindex`) for the
     affected segment and restart the broker; it will rebuild them from the `.log` file.
3. Re-check offsets and smoke I/O after recovery.

Automate later:
- Detect corruption log signatures and run controlled broker recovery workflow.

### 4.8 Transaction state ambiguity (ongoing / prepare-commit)

Observe:
- Transactional id remains `Ongoing` too long.
- `read_committed` stalls while `read_uncommitted` shows records.

Verify:
```bash
kafka-transactions --bootstrap-server "$TARGET_BOOTSTRAP" list
kafka-transactions --bootstrap-server "$TARGET_BOOTSTRAP" \
  describe --transactional-id "$TXN_ID_CRITICAL"

# Compare read_committed vs read_uncommitted progress on the same topic
kafka-console-consumer --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" \
  --from-beginning --isolation-level read_committed \
  --max-messages 200 --timeout-ms 12000

kafka-console-consumer --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" \
  --from-beginning --isolation-level read_uncommitted \
  --max-messages 200 --timeout-ms 12000
```

Recover based on observed transaction state:

**ONGOING** (normal post-restore state):
- The transaction coordinator applies `transaction.timeout.ms` to auto-abort stale
  transactions. Allow the coordinator recovery window to elapse.
- Recheck transaction status and committed-read progress after the timeout.
- If still stuck: restart the coordinator leader broker to force coordinator reload.

**PREPARE_COMMIT** (partial commit — most operationally dangerous state):
- Symptoms: `read_committed` consumers see different last-committed offsets across
  partitions of the same transaction. Some partitions appear fully committed; others
  stall. This occurs because the coordinator has written the COMMIT marker to some
  partitions but not yet to all of them when the snapshot was taken.
- Recovery: the transaction coordinator is designed to re-send COMMIT markers to the
  remaining partitions on recovery. **Do not manually modify segment files.** Allow the
  coordinator to restart and re-send. Monitor `read_committed` progress after coordinator
  restart — it should advance across all partitions.

**PREPARE_ABORT** (symmetric to PREPARE_COMMIT):
- The coordinator will re-send ABORT markers. Same approach: allow coordinator recovery.

Automate later:
- Gate on transaction state + committed-read progress; alert specifically on PREPARE_COMMIT
  duration (should resolve within seconds of coordinator restart; long duration indicates
  a coordinator bug or network partition to a topic partition).

### 4.9 Producer epoch mismatch / idempotent state corruption

Observe:
- Producer receives epoch/sequence exceptions.

Common error classes (any of the following indicate this condition):
```text
OutOfOrderSequenceException
ProducerFencedException
InvalidProducerEpochException
InvalidTxnStateException
TransactionAbortableException
```

The last two (`InvalidTxnStateException`, `TransactionAbortableException`) are raised by
some broker implementations (e.g. Confluent Platform) when the client-side transaction state
machine detects an inconsistency before the broker even responds — they are functionally
equivalent to the classic epoch/sequence exceptions for recovery purposes.

Verify:
```bash
grep -E 'OutOfOrderSequenceException|ProducerFencedException|InvalidProducerEpochException|InvalidTxnStateException|TransactionAbortableException' \
  <producer-logs> <broker-logs>
```

Recover:
1. Keep the **same `transactional.id`** — do not change it. The `transactional.id` is how
   the coordinator maps to the producer's epoch history. Changing it creates a new producer
   identity and leaves the old transaction state as a zombie in `__transaction_state`.
2. Stop the existing producer instance (do not call `close()` on the hung producer if it is
   in a fenced state; just discard it).
3. Create a **new `KafkaProducer` instance** with the same `transactional.id` and call
   `initTransactions()`. This causes the coordinator to bump the epoch, fencing any old
   producer instance that may still be running.
4. Resume producing with the new instance.
5. **Exception**: If `__transaction_state` was copied from a source cluster at a point where
   the epoch had already advanced further than the destination cluster's copy, calling
   `initTransactions()` may still be rejected with a higher-epoch conflict. This is a
   cluster-copy-specific scenario; see the `transaction-adr.md` document for epoch-reset
   options.

Automate later:
- Exception-class trigger -> producer reinit with same `transactional.id` + verify loop.

### 4.10 Consumer group offset re-processing window

Observe:
- Consumers restart from older committed offsets.
- Duplicate processing window appears after restore.

> **Quantified bounds**: The re-processing window is bounded by
> `replica.high.watermark.checkpoint.interval.ms` (default: **5000ms**). In the worst
> case (all brokers crashed without clean shutdown, page cache flushed at crash time, last
> HWM checkpoint was 5 seconds before the crash), consumers may re-process up to 5 seconds
> of messages **per partition**.
>
> With snapshot restores, the actual window depends on the delta between the snapshot
> capture time and the most recent HWM checkpoint file timestamp. Check the checkpoint
> file mtime vs. snapshot timestamp to estimate the actual per-partition reprocessing
> window before ramp.

Verify:
```bash
kafka-consumer-groups --bootstrap-server "$TARGET_BOOTSTRAP" --describe --group <group_id>
# Check checkpoint file timestamp vs. snapshot timestamp
stat "${TARGET_DATA_ROOT}/broker<id>/replication-offset-checkpoint"
```

Recover:
1. Treat as expected at-least-once behavior unless offsets are missing beyond policy.
2. Ensure application dedupe/idempotency is active.
3. If required, manually advance group offsets to a known safe point using admin tooling:
   ```bash
   kafka-consumer-groups --bootstrap-server "$TARGET_BOOTSTRAP" \
     --group <group_id> --reset-offsets --to-offset <safe_offset> \
     --topic <topic>:<partition> --execute
   ```

Automate later:
- Compare expected vs. observed group offsets; enforce duplicate-window threshold (e.g.,
  reject ramp if any group is more than N seconds behind the expected committed offset).

### 4.11 Data regression after restore

Observe:
- Target end offsets lower than expected snapshot baseline.
- Missing keys/messages after boot.

Verify:
```bash
kafka-get-offsets --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" --time -1
```

Recover:
1. Stop target writes.
2. Re-validate snapshot completeness on filesystem.
3. Re-run Kafka-side diagnostics (leader/ISR stability, checkpoint/offset consistency,
   broker recovery logs) and targeted remediation.
4. If unresolved, escalate as snapshot-artifact integrity incident (outside normal Kafka
   recovery path).

Automate later:
- Parity gate: target offsets must be >= captured baseline.

### 4.12 Simultaneous crash restore behavior

Observe:
- Full log recovery on all brokers (no clean-shutdown marker path).
- Small duplicate/replay window may appear depending on offset/checkpoint timing.

Verify:
```bash
# Absence of .kafka_cleanshutdown indicates unclean shutdown (also checked in §3.1)
ls "${TARGET_DATA_ROOT}/broker<id>/.kafka_cleanshutdown" 2>/dev/null \
  || echo "broker<id>: unclean shutdown detected"
grep -Ehi 'Recovering unflushed segments|no clean shutdown' <broker-log-files>
kafka-consumer-groups --bootstrap-server "$TARGET_BOOTSTRAP" --describe --group <group_id>
```

Recover:
1. Validate quorum/partition health first (Phase 2 gates).
2. Validate consumer progress and duplicate window (see §4.10 for bounded window estimate).
3. If loss/regression exceeds policy, halt traffic and escalate as incident requiring
   artifact-level decision (outside normal Kafka recovery path).

Automate later:
- Post-crash acceptance gate using quorum + offset + duplicate-window checks.

---

### Low-likelihood (continued): §4.13

### 4.13 Partition metadata UUID mismatch (`partition.metadata`)

> **Likelihood in a full snapshot restore: LOW.** A complete snapshot of a cluster taken at
> a consistent point in time will carry matching UUIDs everywhere — the KRaft metadata log
> and the `partition.metadata` files in each partition directory are from the same cluster
> identity. This condition arises specifically when snapshots are assembled from mismatched
> sources (e.g. data directories from cluster A, KRaft metadata log from cluster B or from a
> different point in time), or in explicit cluster identity migration scenarios.

Observe:
- Partitions silently go OFFLINE shortly after broker start.
- Broker data directory for a partition gets renamed with a `-stray` suffix.
- No explicit "UUID mismatch" error in broker logs; the partition simply disappears from
  the ISR and goes `Leader: -1`.

Typical log patterns:
```text
INFO  Renaming directory .../topic-name-0 to .../topic-name-0-stray
WARN  Partition topic-name-0 is not found in metadata log; skipping directory
```

This condition arises when the `partition.metadata` file inside each partition directory
contains a topic UUID that does not match the UUID registered in the KRaft metadata log.

Verify:

**Step 1 — check for stray directories (⚡ instant, targeted):**
Do this first. It confirms the problem is present without touching the full data tree.
```bash
# Scope to known critical topic directories only
find "${TARGET_DATA_ROOT}/broker<id>/<critical-topic-name>-*" -maxdepth 0 -name "*-stray" -type d
```

**Step 2 — inspect `partition.metadata` for critical partitions only (⚡ instant, targeted):**
```bash
# Only check the specific critical topic partitions, not the whole data root
for part_dir in "${TARGET_DATA_ROOT}/broker<id>/<critical-topic-name>"-*; do
  echo "=== ${part_dir} ==="; cat "${part_dir}/partition.metadata" 2>/dev/null || echo "missing"
done
```

**Step 3 — cross-reference KRaft metadata log (🕐 fast, but requires metadata snapshot access):**
```bash
kafka-dump-log --files <path-to-latest-metadata-snapshot> --cluster-metadata-decoder \
  | grep -i 'TopicRecord\|PartitionRecord' | head -100
```

> **🚫 Avoid** running a recursive `find` over the full data root to enumerate all
> `partition.metadata` files on a large snapshot (hundreds of GB to TB). Scope to the
> critical topic set first. Expand the scan to other topics only after the system is running
> and the check can be run as a background deferred task.

Recover:

**Option 1 — Preserved cluster.id (same-cluster restore — expected path)**:
If the KRaft metadata and partition data came from the same cluster at a consistent snapshot
time, UUIDs must match. A mismatch here indicates the snapshot was assembled from
inconsistent sources. Stop, investigate which source each directory set came from, and
correct before starting brokers.

**Option 2 — Fresh KRaft with new cluster.id (migration / test scenarios)**:
The topic UUIDs in `partition.metadata` were generated by the source cluster and will never
match a newly formatted KRaft cluster. Stray directories are expected in this case.
Delete them, then re-create topics and assign replicas:
```bash
# After verifying stray directories are the ones you intended to restore
rm -rf "${TARGET_DATA_ROOT}/broker<id>/<topic>-<partition>-stray"
# Re-create topics via admin API, then use partition reassignment to assign replicas
```

Automate later:
- Pre-start targeted check: for each **critical** partition directory only, validate that
  `partition.metadata` UUID matches the UUID in the KRaft metadata log. Alert on mismatch
  before broker start to avoid silent partition loss. Expand to non-critical partitions
  as a deferred background task after the system is running.

---

## 5. Final proposal: command bundles for future automation

No specific tooling assumed. Treat each bundle as a callable unit.

### Bundle A: preflight metadata and disk state
```bash
# A1 meta.properties present on all brokers
# A2 cluster.id uniform across brokers (identify outlier, not overwrite all)
# A3 node.id mapping valid per broker
# A4 critical topic partition dirs exist
# A5 .kafka_cleanshutdown presence logged per broker (affects recovery time estimate)
# A6 partition.metadata UUID matches KRaft-registered UUID for critical partitions
```

### Bundle B: startup acceptance
```bash
# B1 quorum leader exists and is stable (no rapid re-elections)
# B2 no Leader:-1 partitions in critical topic set (use --unavailable-partitions)
# B3 all intended brokers visible in metadata
```

### Bundle C: data and transaction acceptance
```bash
# C1 end offsets readable
# C2 smoke produce/consume passes
# C3 transaction list/describe healthy (if transactional workloads)
# C4 no unresolved producer-epoch/sequence exceptions
# C5 consumer-group offset position within accepted duplicate window
#    (bound = replica.high.watermark.checkpoint.interval.ms, default 5s)
```

### Bundle D: deterministic remediation actions
```bash
# D1  identify outlier cluster.id -> fix only that broker -> restart -> validate
# D2  fix node.id -> restart -> validate
# D3  quorum instability -> stop all, start simultaneously -> validate
# D4  epoch divergence -> allow self-heal (do not rehydrate) -> validate
# D5  checkpoint drift -> wait for ISR convergence (no restart needed) -> validate
# D6  truncated/corrupt tail -> broker recovery path -> validate
# D7  txn ONGOING stuck -> coordinator restart -> validate
# D7b txn PREPARE_COMMIT -> coordinator restart to re-send markers -> validate
# D8  producer epoch errors -> reinit same transactional.id -> validate
# D9  consumer-offset drift -> offset correction policy action -> validate
# D10 partition UUID mismatch -> remove stray dirs + reassign or investigate source
# D11 regression -> stop rollout, run incident triage, artifact-level decision by policy
```

### Done criteria (minimum)
- quorum stable and reachable
- no offline partitions
- critical data path smoke passes
- transactional workloads progress (if applicable)
- consumer-group duplicate window within policy (if applicable)
- no unresolved critical exceptions in broker/producer logs
- no stray partition directories in critical topic set

---

## 6. TL;DR — Automation checklist for snapshot restore

Flat ordered checklist. Run steps in order. Each step includes a time-cost label:

- ⚡ **Instant** — file reads or single metadata queries, completes in seconds.
- 🕐 **Fast** — a handful of CLI calls or a short wait, completes in under a minute.
- 🕑 **Slow** — involves a broker restart or a convergence wait, takes several minutes.
- 🚫 **Defer** — log scans, full topic/group enumerations, or full filesystem traversals.
  Run only after the cluster is serving traffic, in a bounded background window.

If a step has a `→ see §X.Y` reference, that section contains the full recovery procedure.

---

### Stage 1 — Pre-boot (run before starting any broker)

**1. Verify `meta.properties` exists on every broker.** ⚡
- Check: file present at `<data-root>/broker<id>/meta.properties` on each node.
- Pass: all brokers have the file.
- Fail: missing file means the data directory is incomplete or the wrong path is mounted.
  Do not start brokers. Investigate snapshot completeness.

**2. Check `cluster.id` is uniform across all brokers.** ⚡
- Read `cluster.id` from each broker's `meta.properties`.
- Pass: all values are identical.
- Fail: identify the outlier (majority value is authoritative). Correct only the mismatched
  broker. → see §4.1

**3. Check `node.id` matches the expected broker identity on each node.** ⚡
- Read `node.id` from each broker's `meta.properties`.
- Pass: each broker's `node.id` matches the static mapping for that host/directory.
- Fail: correct the `node.id` in `meta.properties` for the affected broker. → see §4.2

**4. Note clean-shutdown status per broker.** ⚡
- Check: presence of `.kafka_cleanshutdown` marker in each data directory.
- Pass (marker present): no segment replay on startup; fast boot expected.
- Pass (marker absent): full log segment recovery will run; startup is slower and a small
  duplicate window is expected. Note which brokers are in this state for §4.10 planning.

**5. Check critical partition directories exist on their assigned brokers.** ⚡
- Verify that the data directories for your critical topics exist on the expected brokers.
- Pass: directories present.
- Fail: missing partition directories indicate an incomplete snapshot. Do not start brokers.

**6. Check for stray directories on critical topic partitions.** ⚡
- Check: look for `<topic>-<partition>-stray` directories under the critical topic paths only
  (do not scan the full data root).
- Pass: no stray directories found.
- Fail: UUID mismatch between partition data and KRaft metadata. Investigate snapshot source
  consistency before starting brokers. → see §4.13

---

### Stage 2 — Startup (start brokers, then verify control plane)

**7. Start all brokers simultaneously.** 🕑
- Start all voter nodes within a few seconds of each other to avoid a stale single-node
  quorum forming. → see §4.3 for quorum startup ordering guidance.

**8. Verify quorum has a stable leader.** ⚡
- Command: `kafka-metadata-quorum --bootstrap-server <bootstrap> describe --status`
- Pass: a valid leader exists; high-watermark is advancing; no rapid leader changes.
- Fail: repeated re-elections or no leader. Stop all brokers and start simultaneously.
  → see §4.3

**9. Verify all intended brokers are visible in metadata.** ⚡
- Command: `kafka-metadata-quorum ... describe --replication` (or equivalent admin describe).
- Pass: all expected broker IDs are listed as active voters/observers.
- Fail: missing broker — check if that broker is up and reachable; inspect its startup logs.

**10. Verify no offline partitions in the critical topic set.** ⚡
- Command: `kafka-topics --bootstrap-server <bootstrap> --describe --unavailable-partitions`
- Pass: output is empty (no `Leader: -1` partitions).
- Fail: trigger preferred leader election for affected partitions. If brokers for those
  replicas are down, bring them up and recheck. → see §4.5

---

### Stage 3 — Data plane (verify I/O before admitting clients)

**11. Read end offsets for the critical restored topic.** ⚡
- Command: `kafka-get-offsets --bootstrap-server <bootstrap> --topic <TOPIC_RESTORE_CHECK> --time -1`
- Pass: offsets are readable and at or above the expected snapshot baseline.
- Fail (offsets missing or zero): ISR may not have converged yet — wait and retry.
  If still failing after ISR is stable, investigate data regression. → see §4.11
- Fail (OFFSET_OUT_OF_RANGE): one broker has a slightly older snapshot; will self-heal as
  the follower truncates to match the leader. → see §4.6

**12. Run smoke produce/consume on the canary topic.** 🕐
- Write a small batch (e.g. 10–20 records) to `<TOPIC_SMOKE_WRITE>` and read them back.
- Pass: writes accepted; reads return the expected records.
- Fail: diagnose by checking quorum stability (Step 8) and ISR state (Step 10) first.

**13. Wait for ISR convergence on critical topics.** 🕑
- Command: `kafka-topics --bootstrap-server <bootstrap> --describe --topic <TOPIC_RESTORE_CHECK>`
- Pass: ISR set equals the full replica set on all critical partitions.
- If slow to converge: this is normal after an unclean snapshot. Allow time proportional to
  the amount of unflushed data. Do not restart brokers to "speed up" convergence — it resets
  the fetch cycle. → see §4.6

**14. Check transaction state (only if transactional workloads are in scope).** 🕐
- Command: `kafka-transactions --bootstrap-server <bootstrap> list`
- Pass: no transactions stuck in `ONGOING` longer than `transaction.timeout.ms`.
  `PREPARE_COMMIT` or `PREPARE_ABORT` states should self-resolve within seconds of
  coordinator startup.
- Fail (ONGOING stuck): restart the coordinator leader broker to force coordinator reload.
  → see §4.8

**15. Check for producer epoch/state exceptions in producer logs.** 🕐
- Search producer and broker logs for:
  `OutOfOrderSequenceException`, `ProducerFencedException`, `InvalidProducerEpochException`,
  `InvalidTxnStateException`, `TransactionAbortableException`
- Pass: no occurrences, or exceptions that self-resolved after producer reinit.
- Fail (persistent): reinit the producer with the same `transactional.id` using a new
  `KafkaProducer` instance and call `initTransactions()`. → see §4.9

**16. Check consumer group offset positions for critical groups.** 🕐
- Command: `kafka-consumer-groups --bootstrap-server <bootstrap> --describe --group <group_id>`
- Check: compare committed offset vs. expected post-snapshot baseline.
- Pass: group lag is within the accepted duplicate window (bounded by
  `replica.high.watermark.checkpoint.interval.ms`, default 5 seconds per partition).
- Fail (offset far behind): determine if application-level deduplication covers the gap.
  If not, manually advance offsets to a safe point. → see §4.10

---

### Stage 4 — Client ramp

**17. Ramp clients in cohorts.** 🕑
- Suggested progression: 1% → 10% → 25% → 50% → 100%.
- At each cohort, hold long enough to observe: consumer lag stability, producer error rate,
  group progress, and broker CPU/network (not a Kafka-level check — use your monitoring).
- Advance only if all Stage 2 and Stage 3 checks remain green.

---

### Stage 5 — Deferred background checks (system already running)

Run these checks after traffic is flowing and the system is stable. They are too expensive
to run before cutover on large snapshots.

**18. All-topic offline partition scan.** 🚫
- Scope progressively: start with the next tier of important topics, then all topics.
- Run in off-peak windows; avoid large `--describe` dumps during peak load.

**19. All consumer group offset audit.** 🚫
- Run in batches, not all groups at once.
- Compare committed offsets against post-restore expected baselines for all groups.

**20. Broker log scan for truncation/corruption signatures.** 🚫
- Search for: `Found invalid messages`, `discarding tail`, `Recovering unflushed segments`,
  `CorruptRecordException` — bounded to a time window around the snapshot timestamp.
- Any findings after the system is running and stable are informational; they do not
  require remediation unless LEO has regressed on a partition. → see §4.7

**21. Full `partition.metadata` UUID audit across all topics.** 🚫
- Expand the targeted check from Step 6 to all partition directories.
- Run as a background scan; do not block traffic on this.
- Any stray directories found at this stage are either already visible as offline partitions
  (caught in Step 10/18) or are for non-critical data. Investigate and remediate by policy.
  → see §4.13
