#!/bin/bash

# Check if git is installed
if ! command -v git &> /dev/null; then
    echo "Error: git is not installed. Please install git before running this script."
    exit 1
fi

# Fetch Omarchy from repo
echo "Fetching Omarchy source..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_DIR="$SCRIPT_DIR/../../omarchy"

if [ -f "$SCRIPT_DIR/fetch-omarchy.sh" ]; then
    chmod +x "$SCRIPT_DIR/fetch-omarchy.sh"
    if ! "$SCRIPT_DIR/fetch-omarchy.sh"; then
        echo "Error: Fetching the Omarchy source failed. Aborting."
        exit 1
    fi
else
    # Fallback if script is missing
    echo "fetch-omarchy.sh not found, falling back to default clone..."
    git clone https://www.github.com/basecamp/omarchy "$OMARCHY_DIR"
fi

if [ ! -d "$OMARCHY_DIR" ]; then
    echo "Error: Failed to fetch Omarchy source at $OMARCHY_DIR"
    exit 1
fi

# Check if yay is installed
if ! command -v yay &> /dev/null; then
    echo "yay is not installed. Installing yay..."

    # Install dependencies for building yay
    sudo pacman -S --needed --noconfirm git base-devel

    # Clone and build yay
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    cd /tmp/yay
    makepkg -si --noconfirm
    cd -

    # Clean up
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

# Locally sign and trust the key
sudo pacman-key --lsign-key F0134EE680CAC571

# Add omarchy repository to pacman.conf (skip if already present)
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
    echo -e "\n[omarchy]\nSigLevel = Optional TrustedOnly\nServer = https://pkgs.omarchy.org/\$arch" | sudo tee -a /etc/pacman.conf > /dev/null
else
    echo "Omarchy repository already present in pacman.conf, skipping."
fi
sudo pacman -Syu

# Remove CachyOS SDDM config
if [ -f /etc/sddm.conf ]; then
    echo "Removing /etc/sddm.conf"
    sudo rm /etc/sddm.conf
fi

# Replace CachyOS's fish login shell with bash.
# Omarchy writes ~/.bashrc and ships its own aliases, functions, completions,
# prompt, and mise activation under default/bash/, but it never runs chsh
# itself. With fish as the login shell none of that is ever sourced, so the
# user gets Omarchy's shell config installed but never loaded.
LOGIN_USER="$(id -un)"
CURRENT_SHELL="$(getent passwd "$LOGIN_USER" | cut -d: -f7)"
if [ "$CURRENT_SHELL" != "/bin/bash" ]; then
    echo ""
    echo "Changing login shell for $LOGIN_USER from $CURRENT_SHELL to /bin/bash..."
    if sudo chsh -s /bin/bash "$LOGIN_USER"; then
        echo "Login shell is now bash. Fish stays installed - run 'fish' to use it."
    else
        echo "Warning: could not change the login shell."
        echo "Run 'chsh -s /bin/bash' yourself after this script finishes."
    fi
else
    echo "Login shell is already bash."
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

# Make adjustments to Omarchy install scripts to support CachyOS
echo ""
echo "Making adjustments to Omarchy install scripts to support CachyOS..."

# Navigate to Omarchy install scripts
cd "$OMARCHY_DIR" || {
    echo "Error: Could not enter Omarchy source directory at $OMARCHY_DIR"
    exit 1
}

# Remove tldr installation to prevent conflict with tealdeer install.
sed -i '/tldr/d' install/omarchy-base.packages

# Update restart-needed for kernel updates to use cachyos instead of arch
sed -i "s/ | sed 's\/-arch\/\\\.arch\/'//" bin/omarchy-update-restart
sed -i "s/'{print \$2}'/'{print \$2 \"-\" \$1}' | sed 's\/-linux\/\/'/" bin/omarchy-update-restart
sed -i '/linux-cachyos/ ! s/pacman -Q linux/pacman -Q linux-cachyos/' bin/omarchy-update-restart

