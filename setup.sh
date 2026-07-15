#!/bin/bash
set -e

# ---------- Config ----------
WORKSPACE=/workspace
VENV=$WORKSPACE/venv
COMFY=$WORKSPACE/ComfyUI

# Keep pip's cache on the volume so downloads survive restarts
export PIP_CACHE_DIR=$WORKSPACE/.pip-cache
mkdir -p "$PIP_CACHE_DIR"

# ---------- ComfyUI on the volume (one-time) ----------
if [ ! -d "$COMFY" ]; then
    echo ">>> First run: cloning ComfyUI to volume..."
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi

# ---------- Venv on the volume (one-time) ----------
if [ ! -d "$VENV" ]; then
    echo ">>> First run: creating venv (inheriting system torch/CUDA)..."
    python3 -m venv --system-site-packages "$VENV"
    source "$VENV/bin/activate"
    pip install --upgrade pip

    # ComfyUI core requirements
    pip install -r "$COMFY/requirements.txt"
else
    echo ">>> Venv exists, activating."
    source "$VENV/bin/activate"
fi

# ---------- Custom node requirements (every boot, but cheap) ----------
# pip skips anything already installed, so this is fast after first run
for req in "$COMFY"/custom_nodes/*/requirements.txt; do
    [ -f "$req" ] && pip install -r "$req"
done

# ---------- Launch (every boot) ----------
cd "$COMFY"
exec python main.py --listen 0.0.0.0 --port 8188
