#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/profile-lib.sh"

BASE_NAME="4x_rtx3090"
ENV_PATH="/etc/${BASE_NAME}.env"
CURRENT_PROFILE_PATH="/etc/${BASE_NAME}.profile"
PROFILE_NAME=""
TMP_ENV=""
TMP_PROFILE=""
BACKUP_ENV=""
BACKUP_PROFILE=""
RESTORE_ON_EXIT=0
SERVICE_STOPPED=0
ROLLBACK_FAILED=0

cleanup() {
  local exit_status="${1:-0}"
  rm -f "$TMP_ENV" "$TMP_PROFILE"

  if [ "$RESTORE_ON_EXIT" -eq 1 ]; then
    [ -n "$BACKUP_ENV" ] && mv -f "$BACKUP_ENV" "$ENV_PATH"

    if [ -n "$BACKUP_PROFILE" ] && [ -f "$BACKUP_PROFILE" ]; then
      mv -f "$BACKUP_PROFILE" "$CURRENT_PROFILE_PATH"
    else
      rm -f "$CURRENT_PROFILE_PATH"
    fi

    if [ "$SERVICE_STOPPED" -eq 1 ]; then
      systemctl reset-failed "${BASE_NAME}.service" >/dev/null 2>&1 || true
      if ! systemctl start "${BASE_NAME}.service" >/dev/null 2>&1; then
        echo "ERROR: Failed to restore ${BASE_NAME}.service with the previous profile." >&2
        ROLLBACK_FAILED=1
      fi
    fi
  fi

  rm -f "$BACKUP_ENV" "$BACKUP_PROFILE"

  if [ "$ROLLBACK_FAILED" -eq 1 ]; then
    exit_status=1
  fi

  trap - EXIT
  exit "$exit_status"
}

trap 'cleanup $?' EXIT

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

MODEL_PATH="$(read_env_value "$ENV_PATH" MODEL_PATH)"
MODEL_QUANTIZATION="$(read_env_value "$ENV_PATH" MODEL_QUANTIZATION 2>/dev/null || true)"
MODEL_QUANTIZATION="${MODEL_QUANTIZATION:-bf16}"
VLLM_PORT="$(read_env_value "$ENV_PATH" VLLM_PORT)"
VLLM_TP="$(read_env_value "$ENV_PATH" VLLM_TP)"
CUDA_VISIBLE_DEVICES="$(read_env_value "$ENV_PATH" CUDA_VISIBLE_DEVICES)"

load_profile "$PROFILE_NAME"

TMP_ENV="$(mktemp "${ENV_PATH}.tmp.XXXXXX")"
TMP_PROFILE="$(mktemp "${CURRENT_PROFILE_PATH}.tmp.XXXXXX")"
BACKUP_ENV="$(mktemp "${ENV_PATH}.bak.XXXXXX")"
cp "$ENV_PATH" "$BACKUP_ENV"

if [ -f "$CURRENT_PROFILE_PATH" ]; then
  BACKUP_PROFILE="$(mktemp "${CURRENT_PROFILE_PATH}.bak.XXXXXX")"
  cp "$CURRENT_PROFILE_PATH" "$BACKUP_PROFILE"
fi

echo "Applying profile ${PROFILE_NAME} (${PROFILE_SUMMARY}) ..."
write_runtime_env "$TMP_ENV" "$PROFILE_NAME" "$MODEL_QUANTIZATION" "$MODEL_PATH" "$VLLM_PORT" "$VLLM_TP" "$CUDA_VISIBLE_DEVICES"
chmod 640 "$TMP_ENV"
printf '%s\n' "$PROFILE_NAME" > "$TMP_PROFILE"
chmod 644 "$TMP_PROFILE"

RESTORE_ON_EXIT=1
echo "Stopping ${BASE_NAME}.service ..."
systemctl stop "${BASE_NAME}.service"
SERVICE_STOPPED=1

mv "$TMP_ENV" "$ENV_PATH"
mv "$TMP_PROFILE" "$CURRENT_PROFILE_PATH"

echo "Starting ${BASE_NAME}.service ..."
systemctl start "${BASE_NAME}.service"
RESTORE_ON_EXIT=0
SERVICE_STOPPED=0
sleep 2
systemctl status "${BASE_NAME}.service" --no-pager
