#!/usr/bin/env sh
### Copyright (c) 2026 Christian Wagner <voodoochriz at gmail dot com>
### Licensed under the ISC license. See LICENSE.txt for details.

# ==============================================================================
# script: cake-governor.sh
# purpose: dynamically adjust MQ CAKE bandwidth based on queue backlog.
# ==============================================================================

set -u

# configuration
IFACE="IFWAN"
UPLINK_BW="MAXUPLINKSPEED"  # total uplink bandwidth (kbit)
OVERHEAD="OVRHD"            # overhead string for CAKE
TXQ_INUSE_COUNT=2           # actual TX queues in use
INTERVAL=10                 # measurement interval (sec)
MIN_SLICE_PERCENT=10        # minimum per‑queue guaranteed bandwidth percent
MAX_FAILURES=6              # consecutive failures before exit
FAIL_COUNT=0                # state tracking

# awk existence
if ! command -v awk >/dev/null 2>&1; then
    printf "ERROR: awk command not found!\n" >&2
    exit 1
fi

# tc existence
if ! command -v tc >/dev/null 2>&1; then
    printf "ERROR: tc command not found!\n" >&2
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

# default to 1 if none detected
if [ "$TXQ_COUNT" -lt 1 ]; then TXQ_COUNT=1; fi

# check TXQ_INUSE_COUNT vs available TX queues
if [ "$TXQ_INUSE_COUNT" -gt "$TXQ_COUNT" ]; then
    printf "ERROR: %s: TXQ_INUSE_COUNT (%d) exceeds detected TXQ_COUNT(%d)!\n" \
        "$IFACE" "$TXQ_INUSE_COUNT" "$TXQ_COUNT" >&2
    exit 1
fi

printf "detected %d TX queues on %s (using %d)\n" "$TXQ_COUNT" "$IFACE" "$TXQ_INUSE_COUNT"

# compute bandwidth slices
MIN_SHARE_BW=$(( (UPLINK_BW * MIN_SLICE_PERCENT) / 100 ))
MAX_SHARE_BW=$(( UPLINK_BW / TXQ_INUSE_COUNT ))
SURPLUS_BW=$(( UPLINK_BW - ( MIN_SHARE_BW * TXQ_INUSE_COUNT ) ))

if [ "$SURPLUS_BW" -lt 0 ]; then
    printf "ERROR: sum of min. bandwidth (%dkbit) per TX queue (%d) exceeds avail. bandwidth (%dkbit)!\n" \
    "$MIN_SHARE_BW" "$TXQ_INUSE_COUNT" "$UPLINK_BW" >&2
    printf "try reducing MIN_SLICE_PERCENT (currently %d%%)\n" "$MIN_SLICE_PERCENT" >&2
    exit 1
fi

set_all_queues_full_bw() {
    # NOTE: iterate over TXQ_COUNT (not TXQ_INUSE_COUNT) to match
    # netqos.sh, which configures every detected TX queue
    # NOTE: $OVERHEAD is unquoted deliberately to allow multiple parameters
    i=1
    while [ "$i" -le "$TXQ_COUNT" ]; do
        HANDLE=$(printf "%x" "$i")
        if ! tc qdisc change dev "$IFACE" parent 1:"$HANDLE" cake \
            bandwidth "${UPLINK_BW}kbit" \
            $OVERHEAD \
            diffserv4 \
            triple-isolate \
            nat \
            ack-filter >/dev/null
        then
            printf "WARNING: failed to restore queue %s to baseline %dkbit\n" "$HANDLE" "$UPLINK_BW" >&2
        fi

        i=$((i + 1))
    done
}

# cleanup handler
cleanup() {
    rc=$?
    printf "resetting all queues to %dkbit\n" "$UPLINK_BW"
    set_all_queues_full_bw
    exit "$rc"
}

# execute cleanup() if the script is terminated or exits
trap cleanup EXIT INT TERM

printf "backlog-only governor active on %s\n" "$IFACE"
printf "MIN_SHARE_BW: %dkbit per queue\n" "$MIN_SHARE_BW"
printf "SURPLUS_BW: %dkbit (distributed by backlog)\n" "$SURPLUS_BW"
printf "MAX_SHARE_BW: %dkbit per queue (no backlog)\n" "$MAX_SHARE_BW"

# initialize all queues to full bandwidth once
set_all_queues_full_bw

# previous bandwidth values for change detection
i=1
while [ "$i" -le "$TXQ_INUSE_COUNT" ]; do
    eval "PREV_BW_$i=$UPLINK_BW"
    i=$((i + 1))
done

