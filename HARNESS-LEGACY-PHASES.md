# Harness Legacy Phases (Phase 1-8)

This document keeps historical phase commands and notes that were removed from `README.md` so the main README can stay focused on current Phase 9 testbed work.

## Historical walkthrough docs

- `PHASE1-WALKTHROUGH.md`
- `PHASE2-WALKTHROUGH.md`
- `PHASE3-WALKTHROUGH.md`
- `PHASE4-WALKTHROUGH.md`
- `PHASE5-WALKTHROUGH.md`
- `PHASE6-WALKTHROUGH.md`
- `PHASE7-WALKTHROUGH.md`
- `PHASE7-RECOVERY-PLAYBOOK.md`
- `PHASE7B-WALKTHROUGH.md`

## Legacy run commands

Phase 1:
```bash
scripts/harness/run_phase1.sh
scripts/harness/run_phase1.sh <topic> <seed_messages> <post_restore_messages>
```

Phase 2:
```bash
scripts/harness/run_phase2.sh
```

Phase 3:
```bash
scripts/harness/run_phase3.sh
```

Phase 4:
```bash
scripts/harness/run_phase4.sh
```

Phase 5:
```bash
scripts/harness/run_phase5.sh
```

Phase 6:
```bash
scripts/harness/run_phase6.sh
```

Phase 7:
```bash
scripts/harness/run_phase7.sh
scripts/harness/run_phase7.sh hard-stop
```

Phase 7b:
```bash
scripts/harness/run_phase7b_loss.sh
scripts/harness/run_phase7b_loss.sh loss-acks1-unclean-target
scripts/harness/run_phase7b_tuned.sh
scripts/harness/run_phase7b_tuned.sh balanced 5
scripts/harness/generate_phase7b_compact_report.sh phase7b-20260220T224830Z
```

Phase 8 ADR:
```bash
scripts/harness/run_phase8_adr.sh
scripts/harness/run_phase8_adr.sh t7-meta-properties-mismatch
scripts/harness/run_phase8_adr.sh t5-prepare-commit-recovery
scripts/harness/run_phase8_adr.sh t6-producer-state-inconsistency
```

## Legacy storage/pruning notes

```bash
scripts/harness/prune_artifacts_keep_proof.sh all
KEEP_SNAPSHOTS_COUNT=2 scripts/harness/prune_artifacts_keep_proof.sh phase7b-20260220T224830Z
```

- Proof bundles: `artifacts/proof/phase7b/`
- Heavy outputs: tuned campaigns are storage intensive.

## Historical roadmap snapshot

1. Phase 1: deterministic single-topic restore parity.
2. Phase 2: multi-topic and compacted-topic coverage.
3. Phase 3: Schema Registry + protobuf checks.
4. Phase 4: consumer/group behavior matrix.
5. Phase 5: transactions and `__transaction_state` behavior.
6. Phase 6: ACL capture/restore checks.
7. Phase 7: uncontrolled capture simulations.
8. Phase 7b: bounded-loss injection + stabilization evidence.
9. Phase 8 ADR: explicit ADR scenario assertions (`T7`, `T8`, `T3`, `T5`, `T6`).
10. Phase 9: current focus in `README.md`.
