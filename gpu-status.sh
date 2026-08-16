#!/usr/bin/env bash
set -euo pipefail

echo "===== GPU Status ====="
echo ""

# nvidia-smi summary
nvidia-smi --query-gpu=index,name,temperature.gpu,memory.used,memory.total,memory.used-perc,utilization.gpu,power.draw --format=csv -l 1 2>/dev/null || echo "nvidia-smi not available"

echo ""
echo "===== GPU Processes ====="
nvidia-smi pmon -c 1 2>/dev/null || echo "Unable to monitor GPU processes"

echo ""
echo "===== Top GPU consumers (by PID) ====="
nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv -l 1 2>/dev/null || echo "Unable to query compute apps"
