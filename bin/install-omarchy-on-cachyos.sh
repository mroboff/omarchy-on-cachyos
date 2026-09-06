#!/bin/bash
# install-omarchy-on-cachyos.sh — Install Omarchy on CachyOS (v3.x and v4.x)
#
# Supports both Omarchy v3 (source clone) and v4 (pacman packages).
# Applies CachyOS compatibility patches and boot safety guards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_DIR="$SCRIPT_DIR/../../omarchy"

# ============================================================================
# Common prerequisites (v3 and v4)
# ============================================================================

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed. Please install git before running this script."
    exit 1
fi

# Fetch Omarchy source
echo "Fetching Omarchy source..."
if [ -f "$SCRIPT_DIR/fetch-omarchy.sh" ]; then
    chmod +x "$SCRIPT_DIR/fetch-omarchy.sh"
    "$SCRIPT_DIR/fetch-omarchy.sh"
else
    echo "fetch-omarchy.sh not found, falling back to default clone..."
    git clone https://www.github.com/basecamp/omarchy "$OMARCHY_DIR"
fi

if [ ! -d "$OMARCHY_DIR" ]; then
    echo "Error: Failed to fetch Omarchy source at $OMARCHY_DIR"
    exit 1
fi

# Detect version from fetch-omarchy.sh or from cloned repo
if [ -n "${OMARCHY_VERSION_MAJOR:-}" ]; then
    echo "Detected Omarchy v${OMARCHY_VERSION_MAJOR}.x"
else
    # Auto-detect from cloned repo
    if [ -f "$OMARCHY_DIR/install.sh" ]; then
        OMARCHY_VERSION_MAJOR="3"
    else
        OMARCHY_VERSION_MAJOR="4"
    fi
    echo "Auto-detected Omarchy v${OMARCHY_VERSION_MAJOR}.x"
fi

# Check if yay is installed
if ! command -v yay &> /dev/null; then
    echo "yay is not installed. Installing yay..."
    sudo pacman -S --needed --noconfirm git base-devel
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    cd /tmp/yay
    makepkg -si --noconfirm
    cd -
    rm -rf /tmp/yay
    if ! command -v yay &> /dev/null; then
        echo "Error: Failed to install yay."
        exit 1
    fi
    echo "yay has been successfully installed."
else
    echo "yay is already installed."
fi

# Receive the Omarchy signing key
sudo pacman-key --recv-keys F0134EE680CAC571
sudo pacman-key --lsign-key F0134EE680CAC571

# Add omarchy repository to pacman.conf (skip if already present)
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
    echo -e "\n[omarchy]\nSigLevel = Optional TrustedOnly\nServer = https://pkgs.omarchy.org/\$arch" | sudo tee -a /etc/pacman.conf > /dev/null
else
    echo "Omarchy repository already present in pacman.conf, skipping."
fi
sudo pacman -Syu

# ============================================================================
# Install boot safety guards BEFORE any omarchy-settings package
# ============================================================================

echo ""
echo "Installing boot safety guards (mkinitcpio + limine protection)..."
chmod +x "$SCRIPT_DIR/boot-guards.sh"
"$SCRIPT_DIR/boot-guards.sh"

# Remove CachyOS SDDM config (conflicts with Omarchy UWSM session autologin)
if [ -f /etc/sddm.conf ]; then
    echo "Removing /etc/sddm.conf"
    sudo rm /etc/sddm.conf
fi

# Prompt user for username
echo ""
echo "Please enter your username:"
read -r OMARCHY_USER_NAME
export OMARCHY_USER_NAME

# Prompt user for email address
echo ""
echo "Please enter your email address:"
read -r OMARCHY_USER_EMAIL
export OMARCHY_USER_EMAIL

# ============================================================================
# Branch: v3 (source) or v4 (packages)
# ============================================================================

if [ "$OMARCHY_VERSION_MAJOR" -eq 3 ]; then
    echo ""
    echo "=========================================="
    echo "  Installing Omarchy v3.x (source mode)  "
    echo "=========================================="
    echo ""
    install_v3
else
    echo ""
    echo "=========================================="
    echo "  Installing Omarchy v4.x (package mode) "
    echo "=========================================="
    echo ""
    install_v4
fi

# ============================================================================
# v3: Source-based install (original flow with patches)
# ============================================================================

