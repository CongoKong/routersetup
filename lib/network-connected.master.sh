#!/usr/bin/env sh
### Copyright (c) 2025-2026 Christian Wagner <voodoochriz at gmail dot com>
### Licensed under the ISC license. See LICENSE.txt for details.
#
# Wait for usable IPv4/IPv6 connectivity on an interface.
# Usage: network-connected.sh [timeout] [mode] [interface]
#   timeout  : 0–99 seconds (default: 60)
#   mode     : ipv4 | ipv6 | dual (default: dual)
#   interface: e.g. eth0

# -e: exit immediately if a command exits with a non-zero status
# -u: treat unset variables as an error when substituting
set -eu

TIMEOUT=${1:-60}
MODE=${2:-"dual"} # Options: ipv4, ipv6, dual
IFACE=${3:-"IFWAN"}

# handle manual termination (Ctrl+C) gracefully
trap 'printf "\n"; exit 130' INT
trap 'printf "\n"; exit 143' TERM

# awk existence
if ! command -v awk >/dev/null 2>&1; then
    printf "ERROR: awk command not found!\n" >&2
    exit 1
fi

# --- validate timeout ---
case "$TIMEOUT" in
    ''|*[!0-9]*|0[0-9]|[0-9][0-9][0-9]*)
        printf "ERROR: timeout must be a canonical integer 0–99 without leading zeros!\n" >&2
        exit 1
        ;;
esac

# --- validate mode ---
MODE_CANON=$(printf '%s' "$MODE" | tr 'A-Z' 'a-z')

case "$MODE_CANON" in
    ipv4|ipv6|dual)
        MODE="$MODE_CANON"   # canonicalize only after validation
        ;;
    *)
        printf "ERROR: mode must be one of: ipv4, ipv6, dual!\n" >&2
        exit 1
        ;;
esac

# --- validate interface existence ---
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    printf "ERROR: interface %s does not exist!\n" "$IFACE" >&2
    exit 1
fi

printf "waiting for %s connectivity on %s (max. %ss)...\n" "$MODE" "$IFACE" "$TIMEOUT"

# timeout=0 means: perform exactly one readiness check
if [ "$TIMEOUT" -eq 0 ]; then TIMEOUT=1; fi

OPFILE="/sys/class/net/$IFACE/operstate"
CFILE="/sys/class/net/$IFACE/carrier"

ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    if [ "$ELAPSED" -gt 0 ]; then sleep 1; fi
    ELAPSED=$((ELAPSED + 1))

    # --- check operstate if available ---
    if [ -e "$OPFILE" ]; then
        OPSTATE=$(cat "$OPFILE" 2>/dev/null || printf "unknown")
        case "$OPSTATE" in
            down|unknown|dormant|lowerlayerdown)
                # driver not ready yet
                printf "[%ss] waiting on %s (state: %s)...\n" "$ELAPSED" "$IFACE" "$OPSTATE"
                continue
                ;;
            up)
                # good; proceed to carrier/IP checks
                ;;
        esac
    fi

    # --- check physical link (carrier) ---
    # not all interfaces (like ppp or tun) support the carrier file
    if [ -e "$CFILE" ]; then
        CARRIER=$(cat "$CFILE" 2>/dev/null || printf "0")
        if [ "$CARRIER" -ne 1 ]; then
            printf "[%ss] link down on %s...\n" "$ELAPSED" "$IFACE"
            continue
        fi
    fi

    # --- count valid global addresses ---
    # we count both regardless of mode to keep the code flow simple
    # we ignore 'deprecated' (old/invalid) and 'tentative' (IPv6 DAD in progress)
    V4_COUNT=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null \
        | awk '!/deprecated/ {c++} END{print c+0}')

    V6_COUNT=$(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null \
        | awk '!/tentative|deprecated/ && /inet6 [23]/ {c++} END{print c+0}')

    # --- evaluate readiness based on mode ---
    IF_READY=0
    case "$MODE" in
        ipv4) if [ "$V4_COUNT" -gt 0 ]; then IF_READY=1; fi ;;
        ipv6) if [ "$V6_COUNT" -gt 0 ]; then IF_READY=1; fi ;;
        dual) if [ "$V4_COUNT" -gt 0 ] && [ "$V6_COUNT" -gt 0 ]; then IF_READY=1; fi ;;
    esac

    if [ "$IF_READY" -eq 1 ]; then
        printf "success: %s ready on %s after %ss.\n" "$MODE" "$IFACE" "$ELAPSED"
        exit 0
    fi

    printf "[%ss] waiting for %s connectivity...\n" "$ELAPSED" "$MODE"
done

# --- timeout reached ---
printf "ERROR: timeout while waiting for %s on %s!\n" "$MODE" "$IFACE" >&2
exit 1