# Remove pacman.sh from preflight/all.sh to prevent conflict with cachyos packages
sed -i '/run_logged \$OMARCHY_INSTALL\/preflight\/pacman\.sh/d' install/preflight/all.sh

# Replace nvidia.sh with custom CachyOS 580xx Driver Logic
cp "$SCRIPT_DIR/nvidia.sh" install/config/hardware/nvidia.sh
chmod +x install/config/hardware/nvidia.sh

# Fix omarchy-ai-skill.sh symlink to be idempotent on re-runs
sed -i 's/ln -s/ln -sf/' install/config/omarchy-ai-skill.sh

# Remove plymouth.sh source line from install.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/plymouth\.sh/d' install/login/all.sh

# Remove limine-snapper.sh source line from install.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/limine-snapper\.sh/d' install/login/all.sh

# Remove alt-bootloaders.sh source line from install.sh
sed -i '/run_logged \$OMARCHY_INSTALL\/login\/alt-bootloaders\.sh/d' install/login/all.sh

# Remove pacman.sh from post-install/all.sh to prevent conflict with cachyos packages
sed -i '/run_logged \$OMARCHY_INSTALL\/post-install\/pacman\.sh/d' install/post-install/all.sh

# Disable wpa_supplicant and configure NetworkManager to use iwd backend.
# CachyOS enables wpa_supplicant by default, which conflicts with omarchy's iwd,
# causing WiFi to appear connected but have no IP or connectivity.
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

# Pin walker to the omarchy repo so CachyOS doesn't override it with an
# incompatible version that breaks compatibility with elephant.
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

# No mise patch is needed. Omarchy's config/uwsm/env activates mise with
# --shims, which exports a PATH entry that every process in the session
# inherits, and default/bash/init activates it for interactive bash. With bash
# as the login shell both paths are covered by Omarchy itself.

# Copy omarchy installation files to ~/.local/share/omarchy
mkdir -p ~/.local/share/omarchy
cp -r . ~/.local/share/omarchy
cd ~/.local/share/omarchy

# Pause and prompt for acknowledgment to begin installation
echo ""
echo "The following adjustments have been completed."
echo " 1. Added Omarchy repo to pacman.conf"
echo " 2. Removed tldr from packages.sh to avoid conflict with tealdeer on CachyOS."
echo " 3. Disabled further Omarchy changes to pacman.conf, preserving CachyOS settings."
echo " 4. Replaced nvidia.sh to respect existing CachyOS NVIDIA drivers (only installs if none present)."
echo " 5. Removed plymouth.sh from install.sh to avoid conflict with CachyOS login display manager installation."
echo " 6. Removed limine-snapper.sh from install.sh to avoid conflict with CachyOS boot loader installation."
echo " 7. Removed alt-bootloaders.sh from install.sh to avoid conflict with CachyOS boot loader installation."
echo " 8. Removed /etc/sddm.conf to avoid conflict with Omarchy UWSM session autologin."
echo " 9. Disabled wpa_supplicant and configured NetworkManager to use iwd backend."
echo "10. Pinned walker to omarchy repo to prevent CachyOS version conflict."
echo "11. Switched the login shell from fish to bash so Omarchy's shell config is loaded."
echo ""
echo "NOTE: If you installed CachyOS without a desktop environment, you do not need"
echo "to do anything extra. SDDM is part of Omarchy's base package set, and Omarchy's"
echo "install/login/sddm.sh sets up the Omarchy session, enables sddm.service, and"
echo "configures autologin for your user, so the desktop starts on the next boot."
echo ""
echo "The Omarchy boot splash (plymouth) is intentionally skipped so it does not"
echo "conflict with the CachyOS boot setup. To enable it anyway, run:"
echo " 1.) ~/.local/share/omarchy/install/login/plymouth.sh"
echo ""
echo "That only sets the boot splash theme. It does not affect how the desktop starts."
echo ""
echo "Press Enter to begin the installation of Omarchy..."
read -r

# Run the modified install.sh script 
chmod +x install.sh
./install.sh
