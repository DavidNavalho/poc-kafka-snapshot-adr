# Kafka Snapshot Recovery — Findings Report

**Scope**: KRaft-based Kafka clusters. Point-in-time disk snapshot (EBS, LVM, ZFS) taken
from a running cluster, restored to a new or replacement environment.

**Basis**: 9 scenario harness (Phase 8 ADR), verified end-to-end. All scenarios reached a
deterministic outcome. No scenario required manual segment-level surgery to resolve.

---

## 1. Can a KRaft cluster be reliably restored from a disk snapshot?

**Yes, with two non-negotiable caveats:**

**1. Some data loss is structurally unavoidable.**
A live-cluster snapshot captures page cache state at a point in time. Writes in-flight at
snapshot time, and writes not yet flushed from page cache to block device, are lost. The
loss window per partition is bounded by `replica.high.watermark.checkpoint.interval.ms`
(default: 5 seconds). This is not a Kafka bug or an operator error — it is a property of
the snapshot mechanism. Plan for it; do not try to eliminate it.

**2. The cluster will not boot cleanly — and that is expected.**
A live-cluster snapshot will never carry a `.kafka_cleanshutdown` marker. Every broker will
run full log segment recovery on startup. This increases boot time and is the source of the
data loss window above. Treat this as the normal path, not an anomaly.

With those two caveats accepted: the cluster reaches a correct, consistent, fully operational
state after restore. All 9 tested failure modes resolved — either automatically or via
deterministic operator actions.

---

## 2. What self-heals without operator intervention?

The majority of post-restore conditions are self-healing once all brokers are started
simultaneously:

| Condition | Mechanism | Operator action |
|---|---|---|
| Stale HWM / checkpoint drift | HWM recomputed from ISR fetch exchanges | None — wait for ISR convergence |
| Cross-node log divergence | Epoch-based truncation; follower aligns to leader | None — do not rehydrate manually |
| Transaction state: ONGOING | Coordinator applies `transaction.timeout.ms` auto-abort | None — allow timeout to elapse |
| Transaction state: PREPARE_COMMIT / PREPARE_ABORT | Coordinator re-sends commit/abort markers on recovery | None — allow coordinator to recover |
| Truncated / partial segment tail | Broker truncates to last valid batch boundary on startup | None unless broker fails to start |
| OFFSET_OUT_OF_RANGE on consumer | Follower truncates to match leader LEO | None — self-resolves |

**Critical implication for startup**: all voter nodes must start within a few seconds of each
other. A rolling start allows a single-node quorum to form with stale state, causing
persistent re-elections that do not self-heal. This is the most common operator mistake
post-restore and the easiest to prevent.

---

## 3. What requires operator action?

| Condition | Likelihood | Action required |
|---|---|---|
| Consumer group offset regression | Certain | Measure the window; advance offsets if beyond policy |
| Producer epoch / state corruption | Likely if transactional producers were active at snapshot time | Detect via broker logs or `kafka-transactions`; force-abort stuck transactions; signal client to reinit |
| Quorum instability (rolling start) | Likely if start sequencing is wrong | Stop all brokers; restart simultaneously |
| Offline partitions in critical topic set | Possible | Trigger leader election; bring replicas online |
| cluster.id mismatch across brokers | Unlikely in a consistent snapshot | Correct only the outlier broker; do not blanket-rewrite |
| node.id mismatch on a broker | Unlikely in a consistent snapshot | Correct affected `meta.properties`; restart |
| Partition metadata UUID mismatch | Unlikely in a consistent snapshot | Investigate snapshot source; resolve before starting or delete stray dirs if migration scenario |

The identity mismatch conditions (bottom three) share an important secondary effect: a
broker in a crash loop due to an identity error causes ISR churn on otherwise-healthy
brokers, making them appear unstable. Always audit all brokers' `meta.properties` before
concluding that an unstable broker is itself the root cause.

---

## 4. Can the restore process be automated?

**Yes — for the core path.** The automation boundary is clear:

### Fully automatable (no human decision required)

- Pre-boot metadata gate: read `meta.properties` on all brokers, assert `cluster.id`
  uniformity, assert `node.id` mapping, assert critical partition directories exist.
- Startup sequencing: start all voter brokers simultaneously within a defined window.
- Control-plane acceptance: poll `kafka-metadata-quorum describe --status` until a stable
  leader exists; poll `--unavailable-partitions` until empty for the critical topic set.
- Data-plane acceptance: read end offsets on the critical topic; smoke produce/consume on
  a canary topic; poll ISR convergence.
