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
- Primary error sections: `4.6`, `4.7`, `4.11`
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
  test -f "${TARGET_DATA_ROOT}/broker${b}/meta.properties" || echo "missing meta.properties on broker${b}"
  grep '^cluster.id=' "${TARGET_DATA_ROOT}/broker${b}/meta.properties"
  grep '^node.id=' "${TARGET_DATA_ROOT}/broker${b}/meta.properties"
done
```

Expected:
- `meta.properties` exists on every broker.
- `cluster.id` identical across brokers.
- `node.id` matches broker identity.

### 3.2 Quorum and partition health

```bash
kafka-metadata-quorum --bootstrap-server "$TARGET_BOOTSTRAP" describe --status
kafka-topics --bootstrap-server "$TARGET_BOOTSTRAP" --describe
```

Signals:
- Healthy quorum has a valid leader and active voters.
- No `Leader: -1` partitions.

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

### 4.1 Cluster identity mismatch (`cluster.id`)

Observe:
- Broker refuses startup.
- Logs contain mismatch text.

Common log shape:
```text
Invalid cluster.id in .../meta.properties. Expected <X>, but read <Y>
```

Verify:
```bash
grep -Ehi 'Invalid cluster.id|Expected .* but read|inconsistent clusterId' <broker-log-files>
for b in $BROKERS; do grep '^cluster.id=' "${TARGET_DATA_ROOT}/broker${b}/meta.properties"; done
```

Recover:
```bash
EXPECTED_ID="<authoritative_cluster_id>"
for b in $BROKERS; do
  awk -F= -v id="$EXPECTED_ID" 'BEGIN{OFS="="} $1=="cluster.id"{$2=id} {print $1,$2}' \
    "${TARGET_DATA_ROOT}/broker${b}/meta.properties" > /tmp/meta.$b
  mv /tmp/meta.$b "${TARGET_DATA_ROOT}/broker${b}/meta.properties"
done
# restart brokers, then rerun quorum checks
```

Automate later:
- pre-start uniformity gate on `cluster.id` across all target brokers.

### 4.2 Node identity mismatch (`node.id`)

Observe:
- Broker startup errors; quorum instability.

Verify:
```bash
for b in $BROKERS; do echo "broker${b}"; grep '^node.id=' "${TARGET_DATA_ROOT}/broker${b}/meta.properties"; done
```

Recover:
- Correct `node.id` in each `meta.properties` to match broker identity.
- Restart corrected brokers.
- Re-run quorum + partition checks.

Automate later:
- static mapping check: directory/broker name -> expected `node.id`.

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
1. Validate controller listener reachability and voter configuration consistency.
2. Restart one broker at a time and wait for quorum status to stabilize after each restart.
3. If one node has persistently invalid/corrupt metadata state, rebuild only that node from a known-good snapshot image, then rejoin.

Automate later:
- bounded election-stability check: fail if leader changes repeatedly within a short window.

### 4.4 Cross-node log divergence at epoch boundary

Observe:
- Followers truncate and replay from leader.
- Logs mention diverging epoch or truncation boundary.

Typical log patterns:
```text
Truncating partition ... due to diverging epoch
divergingEpoch in fetch response
```

Verify:
```bash
grep -Ehi 'diverging epoch|Truncating partition' <broker-log-files>
kafka-topics --bootstrap-server "$TARGET_BOOTSTRAP" --describe --topic "$TOPIC_RESTORE_CHECK"
```

Recover:
1. Treat elected leader as source of truth for that epoch.
2. Allow followers to truncate/replay automatically.
3. If a node repeatedly diverges, stop it, rehydrate that partition directory from a known-good snapshot, restart, and verify ISR convergence.

Automate later:
- detect repeated truncation loops on the same partition and trigger node rehydrate workflow.

### 4.5 Offline partitions / broken leadership

Observe:
- `Leader: -1` in topic describe.
- Consumers/producers hang or fail on specific partitions.

Verify:
```bash
kafka-topics --bootstrap-server "$TARGET_BOOTSTRAP" --describe | grep 'Leader: -1'
```

Recover:
1. Ensure replicas for affected partitions are online.
2. Trigger preferred leader election if available.
3. Restart impacted brokers and re-check ISR/leader state.

Automate later:
- fail fast when any `Leader: -1` exists.

### 4.6 Stale checkpoint / high-watermark drift

Observe:
- Consumer cannot read expected offsets even though data exists.
- End-offset/consumer progress mismatch.
- Inverse case: `HWM > LEO` leads to `OFFSET_OUT_OF_RANGE`.

Verify:
```bash
# checkpoint content (path may vary)
cat "${TARGET_DATA_ROOT}/broker<id>/replication-offset-checkpoint"

# runtime end offsets
kafka-get-offsets --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" --time -1
```

Recover:
1. Restart affected broker to force recovery/checkpoint rebuild.
2. Compare checkpoint vs runtime end offsets again.
3. If inconsistent after restart, move leadership for affected partition and re-check.

Automate later:
- checkpoint-vs-end-offset delta detector with restart/election remediation branch.

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
grep -Ehi 'Found invalid messages|discarding tail|Recovering unflushed segments|CorruptRecordException' <broker-log-files>
kafka-get-offsets --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" --time -1
```

