#!/bin/bash
# Kill all vLLM/LLM-related processes holding GPU memory
# Uses nvidia-smi --query-compute-apps to find PIDs, checks if they're vLLM, then kills them.
set -uo pipefail

count=0

echo "=== Checking GPU processes ==="

# Get all GPU IDs (e.g., "  0", "  1")
gpu_ids=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | sed 's/^ *//;s/ *$//')

[ -z "$gpu_ids" ] && { echo "nvidia-smi unavailable."; exit 1; }

for gpu_id in $gpu_ids; do
    gpu_name=$(nvidia-smi -i "$gpu_id" --query-gpu=name --format=csv,noheader 2>/dev/null | tr -d '[:space:]')

    pids=$(nvidia-smi -i "$gpu_id" --query-compute-apps=pid --format=csv,noheader 2>/dev/null | tr -d '[:space:]' 2>/dev/null || true)
    [ -z "$pids" ] && continue

    while IFS= read -r pid; do
        [ -z "$pid" ] && continue

        cmd=$(ps -p "$pid" -ocmd= 2>/dev/null || echo "")
        [ -z "$cmd" ] && continue

        # Check if this is an LLM-related process
        if echo "$cmd" | grep -qiE 'vllm|llm_worker|transformers|accelerate|huggingface'; then
            mem=$(nvidia-smi -i "$gpu_id" --query-compute-apps=used_memory --format=csv,noheader -s pid,used_memory 2>/dev/null | awk -v p="$pid" '$1==p{print $2}')
            [ -z "$mem" ] && mem="?"
            echo "GPU ${gpu_id} (${gpu_name}): PID=${pid} MEM=${mem}MB"
            echo "  CMD: ${cmd}"
            echo "  -> Killing..."
            kill -9 "$pid" 2>/dev/null && ((count++)) || echo "  -> already dead"
        fi
    done <<< "$pids"
done

echo ""
echo "Done. Killed $count process(es)."

echo "=== Remaining GPU memory usage ==="
nvidia-smi --query-compute-apps=pid,used_memory --format=csv 2>/dev/null || nvidia-smi 2>/dev/null
