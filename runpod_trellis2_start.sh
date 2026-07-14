#!/bin/bash
# =============================================================
# runpod_trellis2_start.sh
# Bootstrap for the Trellis2 RunPod template (image: runpod/comfyui:cuda12.8)
#
# Runs as the container START COMMAND on a CLEAN pod:
#   curl -fsSL https://raw.githubusercontent.com/tenitsky/trellis2_template_files/main/runpod_trellis2_start.sh | bash
#
# It must do EVERYTHING (the start command replaces the image's own
# startup): install nodes, download models, then run ComfyUI in the
# FOREGROUND so the container stays alive.
#
# Zero interaction. Idempotent: if a network volume is attached, the
# second boot skips everything already done and starts in ~1 min.
# Without a volume everything is ephemeral and reinstalls each boot.
#
# Optional template env vars:
#   HF_TOKEN        - HuggingFace token (needed if DinoV3 is gated for you)
#   COMFY_PORT      - default 8188
#   SKIP_JUPYTER=1  - don't start JupyterLab
# =============================================================
set -uo pipefail   # NOT -e: one failed nicety must not kill the pod

LOG=/workspace/trellis2_boot.log
mkdir -p /workspace
exec > >(tee -a "$LOG") 2>&1

echo "=============================================="
echo "TRELLIS2 template bootstrap - $(date)"
echo "=============================================="

COMFY_PORT="${COMFY_PORT:-8188}"

# --- 1. Find ComfyUI in the image (or clone it) ---
COMFY_DIR=""
for c in /workspace/ComfyUI /ComfyUI /workspace/runpod-slim/ComfyUI /comfyui; do
    [ -f "$c/main.py" ] && COMFY_DIR="$c" && break
done
if [ -z "$COMFY_DIR" ]; then
    echo "No ComfyUI in image -> cloning to /workspace/ComfyUI"
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
    COMFY_DIR=/workspace/ComfyUI
fi
echo "ComfyUI: $COMFY_DIR"

# --- 2. Find the python that ComfyUI should run under ---
# Prefer an image venv with torch; fall back to system python3.
PY=""
for p in /venv/bin/python /opt/venv/bin/python /workspace/venv/bin/python \
         "$COMFY_DIR/venv/bin/python" /usr/bin/python3; do
    if [ -x "$p" ] && "$p" -c "import torch" 2>/dev/null; then PY="$p"; break; fi
done
if [ -z "$PY" ]; then
    PY=$(command -v python3)
    echo "No torch-bearing python found; will install torch into $PY"
fi
PIP="$PY -m pip"
echo "Python: $PY ($($PY --version 2>&1))"

# --- 3. Build env: caches on /workspace, arch list for THIS pod's GPU ---
COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 || echo "")
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
echo "GPU: $GPU_NAME (compute cap: ${COMPUTE_CAP:-unknown})"

export PIP_CACHE_DIR=/workspace/.pip-cache
export COMFY_ENV_ROOT=/workspace/.ce
export PIXI_CACHE_DIR=/workspace/.pixi-cache
export RATTLER_CACHE_DIR=/workspace/.pixi-cache
export TMPDIR=/workspace/tmp
export HF_HOME=/workspace/.cache/huggingface
export HUGGINGFACE_HUB_CACHE=/workspace/.cache/huggingface/hub
export TORCH_CUDA_ARCH_LIST="${COMPUTE_CAP:-8.9;12.0}"
export MAX_JOBS=$(( $(nproc) > 8 ? 8 : $(nproc) ))
mkdir -p "$PIP_CACHE_DIR" "$COMFY_ENV_ROOT" "$PIXI_CACHE_DIR" "$TMPDIR" "$HF_HOME"
[ -n "${HF_TOKEN:-}" ] && export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"

# --- 4. Ensure a cu128 torch >= 2.7 (Blackwell + 40xx) ---
TORCH_OK=$("$PY" - <<'PYEOF' 2>/dev/null || echo no
import torch
v = torch.__version__.split("+")[0].split(".")[:2]
ok = (torch.version.cuda or "").startswith("12.8") and tuple(map(int, v)) >= (2, 7)
print("yes" if ok else "no")
PYEOF
)
if [ "$(echo "$TORCH_OK" | tail -1)" != "yes" ]; then
    echo "Installing torch (cu128)..."
    $PIP install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
fi
"$PY" -c "import torch; x=torch.randn(8,8,device='cuda'); (x@x).sum().item(); print('GPU kernel test OK:', torch.__version__)" \
    || echo "WARNING: GPU kernel test failed -- generation may not work on this host"

# --- 5. Install custom nodes ---
cd "$COMFY_DIR/custom_nodes"

clone_if_missing() { [ -d "$2" ] || git clone --depth 1 "$1" "$2"; }

# comfy-env FIRST: TRELLIS2/GeometryPack prestartup + install.py need it
$PIP install --ignore-installed comfy-env
"$PY" -c "import comfy_env" || { echo "FATAL: comfy_env failed to install"; }

clone_if_missing https://github.com/PozzettiAndrea/ComfyUI-TRELLIS2.git ComfyUI-TRELLIS2
( cd ComfyUI-TRELLIS2 && $PIP install -r requirements.txt && "$PY" install.py ) \
    || echo "WARNING: TRELLIS2 install step reported errors -- check log"

clone_if_missing https://github.com/PozzettiAndrea/ComfyUI-GeometryPack.git ComfyUI-GeometryPack
( cd ComfyUI-GeometryPack && $PIP install -r requirements.txt && "$PY" install.py ) \
    || echo "WARNING: GeometryPack install step reported errors -- check log"

clone_if_missing https://github.com/ltdrdata/ComfyUI-Manager.git ComfyUI-Manager

# --- 6. Model weights (resume-safe; skipped in seconds if present) ---
cd "$COMFY_DIR"
mkdir -p models/trellis
$PIP install -q -U huggingface-hub
HF_BIN=$(dirname "$PY")/hf
[ -x "$HF_BIN" ] || HF_BIN=$(dirname "$PY")/huggingface-cli
"$HF_BIN" download microsoft/TRELLIS.2-4B --local-dir models/trellis/ \
    || echo "WARNING: TRELLIS weights download failed -- retry by restarting the pod"

# Pre-fetch DinoV3 (image encoder). If gated for this account, TRELLIS2
# retries at first run; set HF_TOKEN env var on the template if needed.
"$HF_BIN" download facebook/dinov3-vitl16-pretrain-lvd1689m 2>/dev/null \
    || echo "NOTE: DinoV3 not pre-fetched (gated or offline); will retry at first workflow run"

# --- 7. JupyterLab in background (file access for users) ---
if [ "${SKIP_JUPYTER:-0}" != "1" ]; then
    if "$PY" -c "import jupyterlab" 2>/dev/null || $PIP install -q jupyterlab; then
        nohup "$PY" -m jupyter lab --allow-root --ip=0.0.0.0 --port=8888 --no-browser \
            --NotebookApp.token="${JUPYTER_PASSWORD:-}" \
            > /workspace/jupyter.log 2>&1 &
        echo "JupyterLab started on :8888"
    fi
fi

# --- 8. Launch ComfyUI in the FOREGROUND (keeps container alive) ---
echo "=============================================="
echo "Bootstrap done - starting ComfyUI on :$COMFY_PORT"
echo "Log: $LOG"
echo "=============================================="
cd "$COMFY_DIR"
exec "$PY" main.py --listen 0.0.0.0 --port "$COMFY_PORT"
