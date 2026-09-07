#!/bin/bash
# boot-guards.sh — Protect CachyOS bootloader and initramfs from omarchy-settings
#
# Must run BEFORE installing omarchy-settings. Creates override configs that
# survive omarchy-settings upgrades because they sort later (zz-) or are read last.
#
# Safe to run multiple times (idempotent).

set -euo pipefail

echo "[boot-guards] Installing CachyOS boot safety guards..."

# --- 1. mkinitcpio guard ---
# omarchy-settings drops /etc/mkinitcpio.conf.d/omarchy_hooks.conf which replaces
# the HOOKS array with legacy udev/encrypt hooks, breaking systemd-based CachyOS.
# At this point omarchy-settings is NOT installed yet, so the effective HOOKS
# below are the true CachyOS ones. We capture them and re-emit them with a
# zz- drop-in that sorts after omarchy_hooks.conf (later wins).

MKINITCPIO_DIR="/etc/mkinitcpio.conf.d"
GUARD_FILE="$MKINITCPIO_DIR/zz-cachyos-restore-hooks.conf"

# The guard is a SNAPSHOT of the pre-omarchy state. It is created once and
# never rewritten afterwards, so a later re-run while omarchy-settings is
# installed cannot capture omarchy's broken HOOKS and overwrite it.

# Detect whether the omarchy legacy-hooks config is already present
OMARCHY_HOOKS_ACTIVE=false
if [ -f "$MKINITCPIO_DIR/omarchy_hooks.conf" ]; then
    OMARCHY_HOOKS_ACTIVE=true
