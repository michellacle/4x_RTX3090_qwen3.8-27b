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
    load_profile "$profile_name" >/dev/null
    printf "  %-20s %s\n" "$profile_name" "$PROFILE_SUMMARY"
  done
}

write_runtime_env() {
  local env_path="$1"
  local profile_name="$2"
  local model_path="$3"
  local port="$4"
  local tensor_parallel="$5"
  local gpus="$6"

  cat > "$env_path" <<EOF
MODEL_PATH=${model_path}
VLLM_PORT=${port}
VLLM_TP=${tensor_parallel}
VLLM_GPU_MEM=${PROFILE_VLLM_GPU_MEM}
VLLM_MAX_LEN=${PROFILE_VLLM_MAX_LEN}
VLLM_MAX_SEQS=${PROFILE_VLLM_MAX_SEQS}
VLLM_SPECULATIVE_TOKENS=${PROFILE_VLLM_SPECULATIVE_TOKENS}
VLLM_ENABLE_PREFIX_CACHING=${PROFILE_VLLM_ENABLE_PREFIX_CACHING}
CUDA_VISIBLE_DEVICES=${gpus}
RUNTIME_PROFILE=${profile_name}
EOF
}
