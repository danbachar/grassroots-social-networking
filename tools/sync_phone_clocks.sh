#!/usr/bin/env bash
# Set every adb-connected phone's clock from this machine's, then verify.
#
# Why not NTP: Android only corrects a clock that is MORE than ~2 s off NTP
# (5 s on older builds) — inside that threshold it leaves the clock alone, so
# SIM-less phones settle anywhere within a ±2 s band of each other and stay
# there. Measured on this fleet: residuals of 0.3–1.4 s after a forced NTP
# re-query. That band is wider than the e2e latencies being measured.
#
# Why this works without root: the adb shell uid holds SET_TIME, and
# `cmd alarm set-time <millis>` is a direct clock write. The write is aimed
# at this machine's clock (itself NTP-synced) corrected by half the adb
# round-trip, which lands each phone within ~0.1 s of true time. Android's
# own NTP will not fight a clock that close to truth (see threshold above).
#
# Run at home before a field day. Quartz drift is ~1 s/day, so a morning
# sync covers an afternoon offline.
#
# The measured offsets are the ONLY trustworthy clock numbers a field run
# has. A trace cannot recover them after the fact: in a manual-join run every
# phone stamps its step markers at the same SCHEDULED epoch, so all phones
# write identical marker timestamps no matter how far off their clocks are —
# a constant offset is invisible there by construction. Hence --json: write
# the table next to the recordings and hand it to analyze.py --clocks.
#
# Usage: tools/sync_phone_clocks.sh                  # set + verify
#        tools/sync_phone_clocks.sh --check          # measure only
#        tools/sync_phone_clocks.sh --json PATH      # also write the table
set -u

CHECK_ONLY=0
JSON_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --json)  shift; JSON_OUT="${1:-}" ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

serials=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
skipped=$(adb devices | awk 'NR>1 && $1!="" && $2!="device" {print $1" ("$2")"}')
[ -n "$skipped" ] && echo "skipping: $skipped"
if [ -z "$serials" ]; then
  echo "no devices attached"
  exit 1
fi

# The reference: this machine. macOS keeps itself NTP-synced; print its own
# offset so the table below has a trusted zero.
if command -v sntp >/dev/null 2>&1; then
  echo "host vs NTP: $(sntp time.apple.com 2>/dev/null | tail -1)"
fi

CHECK_ONLY="$CHECK_ONLY" JSON_OUT="$JSON_OUT" python3 - "$serials" <<'PY'
import json, os, pathlib, re, subprocess, sys, time

check_only = os.environ["CHECK_ONLY"] == "1"
json_out = os.environ.get("JSON_OUT") or ""

# Wireless debugging does not name a phone by its serial: adb prints the mDNS
# service instead, `adb-<serial>-XXXXXX._adb-tls-connect._tcp`, and the XXXXXX
# is regenerated every time the phone is re-paired. Keying the fleet map by
# that string means the entry dies at the next pairing — silently, since an
# unmapped device just loses its pubkey. The real serial is inside it, so
# identity is taken from there and the map holds serials only.
_MDNS = re.compile(r"^adb-(.+)-[^-]+\._adb-tls-connect\._tcp$")

def stable_id(serial):
    m = _MDNS.match(serial)
    return m.group(1) if m else serial

def sh(serial, *cmd, timeout=10):
    return subprocess.run(["adb", "-s", serial, "shell", *cmd],
                          capture_output=True, text=True,
                          timeout=timeout).stdout.strip()

def sample(serial):
    """One clock read: (device_epoch_s, t0, t1, coarse)."""
    t0 = time.time()
    out = sh(serial, "echo $EPOCHREALTIME")
    t1 = time.time()
    if not out or out.startswith("$"):  # mksh too old for EPOCHREALTIME
        t0 = time.time()
        out = sh(serial, "date", "+%s")
        t1 = time.time()
        return float(out), t0, t1, True
    return float(out), t0, t1, False