function install_v3 {
    # Navigate to Omarchy install scripts
    cd "$OMARCHY_DIR"

    # Remove tldr installation to prevent conflict with tealdeer install
    sed -i '/tldr/d' install/omarchy-base.packages

    # Update restart-needed for kernel updates to use cachyos instead of arch
    sed -i "s/ | sed 's\/-arch\/\\\.arch\/'//" bin/omarchy-update-restart
    sed -i "s/'{print \$2}'/'{print \$2 \"-\" \$1}' | sed 's\/-linux\/\/'/" bin/omarchy-update-restart
    sed -i '/linux-cachyos/ ! s/pacman -Q linux/pacman -Q linux-cachyos/' bin/omarchy-update-restart

    # Remove pacman.sh from preflight/all.sh to prevent conflict with cachyos packages
    sed -i '/run_logged \$OMARCHY_INSTALL\/preflight\/pacman\.sh/d' install/preflight/all.sh

    # Replace nvidia.sh with custom CachyOS driver logic
    cp "$SCRIPT_DIR/nvidia.sh" install/config/hardware/nvidia.sh
    chmod +x install/config/hardware/nvidia.sh

    # Fix omarchy-ai-skill.sh symlink to be idempotent on re-runs
    sed -i 's/ln -s/ln -sf/' install/config/omarchy-ai-skill.sh

    # Remove plymouth.sh source line
    sed -i '/run_logged \$OMARCHY_INSTALL\/login\/plymouth\.sh/d' install/login/all.sh

    # Remove limine-snapper.sh source line
    sed -i '/run_logged \$OMARCHY_INSTALL\/login\/limine-snapper\.sh/d' install/login/all.sh

    # Remove alt-bootloaders.sh source line
    sed -i '/run_logged \$OMARCHY_INSTALL\/login\/alt-bootloaders\.sh/d' install/login/all.sh

    # Remove pacman.sh from post-install/all.sh
    sed -i '/run_logged \$OMARCHY_INSTALL\/post-install\/pacman\.sh/d' install/post-install/all.sh

    # Disable wpa_supplicant and configure NetworkManager to use iwd backend
    cat >> install/config/hardware/network.sh << 'NETEOF'

# Disable wpa_supplicant to prevent conflict with iwd
sudo systemctl disable --now wpa_supplicant.service 2>/dev/null

# Configure NetworkManager to use iwd as its WiFi backend
if ! grep -q "wifi.backend=iwd" /etc/NetworkManager/NetworkManager.conf 2>/dev/null; then
  sudo tee -a /etc/NetworkManager/NetworkManager.conf > /dev/null << EOF

[device]
wifi.backend=iwd
EOF
fi
NETEOF

    # Pin walker to the omarchy repo
    sed -i '1a\
# Pin walker to omarchy repo to prevent CachyOS version conflict\
if ! grep -q "^IgnorePkg.*walker" /etc/pacman.conf 2>/dev/null; then\
  if grep -q "^IgnorePkg" /etc/pacman.conf; then\
    sudo sed -i '"'"'s/^IgnorePkg = \\(.*\\)/IgnorePkg = \\1 walker/'"'"' /etc/pacman.conf\
  else\
    sudo sed -i '"'"'/^\\[options\\]/a IgnorePkg = walker'"'"' /etc/pacman.conf\
  fi\
fi\
' install/config/walker-elephant.sh

    # Update mise activation to support both bash and fish
    sed -i 's/omarchy-cmd-present mise && eval "\$(mise activate bash)"/if [ "\$SHELL" = "\/bin\/bash" ] \&\& command -v mise \&> \/dev\/null; then\n  eval "\$(mise activate bash)"\nelif [ "\$SHELL" = "\/bin\/fish" ] \&\& command -v mise \&> \/dev\/null; then\n  mise activate fish | source\nfi/' config/uwsm/env

    # Copy omarchy installation files to ~/.local/share/omarchy
    mkdir -p ~/.local/share/omarchy
    cp -r . ~/.local/share/omarchy
    cd ~/.local/share/omarchy

    # Print summary
    echo ""
    echo "The following adjustments have been completed."
    echo " 1. Added Omarchy repo to pacman.conf"
    echo " 2. Removed tldr from packages.sh to avoid conflict with tealdeer on CachyOS"
    echo " 3. Disabled further Omarchy changes to pacman.conf, preserving CachyOS settings"
    echo " 4. Replaced nvidia.sh to respect existing CachyOS NVIDIA drivers"
    echo " 5. Removed plymouth.sh to avoid conflict with CachyOS login display manager"
    echo " 6. Removed limine-snapper.sh to avoid conflict with CachyOS boot loader"
    echo " 7. Removed alt-bootloaders.sh to avoid conflict with CachyOS boot loader"
    echo " 8. Removed /etc/sddm.conf to avoid conflict with Omarchy UWSM session autologin"
    echo " 9. Installed boot safety guards (mkinitcpio + limine)"
    echo "10. Disabled wpa_supplicant and configured NetworkManager to use iwd backend"
    echo "11. Pinned walker to omarchy repo to prevent CachyOS version conflict"
    echo ""
    echo "IMPORTANT: If you installed CachyOS without a desktop environment, you will not have a display manager installed."
    echo "If this is the case, you will need to run the following command after this installation script is complete:"
    echo "  1.) ~/.local/share/omarchy/install/login/plymouth.sh"
    echo ""
    echo "The above script will modify your boot to start Omarchy's Hyprland desktop automatically."
    echo ""
    echo "Press Enter to begin the installation of Omarchy..."
    read -r

    # Run the modified install.sh script
    chmod +x install.sh
    ./install.sh
}

