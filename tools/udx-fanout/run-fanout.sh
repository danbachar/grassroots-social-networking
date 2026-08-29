#!/usr/bin/env bash
# Sweeps fan-out on a handset: for each N, hold N UDX streams while sampling
# power, then move on.
#
# Power is sampled here rather than on the phone so the two records stay
# independent — the phone reports what the streams did, this reports what it
# cost, and they line up by timestamp.
set -euo pipefail

# Resolve to this script's own directory: the sweep runs `flutter test` in
# phone/, which must not depend on where it was invoked from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST=""
SERIAL=""
PEERS=(1 4 16 64)
HOLD_S=600
KEEPALIVE_S=20
BASE_PORT=41000
SAMPLE_S=5
OUT="results"

usage() {
    echo "Usage: $0 --host IP [OPTIONS]"
    echo "  --host IP          Responder host (required)"
    echo "  --serial S         adb device serial (default: the only device)"
    echo "  --peers N...       Fan-out values to sweep (default: ${PEERS[*]})"
    echo "  --hold N           Seconds to hold each fan-out (default: $HOLD_S)"
    echo "  --keepalive N      Seconds between keepalives (default: $KEEPALIVE_S)"
    echo "  --base-port N      First responder port (default: $BASE_PORT)"
    echo "  --sample N         Seconds between power samples (default: $SAMPLE_S)"
    echo "  --out DIR          Where results land (default: $OUT)"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --host) HOST="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        --peers) shift; PEERS=(); while [[ $# -gt 0 && ! "$1" =~ ^- ]]; do PEERS+=("$1"); shift; done ;;
        --hold) HOLD_S="$2"; shift 2 ;;
        --keepalive) KEEPALIVE_S="$2"; shift 2 ;;
        --base-port) BASE_PORT="$2"; shift 2 ;;
        --sample) SAMPLE_S="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

[ -z "$HOST" ] && { echo "--host is required"; usage; exit 1; }

ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no device reachable"; exit 1; }
DEVICE=$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')
echo "device: $DEVICE"

# Which power file this handset exposes; they differ by vendor and a missing
# one silently yields an empty column, so find it once and say which it is.
CURRENT_PATH=""
for p in /sys/class/power_supply/battery/current_now \
         /sys/class/power_supply/bms/current_now; do
    if "${ADB[@]}" shell "test -r $p" 2>/dev/null; then CURRENT_PATH="$p"; break; fi
done
[ -z "$CURRENT_PATH" ] && echo "warning: no readable current_now; falling back to charge_counter deltas"
echo "current: ${CURRENT_PATH:-none}"

case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$OUT"

sample_power() {   # $1 = csv path
    echo "ts,current_ua,charge_uah,level,temp_dc" > "$1"
    while :; do
        local dump cur chg lvl tmp
        dump=$("${ADB[@]}" shell dumpsys battery 2>/dev/null | tr -d '\r')
        chg=$(awk -F': ' '/Charge counter/ {print $2}' <<<"$dump")
        lvl=$(awk -F': ' '/^  level/ {print $2}' <<<"$dump")
        tmp=$(awk -F': ' '/temperature/ {print $2}' <<<"$dump")
        cur=""
        [ -n "$CURRENT_PATH" ] && cur=$("${ADB[@]}" shell "cat $CURRENT_PATH" 2>/dev/null | tr -d '\r')
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),${cur},${chg},${lvl},${tmp}" >> "$1"
        sleep "$SAMPLE_S"
    done
}

restore() {
    echo "restoring charging state"
    "${ADB[@]}" shell cmd battery reset >/dev/null 2>&1 || true
}
trap restore EXIT

for n in "${PEERS[@]}"; do
    echo "=== fan-out $n ==="
    # Charging masks draw entirely; unplug for the run and reset afterwards.
    "${ADB[@]}" shell cmd battery unplug >/dev/null 2>&1 \
        || echo "warning: could not unplug; current readings include charge"

    csv="$OUT/n${n}_power.csv"
    log="$OUT/n${n}_phone.jsonl"
    sample_power "$csv" &
    sampler=$!

    set +e
    (cd "$HERE/phone" && flutter test integration_test/fanout_test.dart \
        ${SERIAL:+-d "$SERIAL"} \
        --dart-define=HOST="$HOST" \
        --dart-define=BASE_PORT="$BASE_PORT" \
        --dart-define=PEERS="$n" \
        --dart-define=HOLD_S="$HOLD_S" \
        --dart-define=KEEPALIVE_S="$KEEPALIVE_S") 2>&1 | tee "$log"
    rc=$?
    set -e

    kill "$sampler" 2>/dev/null || true
    wait "$sampler" 2>/dev/null || true
    "${ADB[@]}" shell cmd battery reset >/dev/null 2>&1 || true

    opened=$(grep -o '"opened":[0-9]*' "$log" | tail -1 | cut -d: -f2)
    echo "fan-out $n: exit $rc, opened ${opened:-?}/$n -> $csv"
    sleep 30   # let the radio settle before the next point
done

echo
echo "results in $OUT/; pair each n<N>_power.csv with n<N>_phone.jsonl by timestamp"
