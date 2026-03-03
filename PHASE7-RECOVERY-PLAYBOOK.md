# Phase 7 Recovery Playbook (In-scope Matrix)

Goal:
- recover to stable, operational cluster from snapshot restore (including skewed snapshots)
- accept bounded data loss (RPO) and prioritize service resumption
- record what was wrong, what was done, and proof of recovery

Operationalization:
- Phase 7 baseline scenarios are in `run_phase7.sh`.
- Bounded-loss injection scenarios are implemented in Phase 7b (`run_phase7b_loss.sh`) with acked-only loss accounting.

## Scope and assumptions

In scope for this phase:
- majority rollback / skew effects in KRaft metadata lineage
- partition availability issues after restore
- transaction and consumer-group stabilization issues

Out of scope for now:
- random storage corruption / damaged snapshot media
- cluster.id mismatch due to incorrect manual bootstrap

## Stable condition definition

Restore is considered stable only if all are true:
1. KRaft quorum has a leader and is responsive.
2. No offline partitions (`Leader: -1` count is 0).
3. Produce and consume smoke checks succeed.
4. Internal state is usable (`__consumer_offsets`, `__transaction_state`; `_schemas` when used).

## Why majority rollback matters (and is expected)

KRaft metadata follows majority log lineage.

If snapshot times are skewed across voters, restored majority can be older than the most recent node snapshot.
Cluster can still be healthy, but metadata may roll back (recent topic/config/ACL changes missing).

Example:
- voter1 snapshot at `t0`
- voter2 snapshot at `t10`
- voter3 snapshot at `t20`
- metadata event committed at `t15` (visible only on voter3 snapshot)
- restored majority (`voter1+voter2`) does not include event

Result:
- cluster recovers
- event is absent after restore (expected majority rollback)

## Recovery matrix

### Scenario A: Majority rollback, cluster healthy

Symptoms:
- quorum leader exists
- cluster serves reads/writes
- source-vs-target metadata/data deltas exist

Detection commands:
```bash
kafka-metadata-quorum --bootstrap-server target-broker-1:9092 describe --status
kafka-topics --bootstrap-server target-broker-1:9092 --describe
kafka-get-offsets --bootstrap-server target-broker-1:9092 --topic <topic> --time -1
```

Recovery action:
- no destructive action required
- continue with service resumption and document deltas

Success checks:
- smoke produce/consume pass
- no offline partitions
- deltas documented and accepted as RPO impact

---

### Scenario B: Offline partitions / no leaders

Symptoms:
- `Leader: -1` partitions after restore
- produce/consume failures on affected partitions

Detection commands:
```bash
kafka-topics --bootstrap-server target-broker-1:9092 --describe
```

Automatic remediation order:
1. restart target brokers (once) and re-check
2. if still offline, run targeted unclean leader election only for offline partitions

Targeted unclean election (single partition):
```bash
kafka-leader-election --bootstrap-server target-broker-1:9092 \
  --election-type unclean \
  --topic <topic> --partition <partition>
```

Targeted unclean election (batch via JSON):
```json
{
  "partitions": [
    { "topic": "dr.p7.normal", "partition": 2 },
    { "topic": "dr.p7.groups", "partition": 5 }
  ]
}
```

```bash
kafka-leader-election --bootstrap-server target-broker-1:9092 \
  --election-type unclean \
  --path-to-json-file /tmp/offline-partitions.json
```

Success checks:
- offline partitions become 0
- smoke produce/consume pass
- action logged as explicit extra-loss tradeoff

Stop condition (failover to older snapshot set):
- quorum has no stable leader after restart+election attempts
- or partition availability remains blocked and operational recovery fails

---

### Scenario C: Hanging transactions / read_committed stalls

Symptoms:
- `read_committed` consumers stall or lag unexpectedly
- transactional diagnostics show unresolved/hanging transactions

Detection commands:
```bash
kafka-transactions --bootstrap-server target-broker-1:9092 list
kafka-transactions --bootstrap-server target-broker-1:9092 find-hanging --broker-id 1
kafka-transactions --bootstrap-server target-broker-1:9092 find-hanging --broker-id 2
kafka-transactions --bootstrap-server target-broker-1:9092 find-hanging --broker-id 3
```

Automatic remediation:
```bash
kafka-transactions --bootstrap-server target-broker-1:9092 \
  force-terminate --transactional-id <txid>
```

Success checks:
- hanging scans clear for affected txids
- `read_committed` consume smoke passes

---

### Scenario D: Consumer group offsets inconsistent with post-restore policy

Policy:
- default automatic offset repair is `to-latest` (assume already consumed)

Detection commands:
```bash
kafka-consumer-groups --bootstrap-server target-broker-1:9092 \
  --describe --group <group>
```

Automatic remediation (inactive groups only):
```bash
kafka-consumer-groups --bootstrap-server target-broker-1:9092 \
  --group <group> --topic <topic> \
  --reset-offsets --to-latest --execute
```

Manual alternatives (documented for operator use):
```bash
# specific offset
kafka-consumer-groups --bootstrap-server target-broker-1:9092 \
  --group <group> --topic <topic>:<partition> \
  --reset-offsets --to-offset <offset> --execute

# by timestamp
kafka-consumer-groups --bootstrap-server target-broker-1:9092 \
  --group <group> --topic <topic> \
  --reset-offsets --to-datetime 2026-02-17T12:00:00.000 --execute
```

Success checks:
- group commits are writable after reset
- consumer resumes without repeated offset errors

## Evidence capture standard (required per remediation)

For each detected issue, persist:
1. `problem`: concise label
2. `symptoms`: sample log lines and/or command outputs
3. `metrics_before`: CLI/JMX values
4. `action`: exact command(s) run
5. `metrics_after`: post-action values
6. `result`: `resolved | unresolved | degraded`
7. `operator_note`: optional risk tradeoff (for example unclean election)

Recommended artifact tree:
```text
artifacts/latest/target/phase7/<scenario>/
  recovery_report.txt
  remediations/
    01_<issue>/before/
    01_<issue>/after/
```

## JMX metrics (optional but recommended)

CLI checks are mandatory; JMX adds stronger evidence.

Example object names to capture:
- `kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions`
- `kafka.controller:type=KafkaController,name=OfflinePartitionsCount`
- `kafka.server:type=BrokerTopicMetrics,name=BytesInPerSec`
- `kafka.server:type=BrokerTopicMetrics,name=BytesOutPerSec`

JMX collection example (inside broker container with JMX enabled):
```bash
kafka-run-class org.apache.kafka.tools.JmxTool \
  --jmx-url service:jmx:rmi:///jndi/rmi://localhost:9999/jmxrmi \
  --object-name kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions \
  --one-time --report-format tsv
```

## Guardrails

1. Never run unclean leader election globally without explicit partition scope.
2. Never reset offsets for active consumer groups.
3. If quorum cannot stabilize, stop automatic repair and switch to older snapshot set.
