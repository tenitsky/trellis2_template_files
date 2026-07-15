#!/bin/bash
set -e

# ---------- Config ----------
WORKSPACE=/workspace
VENV=$WORKSPACE/venv
COMFY=$WORKSPACE/ComfyUI
NODES=$COMFY/custom_nodes

export PIP_CACHE_DIR=$WORKSPACE/.pip-cache
mkdir -p "$PIP_CACHE_DIR"

# Custom nodes to install: "git_url" (add more lines as needed)
NODE_REPOS=(
    "https://github.com/ltdrdata/ComfyUI-Manager.git"
    "https://github.com/PozzettiAndrea/ComfyUI-TRELLIS2.git"
    "https://github.com/PozzettiAndrea/ComfyUI-GeometryPack.git"
)

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
    pip install -r "$COMFY/requirements.txt"
else
    echo ">>> Venv exists, activating."
    source "$VENV/bin/activate"
fi

# Sanity print so the log shows what torch/CUDA the nodes will build against
python - <<'EOF'
import torch
print(f">>> torch {torch.__version__} | CUDA {torch.version.cuda} | available: {torch.cuda.is_available()}")
EOF

# ---------- Clone missing custom nodes (one-time each) ----------
mkdir -p "$NODES"
for repo in "${NODE_REPOS[@]}"; do
    name=$(basename "$repo" .git)
    if [ ! -d "$NODES/$name" ]; then
        echo ">>> Cloning custom node: $name"
        git clone "$repo" "$NODES/$name"
    fi
done

# ---------- Per-node install (requirements every boot, install.py ONCE) ----------
FAILED_NODES=()
for dir in "$NODES"/*/; do
    name=$(basename "$dir")

    if [ -f "$dir/requirements.txt" ]; then
        echo ">>> pip requirements for $name"
        pip install -r "$dir/requirements.txt" || FAILED_NODES+=("$name (requirements)")
    fi

    # install.py pulls/compiles wheels (nvdiffrast, flex_gemm, cumesh, o_voxel,
    # nvdiffrec_render, flash_attn for TRELLIS2). Heavy -> run once, mark done.
    if [ -f "$dir/install.py" ] && [ ! -f "$dir/.setup_done" ]; then
        echo ">>> Running install.py for $name (first time, may take a while)..."
        if (cd "$dir" && python install.py); then
            touch "$dir/.setup_done"
            echo ">>> $name install.py OK"
        else
            FAILED_NODES+=("$name (install.py)")
            echo "!!! $name install.py FAILED — node will not load"
        fi
    fi
done

# ---------- Hard fail visibility ----------
if [ ${#FAILED_NODES[@]} -gt 0 ]; then
    echo "============================================"
    echo "!!! SETUP INCOMPLETE. Failed: ${FAILED_NODES[*]}"
    echo "!!! ComfyUI will still start, but these nodes are BROKEN."
    echo "============================================"
fi

# ---------- Verify TRELLIS2 actually imports before claiming victory ----------
python - <<'EOF' || echo "!!! TRELLIS2 dependency check FAILED — do not expect Trellis nodes in the UI"
import importlib
mods = ["nvdiffrast", "flash_attn"]
missing = [m for m in mods if importlib.util.find_spec(m) is None]
if missing:
    raise SystemExit(f"Missing compiled deps: {missing}")
print(">>> TRELLIS2 compiled deps present.")
EOF

# ---------- Launch ----------
cd "$COMFY"
exec python main.py --listen 0.0.0.0 --port 8188
