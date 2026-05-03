#!/bin/sh
### Copyright (c) 2025-2026 Christian Wagner <voodoochriz at gmail dot com>
### Licensed under the ISC license. See LICENSE.txt for details.
#
# Wait for usable IPv4/IPv6 connectivity on an interface.
# Usage: network-connected.sh [timeout] [mode] [interface]
#   timeout  : 0–99 seconds (default: 60)
#   mode     : ipv4 | ipv6 | dual (default: dual)
#   interface: e.g. eth0

# -e: Exit immediately if a command exits with a non-zero status
# -u: Treat unset variables as an error when substituting
set -eu

TIMEOUT=${1:-60}
MODE=${2:-"dual"} # Options: ipv4, ipv6, dual
IFACE=${3:-"IFWAN"}

# Handle manual termination (Ctrl+C) gracefully
trap 'printf "\n"; exit 130' INT TERM

# --- Validation: Timeout ---
case "$TIMEOUT" in
    ''|*[!0-9]*|0[0-9]|[0-9][0-9][0-9]*)
        echo "ERROR: Timeout must be a canonical integer 0–99 without leading zeros." >&2
        exit 11
        ;;
esac

# --- Validation: Mode ---
MODE_CANON=$(printf '%s' "$MODE" | tr 'A-Z' 'a-z')

case "$MODE_CANON" in
    ipv4|ipv6|dual)
        MODE="$MODE_CANON"   # canonicalize only after validation
        ;;
    *)
        echo "ERROR: Mode must be one of: ipv4, ipv6, dual." >&2
        exit 12
        ;;
esac

# --- Validation: Interface Existence ---
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "ERROR: Interface $IFACE does not exist." >&2
    exit 13
fi

echo "Waiting for $MODE connectivity on $IFACE (max. ${TIMEOUT}s)..."

# TIMEOUT=0 means: perform exactly one readiness check
[ "$TIMEOUT" -eq 0 ] && TIMEOUT=1

OPFILE="/sys/class/net/$IFACE/operstate"
CFILE="/sys/class/net/$IFACE/carrier"

ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    ELAPSED=$((ELAPSED + 1))

    [ "$ELAPSED" -gt 1 ] && sleep 1

    # --- Check operstate if available ---
    if [ -e "$OPFILE" ]; then
        OPSTATE=$(cat "$OPFILE" 2>/dev/null || echo "unknown")
        case "$OPSTATE" in
            down|unknown|dormant|lowerlayerdown)
                # Driver not ready yet
                printf "[%ss] Waiting on %s (state: %s)...\n" "$ELAPSED" "$IFACE" "$OPSTATE"
                continue
                ;;
            up)
                # Good; proceed to carrier/IP checks
                ;;
        esac
    fi

    # --- Check Physical Link (Carrier) ---
    # Not all interfaces (like ppp or tun) support the carrier file
    if [ -e "$CFILE" ]; then
        CARRIER=$(cat "$CFILE" 2>/dev/null || echo "0")
        if [ "$CARRIER" -ne 1 ]; then
            printf "[%ss] Link down on %s...\n" "$ELAPSED" "$IFACE"
            continue
        fi
    fi

    # --- Count Valid Global Addresses ---
    # We count both regardless of mode to keep the code flow simple
    # We ignore 'deprecated' (old/invalid) and 'tentative' (IPv6 DAD in progress)
    V4_COUNT=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null \
        | awk '!/deprecated/ {c++} END{print c+0}')

    V6_COUNT=$(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null \
        | awk '!/tentative|deprecated/ {c++} END{print c+0}')

    # --- Evaluate Readiness based on Mode ---
    IF_READY=0
    case "$MODE" in
        ipv4) [ "$V4_COUNT" -gt 0 ] && IF_READY=1 ;;
        ipv6) [ "$V6_COUNT" -gt 0 ] && IF_READY=1 ;;
        dual) [ "$V4_COUNT" -gt 0 ] && [ "$V6_COUNT" -gt 0 ] && IF_READY=1 ;;
    esac

    if [ "$IF_READY" -eq 1 ]; then
        printf "Success: %s ready on %s after %ss.\n" "$MODE" "$IFACE" "$ELAPSED"
        exit 0
    fi

    # Status update with \r to overwrite the current line
    printf "[%ss] Waiting for %s configuration...\n" "$ELAPSED" "$MODE"
done

# --- Timeout Reached ---
printf "ERROR: Timeout while waiting for $MODE on $IFACE.\n" >&2
exit 1
