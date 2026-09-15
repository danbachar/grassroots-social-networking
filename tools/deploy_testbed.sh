#!/usr/bin/env bash
#
# Install the release APK on every connected device and put each one into
# field-run condition. Build first — this script deliberately does not, so a
# token never has to travel through it:
#
#     flutter build apk --release --dart-define=TRACE_TOKEN=<token>
#     tools/deploy_testbed.sh
#
# Never uninstalls. An uninstall wipes the Ed25519 identity and any recording
# not yet uploaded, and there is no recovering either.
#
# Each phone's Bluetooth stack is cycled before its install — a stack left up
# for hours goes deaf on these devices. SKIP_BT_RESET=1 skips it for a quick
# reinstall that is not about to be run.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK="${APK:-$REPO/build/app/outputs/flutter-apk/app-release.apk}"
PKG="${PKG:-co.bachar.grassroots}"
BRIGHTNESS="${BRIGHTNESS:-1}"   # 0 is indistinguishable from off on these panels

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

[[ -f "$APK" ]] || { red "No APK at $APK — build first."; exit 1; }

# A debug APK is signed with a different key, so installing it over the release
# build fails, and "fixing" that means an uninstall. Refuse before that idea
# has a chance to occur to anyone.
if [[ "$APK" == *"app-debug.apk" ]]; then
  red "That is the debug APK. Installing it needs an uninstall, which wipes"
  red "identities and unuploaded recordings. Deploy the release build."
  exit 1
fi

# Deploying a stale APK because the build silently failed is expensive and
# invisible: the phones run yesterday's code and nothing says so.
# Source only: android/.gradle and build/ churn on every invocation and would
# make this warn every single time, which trains you to ignore it.
NEWEST_SRC="$(find "$REPO/lib" "$REPO/android/app/src" "$REPO/pubspec.yaml" \
  -type f -newer "$APK" -print 2>/dev/null | head -1)"
if [[ -n "$NEWEST_SRC" ]]; then
  ylw "WARNING: source is newer than the APK — e.g."
  ylw "  ${NEWEST_SRC#"$REPO"/}"
  ylw "The build may have failed. Ctrl-C to stop, or Enter to deploy anyway."
  read -r _
fi

