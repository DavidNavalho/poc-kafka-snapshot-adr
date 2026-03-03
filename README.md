# Kafka Snapshot Recovery Testbed (Phase 9 Focus)

This repository is currently focused on Phase 9 snapshot-recovery testbed scenarios for KRaft (`cp-server`) restore behavior in a new environment.

Scope in this README:
- Phase 9 scenario execution.
- Phase 9 evidence/report generation.
- Recovery guidance for snapshot boot + error handling.
- Local experiment execution path.

Older phase commands and notes (Phase 1-8, 7b tuning, historical roadmap) were moved to:
- `HARNESS-LEGACY-PHASES.md`

## Current scenarios under test

- `new-identity-direct-import`
  - Expectation profile: `blocked`.
  - Purpose: check whether direct snapshot import into a new identity is rejected.
- `new-identity-reachable-allowed`
  - Expectation profile: `allowed`.
  - Purpose: validate strict safety checks when restore is reachable (critical `post_restore_io_succeeds`).

## Quick start

Local experiment execution guide:
- `LOCAL-EXPERIMENTS.md`

Run all Phase 9 scenarios:

```bash
scripts/harness/run_phase9.sh all
```

Run one scenario:

```bash
scripts/harness/run_phase9.sh new-identity-direct-import
scripts/harness/run_phase9.sh new-identity-reachable-allowed
```

Generate compact report from latest run:

```bash
scripts/harness/generate_phase9_compact_report.sh latest
```

Generate compact report from a specific run id:

```bash
scripts/harness/generate_phase9_compact_report.sh phase9-20260228T124401Z
```

## Artifacts

Primary run outputs:
- `artifacts/phase9-runs/<run_id>/summary.tsv`
- `artifacts/phase9-runs/<run_id>/<scenario>/target/phase9/<scenario>/recovery_report.txt`
- `artifacts/phase9-runs/<run_id>/<scenario>/target/phase9/<scenario>/assertions.tsv`
- `artifacts/phase9-runs/<run_id>/<scenario>/target/phase9/<scenario>/scenario_metrics.env`

Latest pointers:
- `artifacts/latest/phase9_summary.tsv`
- `artifacts/latest/phase9_compact_report.md`
- `artifacts/latest/phase9_compact_scenarios.tsv`

Compact report outputs:
- `artifacts/reports/<run_id>/phase9_compact_report.md`
- `artifacts/reports/<run_id>/phase9_compact_scenarios.tsv`

## Recommended execution sequence

1. Reset lab state if needed:
   ```bash
   scripts/harness/reset_lab.sh
   ```
2. Execute Phase 9 run:
   ```bash
   scripts/harness/run_phase9.sh all
   ```
3. Build compact report:
   ```bash
   scripts/harness/generate_phase9_compact_report.sh latest
   ```
4. Review technical guidance:
   - `snapshot-restore-runbook.md`

## References

- ADR source: `snapshot-recovery-adr.md`
- Local experiments guide: `LOCAL-EXPERIMENTS.md`
- Snapshot recovery runbook (standalone): `snapshot-restore-runbook.md`
- Legacy phase docs and commands: `HARNESS-LEGACY-PHASES.md`
