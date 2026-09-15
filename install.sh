#!/usr/bin/env bash
# ===================================================================
# install.sh -- install Qwen3.8-27B server as a systemd service
#
# Single-purpose: one model, one hardware config (4x RTX 3090).
# Installs CUDA toolkit, creates venv, installs vLLM, downloads
# the model, and starts the service.
#
# Usage: sudo bash install.sh [OPTIONS]
#
# Options:
#   --model PATH       Model directory (default: ~/models/qwen3.8-27b-bf16)
#   --hf-repo REPO     Hugging Face repo (default: Qwen/Qwen3.8-27B)
#   --port NUM         HTTP port (default: 8000)
#   --profile NAME     Runtime profile (default: prompt or safe default)
#   --list-profiles    Show available runtime profiles and exit
#   --user NAME        System user to run as (default: current user)
#   --skip-download    Skip model download (must already exist)
#   --dry-run          Show what would be done without making changes
#
# Hugging Face token:
#   Set HF_TOKEN environment variable, or the script will prompt you.
#   Get a token at: https://huggingface.co/settings/tokens
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/profile-lib.sh"

# ---- defaults -----------------------------------------------------
BASE_PORT=8000
HF_REPO="Qwen/Qwen3.8-27B"
RUN_USER=""
DRY_RUN=0
SKIP_DOWNLOAD=0
BASE_NAME="4x_rtx3090"
GPUS_PER_INSTANCE=4
VENV_DIR="${SCRIPT_DIR}/.venv"
PROFILE_NAME=""

require_option_arg() {
  local option_name="$1"
  if [ $# -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" == -* ]]; then
    echo "ERROR: ${option_name} requires a value." >&2
    exit 1
  fi
}

# ---- parse args ---------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)         require_option_arg "$@"; MODEL_PATH="$2"; shift 2 ;;
    --hf-repo)       require_option_arg "$@"; HF_REPO="$2";     shift 2 ;;
    --port)          require_option_arg "$@"; BASE_PORT="$2";   shift 2 ;;
    --profile)       require_option_arg "$@"; PROFILE_NAME="$2"; shift 2 ;;
    --list-profiles) list_profiles; exit 0 ;;
    --user)          require_option_arg "$@"; RUN_USER="$2";    shift 2 ;;
    --skip-download) SKIP_DOWNLOAD=1;  shift ;;
    --dry-run)       DRY_RUN=1;        shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

PROFILE_NAME="${PROFILE_NAME:-$DEFAULT_PROFILE_NAME}"

load_profile "$PROFILE_NAME"

# ---- determine user -----------------------------------------------
if [ -z "$RUN_USER" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    RUN_USER="${SUDO_USER:-$(find /home -maxdepth 1 -mindepth 1 -printf '%f\n' | head -1)}"
  else
    echo "ERROR: Run with sudo: sudo bash install.sh" >&2
    exit 1
  fi
fi

RUN_HOME=$(eval echo "~${RUN_USER}")
MODEL_PATH="${MODEL_PATH:-${RUN_HOME}/models/qwen3.8-27b-bf16}"

# ---- pre-flight checks --------------------------------------------
echo "=== Qwen3.8-27B Server Installer BF16 (4x RTX 3090) ==="
echo ""

# ---- detect GPUs --------------------------------------------------
if ! command -v nvidia-smi &>/dev/null; then
  echo "ERROR: nvidia-smi not found. Are NVIDIA drivers installed?" >&2
  exit 1
fi

TOTAL_GPUS=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | sed 's/^ *//' | wc -l)

if [ "$TOTAL_GPUS" -lt 4 ]; then
  echo "ERROR: Need at least 4 GPUs. Found: $TOTAL_GPUS" >&2
  exit 1
fi

# Show GPU inventory
echo "Detected $TOTAL_GPUS GPUs:"
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null | \
  while IFS=',' read -r idx name mem; do
    printf "  GPU %s: %s (%s)\n" "$(echo "$idx" | xargs)" "$(echo "$name" | xargs)" "$(echo "$mem" | xargs)"
  done
echo ""

