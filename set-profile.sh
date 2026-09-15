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

cleanup() {
  rm -f "$TMP_ENV" "$TMP_PROFILE"

  if [ "$RESTORE_ON_EXIT" -eq 1 ]; then
    [ -n "$BACKUP_ENV" ] && mv -f "$BACKUP_ENV" "$ENV_PATH"

    if [ -n "$BACKUP_PROFILE" ] && [ -f "$BACKUP_PROFILE" ]; then
      mv -f "$BACKUP_PROFILE" "$CURRENT_PROFILE_PATH"
    else
      rm -f "$CURRENT_PROFILE_PATH"
    fi

    if [ "$SERVICE_STOPPED" -eq 1 ]; then
      systemctl start "${BASE_NAME}.service" >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$BACKUP_ENV" "$BACKUP_PROFILE"
}

trap cleanup EXIT

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

# shellcheck disable=SC1090
source "$ENV_PATH"

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
write_runtime_env "$TMP_ENV" "$PROFILE_NAME" "$MODEL_PATH" "$VLLM_PORT" "$VLLM_TP" "$CUDA_VISIBLE_DEVICES"
chmod 640 "$TMP_ENV"
printf '%s\n' "$PROFILE_NAME" > "$TMP_PROFILE"
chmod 644 "$TMP_PROFILE"

RESTORE_ON_EXIT=1
SERVICE_STOPPED=1
echo "Stopping ${BASE_NAME}.service ..."
systemctl stop "${BASE_NAME}.service"

mv "$TMP_ENV" "$ENV_PATH"
mv "$TMP_PROFILE" "$CURRENT_PROFILE_PATH"

echo "Starting ${BASE_NAME}.service ..."
systemctl start "${BASE_NAME}.service"
RESTORE_ON_EXIT=0
SERVICE_STOPPED=0
sleep 2
systemctl status "${BASE_NAME}.service" --no-pager
