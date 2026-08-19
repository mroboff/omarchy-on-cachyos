#!/bin/bash

set -euo pipefail

# Target destination (relative to this script's location)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$SCRIPT_DIR/../../omarchy"
REPO_URL="https://github.com/basecamp/omarchy"

# Pinned Omarchy version. This is deliberately a single constant and not a
# menu: the installer patches the cloned tree by matching exact upstream text,
# so a patch set is only ever valid against one tree. Offering a choice of tags
# guaranteed silent breakage on every tag but one.
#
# It must stay on 3.x. Omarchy 4.x (quattro) removed the entire install/ tree
# and install.sh - its packages are pacstrapped from an ISO instead - so every
# patch in the installer targets paths that no longer exist there. The
# supported path is: install CachyOS -> install Omarchy 3.x with these scripts
# -> upgrade in place to 4.x afterwards using Omarchy's own updater.
OMARCHY_VERSION="v3.8.4"

# Note: upstream forgot to bump the version file for this release. The tree at
# tag v3.8.4 ships a `version` file containing "3.8.3" (v3.8.2 and v3.8.3 are
# both correct, so this is specific to v3.8.4). The checkout really is v3.8.4 -
# only the string is stale - so anything reading that file, including Omarchy's
# own greeting, reports 3.8.3. That is upstream's to fix, not ours.

# Report what is actually checked out in a directory, so a re-run shows the
# user what they are about to delete and what they ended up with.
describe_checkout() {
    local dir="$1" desc=""

    if [ -d "$dir/.git" ]; then
        # Each of these exits non-zero in the normal case where the previous
        # one already answered, so they need explicit fallbacks under set -e.
        desc="$(git -C "$dir" describe --tags --exact-match 2>/dev/null || true)"
        [ -n "$desc" ] || desc="$(git -C "$dir" symbolic-ref --short -q HEAD || true)"
        [ -n "$desc" ] || desc="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || true)"
    fi

    # This used to be a trailing `[ -r ... ] && desc=...`, which made the
    # function's exit status depend on whether a version file existed. Harmless
    # before, fatal under set -e, so branch explicitly instead.
    if [ -r "$dir/version" ]; then
        desc="${desc:-unknown} (version $(<"$dir/version"))"
    fi

    echo "${desc:-not a git checkout}"
}

# The exact tag at HEAD, or empty when the checkout is not sitting on a tag.
checkout_tag() {
    [ -d "$1/.git" ] || return 0
    git -C "$1" describe --tags --exact-match 2>/dev/null || true
}

# Deal with an existing checkout first. Asking for a version before knowing
# whether a clone will even happen invites the user to skip past the version
# prompt on a re-run, which used to mean "silently install master".
if [ -d "$TARGET_DIR" ]; then
    echo ""
    echo "⚠️  Warning: An existing installation directory was found at $TARGET_DIR"
    echo "    Currently checked out: $(describe_checkout "$TARGET_DIR")"
    echo "    This script installs $OMARCHY_VERSION."
    if ! read -r -p "Would you like to delete it and proceed with a clean install? [y/N]: " CONFIRM; then
        echo ""
        echo "Error: No input available for the cleanup prompt."
        exit 1
    fi

    if [[ "${CONFIRM,,}" =~ ^(y|yes)$ ]]; then
        echo "Cleaning up previous installation files at $TARGET_DIR..."
        rm -rf "$TARGET_DIR"
    else
        # Keeping the tree means the installer patches whatever is already
        # there. That is only safe when it is the pinned tag: the patches match
        # exact v3.8.4 text, and a 4.x tree has no install/ directory at all.
        EXISTING_TAG="$(checkout_tag "$TARGET_DIR")"
        if [ "$EXISTING_TAG" != "$OMARCHY_VERSION" ]; then
            echo ""
            echo "Error: the existing checkout is not $OMARCHY_VERSION."
            echo "       Found: $(describe_checkout "$TARGET_DIR")"
            echo "       The CachyOS patches only apply to $OMARCHY_VERSION, so keeping this"
            echo "       tree would either fail to patch or produce a broken install."
            echo "       Re-run and answer 'y' to replace it with a clean $OMARCHY_VERSION clone."
            exit 1
        fi
        echo "Proceeding with existing $OMARCHY_VERSION files in $TARGET_DIR..."
        # If user chooses not to delete, we should skip the clone but continue the script
        exit 0
    fi
fi

# Confirm the pinned tag still exists on the remote before cloning, so an
# unreachable network or a withdrawn tag fails here with a clear message rather
# than somewhere inside git's clone output.
echo "Checking that $OMARCHY_VERSION is available on $REPO_URL..."
if ! REMOTE_TAG="$(git ls-remote --tags --refs "$REPO_URL" "refs/tags/$OMARCHY_VERSION" 2>/dev/null)"; then
    echo "Error: Could not reach $REPO_URL."
    echo "Check your network connection and try again."
    exit 1
fi

# No matching ref means the pinned 3.x tag is gone. There is no safe fallback:
# master and every 4.x release dropped install/, so cloning either of those
# would hand the user a tree this project cannot install.
if [ -z "$REMOTE_TAG" ]; then
    echo "Error: tag $OMARCHY_VERSION was not found in $REPO_URL."
    echo "       This project only supports Omarchy 3.x. It will not fall back to"
    echo "       master or to any 4.x release, which removed install/ entirely."
    exit 1
fi

# Execute clean, quiet checkout bypassing standard detached HEAD advice warnings.
#
# Deliberately NOT shallow. `--depth` implies `--single-branch`, which leaves
# the clone with `remote.origin.fetch = +refs/tags/vX:refs/tags/vX` and no
# remote-tracking branches at all. Omarchy's own tooling then breaks in two
# ways: `omarchy-branch-set master` (reached via `omarchy-channel-set stable`)
# runs `git switch master` and dies with "fatal: invalid reference: master",
# and `omarchy-update` runs `git pull --autostash`, which reports "Already up
# to date." forever instead of updating. Since the whole point of pinning 3.x
# is to upgrade in place to 4.x afterwards, the clone has to carry the branches
# that upgrade needs. A full clone keeps origin/master and every tag available.
echo "Cloning stable version: $OMARCHY_VERSION..."
echo "Cloning into $TARGET_DIR..."
if ! git -c advice.detachedHead=false clone --quiet -b "$OMARCHY_VERSION" "$REPO_URL" "$TARGET_DIR"; then
    echo "Error: Failed to clone Omarchy repo."
    exit 1
fi

echo "Successfully cloned Omarchy repository layout."
echo "Checked out: $(describe_checkout "$TARGET_DIR")"
