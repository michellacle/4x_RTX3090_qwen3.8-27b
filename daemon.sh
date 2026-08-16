#!/usr/bin/env bash
# ===================================================================
# daemon.sh -- run vLLM directly (no interactive prompts, no benchmark)
# Called by systemd. For manual use, run serve.sh instead.
#
# Environment variables (set via .env file):
#   MODEL_PATH                - path to model (required)
#   VLLM_PORT                 - HTTP port (default: 8000)
#   VLLM_TP                   - tensor parallel size (default: 4)
#   VLLM_GPU_MEM              - GPU memory utilization (default: 0.90)
#   VLLM_MAX_LEN              - max model length (default: 262144)
#   VLLM_MAX_SEQS             - max concurrent sequences (default: 2)
#   CUDA_VISIBLE_DEVICES      - GPU assignment (e.g. "0,1,2,3")
# ===================================================================
set -euo pipefail

export LD_LIBRARY_PATH=/usr/local/cuda-12.8/targets/x86_64-linux/lib/
export VLLM_USE_FLASHINFER_SAMPLER=0

# Restrict visible GPUs if specified
if [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
  export CUDA_VISIBLE_DEVICES
  echo "[daemon] Using GPUs: $CUDA_VISIBLE_DEVICES"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/.venv/bin/vllm" serve \
  "${MODEL_PATH}" \
  --host "${VLLM_HOST:-0.0.0.0}" \
  --port "${VLLM_PORT:-8000}" \
  --tensor-parallel-size "${VLLM_TP:-4}" \
  --gpu-memory-utilization "${VLLM_GPU_MEM:-0.90}" \
  --max-model-len "${VLLM_MAX_LEN:-262144}" \
  --max-num-seqs "${VLLM_MAX_SEQS:-2}" \
  --kv-cache-dtype fp8 \
  --block-size 16 \
  --disable-custom-all-reduce \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --served-model-name Qwen/Qwen3.8-27B \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}' \
  --enable-prefix-caching \
  --reasoning-parser qwen3 \
  --disable-log-stats
