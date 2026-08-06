#!/bin/bash

# Target destination (relative to this script's location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$SCRIPT_DIR/../../omarchy"
REPO_URL="https://github.com/basecamp/omarchy"

# Report what is actually checked out in a directory, so a re-run shows the
# user what they are about to delete and what they ended up with.
describe_checkout() {
    local dir="$1" desc=""

    if [ -d "$dir/.git" ]; then
        desc="$(git -C "$dir" describe --tags --exact-match 2>/dev/null)"
        [ -z "$desc" ] && desc="$(git -C "$dir" symbolic-ref --short -q HEAD)"
        [ -z "$desc" ] && desc="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
    fi

    [ -r "$dir/version" ] && desc="${desc:-unknown} (version $(<"$dir/version"))"

    echo "${desc:-not a git checkout}"
}

# Deal with an existing checkout first. Asking for a version before knowing
# whether a clone will even happen invites the user to skip past the version
# prompt on a re-run, which used to mean "silently install master".
if [ -d "$TARGET_DIR" ]; then
    echo ""
    echo "⚠️  Warning: An existing installation directory was found at $TARGET_DIR"
    echo "    Currently checked out: $(describe_checkout "$TARGET_DIR")"
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

# Fetch available stable version tags from the remote repository cleanly
echo "Fetching available stable releases from GitHub..."
RELEASES=($(git ls-remote --tags --refs $REPO_URL 2>/dev/null | awk -F/ '{print $3}' | sort -rV | head -n 5))

# No tags means the remote could not be reached. Carrying on would offer only
# "bleeding edge" and hand the user master without them asking for it.
if [ ${#RELEASES[@]} -eq 0 ]; then
    echo "Error: Could not fetch release tags from $REPO_URL."
    echo "Check your network connection and try again."
    exit 1
fi

echo "-----------------------------------------------"
echo "Select the Omarchy version you want to install:"
echo "-----------------------------------------------"
echo "1) Bleeding Edge (master branch - Unstable)"

# Dynamically list the stable versions fetched from the repository
for i in "${!RELEASES[@]}"; do
    echo "$((i+2))) Stable Release (${RELEASES[i]})"
done

MAX_CHOICE=$(( ${#RELEASES[@]} + 1 ))

# Keep asking until the answer is a number in range. Every fall-through default
# here lands on the wrong tree, so there is no safe answer but a valid one.
while true; do
    if ! read -r -p "Enter your choice (1-$MAX_CHOICE): " CHOICE; then
        echo ""
        echo "Error: No input available for the version prompt."
        exit 1
    fi

    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$MAX_CHOICE" ]; then
        break
    fi

    echo "Invalid selection '$CHOICE'. Enter a number between 1 and $MAX_CHOICE."
done

# Formulate arguments based on selection
if [ "$CHOICE" -eq 1 ]; then
    CLONE_ARGS=(-b master)
    echo "Cloning bleeding-edge master tree..."
else
    SELECTED_TAG="${RELEASES[$((CHOICE-2))]}"
    CLONE_ARGS=(--depth 1 -b "$SELECTED_TAG")
    echo "Cloning stable version: $SELECTED_TAG..."
fi

# Execute clean, quiet checkout bypassing standard detached HEAD advice warnings
echo "Cloning into $TARGET_DIR..."
if ! git -c advice.detachedHead=false clone --quiet "${CLONE_ARGS[@]}" "$REPO_URL" "$TARGET_DIR"; then
    echo "Error: Failed to clone Omarchy repo."
    exit 1
fi

echo "Successfully cloned Omarchy repository layout."
echo "Checked out: $(describe_checkout "$TARGET_DIR")"
