#!/bin/bash

set -euo pipefail

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
    # There is no safe fallback here. A bare `git clone` with no -b lands on
    # master, which is now 4.x: no install/ tree, no install.sh, and none of
    # the paths the patches below touch. Fail loudly instead.
    echo "Error: fetch-omarchy.sh not found next to this script at $SCRIPT_DIR."
    echo "       It pins the supported Omarchy version, and cloning without it"
    echo "       would check out master (4.x), which this installer cannot patch."
    exit 1
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

# Receive the Omarchy signing key. Keyserver fetches fail transiently often
# enough to be worth retrying, but never worth continuing without: a missing
# key surfaces much later as signature verification failures on every omarchy
# package, which is a far harder failure to read than stopping here.
#
# Full fingerprint and explicit keyserver, matching what Omarchy's own
# install/preflight/pacman.sh uses. The short long-id resolved to the same key,
# but leaving the keyserver to the local default is a common source of the
# transient failures the retry below exists to absorb.
OMARCHY_KEY="40DFB630FF42BCFFB047046CF0134EE680CAC571"
OMARCHY_KEYSERVER="keys.openpgp.org"
for attempt in 1 2 3; do
    if sudo pacman-key --recv-keys "$OMARCHY_KEY" --keyserver "$OMARCHY_KEYSERVER"; then
        break
    fi

    if [ "$attempt" -eq 3 ]; then
        echo "" >&2
        echo "Error: could not receive the Omarchy signing key $OMARCHY_KEY after 3 attempts." >&2
        echo "       Check network and keyserver access, then re-run." >&2
        exit 1
    fi

    echo "Keyserver fetch failed (attempt $attempt/3). Retrying in $((attempt * 5))s..."
    sleep "$((attempt * 5))"
done

# Locally sign and trust the key
sudo pacman-key --lsign-key "$OMARCHY_KEY"

# Add omarchy repository to pacman.conf (skip if already present).
# The /stable/ channel is named explicitly, matching Omarchy's own
# default/pacman/pacman-stable.conf. The channel-less https://pkgs.omarchy.org/$arch
# currently serves a byte-identical database, but that is an undocumented alias
# rather than a published path, so relying on it is a needless dependency.
if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
    echo -e "\n[omarchy]\nSigLevel = Optional TrustedOnly\nServer = https://pkgs.omarchy.org/stable/\$arch" | sudo tee -a /etc/pacman.conf > /dev/null
else
    echo "Omarchy repository already present in pacman.conf, skipping."
fi
sudo pacman -Syu

# Install the Omarchy keyring explicitly, because nothing else will.
#
# Both pacman.sh runs are removed from the install flow below, and the reason is
# post-install/pacman.sh: it does `cp -f` of Omarchy's own pacman.conf and
# mirrorlist over the user's, which would erase the CachyOS repositories
# outright. preflight/pacman.sh copies the same files and is additionally
# wrapped in `if [[ -n ${OMARCHY_ONLINE_INSTALL:-} ]]`, so it never runs here
# anyway - which means it is also never the thing that installs the keyring.
# Neither path leaves the keyring installed, so without this line the key is
# only recv/lsigned by hand and the package itself is simply absent.
sudo pacman -S --needed --noconfirm omarchy-keyring

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

# --- patch assertions --------------------------------------------------------
# Every patch below rewrites upstream text by hand, and that fails in two ways
# sed reports as success. The target file may be gone, and the target text may
# have moved upstream - in which case sed exits 0 having changed nothing and the
# install proceeds with the CachyOS conflict unresolved. So each patch asserts
# its precondition before running and verifies the result afterwards, and any
# failure aborts rather than leaving a half-patched tree.

patch_fail() {
    echo "" >&2
    echo "Error: patch '$1' failed on $2" >&2
    echo "       $3" >&2
    echo "       Upstream has most likely moved. Aborting before a partial install." >&2
    exit 1
}

require_file() {
    [ -f "$2" ] || patch_fail "$1" "$2" "target file does not exist"
}

require_text() {
    grep -qF -- "$3" "$2" || patch_fail "$1" "$2" "expected text not found: $3"
}

require_absent() {
    if grep -qF -- "$3" "$2"; then
        patch_fail "$1" "$2" "text should be gone but is still present: $3"
    fi
}

