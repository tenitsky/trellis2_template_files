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
export PIP_CACHE_DIR=/workspace/.pip-cache
export COMFY_ENV_ROOT=/workspace/.ce
export PIXI_CACHE_DIR=/workspace/.pixi-cache
export RATTLER_CACHE_DIR=/workspace/.pixi-cache
export TMPDIR=/workspace/tmp
export HF_HOME=/workspace/.cache/huggingface
export TORCH_CUDA_ARCH_LIST="${COMPUTE_CAP:-8.9;12.0}"
export MAX_JOBS=$(( $(nproc) > 8 ? 8 : $(nproc) ))
mkdir -p "$PIP_CACHE_DIR" "$COMFY_ENV_ROOT" "$PIXI_CACHE_DIR" "$TMPDIR" "$HF_HOME"
[ -n "${HF_TOKEN:-}" ] && export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"

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
if [ -z "$(ls -A "$COMFYUI_PATH/models/trellis/" 2>/dev/null)" ]; then
  echo "Downloading TRELLIS.2-4B weights..."
  "$HF_BIN" download microsoft/TRELLIS.2-4B --local-dir "$COMFYUI_PATH/models/trellis/"
else
  echo "TRELLIS weights already exist, skipping."
fi

# 6. Pre-fetch DinoV3 image encoder (TRELLIS2 needs it at first run)
"$HF_BIN" download facebook/dinov3-vitl16-pretrain-lvd1689m 2>/dev/null \
  || echo "NOTE: DinoV3 not pre-fetched (gated/offline); retries at first workflow run"

# 7. Start ComfyUI using the official RunPod entrypoint
echo "Setup complete! Handing over to start script..."
exec /start.sh
