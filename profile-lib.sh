#!/usr/bin/env bash
set -euo pipefail

PROFILE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_DIR="${PROFILE_LIB_DIR}/profiles"
DEFAULT_PROFILE_NAME="default"

validate_profile_name() {
  local profile_name="${1:-}"
  [[ "$profile_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

profile_path() {
  local profile_name="$1"
  printf '%s/%s.env\n' "$PROFILE_DIR" "$profile_name"
}

load_profile() {
  local profile_name="${1:-$DEFAULT_PROFILE_NAME}"
  local path

  if ! validate_profile_name "$profile_name"; then
    echo "ERROR: Invalid profile name: $profile_name" >&2
    return 1
  fi

  path="$(profile_path "$profile_name")"
  if [ ! -f "$path" ]; then
    echo "ERROR: Unknown runtime profile: $profile_name" >&2
    return 1
  fi

  PROFILE_SUMMARY=""
  PROFILE_VLLM_GPU_MEM=""
  PROFILE_VLLM_MAX_LEN=""
  PROFILE_VLLM_MAX_SEQS=""
  PROFILE_VLLM_SPECULATIVE_TOKENS=""
  PROFILE_VLLM_ENABLE_PREFIX_CACHING=""
  # shellcheck disable=SC1090
  source "$path"

  if [ -z "${PROFILE_SUMMARY:-}" ] || [ -z "${PROFILE_VLLM_GPU_MEM:-}" ] || [ -z "${PROFILE_VLLM_MAX_LEN:-}" ] || \
     [ -z "${PROFILE_VLLM_MAX_SEQS:-}" ] || [ -z "${PROFILE_VLLM_SPECULATIVE_TOKENS:-}" ] || \
     [ -z "${PROFILE_VLLM_ENABLE_PREFIX_CACHING:-}" ]; then
    echo "ERROR: Profile $profile_name is missing required settings." >&2
    return 1
  fi
}

list_profiles() {
  local path profile_name

  for path in "${PROFILE_DIR}"/*.env; do
    [ -e "$path" ] || continue
    profile_name="$(basename "$path" .env)"
    if load_profile "$profile_name" >/dev/null; then
      printf "  %-20s %s\n" "$profile_name" "$PROFILE_SUMMARY"
    else
      printf "  %-20s %s\n" "$profile_name" "[invalid profile]" >&2
    fi
  done
}

write_runtime_env() {
  local env_path="$1"
  local profile_name="$2"
  local model_path="$3"
  local port="$4"
  local tensor_parallel="$5"
  local gpus="$6"

  {
    printf 'MODEL_PATH=%q\n' "$model_path"
    printf 'VLLM_PORT=%q\n' "$port"
    printf 'VLLM_TP=%q\n' "$tensor_parallel"
    printf 'VLLM_GPU_MEM=%q\n' "$PROFILE_VLLM_GPU_MEM"
    printf 'VLLM_MAX_LEN=%q\n' "$PROFILE_VLLM_MAX_LEN"
    printf 'VLLM_MAX_SEQS=%q\n' "$PROFILE_VLLM_MAX_SEQS"
    printf 'VLLM_SPECULATIVE_TOKENS=%q\n' "$PROFILE_VLLM_SPECULATIVE_TOKENS"
    printf 'VLLM_ENABLE_PREFIX_CACHING=%q\n' "$PROFILE_VLLM_ENABLE_PREFIX_CACHING"
    printf 'CUDA_VISIBLE_DEVICES=%q\n' "$gpus"
    printf 'RUNTIME_PROFILE=%q\n' "$profile_name"
  } > "$env_path"
}

read_env_value() {
  local env_path="$1"
  local key="$2"

  python3 - "$env_path" "$key" <<'PY'
from pathlib import Path
import shlex
import sys

env_path = Path(sys.argv[1])
key = sys.argv[2]

for raw_line in env_path.read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in raw_line:
        continue

    current_key, raw_value = raw_line.split("=", 1)
    if current_key != key:
        continue

    values = shlex.split(raw_value, posix=True)
    if len(values) != 1:
        raise SystemExit(f"ERROR: Invalid value for {key} in {env_path}")

    print(values[0])
    break
else:
    raise SystemExit(f"ERROR: Missing {key} in {env_path}")
PY
}
