#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/profile-lib.sh"

BASE_NAME="4x_rtx3090"
ENV_PATH="/etc/${BASE_NAME}.env"
CURRENT_PROFILE_PATH="/etc/${BASE_NAME}.profile"
PROFILE_NAME=""

usage() {
  cat <<EOF
Usage:
  bash set-profile.sh --list
  sudo bash set-profile.sh <profile>
EOF
}

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

case "${1:-}" in
  --list)
    list_profiles
    exit 0
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  -*)
    echo "ERROR: Unknown option: $1" >&2
    usage >&2
    exit 1
    ;;
  *)
    PROFILE_NAME="$1"
    ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run with sudo: sudo bash set-profile.sh ${PROFILE_NAME}" >&2
  exit 1
fi

if [ ! -f "$ENV_PATH" ]; then
  echo "ERROR: ${ENV_PATH} not found. Install the service first." >&2
  exit 1
fi

load_profile "$PROFILE_NAME"

# shellcheck disable=SC1090
source "$ENV_PATH"

echo "Stopping ${BASE_NAME}.service ..."
systemctl stop "${BASE_NAME}.service"

echo "Applying profile ${PROFILE_NAME} (${PROFILE_SUMMARY}) ..."
write_runtime_env "$ENV_PATH" "$PROFILE_NAME" "$MODEL_PATH" "$VLLM_PORT" "$VLLM_TP" "$CUDA_VISIBLE_DEVICES"
chmod 640 "$ENV_PATH"
printf '%s\n' "$PROFILE_NAME" > "$CURRENT_PROFILE_PATH"
chmod 644 "$CURRENT_PROFILE_PATH"

echo "Starting ${BASE_NAME}.service ..."
systemctl start "${BASE_NAME}.service"
sleep 2
systemctl status "${BASE_NAME}.service" --no-pager