elif [ -f /etc/mkinitcpio.conf ]; then
    # Also detect if effective hooks lost the systemd initramfs (legacy uid)
    EFFECTIVE_LEGACY=false
    ( HOOKS=()
      . /etc/mkinitcpio.conf 2>/dev/null
      for f in /etc/mkinitcpio.conf.d/*.conf; do
          [ -e "$f" ] || continue
          . "$f" >/dev/null 2>&1
      done
      case " ${HOOKS[*]} " in
          *" systemd "*) exit 0 ;;
          *) exit 1 ;;
      esac ) 2>/dev/null && EFFECTIVE_LEGACY=false || EFFECTIVE_LEGACY=true
    if [ "$EFFECTIVE_LEGACY" = true ]; then
        OMARCHY_HOOKS_ACTIVE=true
    fi
fi

if [ -f "$GUARD_FILE" ]; then
    echo "[boot-guards] mkinitcpio guard already present: $GUARD_FILE"
    echo "[boot-guards]   $(tr -d '\n' < "$GUARD_FILE")"
elif [ "$OMARCHY_HOOKS_ACTIVE" = true ]; then
    echo "[boot-guards] WARNING: omarchy legacy hooks already active and no guard exists."
    echo "[boot-guards] Refusing to guess a snapshot. Run this BEFORE installing omarchy-settings."
    exit 1
else
    # Compute the effective HOOKS (mkinitcpio.conf + all drop-ins in sort order),
    # which at this point are the true CachyOS ones since omarchy isn't installed.
    HOOKS=()
    if [ -f /etc/mkinitcpio.conf ]; then
        . /etc/mkinitcpio.conf
        for f in /etc/mkinitcpio.conf.d/*.conf; do
            [ -e "$f" ] || continue
            . "$f" >/dev/null 2>&1
        done
    fi

    if [ -n "${HOOKS[*]:-}" ]; then
        echo "[boot-guards] Capturing effective HOOKS: ${HOOKS[*]}"
        # Re-emit as a plain assignment (omarchy_hooks.conf used a plain assignment,
        # so our zz- file must too, but sorting later makes ours win).
        HOOKS_LINE="HOOKS=(${HOOKS[*]})"
    else
        # No mkinitcpio.conf present — fall back to the known CachyOS systemd layout
        echo "[boot-guards] No /etc/mkinitcpio.conf found; using known CachyOS systemd layout."
        HOOKS_LINE="HOOKS=(base systemd autodetect microcode kms modconf block keyboard sd-vconsole plymouth sd-encrypt filesystems sd-btrfs-overlayfs)"
    fi

    sudo mkdir -p "$MKINITCPIO_DIR"
    echo "$HOOKS_LINE" | sudo tee "$GUARD_FILE" > /dev/null
    echo "[boot-guards] Wrote $GUARD_FILE"
    echo "    $HOOKS_LINE"
fi

# --- 2. limine guard ---
# omarchy-settings drops files in /etc/limine-entry-tool.d/ that override boot
# entry generation (TARGET_OS_NAME, ENABLE_UKI, BOOT_ORDER).
# /etc/default/limine is read last by load_config() in limine-common-functions.
# Same snapshot semantics as the mkinitcpio guard: create once, never overwrite.

LIMINE_DEFAULT="/etc/default/limine"

# An existing /etc/default/limine is not a guard by itself — it usually comes
# pre-seeded by CachyOS without TARGET_OS_NAME/ENABLE_UKI, keys that only
# omarchy-settings would override via /etc/limine-entry-tool.d/. Since
# /etc/default/limine is read LAST, we ensure our guard keys are present.
LIMINE_OVERRIDE_SECTION="# CachyOS boot guard (omarchy-settings override)"

if [ -d /etc/limine-entry-tool.d ] && \
   grep -qE 'TARGET_OS_NAME|ENABLE_UKI|BOOT_ORDER|CUSTOM_UKI_NAME' /etc/limine-entry-tool.d/*.conf 2>/dev/null; then
    echo "[boot-guards] WARNING: omarchy limine configs already present."
    echo "[boot-guards] Refusing to guess defaults. Run this BEFORE installing omarchy-settings."
    exit 1
fi

# Detect current values from the generated limine.conf (best source of truth)
CURRENT_OS="CachyOS"
BOOT_ORDER='*, *lts, *fallback, Snapshots'
if [ -r /boot/limine.conf ]; then
    OS_RAW=$(grep -oP '(?<=description:\s).*' /boot/limine.conf 2>/dev/null | head -n1 || true)
    [ -n "$OS_RAW" ] && CURRENT_OS="$OS_RAW"
    ORD_RAW=$(grep -oP '(?<=^set\s+BOOT_ORDER:\s).*' /boot/limine.conf 2>/dev/null | head -n1 || true)
    [ -n "$ORD_RAW" ] && BOOT_ORDER="$ORD_RAW"
fi
# If a pre-seeded /etc/default/limine declares BOOT_ORDER, defer to it
if [ -f "$LIMINE_DEFAULT" ]; then
    EXISTING_BOOT_ORDER=$(grep -oP '^BOOT_ORDER="\K[^"]+' "$LIMINE_DEFAULT" 2>/dev/null | head -n1 || true)
    [ -n "$EXISTING_BOOT_ORDER" ] && BOOT_ORDER="$EXISTING_BOOT_ORDER"
fi

echo "[boot-guards] Limine: TARGET_OS_NAME=$CURRENT_OS, BOOT_ORDER=$BOOT_ORDER"

# Ensure guard keys are present (append a well-marked section if needed)
NEED_LIMINE=false
if [ -f "$LIMINE_DEFAULT" ]; then
    grep -qF "TARGET_OS_NAME=\"$CURRENT_OS\"" "$LIMINE_DEFAULT" 2>/dev/null || NEED_LIMINE=true
    grep -qF "ENABLE_UKI=no" "$LIMINE_DEFAULT" 2>/dev/null || NEED_LIMINE=true
else
    NEED_LIMINE=true
fi

if [ "$NEED_LIMINE" = true ]; then
    sudo mkdir -p /etc/default
    if [ -f "$LIMINE_DEFAULT" ]; then
        # Append the guard keys to the existing file
        sudo tee -a "$LIMINE_DEFAULT" > /dev/null << LIMINEEOF

$LIMINE_OVERRIDE_SECTION
TARGET_OS_NAME="$CURRENT_OS"
ENABLE_UKI=no
BOOT_ORDER="$BOOT_ORDER"
LIMINEEOF
        echo "[boot-guards] Appended guard keys to existing $LIMINE_DEFAULT"
    else
        sudo tee "$LIMINE_DEFAULT" > /dev/null << LIMINEEOF
# CachyOS boot guard — overrides omarchy-settings limine-entry-tool.d configs
# Written by boot-guards.sh — safe to regenerate
TARGET_OS_NAME="$CURRENT_OS"
ENABLE_UKI=no
BOOT_ORDER="$BOOT_ORDER"
LIMINEEOF
        echo "[boot-guards] Wrote new $LIMINE_DEFAULT"
    fi
else
    echo "[boot-guards] limine guard keys already present."
fi

echo "[boot-guards] Boot safety guards installed successfully."
echo "[boot-guards] These guards survive omarchy-settings upgrades."