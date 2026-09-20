# Qwen3.8-27B on 4x RTX 3090

Single-purpose LLM server. One model, one hardware configuration, zero bloat.

- **Model:** Qwen3.8-27B (BF16, Q8, or Q6 checkpoints)
- **Hardware:** 4x NVIDIA RTX 3090 (24 GB each)
- **Tensor parallel:** 4 (all GPUs)
- **Context:** 262,144 tokens (FP8 KV cache)
- **Engine:** vLLM with FlashInfer
- **API:** OpenAI-compatible (`/v1/chat/completions`, `/v1/completions`, etc.)
- **OS:** Ubuntu 24.04 Linux only (not Windows, WSL, or macOS)
- **Runtime profiles:** Repo-stored presets you can switch without editing scripts

### Requirements

| Component | Version | Notes |
|-----------|---------|-------|
| NVIDIA driver | >= 535 (tested with 595.71.05) | Provides CUDA runtime libraries |
| CUDA toolkit (nvcc) | 12.0+ (installed by `install.sh`) | JIT compilation for Triton/FlashInfer kernels |
| ninja-build | any (installed by `install.sh`) | Build system for FlashInfer |
| Python | 3.12+ | Virtual environment created automatically |
| Disk | ~55 GB+ | Depends on quantization model weights + venv + cache |
| RAM | 32 GB recommended | Model loading uses shared memory |

> **How CUDA works here:** The NVIDIA driver ships CUDA runtime libraries
> (`/usr/local/cuda-12.8/` with driver 595.x). vLLM links against these at
> startup. The `nvidia-cuda-toolkit` package provides `nvcc` for JIT-compiling
> Triton and FlashInfer kernels. Both the runtime (from driver) and compiler
> (from toolkit) must be >= 12.0.

## Install as systemd service (recommended)

```bash
sudo bash install.sh
```

By default the installer uses the safe `default` profile.
To install a different preset deterministically, pass `--profile <name>` explicitly.

Options:

```bash
sudo bash install.sh --model /path/to/model --port 9000
sudo bash install.sh --profile low-latency
sudo bash install.sh --quantization q8 --hf-repo <owner/repo>
sudo bash install.sh --list-profiles
sudo bash install.sh --list-quantizations
sudo bash install.sh --hf-repo Qwen/Qwen3.8-27B    # custom HF repo
sudo bash install.sh --skip-download                    # model already on disk
sudo bash install.sh --dry-run                          # preview without installing
```

Hugging Face token (required for download):

```bash
# Option 1: set before running
export HF_TOKEN=hf_...
sudo -E bash install.sh

# Option 2: the installer will prompt you interactively
sudo bash install.sh
```

Manage the service:

```bash
systemctl status 4x_rtx3090            # check status
journalctl -u 4x_rtx3090 -f           # follow logs
systemctl restart 4x_rtx3090           # restart
bash set-profile.sh --list             # show available runtime profiles
sudo bash set-profile.sh quality-focused
sudo bash uninstall.sh                  # remove service
```

## Manual run

```bash
# Start (with startup benchmark)
bash serve.sh
bash serve.sh --profile low-latency
bash serve.sh --quantization q8 --profile high-throughput

# List profiles
bash serve.sh --list-profiles
bash serve.sh --list-quantizations

# Stop
bash kill-vllm.sh

# Test
bash test.sh

# Check GPUs
bash gpu-status.sh

# Clean logs
bash clean-logs.sh

# Pre-flight check only (don't start)
VLLM_CHECK_ONLY=1 bash serve.sh
```

## Configuration

All settings are environment variables. See `.env.example` for the full list.

| Variable | Default | Description |
| --- | --- | --- |
| `MODEL_QUANTIZATION` | bf16 | Quantization preset (`bf16`, `q8`, `q6`) used for default model path |
| `VLLM_PORT` | 8000 | HTTP port |
| `VLLM_TP` | 4 | Tensor parallel size (GPUs) |
| `VLLM_GPU_MEM` | 0.90 | GPU memory utilization fraction |
| `VLLM_MAX_LEN` | 262144 | Max context length (tokens) |
| `VLLM_MAX_SEQS` | 2 | Max concurrent sequences |
| `VLLM_SPECULATIVE_TOKENS` | 3 | MTP speculative decoding tokens |
| `VLLM_ENABLE_PREFIX_CACHING` | 1 | Enable prefix caching |