# ============================================================================
# v4: Package-based install (pacman + manual configuration)
# ============================================================================

function install_v4 {
    local OMARCHY_SHARE="/usr/share/omarchy"

    echo "Installing Omarchy packages via pacman..."
    sudo pacman -S --needed --noconfirm omarchy omarchy-settings omarchy-nvim

    echo "Installing omarchy-base.packages (minus tldr)..."
    if [ -f "$OMARCHY_SHARE/install/omarchy-base.packages" ]; then
        grep -v '^tldr$' "$OMARCHY_SHARE/install/omarchy-base.packages" | sudo pacman -S --needed --noconfirm -
    else
        echo "Warning: omarchy-base.packages not found at $OMARCHY_SHARE/install/"
    fi

    # --- Hardware scripts ---
    echo ""
    echo "Running hardware configuration scripts..."

    # nvidia: use our CachyOS-aware version
    if [ -f "$OMARCHY_SHARE/install/hardware/nvidia.sh" ]; then
        echo "Running CachyOS-aware nvidia.sh..."
        chmod +x "$SCRIPT_DIR/nvidia.sh"
        "$SCRIPT_DIR/nvidia.sh"
    fi

    # network: v4 centralizes on NetworkManager (disables iwd)
    # The fork's wpa_supplicant/iwd block is no longer needed for v4
    if [ -f "$OMARCHY_SHARE/install/hardware/network.sh" ]; then
        echo "Running network.sh..."
        sudo bash "$OMARCHY_SHARE/install/hardware/network.sh"
    fi

    # --- Post-install (skip pacman.sh) ---
    echo ""
    echo "Running post-install scripts (skipping pacman.sh)..."

    if [ -f "$OMARCHY_SHARE/install/post-install/all.sh" ]; then
        # Source individual scripts, skipping pacman.sh
        for script in "$OMARCHY_SHARE/install/post-install/"*.sh; do
            SCRIPT_NAME=$(basename "$script")
            if [ "$SCRIPT_NAME" = "pacman.sh" ] || [ "$SCRIPT_NAME" = "all.sh" ]; then
                echo "  Skipping $SCRIPT_NAME"
                continue
            fi
            echo "  Running $SCRIPT_NAME..."
            sudo bash "$script" || echo "  Warning: $SCRIPT_NAME returned non-zero"
        done
    fi

    # --- User configuration ---
    echo ""
    echo "Configuring user..."

    # User configs ship via /etc/skel — copy to home
    if [ -d /etc/skel ]; then
        cp -af /etc/skel/. "$HOME/"
        echo "Copied skel configs to $HOME"
    fi

    # Run user provisioning without --first-install (avoids iso-chroot context)
    if command -v omarchy-provision-user &>/dev/null; then
        echo "Running omarchy-provision-user --force..."
        omarchy-provision-user --force || echo "Warning: omarchy-provision-user returned non-zero"
    fi

    # --- SDDM login ---
    echo ""
    echo "Configuring SDM login..."

    # Create state.conf for SDDM (needed for username detection)
    if [ ! -f /var/lib/sddm/state.conf ]; then
        sudo mkdir -p /var/lib/sddm
        echo "[General]" | sudo tee /var/lib/sddm/state.conf > /dev/null
        echo "LastUser=$OMARCHY_USER_NAME" | sudo tee -a /var/lib/sddm/state.conf > /dev/null
        echo "Created /var/lib/sddm/state.conf"
    fi

    # Configure autologin
    sudo mkdir -p /etc/sddm.conf.d
    if [ ! -f /etc/sddm.conf.d/autologin.conf ]; then
        sudo tee /etc/sddm.conf.d/autologin.conf > /dev/null << AUTEOF
[Autologin]
User=$OMARCHY_USER_NAME
Session=hyprland
AUTEOF
        echo "Created /etc/sddm.conf.d/autologin.conf"
    fi

    # --- Boot entries ---
    echo ""
    echo "Refreshing boot entries..."
    if command -v omarchy-refresh-limine &>/dev/null; then
        # Only refresh if limine is the bootloader
        if [ -d /boot/limine ]; then
            omarchy-refresh-limine || echo "Warning: limine refresh returned non-zero"
        fi
    fi

    # --- Summary ---
    echo ""
    echo "=========================================="
    echo "  Omarchy v4.x installation complete!     "
    echo "=========================================="
    echo ""
    echo "  - Packages installed via pacman"
    echo "  - Boot safety guards active (mkinitcpio + limine)"
    echo "  - SDDM configured for autologin"
    echo "  - NVIDIA driver configured (CachyOS-aware)"
    echo ""
    echo "You may need to reboot for all changes to take effect."
    echo ""
}
