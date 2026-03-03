#!/usr/bin/env bash
# purge_lab_data.sh — Reclaim disk space from lab run data.
#
# Deletes the largest disk consumers that are NOT covered by reset_lab.sh:
#   • data/source/*  and  data/target/*   (live broker volumes)
#   • artifacts/snapshots/*               (rsync snapshot trees — usually the biggest)
#   • artifacts/phase8-adr-runs/*         (Phase 8 scenario run archives)
#   • artifacts/phase9-runs/*             (Phase 9 scenario run archives)
#
# By default runs in DRY-RUN mode.  Pass --yes (or -y) to actually delete.
# Pass --runs-only to skip the live data dirs and only prune run archives + snapshots.
# Pass --snapshots-only to skip live data dirs AND run archives; only purge snapshots.
#   (Used by purge_if_low_disk so in-progress run summaries survive mid-run purges.)
#
# Usage:
#   scripts/harness/purge_lab_data.sh              # dry run, show sizes
#   scripts/harness/purge_lab_data.sh --yes         # delete everything
#   scripts/harness/purge_lab_data.sh --runs-only --yes      # keep live data, purge archives
#   scripts/harness/purge_lab_data.sh --snapshots-only --yes # keep live data + run archives
#
# The directories themselves are recreated after deletion so the harness keeps working.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── parse flags ──────────────────────────────────────────────────────────────
DRY_RUN=true
RUNS_ONLY=false
SNAPSHOTS_ONLY=false
for arg in "$@"; do
  case "${arg}" in
    --yes|-y)           DRY_RUN=false ;;
    --runs-only)        RUNS_ONLY=true ;;
    --snapshots-only)   SNAPSHOTS_ONLY=true ;;
    --help|-h)
      sed -n '/^# /s/^# //p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: ${arg}" >&2
      echo "Usage: $0 [--yes|-y] [--runs-only|--snapshots-only]" >&2
      exit 1
      ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────────
dir_size_human() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    du -sh "${path}" 2>/dev/null | awk '{print $1}'
  else
    echo "0"
  fi
}

wipe_dir_contents() {
  # Delete everything inside a directory, then recreate the directory itself.
  local dir="$1"
  if [[ ! -d "${dir}" ]]; then
    return 0
  fi
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [DRY RUN] would delete: ${dir}/*"
    return 0
  fi

  echo "  Wiping: ${dir}"
  # Use rm on individual children rather than the parent so the dir itself
  # (and its permissions) survive — the harness expects these dirs to exist.
  local child
  for child in "${dir}"/.[!.]* "${dir}"/*; do
    [[ -e "${child}" ]] || continue
    set +e
    rm -rf "${child}" 2>/dev/null
    set -e
  done
}

# ── targets ───────────────────────────────────────────────────────────────────
declare -a TARGETS=()

if [[ "${RUNS_ONLY}" == "false" && "${SNAPSHOTS_ONLY}" == "false" ]]; then
  TARGETS+=(
    "${ROOT_DIR}/data/source"
    "${ROOT_DIR}/data/target"
  )
fi

TARGETS+=(
  "${ROOT_DIR}/artifacts/snapshots"
)

if [[ "${SNAPSHOTS_ONLY}" == "false" ]]; then
  TARGETS+=(
    "${ROOT_DIR}/artifacts/phase8-adr-runs"
    "${ROOT_DIR}/artifacts/phase9-runs"
  )
fi

# ── pre-flight report ─────────────────────────────────────────────────────────
echo ""
echo "=== purge_lab_data.sh ==="
if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Mode: DRY RUN (pass --yes to actually delete)"
else
  echo "Mode: LIVE DELETE"
fi
echo ""

total_before_kb=0
echo "Current sizes:"
for dir in "${TARGETS[@]}"; do
  size_human="$(dir_size_human "${dir}")"
  size_kb=0
  if [[ -d "${dir}" ]]; then
    size_kb="$(du -sk "${dir}" 2>/dev/null | awk '{print $1}')"
  fi
  total_before_kb=$((total_before_kb + size_kb))
  printf "  %-55s %s\n" "${dir#"${ROOT_DIR}/"}" "${size_human}"
done
total_before_gb="$(awk -v kb="${total_before_kb}" 'BEGIN {printf "%.2f", kb/1024/1024}')"
echo ""
echo "  Total to reclaim: ~${total_before_gb} GB (${total_before_kb} KB)"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Nothing deleted. Re-run with --yes to proceed."
  exit 0
fi

# ── confirm before live delete ────────────────────────────────────────────────
echo "Deleting contents of ${#TARGETS[@]} directories..."
for dir in "${TARGETS[@]}"; do
  wipe_dir_contents "${dir}"
done

# ── recreate skeleton dirs the harness depends on ─────────────────────────────
echo ""
echo "Recreating required empty directories..."
mkdir -p \
  "${ROOT_DIR}/data/source/broker1" \
  "${ROOT_DIR}/data/source/broker2" \
  "${ROOT_DIR}/data/source/broker3" \
  "${ROOT_DIR}/data/target/broker1" \
  "${ROOT_DIR}/data/target/broker2" \
  "${ROOT_DIR}/data/target/broker3" \
  "${ROOT_DIR}/artifacts/snapshots" \
  "${ROOT_DIR}/artifacts/phase8-adr-runs" \
  "${ROOT_DIR}/artifacts/phase9-runs" \
  "${ROOT_DIR}/artifacts/latest"

# ── post-delete report ────────────────────────────────────────────────────────
total_after_kb=0
for dir in "${TARGETS[@]}"; do
  size_kb=0
  if [[ -d "${dir}" ]]; then
    size_kb="$(du -sk "${dir}" 2>/dev/null | awk '{print $1}')"
  fi
  total_after_kb=$((total_after_kb + size_kb))
done
freed_kb=$((total_before_kb - total_after_kb))
freed_gb="$(awk -v kb="${freed_kb}" 'BEGIN {printf "%.2f", kb/1024/1024}')"

echo ""
echo "Done. Freed ~${freed_gb} GB (${freed_kb} KB)."
echo "Run 'scripts/harness/reset_lab.sh' before starting a new experiment."
