#!/usr/bin/env sh
### Copyright (c) 2025-2026 Christian Wagner <voodoochriz at gmail dot com>
### Licensed under the ISC license. See LICENSE.txt for details.

# ==================================================================================================
# script: netqos.sh
# purpose: This script configures CAKE-based Smart Queue Management (SQM) on a network interface
# to mitigate bufferbloat and manage bandwidth, either globally or
# per transmit queue when multiple hardware queues are available.
# ==================================================================================================

set -eu

START=$(date +%s)

# configuration
IFACE='IFWAN'
UPLINK='MAXUPLINKSPEED'
OVERHEAD='OVRHD'
MODE='TCMODE'   # global | mq
TIMEOUT='30'

# modinfo existence
if ! command -v modinfo >/dev/null 2>&1; then
    printf "ERROR: modinfo command not found!\n" >&2
    exit 1
fi

# tc existence
if ! command -v tc >/dev/null 2>&1; then
    printf "ERROR: tc command not found!\n" >&2
    exit 1
fi

# interface existence
if [ ! -d "/sys/class/net/$IFACE" ]; then
    printf "ERROR: interface $IFACE does not exist!\n" >&2
    exit 1
fi

# wait for operstate=up and carrier=1
OPFILE="/sys/class/net/$IFACE/operstate"
CFILE="/sys/class/net/$IFACE/carrier"

READY=0
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
    # sleep before subsequent checks (skip initial sleep on first iteration)
    if [ "$i" -gt 0 ]; then sleep 1; fi
    i=$((i + 1))

    # check operstate if available
    if [ -e "$OPFILE" ] && read -r OPSTATE < "$OPFILE"; then
        :
    else
        OPSTATE='unknown'
    fi

    case "$OPSTATE" in
        down|unknown|dormant|lowerlayerdown)
            # driver not ready yet
            continue
            ;;
        up)
            # good; proceed to carrier/IP checks
            ;;
        *)
            # unexpected state - treat as not ready
            continue
            ;;
    esac

    # check physical link (carrier) if available
    # not all interfaces (like ppp or tun) support the carrier file
    if [ -e "$CFILE" ] && read -r CARRIER < "$CFILE"; then
        :
    else
        CARRIER='0'
    fi

    [ "$CARRIER" -eq 1 ] || continue

    # operstate=up and carrier=1 → interface is ready
    READY=1
    break
done

# state & carrier are not ready yet
if [ "$READY" -ne 1 ]; then
    printf "ERROR: interface %s did not become ready within timeout (%ds)!\n" "$IFACE" "$TIMEOUT" >&2
    exit 1
fi

# detect TX queue count
TXQ_PATH="/sys/class/net/$IFACE/queues"
TXQ_COUNT=0

if [ -d "$TXQ_PATH" ]; then
    for q in "$TXQ_PATH"/tx-*; do
        [ -d "$q" ] || continue
        TXQ_COUNT=$((TXQ_COUNT + 1))
    done
fi

# default to 1 queue if none detected (e.g., virtual interfaces)
if [ "$TXQ_COUNT" -lt 1 ]; then TXQ_COUNT=1; fi

printf "detected %d TX queues on %s.\n" "$TXQ_COUNT" "$IFACE"

cake_diagnose() {
    if grep -q '^sch_cake' /proc/modules 2>/dev/null; then
        return 0   # loaded; failure is something else, no module hint
    fi
    if modinfo sch_cake >/dev/null 2>&1; then
        printf "hint: sch_cake module not loaded (try: modprobe sch_cake).\n" >&2
    else
        printf "hint: sch_cake module not available (try: modprobe sch_cake).\n" >&2
    fi
}

# attach mq root
if [ "$MODE" = 'mq' ] && [ "$TXQ_COUNT" -gt 1 ]; then
    tc qdisc replace dev "$IFACE" root handle 1: mq || {
        printf "ERROR: failed to attach MQ qdisc!\n" >&2
        exit 1
    }

    # apply per-queue CAKE SQM configuration
    # note: $OVERHEAD is left unquoted deliberately to allow multiple parameters (e.g. "docsis overhead 18")
    # diffserv4: enables 4-way traffic prioritization (tins)
    # triple-isolate: ensures fairness per host-pair (src/dst IP)
    # nat: restores pre-NAT flow hashing (required for nftables masquerade)
    # ack-filter: optimizes the return path by filtering redundant ACKs
    q=1
    while [ "$q" -le "$TXQ_COUNT" ]; do
        HANDLE=$(printf "%x" "$q")
        printf "attaching CAKE to parent 1:%s at %dkbit.\n" "$HANDLE" "$UPLINK"
        tc qdisc replace dev "$IFACE" parent 1:"$HANDLE" cake \
            bandwidth "${UPLINK}kbit" \
            $OVERHEAD \
            diffserv4 \
            triple-isolate \
            nat \
            ack-filter || {
                printf "ERROR: tc command failed for queue %d!\n" "$q" >&2

                # diagnostic: check if module is loaded
                cake_diagnose

                # clean up partially configured queues:
                # revert to the initial (unmanaged) state so the operator can re-run cleanly
                tc qdisc del dev "$IFACE" root 2>/dev/null || true
                exit 1
        }

        q=$((q + 1))
    done

    APPLIED_MODE='mq'
else
    # apply global CAKE
    # note: $OVERHEAD is left unquoted deliberately to allow multiple parameters (e.g. "docsis overhead 18")
    tc qdisc replace dev "$IFACE" root cake \
        bandwidth "${UPLINK}kbit" \
        $OVERHEAD \
        diffserv4 \
        triple-isolate \
        nat \
        ack-filter || {
            printf "ERROR: tc command failed to attach GLOBAL qdisc!\n" >&2

            # diagnostic: check if module is loaded
            cake_diagnose
            exit 1
    }

    APPLIED_MODE='global'
fi

END=$(date +%s)
DURATION=$((END - START))

# success message based on what was actually applied
if [ "$APPLIED_MODE" = 'mq' ]; then
    printf "success: applied mq + per-queue CAKE on %s (%d queues @ %dkbit, took %ds).\n" \
        "$IFACE" "$TXQ_COUNT" "$UPLINK" "$DURATION"
else
    printf "success: applied global CAKE on %s @ %dkbit (took %ds).\n" \
    "$IFACE" "$UPLINK" "$DURATION"
fi

exit 0
