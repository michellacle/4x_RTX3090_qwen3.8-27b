#!/usr/bin/env bash
# ===================================================================
# serve.sh -- start Qwen3.8-27B on 4x RTX 3090 (vLLM OpenAI API)
# ===================================================================
set -euo pipefail

export LD_LIBRARY_PATH=/usr/local/cuda-12.8/targets/x86_64-linux/lib/

# ---- paths --------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/profile-lib.sh"
VLLM_VENV="${SCRIPT_DIR}/.venv"

if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

PROFILE_NAME=""
MODEL_QUANTIZATION="${MODEL_QUANTIZATION:-bf16}"
QUANTIZATION_EXPLICIT=0
MODEL_PATH_CLI_EXPLICIT=0
MODEL_HOME="${HOME}"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  MODEL_HOME="$(eval echo "~${SUDO_USER}")"
fi

quantization_model_dirname() {
  case "$1" in
    bf16) echo "qwen3.8-27b-bf16" ;;
    q8) echo "qwen3.8-27b-q8" ;;
    q6) echo "qwen3.8-27b-q6" ;;
    *)
      echo "ERROR: Unsupported quantization: $1 (expected: bf16, q8, q6)" >&2
      exit 1
      ;;
  esac
}

list_quantizations() {
  cat <<EOF
  bf16                 Full-precision BF16 weights
  q8                   8-bit quantized weights (model/repo dependent)
  q6                   6-bit quantized weights (model/repo dependent)
EOF
}

require_option_arg() {
  local option_name="$1"
  if [ $# -lt 3 ] || [ -z "${3:-}" ] || [[ "${3:-}" == -* ]]; then
    echo "ERROR: ${option_name} requires a value." >&2
    exit 1
  fi
}

require_non_negative_integer() {
  local option_name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${option_name} must be a non-negative integer. Got: ${value}" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) require_option_arg "--model" "$@"; MODEL_PATH="$2"; MODEL_PATH_CLI_EXPLICIT=1; shift 2 ;;
    --profile) require_option_arg "--profile" "$@"; PROFILE_NAME="$2"; shift 2 ;;
    --quantization) require_option_arg "--quantization" "$@"; MODEL_QUANTIZATION="$(echo "$2" | tr '[:upper:]' '[:lower:]')"; QUANTIZATION_EXPLICIT=1; shift 2 ;;
    --list-profiles) list_profiles; exit 0 ;;
    --list-quantizations) list_quantizations; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -n "$PROFILE_NAME" ]; then
  load_profile "$PROFILE_NAME"
fi

quantization_model_dirname "$MODEL_QUANTIZATION" >/dev/null

# ---- configuration (override via env vars or .env file) -----------
if [ "$QUANTIZATION_EXPLICIT" -eq 1 ]; then
  if [ "$MODEL_PATH_CLI_EXPLICIT" -eq 0 ] && [ -z "$PROFILE_NAME" ]; then
    MODEL_PATH=""
  fi
fi
MODEL_PATH="${MODEL_PATH:-${MODEL_HOME}/models/$(quantization_model_dirname "$MODEL_QUANTIZATION")}"
PORT="${VLLM_PORT:-8000}"
HOST="0.0.0.0"
TENSOR_PARALLEL="${VLLM_TP:-4}"
GPU_MEM_UTIL="${VLLM_GPU_MEM:-${PROFILE_VLLM_GPU_MEM:-0.90}}"
MAX_MODEL_LEN="${VLLM_MAX_LEN:-${PROFILE_VLLM_MAX_LEN:-262144}}"
MAX_NUM_SEQS="${VLLM_MAX_SEQS:-${PROFILE_VLLM_MAX_SEQS:-2}}"
SPECULATIVE_TOKENS="${VLLM_SPECULATIVE_TOKENS:-${PROFILE_VLLM_SPECULATIVE_TOKENS:-3}}"
ENABLE_PREFIX_CACHING="${VLLM_ENABLE_PREFIX_CACHING:-${PROFILE_VLLM_ENABLE_PREFIX_CACHING:-1}}"
PID_FILE="/tmp/vllm-${PORT}.pid"

require_non_negative_integer "VLLM_SPECULATIVE_TOKENS" "$SPECULATIVE_TOKENS"

# ---- helpers ------------------------------------------------------
is_running() {
  local pid
  pid=$(cat -- "$PID_FILE" 2>/dev/null) || return 1
  kill -0 "$pid" 2>/dev/null
}

# ---- pre-flight checks --------------------------------------------
if ! command -v nvidia-smi &>/dev/null; then
  echo "ERROR: nvidia-smi not found — no GPU visible." >&2
  exit 1
fi

nvidia-smi -L &>/dev/null || {
  echo "ERROR: nvidia-smi failed (no driver?)" >&2
  exit 1
}

if [ -n "${VLLM_CHECK_ONLY:-}" ]; then
  echo "Pre-flight checks passed."
  exit 0
fi

# ---- stop any previous instance -----------------------------------
if is_running; then
  echo "vLLM already running on port ${PORT} (pid=$(cat "$PID_FILE"))." >&2
  read -rp "Kill existing instance? [y/N] " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    old_pid=$(cat "$PID_FILE")
    echo "Stopping pid ${old_pid} ..."
    kill "$old_pid" 2>/dev/null || true
    sleep 2
    kill -9 "$old_pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    sleep 1
    echo "Existing instance stopped."
  else
    echo "Aborted." >&2
    exit 0
  fi
