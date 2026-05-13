#!/bin/bash
set -e

# Check for NVIDIA GPU — skip entirely if none found
GPU_ID=$(lspci -nn -d 10de: | grep -E "VGA|3D" | head -n1 | grep -oP '(?<=\[10de:)[0-9a-fA-F]{4}(?=\])' || true)

if [[ -z "$GPU_ID" ]]; then
    echo "No NVIDIA GPU found. Skipping."
    exit 0
fi

echo "[*] Found NVIDIA GPU: $GPU_ID"
echo "[*] Skipping driver installation — using CachyOS native NVIDIA drivers."

# Install VA-API utils
sudo pacman -S --needed --noconfirm libva-utils

# Add NVIDIA environment variables for UWSM/Hyprland
cat >>$HOME/.config/uwsm/env <<'EOF'

# NVIDIA
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