# Pure-deletion patches. The goal state is "line gone", so a missing target
# means the goal is already met and there is nothing to fail on - whether
# upstream dropped the line or a previous run removed it, which also makes
# these re-run safe. The tolerance is deliberately limited to deletions: a
# substitution that matches nothing leaves the old behaviour running, so those
# still abort.
delete_line() {
    local name="$1" file="$2" text="$3" pattern="$4"
    require_file "$name" "$file"
    if grep -qF -- "$text" "$file"; then
        sed -i "/$pattern/d" "$file"
        require_absent "$name" "$file" "$text"
        echo "  - $name: applied"
    else
        echo "  - $name: already absent, nothing to remove"
    fi
}

# Remove tldr installation to prevent conflict with tealdeer install.
delete_line "remove tldr" "install/omarchy-base.packages" "tldr" "tldr"

# Kernel restart detection needs no patch: since v3.4.0 upstream resolves the
# running kernel from /usr/lib/modules/*/vmlinuz via `pacman -Qo`, which matches
# linux-cachyos generically. The old `pacman -Q linux` hardcode is gone.

# Remove pacman.sh from preflight/all.sh to prevent conflict with cachyos packages
# $OMARCHY_INSTALL is literal text inside Omarchy's scripts, not a variable of
# ours, so it must not expand here or in any of the deletions that follow.
# shellcheck disable=SC2016
delete_line "remove preflight pacman.sh" "install/preflight/all.sh" \
    'run_logged $OMARCHY_INSTALL/preflight/pacman.sh' \
    'run_logged \$OMARCHY_INSTALL\/preflight\/pacman\.sh'

# Replace nvidia.sh with custom CachyOS 580xx Driver Logic
NVIDIA_PATCH="replace nvidia.sh"
NVIDIA_MARKER="--- NVIDIA Configuration for Omarchy on CachyOS ---"
require_file "$NVIDIA_PATCH" "$SCRIPT_DIR/nvidia.sh"
require_file "$NVIDIA_PATCH" "install/config/hardware/nvidia.sh"
require_text "$NVIDIA_PATCH" "$SCRIPT_DIR/nvidia.sh" "$NVIDIA_MARKER"
cp "$SCRIPT_DIR/nvidia.sh" install/config/hardware/nvidia.sh
chmod +x install/config/hardware/nvidia.sh
require_text "$NVIDIA_PATCH" "install/config/hardware/nvidia.sh" "$NVIDIA_MARKER"
echo "  - $NVIDIA_PATCH: applied"

# No omarchy-ai-skill.sh patch is needed. Upstream switched the symlinks to
# `ln -sfn` in v3.8.0, so they are already idempotent on re-runs. The old
# `s/ln -s/ln -sf/` rewrite now only mangles the existing flags.

# Remove plymouth.sh source line from install.sh
# shellcheck disable=SC2016
delete_line "remove plymouth.sh" "install/login/all.sh" \
    'run_logged $OMARCHY_INSTALL/login/plymouth.sh' \
    'run_logged \$OMARCHY_INSTALL\/login\/plymouth\.sh'

# Remove limine-snapper.sh source line from install.sh
# shellcheck disable=SC2016
delete_line "remove limine-snapper.sh" "install/login/all.sh" \
    'run_logged $OMARCHY_INSTALL/login/limine-snapper.sh' \
    'run_logged \$OMARCHY_INSTALL\/login\/limine-snapper\.sh'

# No alt-bootloaders.sh patch is needed. Upstream dropped that line from
# install/login/all.sh in v3.1.0, so there is nothing left to remove.

# Remove pacman.sh from post-install/all.sh to prevent conflict with cachyos packages
# shellcheck disable=SC2016
delete_line "remove post-install pacman.sh" "install/post-install/all.sh" \
    'run_logged $OMARCHY_INSTALL/post-install/pacman.sh' \
    'run_logged \$OMARCHY_INSTALL\/post-install\/pacman\.sh'

# Disable wpa_supplicant and configure NetworkManager to use iwd backend.
# CachyOS enables wpa_supplicant by default, which conflicts with omarchy's iwd,
# causing WiFi to appear connected but have no IP or connectivity.
NETWORK_PATCH="network iwd backend"
NETWORK_FILE="install/config/hardware/network.sh"
NETWORK_MARKER="wifi.backend=iwd"
require_file "$NETWORK_PATCH" "$NETWORK_FILE"
# fetch-omarchy.sh has a path that keeps an existing checkout, so this can run
# over an already-patched tree. Append once, or the block is duplicated on
# every re-run.
if ! grep -qF -- "$NETWORK_MARKER" "$NETWORK_FILE"; then
    cat >> "$NETWORK_FILE" << 'NETEOF'

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
    echo "  - $NETWORK_PATCH: applied"
