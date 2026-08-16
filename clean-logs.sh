#!/usr/bin/env bash
set -euo pipefail

# Clean vLLM-related logs and temp files
PATTERNS=(
  "vllm*"
  "vllm*.pid"
  "start-vllm*"
  "stop-vllm*"
  "test_vllm*"
)

count=0
for pattern in "${PATTERNS[@]}"; do
  find /tmp -maxdepth 1 -name "$pattern" -type f 2>/dev/null | while read -r f; do
    echo "Removing: $f"
    rm -f "$f"
    ((count++))
  done
done

# Also clean any stale pid files
find /tmp -maxdepth 1 -name "*.pid" -type f 2>/dev/null | while read -r f; do
  echo "Removing: $f"
  rm -f "$f"
  ((count++))
done

echo "Cleaned $count file(s)"