- Transaction state check: `kafka-transactions list`; flag any `ONGOING` past timeout;
  auto force-abort via `kafka-transactions abort` (Kafka 3.x / KIP-664).
- Consumer group offset gate: compare committed offsets to expected baseline; fail if delta
  exceeds the duplicate-window policy threshold.
- Deferred background scans: all-topic partition health, all-group offset audit, broker log
  scan for corruption signatures — all runnable post-cutover in throttled batches.

### Requires decision logic (automatable with policy input)

- Offset reset: automation can detect the duplicate window size; the decision of whether
  to advance offsets or accept the reprocessing is a policy decision. Encode the threshold
  and let automation apply it.
- Client ramp gating: cohort progression (1% → 10% → … → 100%) requires pass/fail
  thresholds for consumer lag, producer error rate, and group progress. These thresholds
  are deployment-specific; once defined, the ramp logic is fully automatable.
- Producer reinit signalling: automation can detect epoch/state exceptions from broker logs
  and force-abort stuck transactions. Signalling non-transactional idempotent producers to
  reinit requires a coordination channel to the client team — the exact mechanism is
  outside Kafka's tooling.

### Requires human judgment (not automatable)

- Snapshot integrity: if pre-boot checks find identity mismatches or missing partition
  directories, the correct response depends on how the snapshot was assembled. Automation
  can detect and halt; resolution requires human review.
- Data regression below baseline: if post-restore end offsets are below the captured
  baseline, the data is gone. Automation can detect and halt rollout; the decision to
  accept, retry with a different snapshot, or escalate is a human call.
- Incident escalation: conditions that fall outside the normal Kafka recovery path (corrupt
  `quorum-state`, persistent ISR divergence with no convergence, regression beyond policy)
  require human escalation. Automation should detect and page; it should not attempt
  remediation beyond the deterministic action set.

---

## 5. Key operational constraints

**Snapshot size changes the cost of checks, not their logic.**
At tens of terabytes, any operation that traverses the full data root (recursive `find`,
unbounded log grep, all-topic describe) becomes prohibitively slow. The correct approach is
to scope every check to the critical topic and group set first, and defer broad scans to
after the system is live. The checks themselves do not change; only their scope and timing.

**Broker logs must be accessible without traversing the full data volume.**
Several important checks (producer epoch exceptions, startup recovery signatures, quorum
election patterns) are log-based. If logs are only available as raw files on the same large
disk as the data, those checks become expensive. Centralised log aggregation (Elasticsearch,
CloudWatch Logs, etc.) makes them instant. This is a prerequisite for practical automation,
not an optional enhancement.

**Data loss is acceptable, but the window must be measured, not assumed.**
The 5-second worst-case bound is a default configuration value, not a guarantee. The actual
window per partition is the delta between the snapshot capture time and the most recent
`replication-offset-checkpoint` file timestamp on that broker. Automation should measure
this delta at restore time and surface it as a concrete "expected reprocessing window" before
client ramp begins.

---

## 6. Scenario results (Phase 8 ADR harness)

All 9 scenarios verified. Run ID: `phase8-adr-20260303T093719Z`.

| Scenario | Outcome | Critical failures | Notes |
|---|---|---|---|
| t1 — stale quorum state | recovered | 0 | |
| t3 — stale HWM checkpoint | recovered | 0 | |
| t4 — truncated segment | recovered | 0 | |
| t5 — prepare-commit recovery | recovered | 0 | Transaction coordinator re-sent COMMIT markers automatically |
| t6 — producer state inconsistency | degraded | 0 | Recovery log line absent in Confluent Platform JVM; exception detection and reinit both passed |
| t7 — cluster.id mismatch | degraded | 0 | Crash loop on rejected broker causes ISR churn on healthy brokers; smoke non-critical |
| t7b — node.id mismatch | recovered | 0 | Same ISR churn pattern as t7; resolved after soak window |
| t8 — simultaneous crash baseline | recovered | 0 | |
| t10 — consumer group reprocessing | recovered | 0 | |

**7 fully recovered, 2 degraded with non-critical failures only. 0 critical failures across all 9.**

The two degraded scenarios (t6, t7) reflect expected environmental properties:
- t6: a broker implementation detail (exception raised before broker response, not by it); the critical recovery path — exception detection, transaction abort, producer reinit — all passed.
- t7: the cluster correctly rejected the mismatched broker and operated with the remaining two; the non-critical assertion was a smoke write through a cluster intentionally missing one broker.