else
    echo "  - $NETWORK_PATCH: already applied, skipping"
fi
require_text "$NETWORK_PATCH" "$NETWORK_FILE" "$NETWORK_MARKER"

# Freeze walker so CachyOS cannot move it to a version incompatible with
# elephant.
#
# Note what IgnorePkg actually does: it excludes walker from upgrades against
# every repository, omarchy's included - it does not bind walker to the omarchy
# repo, despite what this patch used to claim. Whatever version is installed
# when the pin lands is the version that stays until someone removes it.
#
# As of now the guard is precautionary rather than corrective: CachyOS and the
# omarchy stable channel both ship walker 2.17.0-1, so there is nothing to
# diverge from yet. It exists to catch future divergence, and the cost is that
# walker stops receiving updates entirely.
WALKER_PATCH="pin walker"
WALKER_FILE="install/config/walker-elephant.sh"
WALKER_MARKER="# Pin walker to omarchy repo to prevent CachyOS version conflict"
require_file "$WALKER_PATCH" "$WALKER_FILE"
# The insertion is positional ('1a'), so the only precondition that means
# anything is that line 1 really is the shebang. If upstream ever adds a line
# above it, this would splice the block into the middle of the script.
if [ "$(sed -n '1p' "$WALKER_FILE")" != "#!/bin/bash" ]; then
    patch_fail "$WALKER_PATCH" "$WALKER_FILE" \
        "line 1 is not '#!/bin/bash', so the '1a' insertion would land in the wrong place"
fi
# Guarded for the same re-run reason as network.sh above.
if ! grep -qF -- "$WALKER_MARKER" "$WALKER_FILE"; then
    sed -i '1a\
# Pin walker to omarchy repo to prevent CachyOS version conflict\
if ! grep -q "^IgnorePkg.*walker" /etc/pacman.conf 2>/dev/null; then\
  if grep -q "^IgnorePkg" /etc/pacman.conf; then\
    sudo sed -i '"'"'s/^IgnorePkg = \\(.*\\)/IgnorePkg = \\1 walker/'"'"' /etc/pacman.conf\
  else\
    sudo sed -i '"'"'/^\\[options\\]/a IgnorePkg = walker'"'"' /etc/pacman.conf\
  fi\
fi\
' "$WALKER_FILE"
    echo "  - $WALKER_PATCH: applied"
else
    echo "  - $WALKER_PATCH: already applied, skipping"
fi
require_text "$WALKER_PATCH" "$WALKER_FILE" "$WALKER_MARKER"

# No mise patch is needed. Omarchy's config/uwsm/env activates mise with
# --shims, which exports a PATH entry that every process in the session
# inherits, and default/bash/init activates it for interactive bash. With bash
# as the login shell both paths are covered by Omarchy itself.

# Copy omarchy installation files to ~/.local/share/omarchy
OMARCHY_DEST="$HOME/.local/share/omarchy"
PATCH_COMMIT_MSG="CachyOS compatibility patches"

# Refuse to copy over an unrelated checkout. `cp -r .` merges into whatever is
# already there rather than replacing it, and that includes .git: read-only
# pack files fail to overwrite while the old refs and objects survive, so the
# destination ends up neither the old tree nor the new one. A pre-existing
# Omarchy on another branch or major version - a 4.x install tracking dev, say
# - has to be moved aside deliberately, not half-overwritten here.
if [ -d "$OMARCHY_DEST/.git" ]; then
    DEST_HEAD="$(git -C "$OMARCHY_DEST" rev-parse HEAD 2>/dev/null || true)"
    SRC_HEAD="$(git -C "$OMARCHY_DIR" rev-parse HEAD 2>/dev/null || true)"

    # A previous run of this script leaves the patch commit sitting directly on
    # top of the source commit, so the two HEADs legitimately differ. Recognise
    # exactly that shape - our commit subject, parented to the source commit -
    # and treat it as ours. Anything else is someone else's checkout. Matching
    # on the parent matters: a 4.x install has the pinned tag in its history
    # too, so an ancestry test alone would wave it through.
    DEST_IS_OURS=false
    if [ "$DEST_HEAD" = "$SRC_HEAD" ]; then
        DEST_IS_OURS=true
    elif [ "$(git -C "$OMARCHY_DEST" log -1 --format=%s 2>/dev/null || true)" = "$PATCH_COMMIT_MSG" ] &&
        [ "$(git -C "$OMARCHY_DEST" rev-parse -q --verify 'HEAD^' 2>/dev/null || true)" = "$SRC_HEAD" ]; then
        DEST_IS_OURS=true
    fi

    if [ "$DEST_IS_OURS" != "true" ]; then
        DEST_DESC="$(git -C "$OMARCHY_DEST" describe --tags --exact-match 2>/dev/null || true)"
        [ -n "$DEST_DESC" ] || DEST_DESC="$(git -C "$OMARCHY_DEST" symbolic-ref --short -q HEAD || true)"
        [ -n "$DEST_DESC" ] || DEST_DESC="detached HEAD"
        if [ -r "$OMARCHY_DEST/version" ]; then
            DEST_DESC="$DEST_DESC (version $(<"$OMARCHY_DEST/version"))"
        fi

        echo "" >&2
        echo "Error: $OMARCHY_DEST already holds a different Omarchy checkout." >&2
        echo "       Found: $DEST_DESC" >&2
        echo "       Copying over it would merge two trees into one broken repo." >&2
        echo "       Move it aside first, then re-run this script:" >&2
        echo "         mv $OMARCHY_DEST $OMARCHY_DEST.bak" >&2
        exit 1
    fi
