#!/bin/bash
# =============================================================
# RunPod Template Start Script — ComfyUI + TRELLIS.2 pipeline
# Fully self-contained. Base image: bare CUDA 12.8 devel image
#   (nvidia/cuda:12.8.0-cudnn-devel-ubuntu22.04)
#
# EVERYTHING heavy installs onto the PERSISTENT VOLUME (/workspace):
#   venv, ComfyUI, custom nodes, models, pixi envs, caches, workflows.
# Only tiny system apt packages touch the ephemeral container layer.
#
# Services:  ComfyUI :8188   |   JupyterLab :8888
#
# FIRST boot  : builds everything onto /workspace (10-25 min)
# LATER boots : re-applies ephemeral fixes, git-pulls workflows, launches
# =============================================================
set -euo pipefail

# ====== EDIT THIS: your public workflows repo ================
WORKFLOWS_REPO="https://github.com/YOUR_USER/YOUR_WORKFLOWS_REPO.git"
# ============================================================

WORKSPACE=/workspace
COMFY=$WORKSPACE/ComfyUI
VENV=$WORKSPACE/venv
MARKER=$WORKSPACE/.provisioned_v1
PORT=${COMFY_PORT:-8188}
JUPYTER_PORT=${JUPYTER_PORT:-8888}
WF_DIR="$COMFY/user/default/workflows"

# ---- Pin every cache/env to the persistent volume (NOT the container) ----
export HOME="$WORKSPACE"                        # comfy-env/pixi default their workspace under $HOME
export HF_HOME="$WORKSPACE/.cache/huggingface"  # model cache on the volume
export PIP_CACHE_DIR="$WORKSPACE/.cache/pip"     # pip cache on the volume
export XDG_CACHE_HOME="$WORKSPACE/.cache"        # misc caches on the volume
export PIXI_CACHE_DIR="$WORKSPACE/.cache/pixi"   # pixi package cache on the volume
mkdir -p "$HF_HOME" "$PIP_CACHE_DIR" "$XDG_CACHE_HOME" "$PIXI_CACHE_DIR"

log() { echo "[template] $*"; }