# main loop
while :; do
    # extract per-queue backlog (packets), keyed by parent handle (1:X)
    RAW_BACKLOGS=$(
        tc -s qdisc show dev "$IFACE" \
        | awk '
            # match only CAKE qdiscs with a parent handle
            /qdisc cake/ {
                parent=""
                for (i=1; i<=NF; i++) {
                    if ($i == "parent") {
                        split($(i+1), a, ":")
                        parent=a[2]   # hex queue index
                    }
                }
                next
            }

            # match backlog lines only when parent is known
            parent != "" && $1 == "backlog" {
                val=$3
                sub(/p$/, "", val)
                print parent ":" val
                parent=""
            }
        '
    )

    # if no CAKE qdiscs/backlogs seen, increment failure counter
    if [ -z "$RAW_BACKLOGS" ]; then
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf "WARNING: no CAKE backlog data (failure %d/%d)!\n" "$FAIL_COUNT" "$MAX_FAILURES" >&2

        if [ "$FAIL_COUNT" -ge "$MAX_FAILURES" ]; then
            printf "ERROR: %d consecutive failures - exiting!\n" "$MAX_FAILURES" >&2
            exit 1
        fi

        sleep "$INTERVAL"
        continue
    fi

    # success - if we were previously failing, our remembered bandwidths
    # are stale (netqos may have reconfigured the qdiscs on link flap).
    # Re-sync to the baseline netqos applies, so the next comparison
    # reflects reality and the governor re-converges from scratch.
    if [ "$FAIL_COUNT" -gt 0 ]; then
        i=1
        while [ "$i" -le "$TXQ_INUSE_COUNT" ]; do
            eval "PREV_BW_$i=$UPLINK_BW"
            i=$((i + 1))
        done
    fi
    FAIL_COUNT=0

    # initialize per-queue backlog map (decimal index → packets)
    # we only care about queues 1..TXQ_INUSE_COUNT
    i=1
    while [ "$i" -le "$TXQ_INUSE_COUNT" ]; do
        eval "BACK_$i=0"
        i=$((i + 1))
    done

    # fill map from RAW_BACKLOGS
    for entry in $RAW_BACKLOGS; do
        key=${entry%%:*}
        val=${entry##*:}

        # convert hex-like queue index to decimal (parent 1:a → 10, 1:b → 11, etc.)
        # tc uses hex for handles; parent 1:1,1:2,...,1:f,1:10,...
        q_dec=$(printf "%d" 0x$key 2>/dev/null || echo 0)

        if [ "$q_dec" -ge 1 ] && [ "$q_dec" -le "$TXQ_INUSE_COUNT" ]; then
            eval "BACK_$q_dec=\$(( \${BACK_$q_dec} + val ))"
        fi
    done

    # compute TOTAL_BACKLOG over in-use queues only
    TOTAL_BACKLOG=0
    i=1
    while [ "$i" -le "$TXQ_INUSE_COUNT" ]; do
        eval "p=\$BACK_$i"
        TOTAL_BACKLOG=$((TOTAL_BACKLOG + p))
        i=$((i + 1))
    done

    # apply bandwidth per queue
    CHANGED=0
    CHANGE_MSG=""

    i=1
    while [ "$i" -le "$TXQ_INUSE_COUNT" ]; do
        eval "p=\$BACK_$i"

        # dynamic queues
        if [ "$TOTAL_BACKLOG" -gt 0 ]; then
            # distribute surplus based on backlog ratio
            if [ "$p" -gt 0 ]; then
                SURPLUS_SHARE_BW=$(( (p * SURPLUS_BW) / TOTAL_BACKLOG ))
                NEW_BW=$(( MIN_SHARE_BW + SURPLUS_SHARE_BW ))
            else
                # queue without backlog gets only minimum
                NEW_BW=$MIN_SHARE_BW
            fi
        else
            # there is no backlog → distribute bandwidth evenly
            NEW_BW=$MAX_SHARE_BW
        fi

        # check if bandwidth changed
        eval "prev=\$PREV_BW_$i"
        if [ "$NEW_BW" -ne "$prev" ]; then
            HANDLE=$(printf "%x" "$i")
            # NOTE: $OVERHEAD is unquoted deliberately to allow multiple parameters
            if tc qdisc change dev "$IFACE" parent 1:"$HANDLE" cake \
                bandwidth "${NEW_BW}kbit" \
                $OVERHEAD \
                diffserv4 \
                triple-isolate \
                nat \
                ack-filter >/dev/null
            then
                CHANGED=1
                CHANGE_MSG="${CHANGE_MSG} q$i: ${prev}kbit → ${NEW_BW}kbit"
                eval "PREV_BW_$i=$NEW_BW"
            else
                printf "WARNING: tc change failed for queue %s (bw=%dkbit)!\n" "$HANDLE" "$NEW_BW" >&2
            fi
        fi

        i=$((i + 1))
    done

    # Log changes if any occurred
    if [ "$CHANGED" -eq 1 ]; then
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$CHANGE_MSG"
    fi

    sleep "$INTERVAL"
done
