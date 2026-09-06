#!/bin/bash

# Target destination (relative to this script's location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$SCRIPT_DIR/../../omarchy"
REPO_URL="https://github.com/basecamp/omarchy"

# Fetch available stable version tags, filtering out pre-releases
echo "Fetching available stable releases from GitHub..."
ALL_TAGS=($(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null | awk -F/ '{print $3}' | sort -rV))

# Filter out pre-release tags (containing -beta, -alpha, -rc, -dev, -pre, -next)
RELEASES=()
for tag in "${ALL_TAGS[@]}"; do
    if [[ ! "$tag" =~ -(beta|alpha|rc|dev|pre|next) ]]; then
        RELEASES+=("$tag")
    fi
done

# Take only the latest 5 stable releases
RELEASES=("${RELEASES[@]:0:5}")

echo "-----------------------------------------------"
echo "Select the Omarchy version you want to install:"
echo "-----------------------------------------------"
echo "1) Bleeding Edge (dev/main branch - Unstable)"

# Dynamically list the stable versions with major version indicator
for i in "${!RELEASES[@]}"; do
    TAG="${RELEASES[i]}"
    MAJOR="${TAG#v}"
    MAJOR="${MAJOR%%.*}"
    if [ "$MAJOR" -ge 4 ] 2>/dev/null; then
        LABEL="Stable Release (${TAG}) [v4 - packages]"
    else
        LABEL="Stable Release (${TAG}) [v3 - source]"
    fi
    echo "$((i+2))) $LABEL"
done

read -r -p "Enter your choice (1-$(( ${#RELEASES[@]} + 1 ))): " CHOICE

# Validate input
if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt $(( ${#RELEASES[@]} + 1 )) ]; then
    echo "Invalid choice. Exiting."
    exit 1
fi

# Formulate arguments based on selection
if [ "$CHOICE" -eq 1 ] || [ -z "$CHOICE" ]; then
    BRANCH_ARGS=""
    SELECTED_TAG=""
    echo "Cloning bleeding-edge dev tree..."
else
    SELECTED_TAG="${RELEASES[$((CHOICE-2))]}"
    BRANCH_ARGS="--depth 1 -b $SELECTED_TAG"
    echo "Cloning stable version: $SELECTED_TAG..."
fi

# Detect major version for installer branching
if [ -n "$SELECTED_TAG" ]; then
    OMARCHY_VERSION_MAJOR="${SELECTED_TAG#v}"
    OMARCHY_VERSION_MAJOR="${OMARCHY_VERSION_MAJOR%%.*}"
else
    # Bleeding edge: check if main branch has v4 structure
    OMARCHY_VERSION_MAJOR="4"
fi

# Export for the installer to use
export OMARCHY_VERSION_MAJOR
export SELECTED_TAG

# Ensure target directory is clean before git cloning to prevent fatal conflicts
if [ -d "$TARGET_DIR" ]; then
    echo ""
    echo "Warning: An existing installation directory was found at $TARGET_DIR"
    read -r -p "Would you like to delete it and proceed with a clean install? [y/N]: " CONFIRM

    if [[ "${CONFIRM,,}" =~ ^(y|yes)$ ]]; then
        echo "Cleaning up previous installation files at $TARGET_DIR..."
        rm -rf "$TARGET_DIR"
    else
        echo "Proceeding with existing files in $TARGET_DIR..."
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
echo "Detected Omarchy major version: $OMARCHY_VERSION_MAJOR"