def offset(serial):
    """Best-of-5 offset vs this machine, half-RTT corrected."""
    sample(serial)  # warm-up: the first call carries connection setup
    best = None
    for _ in range(5):
        dev, t0, t1, coarse = sample(serial)
        rtt = t1 - t0
        off = dev - (t0 + t1) / 2
        if best is None or rtt < best[1]:
            best = (off, rtt, coarse)
    off, rtt, coarse = best
    return off, rtt / 2 + (0.5 if coarse else 0.0), rtt

rows = []
for serial in sys.argv[1].split():
    model = sh(serial, "getprop", "ro.product.model")
    before, err, rtt = offset(serial)
    after, result = before, ""
    if not check_only:
        # Aim the write at arrival time: now plus one estimated one-way trip.
        target_ms = int((time.time() + rtt / 2) * 1000)
        out = subprocess.run(
            ["adb", "-s", serial, "shell", "cmd", "alarm", "set-time",
             str(target_ms)],
            capture_output=True, text=True, timeout=10)
        result = (out.stdout + out.stderr).strip().replace("\n", " ")
        after, err, _ = offset(serial)
    rows.append((serial, model, before, after, err, result))

print(f"\n{'serial':<24} {'model':<14} {'before':>9} {'after':>9} "
      f"{'±':>7}  verdict")
worst = 0.0
refused = []
for serial, model, before, after, err, result in rows:
    worst = max(worst, abs(after))
    ok = abs(after) <= 0.25 + err
    if not ok:
        refused.append(serial)
    verdict = "OK" if ok else "STILL OFF"
    if not ok and result:
        verdict += f" (set-time said: {result[:60]})"
    print(f"{serial:<24} {model:<14} {before:>+8.3f}s {after:>+8.3f}s "
          f"{err:>6.3f}s  {verdict}")

if json_out:
    # A one-time serial -> pubkey map, because the pubkey cannot be read off
    # the phone: recordings live in app-private storage. Fill it once (the
    # device_id in any upload IS the pubkey hex) and every later sync carries
    # the identity the traces are keyed by.
    fleet = {}
    try:
        fleet = json.loads(pathlib.Path("tools/fleet_map.json").read_text())
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as e:
        print(f"  tools/fleet_map.json unreadable ({e}) — writing without "
              f"pubkeys")
    payload = {
        "measuredAtMs": int(time.time() * 1000),
        "checkOnly": check_only,
        "devices": [
            {"serial": stable_id(serial), "model": model,
             "offsetBeforeS": round(before, 4),
             "offsetS": round(after, 4),
             "errS": round(err, 4),
             **({"pubkey": fleet[stable_id(serial)]}
                if stable_id(serial) in fleet else {})}
            for serial, model, before, after, err, _ in rows
        ],
    }
    pathlib.Path(json_out).write_text(json.dumps(payload, indent=2))
    unmapped = [stable_id(r[0]) for r in rows if stable_id(r[0]) not in fleet]
    print(f"wrote {json_out}")
    if unmapped:
        print(f"  no pubkey for {len(unmapped)} device(s): add them to "
              f"tools/fleet_map.json as {{\"<serial>\": \"<pubkey hex>\"}} "
              f"so analyze.py --clocks can match them")

print()
if worst > 0.3:
    print("a phone would not take the clock write (Android 8.x denies")
    print("SET_TIME to the shell uid — the Nexus 5X). Falling back to NTP:")
    print("point the phone at time.google.com and toggle auto_time, which")
    print("8.x accepts and applies within a minute. Needs the phone on a")
    print("network; measured on the 5X pair it lands within ~150 ms.")
    for serial in refused:
        for cmd in (["settings", "put", "global", "ntp_server", "time.google.com"],
                    ["settings", "put", "global", "auto_time", "0"],
                    ["settings", "put", "global", "auto_time", "1"]):
            subprocess.run(["adb", "-s", serial, "shell"] + cmd,
                           capture_output=True, timeout=15)
        print(f"  {serial}: NTP armed — re-run this script in ~1 min to verify")
else:
    print("all phones now agree with this machine to within measurement error.")
PY
