#!/bin/bash
echo "=== Ensuring System Dependencies are Installed ==="
apt-get update && apt-get install -y wget ca-certificates git

echo "=== Starting TRELLIS2 Template Setup ==="

# Correct ComfyUI path for runpod/comfyui:cuda12.8
COMFYUI_PATH="/workspace/runpod-slim/ComfyUI"

# Self-heal: if ComfyUI isn't in the workspace yet, copy the baked build in
if [ ! -f "$COMFYUI_PATH/main.py" ]; then
  echo "First time setup: Copying baked ComfyUI to workspace..."
  rm -rf "$COMFYUI_PATH"
  mkdir -p /workspace/runpod-slim
  cp -r /opt/comfyui-baked "$COMFYUI_PATH"
fi

# Use the image's cu128 venv (confirmed from a live pod), fall back to pip
PY="$COMFYUI_PATH/.venv-cu128/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
PIP="$PY -m pip"
echo "Using python: $PY"

# Caches + build env on /workspace; arch list for THIS pod's GPU
COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1)
# Caches go on EPHEMERAL container disk (/root, /tmp) so they don't
# bloat the persistent network volume. Only the built envs (COMFY_ENV_ROOT)
# and downloaded model weights need to persist.
#   Before this fix, .pixi-cache (28GB) + .pip-cache lived on the volume
#   as dead weight -- duplicates of packages already extracted into .ce.
export PIP_CACHE_DIR=/root/.pip-cache
export COMFY_ENV_ROOT=/workspace/.ce          # built envs: KEEP on volume
export PIXI_CACHE_DIR=/root/.pixi-cache
export RATTLER_CACHE_DIR=/root/.pixi-cache
export UV_CACHE_DIR=/root/.uv-cache
export TMPDIR=/tmp
# HF cache PERSISTS: --local-dir downloads don't duplicate into it (it stays
# tiny), but DinoV3 + runtime model pulls live here -- ephemeral would mean
# re-downloading them every boot.
export HF_HOME=/workspace/.cache/huggingface
export TORCH_CUDA_ARCH_LIST="${COMPUTE_CAP:-8.9;12.0}"
export MAX_JOBS=$(( $(nproc) > 8 ? 8 : $(nproc) ))
mkdir -p "$PIP_CACHE_DIR" "$COMFY_ENV_ROOT" "$PIXI_CACHE_DIR" "$UV_CACHE_DIR" "$TMPDIR" "$HF_HOME"
[ -n "${HF_TOKEN:-}" ] && export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"

# Persist the env for MANUAL shells too: without COMFY_ENV_ROOT set, a manual
# ComfyUI restart would make comfy-env rebuild all pixi envs on ephemeral ~/.ce
# (slow + wasted GB). Guarded so re-runs don't duplicate.
if ! grep -q "COMFY_ENV_ROOT" /root/.bashrc 2>/dev/null; then
  {
    echo ""
    echo "# TRELLIS2 template env"
    echo "export COMFY_ENV_ROOT=/workspace/.ce"
    echo "export HF_HOME=/workspace/.cache/huggingface"
    echo "export PIXI_CACHE_DIR=/root/.pixi-cache"
    echo "export RATTLER_CACHE_DIR=/root/.pixi-cache"
  } >> /root/.bashrc
fi

# 1. comfy-env FIRST -- TRELLIS2/GeometryPack prestartup + install.py need it.
#    --ignore-installed forces it into THIS venv so pod restarts don't lose it.
echo "Installing comfy-env into the ComfyUI venv..."
$PIP install --ignore-installed comfy-env

# 2. Clone custom nodes into the official ComfyUI directory
echo "Installing custom nodes..."
mkdir -p "$COMFYUI_PATH/custom_nodes"
cd "$COMFYUI_PATH/custom_nodes"
[ -d ComfyUI-TRELLIS2 ]    || git clone --depth 1 https://github.com/PozzettiAndrea/ComfyUI-TRELLIS2.git ComfyUI-TRELLIS2
[ -d ComfyUI-GeometryPack ] || git clone --depth 1 https://github.com/PozzettiAndrea/ComfyUI-GeometryPack.git ComfyUI-GeometryPack
# WAS Node Suite (maintained ltdrdata fork -- original author retired)
[ -d was-node-suite-comfyui ] || git clone --depth 1 https://github.com/ltdrdata/was-node-suite-comfyui.git was-node-suite-comfyui

# 3. Install node requirements (auto-discovered, like the Z-Image template)
echo "Installing node requirements..."
find "$COMFYUI_PATH/custom_nodes/" -name "requirements.txt" -exec $PIP install -r {} \;

# 4. Run the TRELLIS2/GeometryPack build steps (compiles CUDA extensions)
echo "Running node install.py build steps..."
( cd "$COMFYUI_PATH/custom_nodes/ComfyUI-TRELLIS2"    && "$PY" install.py ) || echo "WARN: TRELLIS2 install.py errors"
( cd "$COMFYUI_PATH/custom_nodes/ComfyUI-GeometryPack" && "$PY" install.py ) || echo "WARN: GeometryPack install.py errors"

# 5. Download TRELLIS.2 model weights (resume-safe; skipped if present)
echo "Preparing model directories..."
mkdir -p "$COMFYUI_PATH/models/trellis"
$PIP install -q -U huggingface-hub
HF_BIN="$(dirname "$PY")/hf"
[ -x "$HF_BIN" ] || HF_BIN="$(dirname "$PY")/huggingface-cli"
# Always run: hf download resumes partial downloads and no-ops in seconds
# when complete. (A non-empty-dir check would skip forever on a download
# that a crashed pod left half-finished.)
echo "Downloading/verifying TRELLIS.2-4B weights..."
"$HF_BIN" download microsoft/TRELLIS.2-4B --local-dir "$COMFYUI_PATH/models/trellis/"

# 6. Pre-fetch DinoV3 image encoder (TRELLIS2 needs it at first run)
"$HF_BIN" download facebook/dinov3-vitl16-pretrain-lvd1689m 2>/dev/null \
  || echo "NOTE: DinoV3 not pre-fetched (gated/offline); retries at first workflow run"

# 7. Copy ALL bundled workflows into ComfyUI so they show in the Workflows
#    sidebar. The cmd override cloned this whole repo to /tmp/temp_repo, so
#    the workflows/ folder is already on disk there.
echo "Installing workflows..."
WF_DEST="$COMFYUI_PATH/user/default/workflows"
mkdir -p "$WF_DEST"
if [ -d /tmp/temp_repo/workflows ]; then
  cp -rf /tmp/temp_repo/workflows/. "$WF_DEST/" \
    && echo "Workflows copied: $(ls "$WF_DEST" | tr '\n' ' ')" \
    || echo "WARN: workflow copy failed"
else
  echo "WARN: /tmp/temp_repo/workflows not found -- repo layout changed?"
fi

# 8. Start ComfyUI using the official RunPod entrypoint
echo "Setup complete! Handing over to start script..."
exec /start.sh
