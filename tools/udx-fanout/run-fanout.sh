for n in "${PEERS[@]}"; do
  for rep in $(seq 1 "$REPS"); do
    echo "=== fan-out $n, run $rep/$REPS ==="
    check_on_battery || ON_POWER=1

    csv="$OUT/n${n}_r${rep}_power.csv"
    log="$OUT/n${n}_r${rep}_phone.jsonl"
    sample_power "$csv" &
    sampler=$!

    # Each run is its own `flutter test` process, so its UDP socket, its
    # multiplexer and every stream on it are created and destroyed inside
    # that process. Repeats therefore share nothing but the handset — no
    # inherited flow-control state, no sockets left half-open.
    set +e
    (cd "$HERE/phone" && flutter test integration_test/fanout_test.dart \
        ${SERIAL:+-d "$SERIAL"} \
        --dart-define=HOST="$HOST" \
        --dart-define=BASE_PORT="$BASE_PORT" \
        --dart-define=PEERS="$n" \
        --dart-define=HOLD_S="$HOLD_S" \
        --dart-define=KEEPALIVE_S="$KEEPALIVE_S" \
        --dart-define=CHUNK_BYTES="$CHUNK_BYTES" \
        --dart-define=REPORT_S="$REPORT_S") 2>&1 | tee "$log"
    rc=$?
    set -e

    kill "$sampler" 2>/dev/null || true
    wait "$sampler" 2>/dev/null || true

    opened=$(grep -o '"opened":[0-9]*' "$log" | tail -1 | cut -d: -f2)
    closed=$(grep -c '"ev":"closed"' "$log")
    bps=$(grep -o '"aggregateBps":[0-9]*' "$log" | tail -1 | cut -d: -f2)
    echo "n=$n run=$rep: exit $rc, opened ${opened:-?}/$n, closed=${closed}, ${bps:-?} B/s"
    sleep "$SETTLE_S"
  done
done
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
CHUNK_BYTES=0
REPORT_S=10
REPS=1
SETTLE_S=20
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
    echo "  --chunk N          Bytes per write, turning the hold into a throughput"
    echo "                     run: every stream writes flat out and the report is"
    echo "                     goodput and its spread. 0 (default) holds idle."
    echo "  --report N         Seconds between throughput reports (default: $REPORT_S)"
    echo "  --reps N           Independent runs per fan-out (default: $REPS). Each is"
    echo "                     its own process, so sockets are built and torn down"
    echo "                     fresh and runs share no transport state."
    echo "  --settle N         Seconds between runs (default: $SETTLE_S)"
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
        --chunk) CHUNK_BYTES="$2"; shift 2 ;;
        --report) REPORT_S="$2"; shift 2 ;;
        --reps) REPS="$2"; shift 2 ;;
        --settle) SETTLE_S="$2"; shift 2 ;;
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
ON_POWER=0

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

# Charging masks the draw entirely, so the handset has to be on battery.
# It is unplugged by hand, over wireless adb, rather than with `battery
# unplug`: simulating the unplug reconfigures USB on some devices and takes
# adb down mid-run, which loses the run AND strands the phone in a state
# where it will not charge.
check_on_battery() {
    local dump powered
    dump=$("${ADB[@]}" shell dumpsys battery 2>/dev/null | tr -d '\r')
    powered=$(awk -F': ' '/powered/ && $2 == "true" {print $1}' <<<"$dump")
    if [ -n "$powered" ]; then
        echo "WARNING: still on power ($(tr -d ' ' <<<"$powered" | paste -sd, -))."
        echo "         Charge counters will not fall and the power column is"
        echo "         meaningless. Unplug the cable and rerun."
        return 1
    fi
    return 0
}

for n in "${PEERS[@]}"; do
    echo "=== fan-out $n ==="
    check_on_battery || ON_POWER=1

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
        --dart-define=KEEPALIVE_S="$KEEPALIVE_S" \
        --dart-define=CHUNK_BYTES="$CHUNK_BYTES" \
        --dart-define=REPORT_S="$REPORT_S") 2>&1 | tee "$log"
    rc=$?
    set -e

    kill "$sampler" 2>/dev/null || true
    wait "$sampler" 2>/dev/null || true

    opened=$(grep -o '"opened":[0-9]*' "$log" | tail -1 | cut -d: -f2)
    echo "fan-out $n: exit $rc, opened ${opened:-?}/$n -> $csv"
    sleep 30   # let the radio settle before the next point
done

echo
echo "results in $OUT/; pair each n<N>_power.csv with n<N>_phone.jsonl by timestamp"
[ "$ON_POWER" = 1 ] && echo "NOTE: at least one point ran on power; its power column is not usable."
exit 0
