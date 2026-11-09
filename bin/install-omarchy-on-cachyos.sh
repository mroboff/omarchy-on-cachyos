#!/bin/bash
# install-omarchy-on-cachyos.sh — Install Omarchy on CachyOS (v3.x and v4.x)
#
# Supports both Omarchy v3 (source clone) and v4 (pacman packages).
# Applies CachyOS compatibility patches and boot safety guards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY_DIR="$SCRIPT_DIR/../../omarchy"

# ============================================================================
# --fix-qt: apply ONLY the Qt 6.12 Color singleton fix (omacom/omarchy#14469)
# Self-contained mode: no git, no clone, no full install. Installs the fix
# script + the pacman hook so the fix survives future omarchy package updates
# (their update runs `pacman -Syu --overwrite '/usr/share/omarchy/*'`, which
# would otherwise restore the broken shell). Then applies the fix now.
#
# Remove this block (the whole "commit") once upstream publishes the fix.
# ============================================================================
if [ "${1:-}" = "--fix-qt" ]; then
    if [ ! -f "$SCRIPT_DIR/omarchy-qt-color-fix.sh" ]; then
        echo "Error: $SCRIPT_DIR/omarchy-qt-color-fix.sh not found."
        exit 1
    fi
    echo "Applying Qt 6.12 Color singleton fix (omarchy#14469)..."
    sudo install -m 755 "$SCRIPT_DIR/omarchy-qt-color-fix.sh" /usr/local/bin/omarchy-qt-color-fix.sh
    sudo install -Dm 644 "$SCRIPT_DIR/omarchy-qt-color-fix.hook" \
        /etc/pacman.d/hooks/omarchy-qt-color-fix.hook
    echo "Installed: /usr/local/bin/omarchy-qt-color-fix.sh"
    echo "           /etc/pacman.d/hooks/omarchy-qt-color-fix.hook"
    sudo /usr/local/bin/omarchy-qt-color-fix.sh
    echo "Done."
    exit 0
fi

# ============================================================================
# --fix-mirrors: reorder the pacman mirrorlists by measured download speed.
#
# `cachyos-rate-mirrors` (systemd timer, 3x/day) regenerates the mirrorlists
# with `rate-mirrors`, whose ~300 ms probe can mis-rank a mirror that has
# since degraded. We hit exactly that: `ca.mirror.cx` was first in the list at
# 5 KB/s while `mirror.krfoss.org` (third) served 30 MB/s, and `omarchy
# update` crawled at ~20 KiB/s with a 40-minute ETA.
#
# This installs the reorder script, a systemd drop-in that runs right after
# `cachyos-rate-mirrors` regenerates the lists, and a pacman hook for the
# `cachyos-mirrorlist` package. Then it applies the reorder now.
# ============================================================================
if [ "${1:-}" = "--fix-mirrors" ]; then
    if [ ! -f "$SCRIPT_DIR/cachyos-mirror-order.sh" ]; then
        echo "Error: $SCRIPT_DIR/cachyos-mirror-order.sh not found."
        exit 1
    fi
    echo "Installing the mirror speed reorderer..."
    sudo install -m 755 "$SCRIPT_DIR/cachyos-mirror-order.sh" /usr/local/bin/cachyos-mirror-order.sh
    sudo install -Dm 644 "$SCRIPT_DIR/omarchy-mirror-order.service" \
        /etc/systemd/system/omarchy-mirror-order.service
    sudo install -Dm 644 "$SCRIPT_DIR/omarchy-mirror-order.hook" \
        /etc/pacman.d/hooks/omarchy-mirror-order.hook
    # Drop-in: run the reorderer right after cachyos-rate-mirrors regenerates
    # the mirrorlists, so the fast mirror always ends up first.
    sudo install -Dm 644 "$SCRIPT_DIR/cachyos-rate-mirrors.service.d/omarchy-mirror-order.conf" \
        /etc/systemd/system/cachyos-rate-mirrors.service.d/omarchy-mirror-order.conf
    sudo systemctl daemon-reload
    echo "Installed: /usr/local/bin/cachyos-mirror-order.sh"
    echo "           /etc/systemd/system/omarchy-mirror-order.service"
    echo "           /etc/systemd/system/cachyos-rate-mirrors.service.d/omarchy-mirror-order.conf"
    echo "           /etc/pacman.d/hooks/omarchy-mirror-order.hook"
    sudo /usr/local/bin/cachyos-mirror-order.sh
    echo "Done."
    exit 0
