#!/usr/bin/env bash
# ===================================================================
# uninstall.sh -- remove Qwen3.8-27B systemd service
#
# Usage:
#   sudo bash uninstall.sh            # remove the service
# ===================================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run with sudo: sudo bash uninstall.sh" >&2
  exit 1
fi

BASE_NAME="4x_rtx3090"
UNIT_PATH="/etc/systemd/system/${BASE_NAME}.service"
ENV_PATH="/etc/${BASE_NAME}.env"
CURRENT_PROFILE_PATH="/etc/${BASE_NAME}.profile"

echo "=== Uninstalling ${BASE_NAME} ==="

# Stop and disable
if systemctl list-unit-files | grep -q "${BASE_NAME}"; then
  echo "  Stopping ..."
  systemctl stop "${BASE_NAME}.service" 2>/dev/null || true
  echo "  Disabling ..."
  systemctl disable "${BASE_NAME}.service" 2>/dev/null || true
fi

# Remove files
echo "  Removing unit file: $UNIT_PATH"
rm -f "$UNIT_PATH"

echo "  Removing environment file: $ENV_PATH"
rm -f "$ENV_PATH"

echo "  Removing current profile file: $CURRENT_PROFILE_PATH"
rm -f "$CURRENT_PROFILE_PATH"

echo "  Removing log directory: /var/log/${BASE_NAME}"
rm -rf "/var/log/${BASE_NAME}"

rm -f "/run/${BASE_NAME}.pid"

# Reload
systemctl daemon-reload
systemctl reset-failed

echo ""
echo "Done. Repo files are untouched."
echo "To reinstall: sudo bash install.sh"
