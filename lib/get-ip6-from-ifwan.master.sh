#!/bin/sh
### get IPv6 Global Unicast Address of WAN interface
###
### Copyright (c) 2025-2026 Christian Wagner <voodoochriz at gmail dot com>
### Licensed under the ISC license. See LICENSE.txt for details.

# -u: Treat unset variables as an error when substituting
set -u

IFACE="IFWAN"

GUA_IP=$(
    ip -6 addr show dev "$IFACE" scope global 2>/dev/null |
    while read -r a b c d; do
        case "$a $b" in
            inet6\ [23]*)
                # b contains the IP/prefix (e.g., 2001:db8::1/64)
                # c+ contain the flags (e.g., scope global dynamic)
                case "$c $d" in
                    *temporary*) continue ;;
                esac

                echo "$b" | sed 's#/.*##'
                ;;
        esac
    done | head -n 1
)

# if the pipeline found nothing, GUA_IP is empty.
if [ -z "$GUA_IP" ]; then
    # Optional: print an error to stderr so you know why it failed
    echo "No GUA IP found for $IFACE" >&2
    exit 1
fi

echo "$GUA_IP"