fi

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
sudo pacman -Syu --noconfirm

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
# Robust patching helper
# ============================================================================
# The layout of the omarchy repo changed a lot across releases, so a bare
# `sed -i` is not safe here:
#   - if the file is missing the sed fails and `set -e` aborts the install
#     (install/config/walker-elephant.sh only exists from v3.2.0,
#      install/config/omarchy-ai-skill.sh only from v3.3.0);
#   - if the file exists but upstream changed the line, the sed silently
#     does nothing and you believe a fix was applied when it was not
#     (config/uwsm/env gained `--shims`, and bin/omarchy-update-restart was
#     rewritten from scratch).
#
# patch <file> <detect-regex> <description> <sed-expression>
#   file missing      -> [skip]   and keep going
#   pattern missing   -> [aviso]  and keep going (upstream moved on)
#   pattern present   -> [ok]     and apply the sed
function patch {
    local file="$1" detect="$2" desc="$3" sedexpr="$4"

    if [ ! -f "$file" ]; then
        echo "  [skip]  $desc -- $file does not exist in this release"
        return 0
    fi
    if ! grep -qE -- "$detect" "$file"; then
        echo "  [aviso] $desc -- upstream changed it, pattern not found in $file"
        return 0
    fi
    sed -i -E "$sedexpr" "$file"
    echo "  [ok]    $desc"
}

# ============================================================================
# v3: Source-based install (original flow with patches)
# ============================================================================

