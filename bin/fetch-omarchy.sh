#!/bin/bash

# Target destination (relative to this script's location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$SCRIPT_DIR/../../omarchy"
REPO_URL="https://github.com/basecamp/omarchy"

# Fetch available stable version tags from the remote repository cleanly
echo "Fetching available stable releases from GitHub..."
RELEASES=($(git ls-remote --tags --refs $REPO_URL 2>/dev/null | awk -F/ '{print $3}' | sort -rV | head -n 5))

echo "-----------------------------------------------"
echo "Select the Omarchy version you want to install:"
echo "-----------------------------------------------"
echo "1) Bleeding Edge (master branch - Unstable)"

# Dynamically list the stable versions fetched from the repository
for i in "${!RELEASES[@]}"; do
    echo "$((i+2))) Stable Release (${RELEASES[i]})"
done

read -r -p "Enter your choice (1-$(( ${#RELEASES[@]} + 1 ))): " CHOICE

# Formulate arguments based on selection
if [ "$CHOICE" -eq 1 ] || [ -z "$CHOICE" ]; then
    BRANCH_ARGS="-b master"
    echo "Cloning bleeding-edge master tree..."
else
    SELECTED_TAG="${RELEASES[$((CHOICE-2))]}"
    BRANCH_ARGS="--depth 1 -b $SELECTED_TAG"
    echo "Cloning stable version: $SELECTED_TAG..."
fi

# Ensure target directory is clean before git cloning to prevent fatal conflicts
if [ -d "$TARGET_DIR" ]; then
    echo ""
    echo "⚠️  Warning: An existing installation directory was found at $TARGET_DIR"
    read -r -p "Would you like to delete it and proceed with a clean install? [y/N]: " CONFIRM
    
    if [[ "${CONFIRM,,}" =~ ^(y|yes)$ ]]; then
        echo "Cleaning up previous installation files at $TARGET_DIR..."
        rm -rf "$TARGET_DIR"
    else
        echo "Proceeding with existing files in $TARGET_DIR..."
        # If user chooses not to delete, we should skip the clone but continue the script
        exit 0
    fi
fi

# Execute clean, quiet checkout bypassing standard detached HEAD advice warnings
echo "Cloning into $TARGET_DIR..."
if ! git -c advice.detachedHead=false clone --quiet $BRANCH_ARGS $REPO_URL "$TARGET_DIR"; then
    echo "Error: Failed to clone Omarchy repo."
    exit 1
fi

echo "Successfully cloned Omarchy repository layout."