Recover:
1. Let broker recovery truncate to last valid batch boundary.
2. If broker does not recover cleanly:
   - stop broker
   - backup affected partition directory
   - rebuild index sidecars (`*.index`, `*.timeindex`, `*.txnindex`) by removing corrupted sidecars and restarting broker
3. Re-check offsets and smoke I/O.

Automate later:
- detect corruption log signatures and run controlled broker recovery workflow.

### 4.8 Transaction state ambiguity (ongoing / prepare-commit)

Observe:
- Transactional id remains `Ongoing` too long.
- `read_committed` stalls while `read_uncommitted` shows records.

Verify:
```bash
kafka-transactions --bootstrap-server "$TARGET_BOOTSTRAP" list
kafka-transactions --bootstrap-server "$TARGET_BOOTSTRAP" describe --transactional-id "$TXN_ID_CRITICAL"

kafka-console-consumer --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" \
  --from-beginning --isolation-level read_committed --max-messages 200 --timeout-ms 12000

kafka-console-consumer --bootstrap-server "$TARGET_BOOTSTRAP" --topic "$TOPIC_RESTORE_CHECK" \
  --from-beginning --isolation-level read_uncommitted --max-messages 200 --timeout-ms 12000
```

Recover:
1. Allow coordinator recovery window.
2. Recheck transaction status and committed-read progress.
3. If stuck, restart coordinator leader broker and retry.

Automate later:
- gate on transaction state + committed-read progress.

### 4.9 Producer epoch mismatch / idempotent state corruption

Observe:
- Producer receives epoch/sequence exceptions.

Common error classes:
```text
InvalidProducerEpochException
OutOfOrderSequenceException
ProducerFencedException
```

Verify:
```bash
grep -E 'InvalidProducerEpochException|OutOfOrderSequenceException|ProducerFencedException' <producer-logs> <broker-logs>
```

Recover:
1. Stop using stale producer identity.
2. Reinitialize producer with fresh transactional epoch (`initTransactions` path).
3. Re-run bounded produce/consume smoke.

Automate later:
- exception-class trigger -> producer reinit + verify loop.

### 4.10 Consumer group offset re-processing window

Observe:
- Consumers restart from older committed offsets.
- Duplicate processing window appears after restore.

Verify:
```bash
kafka-consumer-groups --bootstrap-server "$TARGET_BOOTSTRAP" --describe --group <group_id>
```

Recover:
1. Treat as expected at-least-once behavior unless offsets are missing beyond policy.
2. Ensure application dedupe/idempotency is active.
3. If required, manually advance group offsets to a known safe point using admin tooling.

Automate later:
- compare expected vs observed group offsets; enforce duplicate-window threshold.

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
3. Re-run Kafka-side diagnostics (leader/ISR stability, checkpoint/offset consistency, broker recovery logs) and targeted remediation.
4. If unresolved, escalate as snapshot-artifact integrity incident (outside normal Kafka recovery path).

Automate later:
- parity gate: target offsets must be >= captured baseline.

### 4.12 Simultaneous crash restore behavior

Observe:
- Full log recovery on all brokers (no clean-shutdown marker path).
- Small duplicate/replay window may appear depending on offset/checkpoint timing.

Verify:
```bash
grep -Ehi 'Recovering unflushed segments|no clean shutdown|kafka_cleanshutdown' <broker-log-files>
kafka-consumer-groups --bootstrap-server "$TARGET_BOOTSTRAP" --describe --group <group_id>
```

Recover:
1. Validate quorum/partition health first.
2. Validate consumer progress and duplicate window.
3. If loss/regression exceeds policy, halt traffic and escalate as incident requiring artifact-level decision (outside normal Kafka recovery path).

Automate later:
- post-crash acceptance gate using quorum + offset + duplicate-window checks.

---

## 5. Final proposal: command bundles for future automation

No specific tooling assumed. Treat each bundle as a callable unit.

### Bundle A: preflight metadata and disk state

```bash
# A1 meta.properties present
# A2 cluster.id uniform
# A3 node.id mapping valid
# A4 critical topic partition dirs exist
```

### Bundle B: startup acceptance

```bash
# B1 quorum leader exists
# B2 no Leader:-1 partitions
# B3 all intended brokers visible in metadata
```

### Bundle C: data and transaction acceptance

```bash
# C1 end offsets readable
# C2 smoke produce/consume passes
# C3 transaction list/describe healthy (if transactional workloads)
# C4 no unresolved producer-epoch/sequence exceptions
# C5 consumer-group offset position within accepted duplicate window
```

### Bundle D: deterministic remediation actions

```bash
# D1 rewrite cluster.id -> restart -> validate
# D2 fix node.id -> restart -> validate
# D3 quorum instability -> controlled rolling restart -> validate
# D4 epoch divergence loop -> rehydrate divergent node/partition -> validate
# D5 checkpoint drift -> restart/elect leader -> validate
# D6 truncated/corrupt tail -> broker recovery path -> validate
# D7 txn stuck -> coordinator restart -> validate
# D8 producer epoch errors -> reinit txid -> validate
# D9 consumer-offset drift -> offset correction policy action -> validate
# D10 regression -> stop rollout, run incident triage, and decide artifact-level action by policy
```

### Done criteria (minimum)

- quorum stable and reachable
- no offline partitions
- critical data path smoke passes
- transactional workloads progress (if applicable)
- consumer-group duplicate window within policy (if applicable)
- no unresolved critical exceptions in broker/producer logs