Override inline: `VLLM_PORT=9000 VLLM_GPU_MEM=0.92 bash serve.sh`

## Runtime profiles and quantizations

Profiles live in `profiles/*.env` in the repo so the team can share working presets.
Quantization is selected independently (`bf16`, `q8`, `q6`) so every profile can be used with every quantization.

| Profile | Tradeoff |
| --- | --- |
| `default` | Safe default using the current 262K / 2-sequence settings |
| `low-latency` | Faster first-token and single-request response times |
| `high-throughput` | Higher short-job throughput with reduced context |
| `aggressive` | Fastest / lowest-quality preset for short prompts and bulk experimentation |
| `long-context` | Better for large prompts and retrieval-heavy work, slower than fast presets |
| `quality-focused` | Slowest preset with long context, low concurrency, and speculative decoding disabled |

`set-profile.sh` keeps the existing install-specific values (`MODEL_QUANTIZATION`, `MODEL_PATH`, `VLLM_PORT`, `VLLM_TP`, and `CUDA_VISIBLE_DEVICES`), atomically replaces `/etc/4x_rtx3090.env` with the selected preset, records the active profile in `/etc/4x_rtx3090.profile`, and restarts the service.

## API

OpenAI-compatible endpoints:

- `GET /health` — health check
- `GET /v1/models` — list models
- `POST /v1/chat/completions` — chat
- `POST /v1/completions` — completions
- `POST /v1/embeddings` — embeddings (if supported)

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3.8-27B",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'
```

## Features

- **Multiple quantizations** — BF16, Q8, and Q6 profile-compatible workflows
- **FP8 KV cache** — extended context with reduced memory
- **Multi-token prediction** — 3 speculative tokens via MTP
- **Prefix caching** — fast repeated prefixes (e.g. system prompts)
- **Qwen3 reasoning parser** — structured reasoning output
- **Qwen3 coder tool parser** — function calling support

## Benchmark

Measured on 4x NVIDIA RTX 3090 (24 GB each), vLLM 0.23.0, Qwen3.8-27B BF16.

| Metric | Result |
|--------|--------|
| TTFT (Time To First Token) | ~5 ms |
| Generation speed (100 tokens) | 74.6 tok/s |
| Generation speed (500 tokens) | 74.0 tok/s |
| Generation speed (1000 tokens) | 74.7 tok/s |
| GPU memory per GPU | ~21.9 GB / 24.6 GB |

Tested with streaming chat completions, temperature=0, default system prompt.
Speed is consistent across response lengths due to FP8 KV cache and multi-token prediction.

## Files

| File                    | Purpose                                      |
|-------------------------|----------------------------------------------|
| `install.sh`            | Install as systemd service (+ download)      |
| `uninstall.sh`          | Remove systemd service                       |
| `download_model.py`     | Download model from Hugging Face             |
| `daemon.sh`             | Systemd entry point (no interactive UI)      |
| `serve.sh`              | Manual start with benchmark                  |
| `test.sh`               | Quick smoke test (5 checks)                  |
| `kill-vllm.sh`          | Stop the server                              |
| `gpu-status.sh`         | GPU health and memory usage                  |
| `set_gpus_limits.sh`    | Set GPU power limits (225W)                  |
| `clean-logs.sh`         | Clean up log files                           |
| `multi-instance.sh`     | Show GPU + instance status                   |
| `restart.sh`            | Restart the systemd service                  |
| `set-profile.sh`        | Switch to a different runtime profile        |
| `profile-lib.sh`        | Shared runtime profile loader/writer         |
| `profiles/*.env`        | Repo-stored runtime presets                  |
| `.env.example`          | Configuration reference                      |

## Logging

- **Systemd:** `journalctl -u 4x_rtx3090 -f`
- **Manual:** `/tmp/vllm-serve.log`
- **PID file:** `/tmp/vllm-<PORT>.pid`

## GPU power limits

To reduce power consumption (optional):

```bash
sudo bash set_gpus_limits.sh    # sets all 4 GPUs to 225W
```

> Power limits reset to defaults after reboot. Run again or add to a startup script.

## Design philosophy

Most LLM serving tools try to be universal — support every model on every hardware. This results in complex configs, hidden defaults, and fragile setups.

This repo serves a 27B Qwen model family on 4x RTX 3090s with shared runtime profiles and selectable quantization checkpoints (BF16/Q8/Q6). If you have different hardware, fork and adjust.
