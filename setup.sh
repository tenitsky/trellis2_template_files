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

# ---------------------------------------------------------------------------
# GPU ARCH DETECTION (Ada sm_89, Hopper sm_90, Blackwell sm_120, ...)
# cu128 torch (>=2.7) DOES support Blackwell consumer (sm_120 / RTX 5090),
# but ONLY if the CUDA extensions we compile are built for the arch of THIS
# pod's GPU. The network volume persists compiled envs across pods, so a
# 4090-built env silently breaks on a 5090 and vice versa. We stamp the arch
# the envs were built for and force a rebuild when it changes.
# ---------------------------------------------------------------------------
COMPUTE_CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')
if [ -n "$COMPUTE_CAP" ]; then
  # Build for exactly this GPU + PTX so future arches can JIT as a fallback
  export TORCH_CUDA_ARCH_LIST="${COMPUTE_CAP}+PTX"
else
  # Detection failed: build fat binary covering Ada, Hopper, Blackwell
  echo "WARN: could not detect GPU compute capability; building multi-arch"
  export TORCH_CUDA_ARCH_LIST="8.9;9.0;12.0+PTX"
fi
echo "GPU compute capability: ${COMPUTE_CAP:-unknown} | TORCH_CUDA_ARCH_LIST=$TORCH_CUDA_ARCH_LIST"

# Caches go on EPHEMERAL container disk (/root, /tmp) so they don't
# bloat the persistent network volume. Only the built envs (COMFY_ENV_ROOT)
# and downloaded model weights need to persist.
export PIP_CACHE_DIR=/root/.pip-cache
export COMFY_ENV_ROOT=/workspace/.ce          # built envs: KEEP on volume
export PIXI_CACHE_DIR=/root/.pixi-cache
export RATTLER_CACHE_DIR=/root/.pixi-cache
export UV_CACHE_DIR=/root/.uv-cache
export TMPDIR=/tmp
# HF cache PERSISTS: --local-dir downloads don't duplicate into it (it stays
# tiny), but DinoV3 + BiRefNet + runtime model pulls live here -- ephemeral
# would mean re-downloading them every boot.
export HF_HOME=/workspace/.cache/huggingface
export MAX_JOBS=$(( $(nproc) > 8 ? 8 : $(nproc) ))
mkdir -p "$PIP_CACHE_DIR" "$COMFY_ENV_ROOT" "$PIXI_CACHE_DIR" "$UV_CACHE_DIR" "$TMPDIR" "$HF_HOME"
[ -n "${HF_TOKEN:-}" ] && export HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"

# ---------------------------------------------------------------------------
# ARCH-MISMATCH GUARD: if the persisted envs were compiled for a different
# GPU than this pod has, wipe the compiled bits so they rebuild for THIS
# arch. This is what makes the template portable across 4090 <-> 5090 pods
# sharing one network volume.
# ---------------------------------------------------------------------------
ARCH_STAMP="$COMFY_ENV_ROOT/.built-for-arch"
BUILT_FOR=$(cat "$ARCH_STAMP" 2>/dev/null || echo "")
if [ -n "$COMPUTE_CAP" ] && [ -n "$BUILT_FOR" ] && [ "$BUILT_FOR" != "$COMPUTE_CAP" ]; then
  echo "GPU ARCH CHANGED: envs built for sm_${BUILT_FOR} but this pod is sm_${COMPUTE_CAP}"
  echo "Wiping compiled envs so CUDA extensions rebuild for this GPU..."
  rm -rf "$COMFY_ENV_ROOT/.pixi"
  # Also nuke in-repo build artifacts from previous install.py runs
  for repo in ComfyUI-TRELLIS2 ComfyUI-GeometryPack; do
    find "$COMFYUI_PATH/custom_nodes/$repo" \
      \( -name "*.so" -o -name "build" -type d \) -exec rm -rf {} + 2>/dev/null
  done
  # Torch extension + triton JIT caches can also hold wrong-arch cubins
  rm -rf /root/.cache/torch_extensions /root/.triton 2>/dev/null
