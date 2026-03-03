#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

safe_rm_path() {
  local path="$1"
  local i
  if [[ ! -e "${path}" ]]; then
    return 0
  fi

  for i in 1 2 3; do
    set +e
    rm -rf "${path}" 2>/dev/null
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 && ! -e "${path}" ]]; then
      return 0
    fi
    sleep 1
  done

  set +e
  chmod -R u+w "${path}" 2>/dev/null
  find "${path}" -depth -type f -exec rm -f {} + 2>/dev/null
  find "${path}" -depth -type d -exec rmdir {} + 2>/dev/null
  rm -rf "${path}" 2>/dev/null
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 && ! -e "${path}" ]]; then
    return 0
  fi

  echo "Failed to clean path: ${path}" >&2
  return 1
}

compose_cmd down --remove-orphans

safe_rm_path "${ROOT_DIR}/data/source"
safe_rm_path "${ROOT_DIR}/data/target"
safe_rm_path "${ROOT_DIR}/artifacts/latest"
rm -f "${ROOT_DIR}/artifacts/runtime.env"
mkdir -p \
  "${ROOT_DIR}/data/source/broker1" \
  "${ROOT_DIR}/data/source/broker2" \
  "${ROOT_DIR}/data/source/broker3" \
  "${ROOT_DIR}/data/target/broker1" \
  "${ROOT_DIR}/data/target/broker2" \
  "${ROOT_DIR}/data/target/broker3" \
  "${ROOT_DIR}/artifacts/snapshots"

echo "Lab reset complete."