# -------------------------------------------------------------
# 0. System packages — the ONLY things on the ephemeral layer.
#    Small + fast; a bare CUDA image has no python/git/ffmpeg.
# -------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  log "Installing system packages (ephemeral layer)..."
  apt-get update
  apt-get install -y --no-install-recommends \
    python3 python3-venv python3-dev python3-pip \
    git wget curl build-essential ninja-build \
    libgl1 libglib2.0-0 ffmpeg ca-certificates
  rm -rf /var/lib/apt/lists/*
fi

# -------------------------------------------------------------
# 1. One-time provisioning — ALL onto the persistent volume
# -------------------------------------------------------------
if [ ! -f "$MARKER" ]; then
  log "Fresh volume detected - provisioning to /workspace (10-25 min)..."

  [ -d "$VENV" ] || python3 -m venv "$VENV"   # venv ON THE VOLUME
  PIP="$VENV/bin/pip"
  PY="$VENV/bin/python"
  "$PIP" install --upgrade pip wheel setuptools

  # PyTorch for CUDA 12.8 (into the volume venv)
  "$PIP" install torch torchvision torchaudio \
      --index-url https://download.pytorch.org/whl/cu128

  # JupyterLab (into the volume venv)
  "$PIP" install jupyterlab

  # ComfyUI core (on the volume)
  [ -d "$COMFY" ] || git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
  "$PIP" install -r "$COMFY/requirements.txt"

  # Custom nodes (on the volume)
  cd "$COMFY/custom_nodes"
  [ -d ComfyUI-Manager ]        || git clone https://github.com/Comfy-Org/ComfyUI-Manager.git
  [ -d ComfyUI-TRELLIS2 ]       || git clone https://github.com/PozzettiAndrea/ComfyUI-TRELLIS2.git
  [ -d ComfyUI-GeometryPack ]   || git clone https://github.com/PozzettiAndrea/ComfyUI-GeometryPack.git
  [ -d was-node-suite-comfyui ] || git clone https://github.com/WASasquatch/was-node-suite-comfyui.git

  for d in ComfyUI-Manager was-node-suite-comfyui ComfyUI-TRELLIS2 ComfyUI-GeometryPack; do
    [ -f "$d/requirements.txt" ] && "$PIP" install -r "$d/requirements.txt" || true
  done

  # GeometryPack prestartup dependency
  "$PIP" install comfy_3d_viewers

  # onnxruntime: CPU ONLY (gpu wheel targets CUDA 13 -> libcudart.so.13 crash)
  "$PIP" uninstall -y onnxruntime-gpu 2>/dev/null || true
  "$PIP" install onnxruntime "rembg[cpu]"

  # ---- Workflows repo (on the volume, in ComfyUI's workflow dir) ----
  if [ "$WORKFLOWS_REPO" != "https://github.com/YOUR_USER/YOUR_WORKFLOWS_REPO.git" ]; then
    mkdir -p "$(dirname "$WF_DIR")"
    [ -d "$WF_DIR/.git" ] || git clone "$WORKFLOWS_REPO" "$WF_DIR"
  else
    log "WARNING: WORKFLOWS_REPO not set - skipping workflow clone."
  fi

  # ---- Models (on the volume, once) ----
  "$PIP" install "huggingface_hub[cli]"
  HF="$VENV/bin/hf"

  "$HF" download microsoft/TRELLIS.2-4B \
      --local-dir "$COMFY/models/trellis"
  "$HF" download facebook/dinov3-vitl16-pretrain-lvd1689m \
      --local-dir "$COMFY/models/facebook/dinov3-vitl16-pretrain-lvd1689m"
  "$HF" download ZhengPeng7/BiRefNet \
      --local-dir "$COMFY/models/BiRefNet"

  # rembg birefnet-general ONNX session -> $HOME/.u2net (== /workspace/.u2net, persistent)
  mkdir -p "$HOME/.u2net"
  "$PY" - <<'PYEOF' || echo "[template] rembg birefnet prefetch skipped (non-fatal)"
from rembg import new_session
new_session("birefnet-general")
PYEOF

  touch "$MARKER"
  log "Provisioning complete - everything is on /workspace."
fi

# -------------------------------------------------------------
# 2. Every-boot fixes (ephemeral container layer only)
# -------------------------------------------------------------
PIP="$VENV/bin/pip"
PY="$VENV/bin/python"

# CPU onnxruntime must be importable
if ! "$PY" -c "import onnxruntime" 2>/dev/null; then
  log "Repairing onnxruntime (CPU)..."
  "$PIP" uninstall -y onnxruntime-gpu 2>/dev/null || true
  "$PIP" install --force-reinstall onnxruntime
fi

# Refresh workflows from repo (fast-forward only; won't clobber local edits)
if [ -d "$WF_DIR/.git" ]; then
  log "Updating workflows from repo..."
  git -C "$WF_DIR" pull --ff-only 2>/dev/null || log "workflow pull skipped (local changes or offline)"
fi

# -------------------------------------------------------------
# 3. Launch JupyterLab (background) then ComfyUI (foreground)
# -------------------------------------------------------------
log "Starting JupyterLab on port $JUPYTER_PORT"
cd "$WORKSPACE"
nohup "$VENV/bin/jupyter" lab \
    --ip=0.0.0.0 --port="$JUPYTER_PORT" --allow-root --no-browser \
    --ServerApp.token='' --ServerApp.password='' \
    --ServerApp.root_dir="$WORKSPACE" \
    > "$WORKSPACE/jupyter.log" 2>&1 &

log "Starting ComfyUI on port $PORT"
cd "$COMFY"
exec "$PY" main.py --listen 0.0.0.0 --port "$PORT"