elif [ -f "$PID_FILE" ]; then
  rm -f "$PID_FILE"   # stale pid file
fi

# ---- launch -------------------------------------------------------
echo "Starting vLLM on ${HOST}:${PORT} ..."

VLLM_ARGS=(
  "$MODEL_PATH"
  --host "$HOST"
  --port "$PORT"
  --tensor-parallel-size "$TENSOR_PARALLEL"
  --gpu-memory-utilization "$GPU_MEM_UTIL"
  --max-model-len "$MAX_MODEL_LEN"
  --max-num-seqs "$MAX_NUM_SEQS"
  --kv-cache-dtype fp8
  --block-size 16
  --disable-custom-all-reduce
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder
  --served-model-name Qwen/Qwen3.8-27B
  --reasoning-parser qwen3
  --disable-log-stats
)

if [ "$SPECULATIVE_TOKENS" -gt 0 ]; then
  VLLM_ARGS+=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${SPECULATIVE_TOKENS}}")
fi

if [ "$ENABLE_PREFIX_CACHING" = "1" ]; then
  VLLM_ARGS+=(--enable-prefix-caching)
fi

nohup "$VLLM_VENV/bin/vllm" serve "${VLLM_ARGS[@]}" > /tmp/vllm-serve.log 2>&1 &

VLLM_PID=$!
echo "$VLLM_PID" > "$PID_FILE"
echo "vLLM started (pid ${VLLM_PID}). Waiting for health check ..."

# wait for /health to return 200
for i in $(seq 1 120); do
  if curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null; then
    echo "vLLM is healthy on http://0.0.0.0:${PORT}"
    echo ""

    # ---- quick benchmark: streaming request with timing ----
    BODY=$(printf '{
      "model": "Qwen/Qwen3.8-27B",
      "messages": [{"role": "user", "content": "Say hi"}],
      "max_tokens": 10,
      "temperature": 0,
      "stream": true,
      "stream_options": {"include_usage": true}
    }')

    OUTPUT=$(curl -s -w "\n---TIMING---%{time_starttransfer}---%{time_total}---" "$BODY" \
      "http://127.0.0.1:${PORT}/v1/chat/completions" -H "Content-Type: application/json" \
      2>/dev/null)

    TTFT_S=$(echo "$OUTPUT" | sed -n 's/.*---TIMING---\([0-9.]*\)-\([0-9.]*\)---.*/\1/p')
    TOTAL_S=$(echo "$OUTPUT" | sed -n 's/.*---TIMING---\([0-9.]*\)-\([0-9.]*\)---.*/\2/p')

    TTFT_MS=$(awk "BEGIN {printf \"%.1f\", ${TTFT_S:-0} * 1000}")
    TOTAL_MS=$(awk "BEGIN {printf \"%.1f\", ${TOTAL_S:-0} * 1000}")
    GEN_S=$(awk "BEGIN {v=${TOTAL_S:-0} - ${TTFT_S:-0}; printf \"%.6f\", (v>0)?v:0}")

    USAGE=$(echo "$OUTPUT" | grep -o '"usage":{[^}]*}')
    PROMPT_TOKS=$(echo "$USAGE" | grep -oP '"prompt_tokens":\s*\K[0-9]+')
    COMPLETION_TOKS=$(echo "$USAGE" | grep -oP '"completion_tokens":\s*\K[0-9]+')
    TOTAL_TOKS=$(echo "$USAGE" | grep -oP '"total_tokens":\s*\K[0-9]+')

    TOKS_OUT=$(awk "BEGIN {if(${GEN_S}>0 && ${COMPLETION_TOKS:-0}>0) printf \"%.1f\", ${COMPLETION_TOKS}/${GEN_S}; else print \"N/A\"}")
    TOKS_TOTAL=$(awk "BEGIN {if(${TOTAL_S:-0}>0 && ${TOTAL_TOKS:-0}>0) printf \"%.1f\", ${TOTAL_TOKS}/${TOTAL_S}; else print \"N/A\"}")

    echo "  TTFT:       ${TTFT_MS} ms"
    echo "  Gen time:   ${TOTAL_MS} ms"
    echo "  Context:    ${PROMPT_TOKS:-N/A} tokens"
    echo "  tok/s out:  ${TOKS_OUT}"
    echo "  tok/s total: ${TOKS_TOTAL}"

    echo ""
    echo "  vRAM:"
    nvidia-smi --query-gpu=index,memory.used,memory.total \
      --format=csv,noheader,nounits 2>/dev/null | \
      while IFS=',' read -r idx used total; do
        echo "    GPU${idx}: ${used} / ${total} GB"
      done

    echo "======="
    exit 0
  fi
  if ! kill -0 "$VLLM_PID" 2>/dev/null; then
    echo "ERROR: vLLM process died. Check /tmp/vllm-serve.log" >&2
    exit 1
  fi
  sleep 1
done

echo "ERROR: health check timed out after 120s." >&2
echo "Check logs: /tmp/vllm-serve.log" >&2
exit 1