# Read into an array without mapfile: macOS ships bash 3.2, which lacks it,
# and the failure was silent enough to look like "no devices connected".
DEVICES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && DEVICES+=("$line")
done < <(adb devices | awk '/\tdevice$/{print $1}')
(( ${#DEVICES[@]} )) || { red "No devices. Check USB and 'adb devices'."; exit 1; }

printf 'APK  %s (%s)\n' "${APK#"$REPO"/}" \
  "$(du -h "$APK" | cut -f1)"
printf 'Built %s\n' "$(date -r "$APK" '+%Y-%m-%d %H:%M')"
printf 'Deploying to %d device(s)\n\n' "${#DEVICES[@]}"

ok=0; failed=(); wireless=(); btoff=()
for s in "${DEVICES[@]}"; do
  model="$(adb -s "$s" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  printf '== %-18s %s\n' "$s" "$model"

  # Stop Play Protect intercepting the sideload. It holds the install session
  # open behind a "Send app for a security check?" dialog waiting for a tap,
  # so `adb install` blocks with no output and the deploy looks hung rather
  # than prompted. Set before the install, since the dialog appears during it.
  # Undo with `settings put global verifier_verify_adb_installs 1`.
  adb -s "$s" shell settings put global verifier_verify_adb_installs 0 \
    >/dev/null 2>&1 || true
  adb -s "$s" shell settings put global package_verifier_user_consent -1 \
    >/dev/null 2>&1 || true

  # Cycle the Bluetooth stack BEFORE installing.
  #
  # A long-lived Bluedroid stack goes deaf on these phones: on 2026-08-25 a
  # Nexus 5X at 1h43m of stack uptime discovered exactly one peer — the one it
  # was already linked to — for a whole run, was never seen by the other six,
  # and cost that run its N=2 pairing. Every other phone's stack had crashed
  # and been restarted by Android during the previous run; that one's had not.
  #
  # The app is stopped FIRST and left stopped: it survives a stack restart and
  # resumes its connect loop within seconds, refilling the native GATT table
  # the reset exists to free. Installing next is what keeps it stopped — the
  # install is also the settle time, and relaunching against a half-up adapter
  # is what made an earlier attempt fail.
  #
  # Verified by the stack's pid changing, never by the adapter state string: a
  # disable settles in BLE_ON rather than OFF while ble_scan_always_enabled is
  # set, so a check for "OFF" reports a false failure. `svc bluetooth` and
  # `cmd bluetooth_manager` are not usable here — the first needs a permission
  # the shell user lacks below Android 16, the second returns 0 while doing
  # nothing below Android 13.
  if [[ "${SKIP_BT_RESET:-0}" != "1" ]]; then
    pid_before="$(adb -s "$s" shell pidof com.android.bluetooth 2>/dev/null | tr -d '\r')"
    adb -s "$s" shell am force-stop "$PKG" >/dev/null 2>&1 || true
    adb -s "$s" shell am force-stop com.android.bluetooth >/dev/null 2>&1 || true
    sleep 3
    pid_after="$(adb -s "$s" shell pidof com.android.bluetooth 2>/dev/null | tr -d '\r')"
    if [[ -n "$pid_before" && "$pid_before" == "$pid_after" ]]; then
      ylw "   Bluetooth stack did NOT restart (pid $pid_before) — reset it by"
      ylw "   hand before the run, or this phone may go deaf mid-run"
    else
      printf '   bluetooth stack reset (pid %s -> %s)\n' \
        "${pid_before:-none}" "${pid_after:-restarting}"
    fi
  fi

  if ! adb -s "$s" install -r "$APK" >/dev/null 2>&1; then
    red "   install FAILED"
    failed+=("$s ($model)")
    continue
  fi
  printf '   installed\n'

  # One GPS fix per phone at placement needs this, and granting it here beats
  # dismissing eight dialogs while walking a line.
  adb -s "$s" shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION \
    >/dev/null 2>&1 || ylw "   could not grant location (grant it on the phone)"

  # The screen must stay on: a sleeping phone stops scanning, and that is a
  # hole in the topology for the rest of the run.
  adb -s "$s" shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1
  adb -s "$s" shell settings put system screen_brightness_mode 0 >/dev/null 2>&1
  # adb -s "$s" shell settings put system screen_brightness "$BRIGHTNESS" >/dev/null 2>&1
  adb -s "$s" shell dumpsys deviceidle whitelist "+$PKG" >/dev/null 2>&1

  # A phone reached over wireless debugging keeps Wi-Fi associated and
  # transmitting on 2.4 GHz for the whole run, and BLE shares that front end.
  # Scanning survives the contention; opening connections does not. One
  # Pixel 7a on wireless debugging spent a 2h41m run with 12k RSSI samples,
  # 11 verified ANNOUNCEs and ZERO successful dials after its first link died.
  if [[ "$s" == *"_adb-tls-connect._tcp"* || "$s" == *:5555 ]]; then
    ylw "   over WIRELESS DEBUGGING — Wi-Fi will stay on and starve BLE"
    wireless+=("$s ($model)")
  fi

  # System Bluetooth must be ON before the run: the app can turn its own
  # transport on and off, but it cannot turn the adapter on, and a phone whose
  # adapter is off joins nothing. On 2026-08-25 one Pixel sat with its adapter
  # off through its whole join step — the app raised radio-suspect 20 s in and
  # the operator reached it 89 s later, by which time that clique size had
  # been measured with one phone missing. Read from the settings key, which
  # both dumpsys formats agree on, rather than parsing dumpsys per platform.
  bt_on="$(adb -s "$s" shell settings get global bluetooth_on 2>/dev/null | tr -d '\r')"
  if [[ "$bt_on" != "1" ]]; then
    red "   SYSTEM BLUETOOTH IS OFF — turn it on before the run"
    btoff+=("$s ($model)")
  fi

  batt="$(adb -s "$s" shell dumpsys battery 2>/dev/null | awk '/level:/{print $2}' | tr -d '\r')"
  printf '   ready — battery %s%%\n' "${batt:-?}"
  (( ok++ ))
done

echo
if (( ${#failed[@]} )); then
  red "$ok/${#DEVICES[@]} deployed — FAILED:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
grn "$ok/${#DEVICES[@]} deployed and configured."
echo
if (( ${#btoff[@]} )); then
  red "System Bluetooth is OFF on these — the app cannot turn it on, and a"
  red "phone whose adapter is off will join nothing:"
  printf '  %s\n' "${btoff[@]}"
  echo
fi
if (( ${#wireless[@]} )); then
  ylw "Reached over wireless debugging — deploy these by USB and turn Wi-Fi OFF"
  ylw "before the run, or expect them to scan all day and never connect:"
  printf '  %s\n' "${wireless[@]}"
  echo
fi
echo "Before leaving: on each phone confirm Upload is green, then delete the"
echo "experiment files — a new run appends to the old file otherwise, and"
echo "re-uploading it stores the previous run's records a second time."
