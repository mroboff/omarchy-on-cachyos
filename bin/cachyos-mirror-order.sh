#!/usr/bin/env bash
# Reorder the pacman mirrorlists by measured download speed.
#
# Why this exists
# ---------------
# `cachyos-rate-mirrors` (systemd timer, 3x/day) regenerates the mirrorlists
# with `rate-mirrors`, which ranks mirrors using a ~300 ms probe. That probe is
# short enough to mis-rank a mirror that has since degraded: we measured
# `ca.mirror.cx` at 5 KB/s while it sat first in the list, and pacman kept
# hammering it instead of falling through to the next mirror. The result is an
# `omarchy update` crawling at ~20 KiB/s with a 40-minute ETA.
#
# This script re-measures every mirror with a real transfer and rewrites the
# `Server =` lines fastest-first. Slow mirrors are demoted, never dropped, so
# they remain usable as fallback when the fast ones are busy.
#
# Install
#   sudo install -m 755 cachyos-mirror-order.sh /usr/local/bin/
#
# Usage
#   sudo cachyos-mirror-order.sh            # measure and apply
#   sudo cachyos-mirror-order.sh --dry-run  # report only
#
# Environment overrides
#   MIN_SPEED     bytes/s below which a mirror is demoted (default 102400)
#   FAST_ENOUGH   bytes/s at which the list is already fine and nothing is
#                 rewritten (default 200000)
#   MAX_TIME      seconds allowed per probe (default 6)
#   MIN_BYTES     minimum bytes a probe must transfer to count (default 131072)
#   RANGE_BYTES   bytes fetched per probe (default 262144)
#   CONCURRENCY   parallel probes (default 8)
#   MIRROR_DIR    where the mirrorlists live (default /etc/pacman.d)
set -euo pipefail

MIRROR_DIR="${MIRROR_DIR:-/etc/pacman.d}"
MIN_SPEED="${MIN_SPEED:-102400}"
FAST_ENOUGH="${FAST_ENOUGH:-200000}"
MAX_TIME="${MAX_TIME:-6}"
MIN_BYTES="${MIN_BYTES:-131072}"
RANGE_BYTES="${RANGE_BYTES:-262144}"
CONCURRENCY="${CONCURRENCY:-8}"
DRY_RUN=0

# Speed per host, so the three mirrorlists (which list the same hosts with a
# different $arch token) are only measured once per run. Kept in a file
# because the probes run in background subshells, where a shell variable
# would not be shared back.
CACHE_FILE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            sed -n '2,32p' "$0"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

log() { printf '%b\n' "$*" >&2; }

# logf <format> [args...] - printf-style message.
logf() {
    local fmt="$1"
    shift
    # shellcheck disable=SC2059
    printf "$fmt\n" "$@" >&2
}

# Which concrete repo names to probe, per mirrorlist. The `$repo` token is
# filled in by pacman per repository, so a single mirrorlist file serves
# several repos; any of them is a valid probe target. Smallest first: the
# probe stops as soon as one of them transfers enough bytes.
repo_candidates() {
    case "$1" in
        *v4-mirrorlist) printf '%s\n' cachyos-znver4 cachyos-core-znver4 cachyos-extra-znver4 ;;
        *v3-mirrorlist) printf '%s\n' cachyos-v3 cachyos-core-v3 cachyos-extra-v3 ;;
        *cachyos-mirrorlist) printf '%s\n' cachyos ;;
        mirrorlist) printf '%s\n' multilib core extra ;;
        *) printf '%s\n' cachyos extra core ;;
    esac
}

# Expand $arch / $arch_v3 / $arch_v4 and $repo in a mirror template.
expand_template() {
    local tpl="$1"
    local repo="$2"
    local out
    out="${tpl//\$arch_v4/x86_64_v4}"
    out="${out//\$arch_v3/x86_64_v3}"
    out="${out//\$arch/x86_64}"
    out="${out//\$repo/$repo}"
    printf '%s' "$out"
}