fi

mkdir -p "$OMARCHY_DEST"
# -f because git writes pack files mode 444: without it a second run dies with
# "Permission denied" on .git/objects/pack/*, since cp cannot open a read-only
# destination. -f unlinks and recreates instead.
cp -rf . "$OMARCHY_DEST"
cd "$OMARCHY_DEST"

# Commit the CachyOS patches so the checkout is clean.
#
# This is what makes the upgrade to 4.x possible later. The patches are edits to
# tracked files on a detached checkout of the pinned tag, and 4.x deletes the
# whole install/ tree they live in. Left uncommitted they block every route
# forward: `omarchy-update` refuses because HEAD is not on a branch,
# `omarchy-branch-set master` refuses rather than overwrite local changes, and
# `omarchy-update-branch master` stashes, switches, then hits modify/delete
# conflicts on the pop and resurrects a dead install/ tree onto a 4.x checkout.
# Committing costs nothing - the work is already done and the commit stays
# reachable - and leaves `git switch master && omarchy-update` conflict-free.
#
# Identity is passed inline so this does not depend on the user having git
# user.name/user.email configured, and does not write to their global config.
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git -c user.name="omarchy-on-cachyos" \
        -c user.email="omarchy-on-cachyos@localhost" \
        commit -aqm "$PATCH_COMMIT_MSG" \
        && echo "Committed the CachyOS patches so the tree is clean for a later upgrade."
fi

# Pause and prompt for acknowledgment to begin installation
echo ""
echo "The following adjustments have been completed."
echo " 1. Added Omarchy repo to pacman.conf and installed omarchy-keyring."
echo " 2. Removed tldr from install/omarchy-base.packages to avoid conflict with tealdeer on CachyOS."
echo " 3. Disabled further Omarchy changes to pacman.conf, preserving CachyOS settings."
echo " 4. Replaced nvidia.sh to respect existing CachyOS NVIDIA drivers (only installs if none present)."
echo " 5. Removed plymouth.sh from install.sh to avoid conflict with CachyOS login display manager installation."
echo " 6. Removed limine-snapper.sh from install.sh to avoid conflict with CachyOS boot loader installation."
echo " 7. Removed /etc/sddm.conf to avoid conflict with Omarchy UWSM session autologin."
echo " 8. Disabled wpa_supplicant and configured NetworkManager to use iwd backend."
echo " 9. Pinned walker to omarchy repo to prevent CachyOS version conflict."
echo "10. Switched the login shell from fish to bash so Omarchy's shell config is loaded."
echo ""
echo "NOTE: If you installed CachyOS without a desktop environment, you do not need"
echo "to do anything extra. SDDM is part of Omarchy's base package set, and Omarchy's"
echo "install/login/sddm.sh sets up the Omarchy session, enables sddm.service, and"
echo "configures autologin for your user, so the desktop starts on the next boot."
echo ""
echo "To upgrade to Omarchy 4.x later, switch branch and update:"
echo " 1.) omarchy-branch-set master"
echo " 2.) omarchy-update"
echo ""
echo "Do NOT use 'omarchy-channel-set' for this. It also runs omarchy-refresh-pacman,"
echo "which overwrites /etc/pacman.conf with Omarchy's own and removes the CachyOS"
echo "repositories (it backs the old one up to /etc/pacman.conf.bak first)."
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
