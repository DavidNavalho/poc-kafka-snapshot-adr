#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
RUNTIME_ENV_FILE="${ROOT_DIR}/artifacts/runtime.env"

SOURCE_SERVICES=(source-broker-1 source-broker-2 source-broker-3)
TARGET_SERVICES=(target-broker-1 target-broker-2 target-broker-3)
SOURCE_SCHEMA_SERVICE="source-schema-registry"
TARGET_SCHEMA_SERVICE="target-schema-registry"

SOURCE_BOOTSTRAP="source-broker-1:9092"
TARGET_BOOTSTRAP="target-broker-1:9092"
SOURCE_SCHEMA_URL="http://source-schema-registry:8081"
TARGET_SCHEMA_URL="http://target-schema-registry:8081"

compose_cmd() {
  load_runtime_env
  docker compose -f "${COMPOSE_FILE}" "$@"
}

load_runtime_env() {
  if [[ -f "${RUNTIME_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    set -a
    source "${RUNTIME_ENV_FILE}"
    set +a
  fi
}

upsert_runtime_var() {
  local key="$1"
  local value="$2"
  local tmp

  mkdir -p "$(dirname "${RUNTIME_ENV_FILE}")"
  tmp="$(mktemp)"
  if [[ -f "${RUNTIME_ENV_FILE}" ]]; then
    grep -v "^${key}=" "${RUNTIME_ENV_FILE}" > "${tmp}" || true
  fi
  printf '%s=%s\n' "${key}" "${value}" >> "${tmp}"
  mv "${tmp}" "${RUNTIME_ENV_FILE}"
}

wait_for_bootstrap() {
  local service="$1"
  local bootstrap="$2"
  local retries="${3:-60}"

  for ((i = 1; i <= retries; i++)); do
    if compose_cmd exec -T "${service}" bash -lc "kafka-topics --bootstrap-server ${bootstrap} --list >/dev/null 2>&1"; then
      return 0
    fi
    sleep 2
  done

  echo "Timed out waiting for ${service} (${bootstrap}) to become ready." >&2
  return 1
}

wait_for_schema_registry() {
  local service="$1"
  local schema_url="$2"
  local retries="${3:-60}"

  for ((i = 1; i <= retries; i++)); do
    if compose_cmd exec -T "${service}" bash -lc "curl -fsS ${schema_url}/subjects >/dev/null 2>&1"; then
      return 0
    fi
    sleep 2
  done

  echo "Timed out waiting for ${service} (${schema_url}) to become ready." >&2
  return 1
}

timestamp_utc() {
  date -u +"%Y%m%dT%H%M%SZ"
}

# purge_if_low_disk MIN_GB
# If available disk on ROOT_DIR's filesystem is below MIN_GB, auto-purge
# snapshots ONLY (preserves run archives so in-progress run summaries survive).
purge_if_low_disk() {
  local min_gb="${1:-10}"
  local min_kb=$(( min_gb * 1024 * 1024 ))
  local avail_kb
  avail_kb="$(df -k "${ROOT_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [[ -z "${avail_kb}" || "${avail_kb}" -ge "${min_kb}" ]]; then
    return 0
  fi
  local avail_gb
  avail_gb="$(awk -v kb="${avail_kb}" 'BEGIN {printf "%.1f", kb/1024/1024}')"
  echo "WARN: only ${avail_gb} GB free (< ${min_gb} GB threshold). Auto-purging snapshots only (run archives preserved)..." >&2
  "${ROOT_DIR}/scripts/harness/purge_lab_data.sh" --snapshots-only --yes >&2
}

hash_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{print $1}'
  else
    shasum -a 256 "${file}" | awk '{print $1}'
  fi
}

ensure_broker_data_present() {
  local root="$1"
  local broker="$2"
  local meta="${root}/broker${broker}/meta.properties"

  if [[ ! -f "${meta}" ]]; then
    echo "Missing ${meta}. Snapshot copy is incomplete." >&2
    return 1
  fi
}