# Probe one mirror template. Echoes "<bytes_per_second>\t<template>".
#
# The probe fetches at most RANGE_BYTES of the repository database: enough to
# get a meaningful speed number while keeping the bandwidth cost low (the
# extra.db database alone is 8 MB, and there are ~23 mirrors to check).
#
# A probe only counts when the server answers 200 AND transfers at least
# MIN_BYTES: that rules out both 404s and a connection that dies after a few
# kilobytes, which would otherwise be scored as "very slow but valid".
measure_mirror() {
    local tpl="$1"
    local file="$2"
    local repo url out speed code size host cached

    # Same host, different $arch: reuse the speed measured for it.
    host="${tpl#*://}"
    host="${host%%/*}"
    if [ -n "$CACHE_FILE" ] && [ -s "$CACHE_FILE" ]; then
        # `|| true`: grep exits 1 when the host is not cached yet, and under
        # `set -e -o pipefail` that would kill the whole run.
        cached="$(grep -m1 "^${host}[[:space:]]" "$CACHE_FILE" 2>/dev/null | head -1 | cut -d' ' -f2 || true)"
        if [ -n "${cached:-}" ]; then
            printf '%s\t%s\n' "$cached" "$tpl"
            return 0
        fi
    fi

    while read -r repo; do
        [ -n "$repo" ] || continue
        url="$(expand_template "$tpl" "$repo")/$repo.db"
        out="$(curl -sL --connect-timeout 4 --max-time "$MAX_TIME" -o /dev/null \
            -H "Range: bytes=0-$((RANGE_BYTES - 1))" \
            -w '%{speed_download} %{http_code} %{size_download}' "$url" 2>/dev/null)" || out="0 000 0"
        read -r speed code size <<<"$out"
        # 200 = the server ignored the Range header and sent the whole file,
        # 206 = it honoured it and sent only the requested slice.
        if { [ "$code" = "200" ] || [ "$code" = "206" ]; } && [ "${size:-0}" -ge "$MIN_BYTES" ]; then
            printf '%s\t%s\n' "${speed%%.*}" "$tpl"
            [ -n "$CACHE_FILE" ] && printf '%s %s\n' "$host" "${speed%%.*}" >>"$CACHE_FILE"
            return 0
        fi
    done < <(repo_candidates "$file")
    printf '0\t%s\n' "$tpl"
    [ -n "$CACHE_FILE" ] && printf '%s 0\n' "$host" >>"$CACHE_FILE"
    return 0
}

# Measure every template and echo them sorted fastest first.
# The first argument is the mirrorlist file name: it decides which concrete
# repositories are used to probe the mirrors.
#
# Probes run sequentially on purpose. There are ~23 mirrors and each probe is
# capped at RANGE_BYTES, so a full pass costs a few seconds and a few MB.
# Running them in parallel made the background jobs race each other's result
# files, which silently dropped most of the measurements.
measure_all() {
    local file="$1"
    shift
    local tpl
    for tpl in "$@"; do
        [ -n "$tpl" ] || continue
        measure_mirror "$tpl" "$file"
    done | sort -t"$(printf '\t')" -k1,1nr
}