fi

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
    echo "export TORCH_CUDA_ARCH_LIST=\"$TORCH_CUDA_ARCH_LIST\""
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

# 4. Run the TRELLIS2/GeometryPack build steps (compiles CUDA extensions).
#    TORCH_CUDA_ARCH_LIST is already set for THIS pod's GPU, so on a 5090
#    these compile sm_120 kernels; on Ada they compile sm_89.
echo "Running node install.py build steps (arch: $TORCH_CUDA_ARCH_LIST)..."
( cd "$COMFYUI_PATH/custom_nodes/ComfyUI-TRELLIS2"    && "$PY" install.py ) || echo "WARN: TRELLIS2 install.py errors"
( cd "$COMFYUI_PATH/custom_nodes/ComfyUI-GeometryPack" && "$PY" install.py ) || echo "WARN: GeometryPack install.py errors"

# Stamp the arch the envs are now built for (used by the guard above)
[ -n "$COMPUTE_CAP" ] && echo "$COMPUTE_CAP" > "$ARCH_STAMP"

# 4.6. Make comfy_kitchen available inside the TRELLIS2 worker env.
#      The isolated pixi env doesn't inherit the main venv, so the worker
#      logs "Failed to import comfy_kitchen -- fp8/fp4 not available".
#      fp8/fp4 matters most on Blackwell, so inject it if the env exists.
TRELLIS_ENV_PY="$COMFY_ENV_ROOT/.pixi/envs/trellis2-nodes/bin/python"
if [ -x "$TRELLIS_ENV_PY" ]; then
  echo "Ensuring comfy_kitchen in TRELLIS2 worker env..."
  "$TRELLIS_ENV_PY" -m pip install -q comfy-kitchen 2>/dev/null \
    || echo "NOTE: comfy-kitchen not installable in worker env (fp8/fp4 stays off; workflows still run)"
fi

# 4.5. Pin numpy for numba compatibility (WAS Node Suite).
echo "Pinning numpy for numba compatibility..."
$PIP install "numpy>=2.0,<2.5"
"$PY" - <<'EOF' || echo "WARN: numba/numpy still incompatible -- WAS nodes will not load"
import numpy, numba
print(f"numpy {numpy.__version__} + numba {numba.__version__}: OK")
EOF

# 5. Download TRELLIS.2 model weights (resume-safe; skipped if present)
echo "Preparing model directories..."
mkdir -p "$COMFYUI_PATH/models/trellis"
$PIP install -q -U huggingface-hub
HF_BIN="$(dirname "$PY")/hf"
[ -x "$HF_BIN" ] || HF_BIN="$(dirname "$PY")/huggingface-cli"
# Always run: hf download resumes partial downloads and no-ops in seconds
# when complete.
echo "Downloading/verifying TRELLIS.2-4B weights..."
"$HF_BIN" download microsoft/TRELLIS.2-4B --local-dir "$COMFYUI_PATH/models/trellis/"

# 5.5. Pre-fetch BiRefNet (background removal) into the HF CACHE -- NOT
#      --local-dir, because the node loads it by repo id via from_pretrained
#      and only finds it in the cache layout. Public repo, no token needed.
#      With it cached, HF's transient 504s on the startup HEAD check fall
#      back to the cached copy instead of blocking the workflow.
echo "Pre-fetching BiRefNet into HF cache..."
"$HF_BIN" download ZhengPeng7/BiRefNet \
  || echo "WARN: BiRefNet prefetch failed (HF hiccup); node will download at first run"

# 6. Pre-fetch DinoV3 image encoder (GATED: needs user's HF_TOKEN + accepted
#    license -- cannot be baked into a public template)
if [ -n "${HF_TOKEN:-}" ]; then
  echo "Pre-fetching DinoV3 encoder (token provided)..."
  "$HF_BIN" download facebook/dinov3-vitl16-pretrain-lvd1689m \
    || echo "WARN: DinoV3 prefetch failed -- accept the license at huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m"
else
  echo "NOTE: no HF_TOKEN set -- DinoV3 (gated) will download at first workflow run once you add a token"
fi

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
