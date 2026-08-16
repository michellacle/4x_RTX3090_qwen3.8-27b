#!/usr/bin/env bash
# ===================================================================
# restart.sh -- restart the vLLM systemd service and show status
#
# Usage:
#   sudo bash restart.sh              # restart the service
# ===================================================================
set -euo pipefail

BASE_NAME="4x_rtx3090"

echo "Restarting ${BASE_NAME} ..."
sudo systemctl restart "${BASE_NAME}"
sleep 2
sudo systemctl status "${BASE_NAME}" --no-pager