# Rewrite one mirrorlist so its Server lines are ordered fastest first.
# The file is left untouched when the order is already correct, which keeps the
# systemd path unit below from looping on its own writes.
process_file() {
    local file="$1"
    local name
    name="$(basename "$file")"

    if [ ! -f "$file" ]; then
        return 0
    fi

    local -a lines=()
    local -a templates=()
    local -a full_lines=()
    local -a order=()
    local line tpl url speed
    local first=-1
    local last=-1

    while IFS= read -r line; do
        lines+=("$line")
    done <"$file"

    local i=0
    for line in "${lines[@]}"; do
        if [[ "$line" =~ ^[[:space:]]*Server[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            tpl="${BASH_REMATCH[1]}"
            templates+=("$tpl")
            full_lines+=("$line")
            if [ "$first" -lt 0 ]; then
                first=$i
            fi
            last=$i
        fi
        i=$((i + 1))
    done

    if [ "${#templates[@]}" -eq 0 ]; then
        return 0
    fi

    # Only reorder a contiguous run of Server lines; anything else means the
    # file has a layout we do not understand, so leave it alone.
    for ((i = first; i <= last; i++)); do
        if [[ ! "${lines[$i]}" =~ ^[[:space:]]*Server[[:space:]]*= ]]; then
            log "  $name: unexpected layout around line $((i + 1)); skipped"
            return 0
        fi
    done

    log "  $name: checking the mirror in first place..."
    local -a head_order=()
    while IFS=$'\t' read -r speed tpl; do
        [ -n "$tpl" ] || continue
        head_order+=("$speed"$'\t'"$tpl")
    done < <(measure_all "$name" "${templates[0]}")

    local head_speed=0
    if [ "${#head_order[@]}" -gt 0 ]; then
        head_speed="${head_order[0]%%$'\t'*}"
    fi

    if [ "$head_speed" -ge "$FAST_ENOUGH" ]; then
        logf "  $name: first mirror already at %d B/s; nothing to do" "$head_speed"
        return 0
    fi

    log "  $name: measuring ${#templates[@]} mirrors..."
    while IFS=$'\t' read -r speed tpl; do
        [ -n "$tpl" ] || continue
        order+=("$speed"$'\t'"$tpl")
    done < <(measure_all "$name" "${templates[@]}")

    # Reassemble the Server block, demoting anything slower than MIN_SPEED.
    local -a fast=()
    local -a slow=()
    for entry in "${order[@]}"; do
        speed="${entry%%$'\t'*}"
        if [ "$speed" -ge "$MIN_SPEED" ]; then
            fast+=("$entry")
        else
            slow+=("$entry")
        fi
    done

    log "  $name: ${#fast[@]} fast, ${#slow[@]} demoted"
    for entry in "${order[@]}"; do
        speed="${entry%%$'\t'*}"
        url="${entry#*$'\t'}"
        if [ "$speed" -ge "$MIN_SPEED" ]; then
            logf '    %9d B/s  %s' "$speed" "$url"
        else
            logf '    %9d B/s  %s  (demoted)' "$speed" "$url"
        fi
    done

    # Build the new Server block, keeping each original line verbatim.
    local -a new_block=()
    local original
    for entry in "${fast[@]}" "${slow[@]}"; do
        [ -n "$entry" ] || continue
        url="${entry#*$'\t'}"
        for original in "${full_lines[@]}"; do
            if [[ "$original" =~ ^[[:space:]]*Server[[:space:]]*=[[:space:]]*(.+)$ ]] &&
                [ "${BASH_REMATCH[1]}" = "$url" ]; then
                new_block+=("$original")
                break
            fi
        done
    done

    if [ "${#new_block[@]}" -ne "${#full_lines[@]}" ]; then
        log "  $name: could not rebuild the Server block; skipped"
        return 0
    fi

    # Is the order already correct?
    local unchanged=1
    for ((i = 0; i < ${#new_block[@]}; i++)); do
        if [ "${new_block[$i]}" != "${full_lines[$i]}" ]; then
            unchanged=0
            break
        fi
    done

    if [ "$unchanged" -eq 1 ]; then
        log "  $name: already ordered fastest-first"
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log "  $name: would reorder (dry run, nothing written)"
        return 0
    fi

    local -a out=()
    for ((i = 0; i < first; i++)); do
        out+=("${lines[$i]}")
    done
    out+=("${new_block[@]}")
    for ((i = last + 1; i < ${#lines[@]}; i++)); do
        out+=("${lines[$i]}")
    done

    printf '%s\n' "${out[@]}" >"$file.tmp"
    # Replace atomically (rename) so a pacman run reading the mirrorlist at
    # this exact moment never sees a half-written file.
    chmod --reference="$file" "$file.tmp" 2>/dev/null || chmod 0644 "$file.tmp"
    chown --reference="$file" "$file.tmp" 2>/dev/null || true
    mv -f "$file.tmp" "$file"
    log "  $name: reordered"
}

main() {
    local file
    CACHE_FILE="$(mktemp)"
    trap 'rm -f "$CACHE_FILE"' EXIT
    for file in \
        "$MIRROR_DIR/cachyos-v4-mirrorlist" \
        "$MIRROR_DIR/cachyos-v3-mirrorlist" \
        "$MIRROR_DIR/cachyos-mirrorlist" \
        "$MIRROR_DIR/mirrorlist"
    do
        process_file "$file"
    done
}

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    log "This script writes to $MIRROR_DIR; run it as root (or use --dry-run)."
    exit 1
fi

main
