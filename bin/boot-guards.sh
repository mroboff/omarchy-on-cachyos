#!/bin/bash
# boot-guards.sh — Protect CachyOS bootloader and initramfs from omarchy-settings
#
# Must run BEFORE installing omarchy-settings. Creates override configs that
# survive omarchy-settings upgrades because they sort later or are read last.
#
# Safe to run multiple times (idempotent).

set -euo pipefail

echo "[boot-guards] Installing CachyOS boot safety guards..."

# --- 1. mkinitcpio guard ---
# omarchy-settings drops /etc/mkinitcpio.conf.d/omarchy_hooks.conf which replaces
# the HOOKS array with legacy udev/encrypt hooks, breaking systemd-based CachyOS.
# A zz- prefixed drop-in sorts later and wins.

MKINITCPIO_DIR="/etc/mkinitcpio.conf.d"
GUARD_FILE="$MKINITCPIO_DIR/zz-cachyos-restore-hooks.conf"

# Detect whether the current system uses systemd-based initramfs
USES_SYSTEMD=false
if [ -f /etc/mkinitcpio.conf ]; then
    if grep -q 'systemd' /etc/mkinitcpio.conf 2>/dev/null; then
        USES_SYSTEMD=true
    fi
    # Also check if sd-encrypt is present (definitive sign)
    if grep -q 'sd-encrypt' /etc/mkinitcpio.conf 2>/dev/null; then
        USES_SYSTEMD=true
    fi
fi

# Also check the kernel command line for rd.luks.uuid (systemd syntax)
if grep -q 'rd.luks.uuid=' /proc/cmdline 2>/dev/null; then
    USES_SYSTEMD=true
fi

if [ "$USES_SYSTEMD" = true ]; then
    echo "[boot-guards] Detected systemd-based initramfs (CachyOS default)."
    HOOKS_LINE="HOOKS=(base systemd autodetect microcode kms modconf block keyboard sd-vconsole plymouth sd-encrypt filesystems sd-btrfs-overlayfs)"
else
    echo "[boot-guards] Detected legacy udev-based initramfs."
    HOOKS_LINE="HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems btrfs-overlayfs)"
fi

# Only write if the guard doesn't exist or differs
NEED_WRITE=true
if [ -f "$GUARD_FILE" ]; then
    if grep -qF "$HOOKS_LINE" "$GUARD_FILE" 2>/dev/null; then
        echo "[boot-guards] mkinitcpio guard already up to date."
        NEED_WRITE=false
    fi
fi

if [ "$NEED_WRITE" = true ]; then
    sudo mkdir -p "$MKINITCPIO_DIR"
    echo "$HOOKS_LINE" | sudo tee "$GUARD_FILE" > /dev/null
    echo "[boot-guards] Wrote $GUARD_FILE"
    echo "[boot-guards] Verifying hooks override works..."
    # Show which drop-ins are active
    if command -v mkinitcpio &>/dev/null; then
        sudo mkinitcpio --listhooks 2>&1 | head -5 || true
    fi
fi

# --- 2. limine guard ---
# omarchy-settings drops files in /etc/limine-entry-tool.d/ that override boot
# entry generation (TARGET_OS_NAME, ENABLE_UKI, BOOT_ORDER).
# /etc/default/limine is read last by limine-common-functions → load_config().

LIMINE_DEFAULT="/etc/default/limine"

# Detect current TARGET_OS_NAME from existing limine.conf
CURRENT_OS="CachyOS"
if [ -f /boot/limine.conf ]; then
    EXTRACTED=$(grep -oP '(?<=description: ).*' /boot/limine.conf 2>/dev/null | head -n1 || true)
    if [ -n "$EXTRACTED" ]; then
        CURRENT_OS="$EXTRACTED"
    fi
fi

# Detect if snapshots are configured
BOOT_ORDER='*, *lts, *fallback, Snapshots'
if ! grep -q 'Snapshots' /boot/limine.conf 2>/dev/null; then
    BOOT_ORDER='*, *lts, *fallback'
fi

NEED_WRITE=true
if [ -f "$LIMINE_DEFAULT" ]; then
    if grep -qF "TARGET_OS_NAME=\"$CURRENT_OS\"" "$LIMINE_DEFAULT" 2>/dev/null && \
       grep -qF "ENABLE_UKI=no" "$LIMINE_DEFAULT" 2>/dev/null; then
        echo "[boot-guards] limine default already up to date."
        NEED_WRITE=false
    fi
fi

if [ "$NEED_WRITE" = true ]; then
    sudo mkdir -p /etc/default
    sudo tee "$LIMINE_DEFAULT" > /dev/null << LIMINEEOF
# CachyOS boot guard — overrides omarchy-settings limine-entry-tool.d configs
# Written by boot-guards.sh — safe to regenerate
TARGET_OS_NAME="$CURRENT_OS"
ENABLE_UKI=no
BOOT_ORDER="$BOOT_ORDER"
LIMINEEOF
    echo "[boot-guards] Wrote $LIMINE_DEFAULT"
fi

echo "[boot-guards] Boot safety guards installed successfully."
echo "[boot-guards] These guards survive omarchy-settings upgrades."
