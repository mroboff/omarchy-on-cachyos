#!/bin/bash
set -e

# --- NVIDIA Configuration for Omarchy on CachyOS ---
# Philosophy: detect and use whatever NVIDIA driver CachyOS has installed.
# Only install a driver if none is present. Never downgrade or force-replace.

# Exit early if no NVIDIA GPU is present
if ! lspci -nn -d 10de: | grep -qE "VGA|3D"; then
    echo "[*] No NVIDIA GPU found. Skipping."
    exit 0
fi

GPU_NAME=$(lspci -d 10de: | grep -E "VGA|3D" | head -n1 | sed 's/.*: //')
echo "[*] NVIDIA GPU detected: $GPU_NAME"

# Determine if a working NVIDIA driver is already installed
NVIDIA_DRIVER=$(pacman -Qq | grep -E '^nvidia-(dkms|open-dkms|utils)$' | head -n1 || true)

if [[ -n "$NVIDIA_DRIVER" ]]; then
    DRIVER_VERSION=$(pacman -Q "$NVIDIA_DRIVER" 2>/dev/null | awk '{print $2}')
    echo "[*] Active NVIDIA driver found: $NVIDIA_DRIVER $DRIVER_VERSION"
    echo "[*] Respecting existing CachyOS driver installation."
else
    echo "[!] No NVIDIA driver detected — installing via chwd..."
    sudo chwd -a
    echo "[*] Driver installed via CachyOS hardware detection."
fi

# Ensure VA-API utils are present for hardware video acceleration
sudo pacman -S --needed --noconfirm libva-utils

# Apply NVIDIA environment variables for UWSM/Hyprland
# In the v4 package flow this script runs via omarchy-apply-hardware as root
# (OMARCHY_INSTALL_USER is exported by the installer), so $HOME would point to
# /root and the variables would never reach the desktop user.
TARGET_HOME="${HOME}"
if [ -n "${OMARCHY_INSTALL_USER:-}" ] && [ "$(id -u)" -eq 0 ]; then
    TARGET_HOME="$(getent passwd "${OMARCHY_INSTALL_USER}" | cut -d: -f6)"
fi
if [ -z "${TARGET_HOME}" ]; then
    echo "[!] Could not resolve target home; falling back to \$HOME"
    TARGET_HOME="${HOME}"
fi
mkdir -p "${TARGET_HOME}/.config/uwsm"
if ! grep -q "GBM_BACKEND=nvidia-drm" "${TARGET_HOME}/.config/uwsm/env" 2>/dev/null; then
    cat >>"${TARGET_HOME}/.config/uwsm/env" <<'EOF'

# NVIDIA
export LIBVA_DRIVER_NAME=nvidia
export GBM_BACKEND=nvidia-drm
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export NVD_BACKEND=direct
export MOZ_DISABLE_RDD_SANDBOX=1
export CUDA_DISABLE_PERF_BOOST=1
EOF
    echo "[*] NVIDIA environment variables written to ${TARGET_HOME}/.config/uwsm/env"
else
    echo "[*] NVIDIA environment variables already present."
fi

echo "[*] NVIDIA configuration complete."
