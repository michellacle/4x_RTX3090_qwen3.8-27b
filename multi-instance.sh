#!/usr/bin/env bash
# ===================================================================
# multi-instance.sh -- show GPU status and instance info
#
# On 4x RTX 3090, only one instance fits (uses all 4 GPUs at TP=4).
# This script shows GPU status and running instance info.
#
# Usage:
#   sudo bash multi-instance.sh status   # show GPUs + instance status
# ===================================================================
set -euo pipefail

BASE_NAME="4x_rtx3090"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd_status() {
  echo "===== GPU Status ====="
  echo ""
  printf "%-6s %-24s %10s %10s %8s\n" "GPU" "Name" "Used" "Total" "Free%"
  printf "%-6s %-24s %10s %10s %8s\n" "---" "----" "----" "-----" "-----"
  nvidia-smi --query-gpu=index,name,memory.used,memory.total,memory.free --format=csv,noheader 2>/dev/null | \
    while IFS=',' read -r idx name used total free; do
      idx=$(echo "$idx" | tr -d '[:space:]')
      name=$(echo "$name" | xargs)
      used=$(echo "$used" | tr -d '[:space:]')
      total=$(echo "$total" | tr -d '[:space:]')
      free=$(echo "$free" | tr -d '[:space:]')
      printf "%-6s %-24s %10s %10s %8s\n" "$idx" "$name" "$used" "$total" "$free"
    done

  echo ""
  echo "===== Instance ====="
  echo ""

  if systemctl list-unit-files "${BASE_NAME}.service" &>/dev/null 2>&1; then
    if systemctl is-active "${BASE_NAME}" &>/dev/null 2>&1; then
      local state="active"
      local port
      port=$(grep -oP 'VLLM_PORT=\K[0-9]*' "/etc/${BASE_NAME}.env" 2>/dev/null || echo "8000")
      local gpus
      gpus=$(grep -oP 'CUDA_VISIBLE_DEVICES=\K[^ ]*' "/etc/${BASE_NAME}.env" 2>/dev/null || echo "0,1,2,3")
      local health="unknown"
      if curl -sf "http://127.0.0.1:${port}/health" &>/dev/null; then
        health="healthy"
      else
        health="starting/unhealthy"
      fi
      printf "  Instance %-4s  Port: %-6s  GPUs: %-8s  State: %-12s  Health: %s\n" \
        "base" "$port" "$gpus" "$state" "$health"
    else
      echo "  Instance base: inactive"
    fi
  else
    echo "  No instance configured."
  fi

  echo ""
  echo "  Note: With 4x RTX 3090, only one instance fits (TP=4, all GPUs)."
}

usage() {
  echo "Usage: sudo bash multi-instance.sh <command>"
  echo ""
  echo "Commands:"
  echo "  status    Show GPU usage and instance status"
}

case "${1:-}" in
  status) cmd_status ;;
  *)      usage ;;
esac