function install_v3 {
    # Navigate to Omarchy install scripts
    cd "$OMARCHY_DIR"

    # Remove tldr installation to prevent conflict with tealdeer install
    patch install/omarchy-base.packages '^[ \t]*tldr[ \t]*$' \
        "drop tldr (clashes with tealdeer)" \
        '/^[ \t]*tldr[ \t]*$/d'

    # Update restart-needed for kernel updates to use cachyos instead of arch.
    # Only older v3 releases compare `pacman -Q linux`; later ones walk
    # /usr/lib/modules with `pacman -Qo`, which is already kernel-agnostic and
    # correct on linux-cachyos, so there is nothing to patch there.
    if [ -f bin/omarchy-update-restart ]; then
        if grep -qF 'pacman -Q linux' bin/omarchy-update-restart; then
            sed -i "s/ | sed 's\/-arch\/\\\.arch\/'//" bin/omarchy-update-restart
            sed -i "s/'{print \$2}'/'{print \$2 \"-\" \$1}' | sed 's\/-linux\/\/'/" bin/omarchy-update-restart
            sed -i '/linux-cachyos/ ! s/pacman -Q linux/pacman -Q linux-cachyos/' bin/omarchy-update-restart
            echo "  [ok]    omarchy-update-restart -> cachyos"
        else
            echo "  [ok]    omarchy-update-restart is already kernel-agnostic (no patch needed)"
        fi
    else
        echo "  [skip]  bin/omarchy-update-restart does not exist in this release"
    fi

    # Remove pacman.sh from preflight/all.sh to prevent conflict with cachyos packages
    patch install/preflight/all.sh 'run_logged \$OMARCHY_INSTALL/preflight/pacman\.sh' \
        "drop pacman.sh from preflight/all.sh" \
        '/run_logged \$OMARCHY_INSTALL\/preflight\/pacman\.sh/d'

    # Replace nvidia.sh with custom CachyOS driver logic
    if [ -f install/config/hardware/nvidia.sh ]; then
        cp "$SCRIPT_DIR/nvidia.sh" install/config/hardware/nvidia.sh
        chmod +x install/config/hardware/nvidia.sh
        echo "  [ok]    nvidia.sh de CachyOS"
    else
        echo "  [skip]  install/config/hardware/nvidia.sh does not exist in this release"
    fi

    # Fix omarchy-ai-skill.sh symlink to be idempotent on re-runs.
    # \b keeps an already-idempotent `ln -sfn` untouched (upstream ships it
    # that way since v3.3.x); a plain `s/ln -s/ln -sf/` would turn it into the
    # nonsense flag soup `ln -sfsn`.
    patch install/config/omarchy-ai-skill.sh '\bln -s\b' \
        "omarchy-ai-skill.sh: idempotent symlinks" \
        's/\bln -s\b/ln -sfn/g'

    # Remove plymouth.sh source line
    patch install/login/all.sh 'run_logged \$OMARCHY_INSTALL/login/plymouth\.sh' \
        "drop plymouth.sh" \
        '/run_logged \$OMARCHY_INSTALL\/login\/plymouth\.sh/d'

    # Remove limine-snapper.sh source line
    patch install/login/all.sh 'run_logged \$OMARCHY_INSTALL/login/limine-snapper\.sh' \
        "drop limine-snapper.sh" \
        '/run_logged \$OMARCHY_INSTALL\/login\/limine-snapper\.sh/d'

    # Remove alt-bootloaders.sh source line (dropped by upstream in later v3)
    patch install/login/all.sh 'run_logged \$OMARCHY_INSTALL/login/alt-bootloaders\.sh' \
        "drop alt-bootloaders.sh" \
        '/run_logged \$OMARCHY_INSTALL\/login\/alt-bootloaders\.sh/d'

    # Remove pacman.sh from post-install/all.sh
    patch install/post-install/all.sh 'run_logged \$OMARCHY_INSTALL/post-install/pacman\.sh' \
        "drop pacman.sh from post-install/all.sh" \
        '/run_logged \$OMARCHY_INSTALL\/post-install\/pacman\.sh/d'

    # Disable wpa_supplicant and configure NetworkManager to use iwd backend
    if [ -f install/config/hardware/network.sh ]; then
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
        echo "  [ok]    iwd backend + wpa_supplicant disabled"
    else
        echo "  [skip]  install/config/hardware/network.sh does not exist in this release"
    fi

    # Pin walker to the omarchy repo
    if [ -f install/config/walker-elephant.sh ]; then
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
        echo "  [ok]    walker pinned to the omarchy repo"
    else
        echo "  [skip]  install/config/walker-elephant.sh does not exist in this release"
    fi

    # Update mise activation to support both bash and fish.
    # Upstream added `--shims` in later v3 releases, so the pattern has to
    # match both forms; \1 preserves whatever the upstream line was using.
    patch config/uwsm/env '^omarchy-cmd-present mise && eval' \
        "mise: activate for bash and fish" \
        's|^omarchy-cmd-present mise && eval "\$\(mise activate bash( --shims)?\)"$|if [ "$SHELL" = "/bin/bash" ] \&\& command -v mise \&> /dev/null; then\n  eval "$(mise activate bash\1)"\nelif [ "$SHELL" = "/bin/fish" ] \&\& command -v mise \&> /dev/null; then\n  mise activate fish\1 \| source\nfi|'

    # Allow CachyOS by leaving the upstream Arch-derivative guard loop
    # syntactically intact but empty
    patch install/preflight/guard.sh '^for marker in .*; do$' \
        "allow CachyOS in the derivative guard" \
        's|^for marker in .*; do$|for marker in; do # CachyOS: derivatives allowed by omarchy-on-cachyos|'

    # Prevent silent abort in presentation.sh when no TTY is available
    patch install/helpers/presentation.sh 'TERM_SIZE=\$\(stty size 2>/dev/null </dev/tty\)' \
        "presentation.sh headless-safe" \
        's#TERM_SIZE=\$\(stty size 2>/dev/null </dev/tty\)#TERM_SIZE=$(stty size 2>/dev/null </dev/tty || true)#'

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
    echo "12. Allowed CachyOS as an install target (disabled upstream Arch-derivative guard)"
    echo "13. Made installer TTY-independent (stty no longer aborts headless installs)"
    echo "14. Enabled mise for bash and fish shells"
    echo ""
    echo "Some of the adjustments above did not apply to this Omarchy release and were"
    echo "reported as [skip] or [aviso] above. That is expected: upstream moved some of"
    echo "those files or already made them CachyOS-compatible."
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
    TERM=xterm-256color script -qec './install.sh' /dev/null
}

# ============================================================================
# v4: Package-based install (pacman + manual configuration)
# ============================================================================