# Build GPU list (use first 4 GPUs)
GPUS="0,1,2,3"
PORT=$BASE_PORT
UNIT_PATH="/etc/systemd/system/${BASE_NAME}.service"
ENV_PATH="/etc/${BASE_NAME}.env"
CURRENT_PROFILE_PATH="/etc/${BASE_NAME}.profile"

echo "=== Install Plan ==="
echo "  Service: ${BASE_NAME}.service"
echo "  Profile: ${PROFILE_NAME} (${PROFILE_SUMMARY})"
echo "  GPUs:    $GPUS"
echo "  Port:    $PORT"
echo "  TP:      $GPUS_PER_INSTANCE"
echo "  Context: ${PROFILE_VLLM_MAX_LEN} tokens"
echo ""

# ---- install CUDA toolkit -----------------------------------------
if ! command -v nvcc &>/dev/null; then
  echo "CUDA toolkit (nvcc) not found. Installing nvidia-cuda-toolkit ..."
  apt-get update -qq
  apt-get install -y nvidia-cuda-toolkit ninja-build
  echo "CUDA toolkit installed: $(nvcc --version | grep 'release')"
else
  echo "CUDA: nvcc $(nvcc --version | grep 'release' | awk '{print $NF}')"
fi

# ---- create venv and install vLLM ---------------------------------
if [ ! -f "${VENV_DIR}/bin/vllm" ]; then
  echo ""
  echo "Creating virtual environment and installing vLLM ..."
  if [ ! -d "${VENV_DIR}" ]; then
    python3 -m venv "${VENV_DIR}"
  fi
  "${VENV_DIR}/bin/pip" install --upgrade pip
  "${VENV_DIR}/bin/pip" install vllm
  echo "vLLM installed: $("${VENV_DIR}/bin/vllm" --version)"
else
  echo "vLLM: $("${VENV_DIR}/bin/vllm" --version)"
fi

# ---- download model -----------------------------------------------
MODEL_EXISTS=0
if [ -f "${MODEL_PATH}/config.json" ]; then
  MODEL_EXISTS=1
fi

if [ "$MODEL_EXISTS" -eq 0 ]; then
  if [ "$SKIP_DOWNLOAD" -eq 1 ]; then
    echo "ERROR: Model not found at $MODEL_PATH and --skip-download is set." >&2
    exit 1
  fi

  echo ""
  echo "Model not found at $MODEL_PATH"
  echo "Downloading from Hugging Face: $HF_REPO"
  echo ""

  # Get HF token
  HF_TOKEN="${HF_TOKEN:-}"
  if [ -z "$HF_TOKEN" ]; then
    echo "No HF_TOKEN environment variable set."
    echo "Get a token at: https://huggingface.co/settings/tokens"
    echo ""
    read -rs -p "Hugging Face token: " HF_TOKEN
    echo ""
    if [ -z "$HF_TOKEN" ]; then
      echo "ERROR: Empty token." >&2
      exit 1
    fi
  fi

  echo "Downloading model (this may take several minutes) ..."
  echo ""

  export HF_TOKEN
  DOWNLOAD_OUTPUT=$("${VENV_DIR}/bin/python3" "${SCRIPT_DIR}/download_model.py" \
    "$HF_REPO" \
    --local-dir "$MODEL_PATH" \
    --token "$HF_TOKEN" 2>&1)
  DOWNLOAD_EXIT=$?

  echo "$DOWNLOAD_OUTPUT"

  if [ "$DOWNLOAD_EXIT" -ne 0 ]; then
    echo "" >&2
    echo "ERROR: Model download failed." >&2
    exit 1
  fi

  # Fix ownership
  chown -R "${RUN_USER}:${RUN_USER}" "$(dirname "$MODEL_PATH")" 2>/dev/null || true
  echo ""
  echo "Model downloaded successfully."
else
  echo "Model: $MODEL_PATH (already exists)"
fi

# ---- fix cache ownership -------------------------------------------
for cache_dir in "${RUN_HOME}/.triton" "${RUN_HOME}/.cache/vllm" "${RUN_HOME}/.cache/flashinfer"; do
  if [ -d "$cache_dir" ]; then
    echo "Fixing ownership: $cache_dir"
    chown -R "${RUN_USER}:${RUN_USER}" "$cache_dir"
  fi
