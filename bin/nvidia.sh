#!/bin/bash
set -e

# Detect NVIDIA GPU
NVIDIA="$(lspci | grep -i 'nvidia')"

if [[ -z "$NVIDIA" ]]; then
    echo "No NVIDIA GPU found. Skipping."
    exit 0
fi

echo "[*] Found NVIDIA GPU."
echo "[*] Keeping CachyOS provided drivers as requested."

# 1. Install VA-API utils
sudo pacman -S --needed --noconfirm libva-utils

# 2. Add NVIDIA environment variables for UWSM based on GPU architecture
if echo "$NVIDIA" | grep -qE "GTX 16[0-9]{2}|RTX [2-5][0-9]{3}|RTX PRO [0-9]{4}|Quadro RTX|RTX A[0-9]{4}|A[1-9][0-9]{2}|H[1-9][0-9]{2}|T4|L[0-9]+"; then
    echo "[*] Detected Turing+ GPU architecture (GSP firmware support)."
    cat >>$HOME/.config/uwsm/env <<'EOF'

# NVIDIA (Turing+ with GSP firmware)
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
elif echo "$NVIDIA" | grep -qE "GTX (9[0-9]{2}|10[0-9]{2})|GT 10[0-9]{2}|Quadro [PM][0-9]{3,4}|Quadro GV100|MX *[0-9]+|Titan (X|Xp|V)|Tesla V100"; then
    echo "[*] Detected Maxwell/Pascal/Volta GPU architecture (No GSP firmware support)."
    cat >>$HOME/.config/uwsm/env <<'EOF'

# NVIDIA (Maxwell/Pascal/Volta without GSP firmware)
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=egl
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
else
    echo "[*] Detected unknown/legacy NVIDIA GPU architecture. Using default variables."
    cat >>$HOME/.config/uwsm/env <<'EOF'

# NVIDIA (Default)
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
fi

echo "[*] NVIDIA configuration completed successfully."
