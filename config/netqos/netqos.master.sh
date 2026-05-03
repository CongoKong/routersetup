#!/bin/sh
### Copyright (c) 2025-2026 Christian Wagner <voodoochriz at gmail dot com>
### Licensed under the ISC license. See LICENSE.txt for details.

set -eu

START=$(date +%s)

# configuration
IFACE="IFWAN"
UPLINK="MAXUPLINKSPEED"
# TYPE: "cable", "dsl", or "fiber"
TYPE="CONNTYPE"

# interface existence
if [ ! -d "/sys/class/net/$IFACE" ]; then
    echo "error: interface $IFACE does not exist." >&2
    exit 1
fi

# wait for operstate=up and carrier=1
OPFILE="/sys/class/net/$IFACE/operstate"
CFILE="/sys/class/net/$IFACE/carrier"

READY=0
i=0
while [ "$i" -lt 30 ]; do
    i=$((i + 1))

    [ "$i" -gt 1 ] && sleep 1

    # --- Check operstate if available ---
    if [ -e "$OPFILE" ]; then
        OPSTATE=$(cat "$OPFILE" 2>/dev/null || echo "unknown")
        case "$OPSTATE" in
            down|unknown|dormant|lowerlayerdown)
                # Driver not ready yet
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
            continue
        fi
    fi

    # operstate=up and carrier=1 → interface is ready
    READY=1
    break
done

# state & carrier are not ready yet
if [ "$READY" -ne 1 ]; then
    echo "error: interface $IFACE did not become ready within timeout (30s)" >&2
    exit 1
fi

# overhead selection
case "$TYPE" in
    cable)
        # DOCSIS framing
        OVERHEAD="overhead 18 docsis"
        ;;
    dsl)
        # VDSL2/PTM usually needs more (44 is a safe bet for PPPoE+VLAN)
        OVERHEAD="overhead 44 ptm"
        ;;
    fiber)
        # Fiber is usually 18 (Ethernet) or 26 (Ethernet + VLAN + PPPoE)
        # We'll use 18 as a clean baseline for FTTH.
        OVERHEAD="overhead 18"
        ;;
    *)
        echo "error: unknown connection type '$TYPE'" >&2
        exit 1
        ;;
esac

# apply CAKE
if tc qdisc replace dev "$IFACE" root cake \
    bandwidth "$UPLINK" \
    $OVERHEAD \
    triple-isolate \
    wash \
    ack-filter; then

    END=$(date +%s)
    DURATION=$((END - START))
    echo "Success: applied CAKE ($TYPE) on $IFACE at $UPLINK (took ${DURATION}s)"
else
    echo "error: tc command failed. check sch_cake module." >&2
    exit 1
fi