function install_v4 {
    local OMARCHY_SHARE="/usr/share/omarchy"
    local USER_HOME

    echo "Installing Omarchy packages via pacman..."
    sudo pacman -S --needed --noconfirm omarchy omarchy-settings omarchy-nvim

    # The version picked in fetch-omarchy.sh cannot be honoured in v4 mode: the
    # omarchy repository only ever publishes the latest release, so pacman
    # always resolves to whatever is newest. The clone from step 1 is only
    # used to decide v3-vs-v4. Report what actually got installed so the
    # mismatch is visible instead of silently ignored.
    local INSTALLED_OMARCHY
    INSTALLED_OMARCHY=$(pacman -Q omarchy 2>/dev/null | awk '{print $2}' || true)
    echo "Installed omarchy version: ${INSTALLED_OMARCHY:-unknown}"
    echo "NOTE: pkgs.omarchy.org only publishes the latest v4 release, so the"
    echo "      version chosen in step 1 cannot be pinned in v4 mode."

    if [ ! -d "$OMARCHY_SHARE" ]; then
        echo "Error: omarchy package installed but $OMARCHY_SHARE missing."
        exit 1
    fi

    # --- Base packages (filtered for CachyOS) ---
    echo "Installing omarchy-base.packages (filtered for CachyOS)..."
    if [ -f "$OMARCHY_SHARE/install/omarchy-base.packages" ]; then
        local FILTERED="/tmp/omarchy-base.cachyos.packages"
        # Remove tldr (CachyOS ships tealdeer), replace nvim with neovim
        # (omarchy's nvim rebuild lives only in their pinned Arch mirror),
        # drop omarchy-hyprland-titlebars (pin mismatch with CachyOS hyprland),
        # and normalize quickshell-git to quickshell if present.
        grep -vE '^\s*(#|$)' "$OMARCHY_SHARE/install/omarchy-base.packages" \
            | sed -e '/^tldr$/d' \
                  -e 's/^nvim$/neovim/' \
                  -e 's/^quickshell-git$/quickshell/' \
                  -e '/^omarchy-hyprland-titlebars$/d' \
            > "$FILTERED"
        echo "Filtered package list:"
        cat "$FILTERED"
        sudo pacman -S --needed --noconfirm - < "$FILTERED" \
            || echo "Warning: some packages could not be installed."
    else
        echo "Warning: omarchy-base.packages not found at $OMARCHY_SHARE/install/"
    fi

    # --- Overlay our CachyOS-aware nvidia.sh ---
    # The v4 upstream nvidia.sh installs DKMS drivers that conflict with
    # CachyOS's prebuilt linux-cachyos-nvidia-open. Overlay our copy so
    # refresh/hardware runs (omarchy-apply-hardware) use the CachyOS-aware
    # logic instead.
    if [ -f "$OMARCHY_SHARE/install/hardware/nvidia.sh" ]; then
        echo "Overlaying CachyOS-aware nvidia.sh into $OMARCHY_SHARE..."
        sudo cp "$SCRIPT_DIR/nvidia.sh" "$OMARCHY_SHARE/install/hardware/nvidia.sh"
        sudo chmod +x "$OMARCHY_SHARE/install/hardware/nvidia.sh"
    fi

    # --- System apply (replicates omarchy-apply-system minus pacman.sh) ---
    # post-install/pacman.sh overwrites /etc/pacman.conf and the mirrorlist
    # with Omarchy's — a partial-upgrade hazard on CachyOS. Everything else is
    # safe to run. Requires root; run in a single su'd helper.
    echo ""
    echo "Running Omarchy system setup (skipping post-install/pacman.sh)..."
    local APPLY_SCRIPT
    if [ -f "$OMARCHY_SHARE/install/helpers/logging.sh" ]; then
        # mktemp + chmod 600: a fixed /tmp path piped through `sudo bash`
        # is a privilege-escalation hole (local user pre-creates it, or swaps
        # it in the sudo race window). 600 keeps it read-write by our user
        # only, and root reads it via sudo.
        APPLY_SCRIPT="$(mktemp /tmp/omarchy-apply-cachyos.XXXXXX.sh)"
        chmod 600 "$APPLY_SCRIPT"
        # Quoted delimiter: dynamic values (OMARCHY_PATH, INSTALL_USER) are
        # injected through the sudo env instead of being interpolated here.
        cat > "$APPLY_SCRIPT" << 'APPLYEOF'
#!/bin/bash
set -euo pipefail
export OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
export OMARCHY_INSTALL="${OMARCHY_PATH}/install"
export OMARCHY_INSTALL_USER="${OMARCHY_INSTALL_USER:-}"
export OMARCHY_INSTALL_LOG_FILE="/var/log/omarchy-install.log"
export OMARCHY_FIRST_INSTALL="0"
export OMARCHY_UPGRADE="0"
export PATH="${OMARCHY_PATH}/bin:${PATH}"
source "${OMARCHY_INSTALL}/helpers/logging.sh"
start_install_log
echo "  -> config/all.sh"
source "${OMARCHY_INSTALL}/config/all.sh"
echo "  -> omarchy-apply-hardware --install-user ${OMARCHY_INSTALL_USER}"
omarchy-apply-hardware --install-user "${OMARCHY_INSTALL_USER}"
echo "  -> login/all.sh"
source "${OMARCHY_INSTALL}/login/all.sh"
echo "  -> post-install/udev.sh (post-install/pacman.sh skipped)"
run_logged "${OMARCHY_INSTALL}/post-install/udev.sh"
echo "  -> post-install/localdb.sh"
run_logged "${OMARCHY_INSTALL}/post-install/localdb.sh"
stop_install_log
echo "SYSTEM_APPLY_DONE"
APPLYEOF
        # `sudo env VAR=x ...` en vez de `sudo VAR=x ...`: ambos pasan las
        # variables (verificado con sudo 1.9.17), pero la forma con `env` no
        # depende de que la politica sudoers local permita variables arbitrarias
        # en la linea de comandos (env_check/env_delete/setenv), y es la misma
        # que ya se usa mas abajo con omarchy-provision-user.
        sudo env OMARCHY_PATH="$OMARCHY_SHARE" OMARCHY_INSTALL_USER="${OMARCHY_USER_NAME}" \
            bash "$APPLY_SCRIPT" \
            || echo "Warning: system apply returned non-zero"
        rm -f "$APPLY_SCRIPT"
    else
        echo "Warning: $OMARCHY_SHARE/install/helpers/logging.sh not found; skipping system apply."
    fi

    # --- User configuration ---
    echo ""
    echo "Configuring user..."

    # Run user provisioning as the target user (NOT root).
    # --force only — --first-install forces OMARCHY_SETUP_CONTEXT=iso-chroot,
    # which hard-fails on a missing /opt/packages Node tarball.
    USER_HOME=$(getent passwd "$OMARCHY_USER_NAME" | cut -d: -f6)
    if command -v omarchy-provision-user &>/dev/null && [ -n "$USER_HOME" ]; then
        echo "Running omarchy-provision-user --force as $OMARCHY_USER_NAME..."
        sudo -u "$OMARCHY_USER_NAME" env \
            HOME="$USER_HOME" \
            OMARCHY_PATH="$OMARCHY_SHARE" \
            OMARCHY_INSTALL="$OMARCHY_SHARE/install" \
            omarchy-provision-user --force \
            || echo "Warning: omarchy-provision-user returned non-zero"
    elif [ -f "$OMARCHY_SHARE/bin/omarchy-provision-user" ]; then
        echo "Running $OMARCHY_SHARE/bin/omarchy-provision-user --force..."
        sudo -u "$OMARCHY_USER_NAME" env \
            HOME="$USER_HOME" \
            OMARCHY_PATH="$OMARCHY_SHARE" \
            OMARCHY_INSTALL="$OMARCHY_SHARE/install" \
            bash "$OMARCHY_SHARE/bin/omarchy-provision-user" --force \
            || echo "Warning: omarchy-provision-user returned non-zero"
    fi

    # User configs ship via /etc/skel — copy to home so the current account
    # gets them now
    if [ -d /etc/skel ]; then
        echo "Copying /etc/skel to $USER_HOME..."
        sudo -u "$OMARCHY_USER_NAME" cp -af /etc/skel/. "$USER_HOME/"
    fi

    # Neutralize broken omarchy-hyprland-titlebars migration (1791403310.sh).
    # In CachyOS, hyprland is 0.57+ while pkgs.omarchy.org pins 0.56.2,
    # which causes omarchy-migrate to fail and abort omarchy update.
    if [ -n "${USER_HOME:-}" ]; then
        sudo -u "$OMARCHY_USER_NAME" mkdir -p "$USER_HOME/.local/state/omarchy/migrations"
        sudo -u "$OMARCHY_USER_NAME" touch "$USER_HOME/.local/state/omarchy/migrations/1791403310.sh"
    fi

    # Optimize AUR package download speeds with aria2c parallel streams
    if command -v aria2c &>/dev/null && [ -n "${USER_HOME:-}" ]; then
        sudo -u "$OMARCHY_USER_NAME" mkdir -p "$USER_HOME/.config/pacman"
        local MAKEPKG_CONF="$USER_HOME/.config/pacman/makepkg.conf"
        if [ ! -f "$MAKEPKG_CONF" ]; then
            sudo -u "$OMARCHY_USER_NAME" tee "$MAKEPKG_CONF" >/dev/null << 'MKEOF'
# Generated by omarchy-on-cachyos: parallel AUR downloads using aria2c
DLAGENTS=('file::/usr/bin/curl -qgC - -o %o %u'
          'ftp::/usr/bin/curl -qgfC - --ftp-pasv --retry 3 --retry-delay 3 -o %o %u'
          'http::/usr/bin/aria2c -UWget -s 16 -x 16 -k 1M --allow-overwrite=true -o %o %u'
          'https::/usr/bin/aria2c -UWget -s 16 -x 16 -k 1M --allow-overwrite=true -o %o %u'
          'rsync::/usr/bin/rsync --no-motd -z %u %o'
          'scp::/usr/bin/scp -C %u %o')
MKEOF
        fi
    fi

    # --- SDDM login ---
    # The Omarchy SDDM theme has no username field; it logs in the last user
    # via state.conf. Regex-averse: state.conf must exist and name the user,
    # and autologin uses the omarchy desktop entry (not hyprland).
    echo ""
    echo "Configuring SDDM login..."
    sudo mkdir -p /var/lib/sddm
    printf '[Last]\nSession=omarchy.desktop\nUser=%s\n' "$OMARCHY_USER_NAME" \
        | sudo tee /var/lib/sddm/state.conf > /dev/null
    sudo chown -R sddm:sddm /var/lib/sddm 2>/dev/null || true

    sudo mkdir -p /etc/sddm.conf.d
    printf '[Autologin]\nUser=%s\nSession=omarchy.desktop\n' "$OMARCHY_USER_NAME" \
        | sudo tee /etc/sddm.conf.d/autologin.conf > /dev/null
    echo "SDDM autologin configured for $OMARCHY_USER_NAME (omarchy.desktop)."

    # --- Boot entries ---
    # Deliberately do NOT call omarchy-refresh-limine or omarchy-refresh-plymouth:
    # they replace limine.conf with a theming-only template and rebuild the
    # initramfs, bypassing the CachyOS hooks guard. CachyOS's limine-snapper-sync
    # + our /etc/default/limine guard keep the real boot entries correct.

    # --- CachyOS compatibility guards and hooks ---
    echo ""
    echo "Installing CachyOS update safety guards..."
    if [ -f "$SCRIPT_DIR/omarchy-qt-color-fix.sh" ]; then
        sudo install -m 755 "$SCRIPT_DIR/omarchy-qt-color-fix.sh" /usr/local/bin/omarchy-qt-color-fix.sh
        sudo install -Dm 644 "$SCRIPT_DIR/omarchy-qt-color-fix.hook" /etc/pacman.d/hooks/omarchy-qt-color-fix.hook
        sudo /usr/local/bin/omarchy-qt-color-fix.sh
    fi

    if [ -f "$SCRIPT_DIR/cachyos-mirror-order.sh" ]; then
        sudo install -m 755 "$SCRIPT_DIR/cachyos-mirror-order.sh" /usr/local/bin/cachyos-mirror-order.sh
        sudo install -Dm 644 "$SCRIPT_DIR/omarchy-mirror-order.service" /etc/systemd/system/omarchy-mirror-order.service
        sudo install -Dm 644 "$SCRIPT_DIR/omarchy-mirror-order.hook" /etc/pacman.d/hooks/omarchy-mirror-order.hook
        sudo install -Dm 644 "$SCRIPT_DIR/cachyos-rate-mirrors.service.d/omarchy-mirror-order.conf" \
            /etc/systemd/system/cachyos-rate-mirrors.service.d/omarchy-mirror-order.conf
        sudo systemctl daemon-reload
        sudo /usr/local/bin/cachyos-mirror-order.sh
    fi

    # --- Summary ---
    echo ""
    echo "=========================================="
    echo "  Omarchy v4.x installation complete!     "
    echo "=========================================="
    echo ""
    echo "  - Packages installed via pacman"
    echo "  - Boot safety guards active (mkinitcpio + limine)"
    echo "  - SDDM configured for $OMARCHY_USER_NAME (omarchy.desktop)"
    echo "  - NVIDIA driver configured (CachyOS-aware)"
    echo ""
    echo "You may need to reboot for all changes to take effect."
    echo ""
}

# ============================================================================
# Branch: v3 (source) or v4 (packages)
# Note: dispatched AFTER function definitions so both branches resolve.
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
