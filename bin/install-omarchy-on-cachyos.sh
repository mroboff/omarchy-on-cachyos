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
    "$SCRIPT_DIR/fetch-omarchy.sh"
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

# Prompt user for username
echo ""
echo "Please enter your name for git commits (e.g. John Doe)."
echo "This also sets a CapsLock+Space+N shortcut to type it quickly."
read -r OMARCHY_USER_NAME
export OMARCHY_USER_NAME

# Prompt user for email address
echo ""
echo "Please enter your email for git commits (e.g. you@example.com)."
echo "This also sets a CapsLock+Space+E shortcut to type it quickly. Leave blank to skip."
echo "(Stays on your machine only — not sent anywhere, no newsletters, no telemetry.)"
while true; do
    read -r OMARCHY_USER_EMAIL
    if [[ -z "$OMARCHY_USER_EMAIL" ]]; then
        echo "Skipping email configuration."
        break
    elif [[ "$OMARCHY_USER_EMAIL" =~ ^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$ ]]; then
        break
    else
        echo "Invalid email format. Please try again (or leave blank to skip):"
    fi
done
export OMARCHY_USER_EMAIL

# Prompt user for autologin preference
echo ""
echo "Do you want to enable automatic login to Omarchy?"
echo "If 'no', you will be prompted for a password at boot and can choose your desktop environment (e.g. KDE)."
read -r -p "[y/N]: " ENABLE_AUTOLOGIN

# Make adjustments to Omarchy install scripts to support CachyOS
echo ""
echo "Making adjustments to Omarchy install scripts to support CachyOS..."

# Navigate to Omarchy install scripts
cd "$OMARCHY_DIR" || { echo "Error: failed to change directory to $OMARCHY_DIR"; exit 1; }

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

# Make autologin optional
if [[ ! "${ENABLE_AUTOLOGIN,,}" =~ ^(y|yes)$ ]]; then
    # Remove autologin configuration from Omarchy's SDDM setup
    sed -i '/\[Autologin\]/d' install/login/sddm.sh
    sed -i '/User=\$USER/d' install/login/sddm.sh
    sed -i '/Session=omarchy/d' install/login/sddm.sh
    
    # Remove any existing autologin conf so SDDM prompts for password
    sudo rm -f /etc/sddm.conf.d/autologin.conf 2>/dev/null
fi

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

# Update mise activation to support both bash and fish
sed -i 's/omarchy-cmd-present mise && eval "\$(mise activate bash)"/if [ "\$SHELL" = "\/bin\/bash" ] \&\& command -v mise \&> \/dev\/null; then\n  eval "\$(mise activate bash)"\nelif [ "\$SHELL" = "\/bin\/fish" ] \&\& command -v mise \&> \/dev\/null; then\n  mise activate fish | source\nfi/' config/uwsm/env

# Copy omarchy installation files to ~/.local/share/omarchy
rm -rf ~/.local/share/omarchy
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
if [[ "${ENABLE_AUTOLOGIN,,}" =~ ^(y|yes)$ ]]; then
    echo " 8. Removed /etc/sddm.conf and configured Omarchy SDDM autologin."
else
    echo " 8. Removed /etc/sddm.conf and disabled Omarchy SDDM autologin."
fi
echo " 9. Disabled wpa_supplicant and configured NetworkManager to use iwd backend."
echo "10. Pinned walker to omarchy repo to prevent CachyOS version conflict."
echo ""
echo "IMPORTANT: If you installed CachyOS without a desktop environment, you will not have a display manager installed."
echo "If this is the case, you will need to run the following command after this installation script is complete:"
echo "  ~/.local/share/omarchy/install/login/plymouth.sh"
echo ""
echo "That script only sets the Omarchy boot splash (Plymouth theme). It does NOT change your bootloader."
echo ""
echo "  - Already have KDE or GNOME? No action needed — your existing login screen and desktop are untouched."
echo "    Omarchy will appear as a selectable session in your display manager (e.g. SDDM)."
echo ""
echo "  - Multi-boot with Windows? Safe — this script does not modify GRUB or your boot entries."
echo "    Your Windows partition and boot menu remain exactly as they are."
echo ""
echo "Press Enter to begin the installation of Omarchy..."
read -r

# Run the modified install.sh script 
chmod +x install.sh
./install.sh