done

# Clear stale FlashInfer cache (can cause CUDA compatibility issues on restart)
echo ""
echo "Clearing stale FlashInfer cache (will rebuild on next start) ..."
rm -rf "${RUN_HOME}/.cache/flashinfer" 2>/dev/null || true

# ---- write config -------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo ""
  echo "--- DRY RUN complete ---"
  exit 0
fi

if [ "$DRY_RUN" -eq 0 ]; then
  # Create log directory
  mkdir -p "/var/log/${BASE_NAME}"
  chown "${RUN_USER}:${RUN_USER}" "/var/log/${BASE_NAME}" 2>/dev/null || true

  # Write environment file
  echo ""
  echo "Writing $ENV_PATH ..."
  TMP_ENV="$(mktemp "${ENV_PATH}.tmp.XXXXXX")"
  TMP_PROFILE="$(mktemp "${CURRENT_PROFILE_PATH}.tmp.XXXXXX")"
  write_runtime_env "$TMP_ENV" "$PROFILE_NAME" "$MODEL_PATH" "$PORT" "$GPUS_PER_INSTANCE" "$GPUS"
  chmod 640 "$TMP_ENV"
  printf '%s\n' "$PROFILE_NAME" > "$TMP_PROFILE"
  chmod 644 "$TMP_PROFILE"
  mv "$TMP_ENV" "$ENV_PATH"
  mv "$TMP_PROFILE" "$CURRENT_PROFILE_PATH"

  # Write systemd unit
  echo "Writing $UNIT_PATH ..."
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Qwen3.8-27B LLM Server (4x RTX 3090)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${SCRIPT_DIR}
EnvironmentFile=${ENV_PATH}
ExecStart=${SCRIPT_DIR}/daemon.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
LogsDirectory=${BASE_NAME}
PIDFile=/run/${BASE_NAME}.pid

[Install]
WantedBy=multi-user.target
EOF

  # ---- reload, enable, start ----------------------------------------
  echo ""
  echo "Reloading systemd ..."
  systemctl daemon-reload

  echo "Enabling ${BASE_NAME}.service ..."
  systemctl enable "${BASE_NAME}.service"

  echo ""
  echo "Starting ${BASE_NAME} ..."
  systemctl start "${BASE_NAME}.service"

  # ---- verify -------------------------------------------------------
  echo ""
  echo "Waiting for server to start (model loading takes 1-2 minutes) ..."

  for attempt in $(seq 1 180); do
    if curl -sf "http://127.0.0.1:${PORT}/health" &>/dev/null; then
      echo ""
      echo "=== Server is healthy on http://0.0.0.0:${PORT} ==="
      echo ""
      echo "  systemd:  systemctl status ${BASE_NAME}"
      echo "  logs:     journalctl -u ${BASE_NAME} -f"
      echo "  restart:  sudo bash ${SCRIPT_DIR}/restart.sh"
      echo "  profile:  sudo bash ${SCRIPT_DIR}/set-profile.sh <name>"
      echo "  test:     bash ${SCRIPT_DIR}/test.sh"
      echo "  stop:     sudo bash ${SCRIPT_DIR}/uninstall.sh"
      echo ""

      # Show vRAM usage
      echo "  vRAM:"
      nvidia-smi --query-gpu=index,memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | \
        while IFS=',' read -r idx used total; do
          echo "    GPU${idx}: ${used} / ${total} GB"
        done
      exit 0
    fi

    if systemctl is-failed "${BASE_NAME}" &>/dev/null; then
      echo ""
      echo "ERROR: Service failed to start."
      echo "Check logs: journalctl -u ${BASE_NAME} -f"
      exit 1
    fi

    sleep 2
  done
fi

if [ "$DRY_RUN" -eq 0 ]; then
  echo ""
  echo "WARNING: Server did not become healthy within 6 minutes."
  echo "Check logs: journalctl -u ${BASE_NAME} -f"
  exit 1
fi
