#!/usr/bin/env sh
### get IPv6 Global Unicast Address of WAN interface
###
### Copyright (c) 2025-2026 Christian Wagner <voodoochriz at gmail dot com>
### Licensed under the ISC license. See LICENSE.txt for details.

# -u: treat unset variables as an error when substituting
set -u

IFACE="IFWAN"

GUA_IP=$(
    ip -6 addr show dev "$IFACE" scope global 2>/dev/null |
    while read -r a b rest; do
        # $a=inet6  $b=addr/prefix (e.g. 2001:db8::1/64)  $rest=remaining flags

        case "$a $b" in
            inet6\ [23]*)   # 2000::/3 — Global Unicast (excludes ULA, NAT64, etc.)

                # skip temporary (privacy) addresses
                case "$rest" in
                    *temporary*) continue ;;
                esac

                printf "%s\n" "${b%%/*}"
                break
                ;;
        esac
    done
)

# if the pipeline found nothing, GUA_IP is empty
if [ -z "$GUA_IP" ]; then
    printf "ERROR: no GUA IP found for %s!\n" "$IFACE" >&2
    exit 1
fi

printf "%s\n" "$GUA_IP"
