# Fleet map — adb serial ↔ Grassroots pubkey

`tools/sync_phone_clocks.sh --json` measures a clock offset per **adb serial**;
every trace is keyed by **pubkey**. Nothing on the phone bridges the two: the
recordings live in app-private storage, so adb cannot read the identity, and
four handsets share one model (Nexus 5X) so the model does not disambiguate
them either. Hence this file — serials are stable, join orders are not.

`tools/fleet_map.json` is the machine-readable half:

```json
{
  "<adb serial>": "<full pubkey hex>"
}
```

## The fleet as of 2026-08-13 — RENUMBERED, and one phone short

The Pixel 2 dropped off adb (wireless debugging pairing lost) and is out of the
fleet until it is re-paired or cabled. The remaining seven were renumbered 1-7
contiguously with the traveller as 1, so there is no gap where it was.

| join | serial | phone | Android | pubkey | was |
|---|---|---|---|---|---|
| 1 | `56261FDCH00B50` | Pixel 10 Pro | 16 | `f5aee069…` | 2 |
| 2 | `8DM0218B02000956` | Huawei HMA-L09 | 9 | `be3a5ef5…` | 1 |
| 3 | `RF8M337Q3FE` | Galaxy S10e | 12 | `929a022c…` | 4 |
| 4 | `00f8380a3668adb1` | Nexus 5X | 8.1 | `18130c0f…` | 5 |
| 5 | `00de4b24f89021e4` | Nexus 5X | 8.1 | `b7d04acb…` | 6 |
| 6 | `0253914a45ebaeb0` | Nexus 5X | 8.1 | `44a266c4…` | 7 |
| 7 | `00d98aa1795bc454` | Nexus 5X | 8.1 | `d5aedd63…` | 8 |
| — | `HT7AG1A00486` | Pixel 2 | 11 | `c3cba742…` | 3, OFF ADB |

**Node 1 is the TRAVELLER** — the phone that goes dark in a store-carry-forward
run. It moved to the Pixel 10 Pro because it is the only handset in the fleet
with no GATT exhaustion and no Bluetooth stack crashes; the Pixel 2 that held
the role had seven stack crashes in one day.

**As of writing, 2-7 are confirmed renamed** (each read off its own You screen
after saving, with the pubkey verified first). **The Pixel 10 is still `2`** —
it is locked behind its post-boot PIN, so its app data is credential-encrypted
and the launcher activity does not resolve. It needs one physical unlock before
the rename to `1` can be made.

A peer's Nearby list LAGS a rename — during the renumber several phones showed
two peers claiming one number. The authoritative value is the phone's own You
screen, never a neighbour's list of it.

**Every trace recorded before 2026-08-13 uses the OLD numbering**, and
scf-rearm-1..5 additionally ran with eight phones. Join order is only meaningful
alongside the numbering that was live when the run was recorded; the pubkey is
the only identifier that never moves.

### The ninth handset

`31311JEHN12328` / `6b819f64…` (Pixel 7a) carries a key and appears in runs up
to 2026-08-11, but was not attached on 2026-08-12. It held join order 1 under
the old numbering, which the Huawei now holds.

### A nickname must be a number

The nickname IS the join order the testbed screen reads (`int.tryParse`,
strict — `pixel-2` must not silently become node 2). A non-numeric nickname
falls back to 1, which is how `load-sweep-1` ended up with several phones
believing they were node 1 and only 45 of its 300 steps ever reaching
`connected`. Check every phone's nickname parses before a plan whose steps
gate on `role <= n`.

### The mDNS name is not a serial

Over wireless debugging, `adb devices` prints
`adb-<serial>-XXXXXX._adb-tls-connect._tcp` rather than the serial, and the
`XXXXXX` is regenerated on every re-pairing. `fleet_map.json` therefore holds
**serials only**; `sync_phone_clocks.sh` strips the mDNS wrapper before the
lookup. Do not add an `adb-…_tcp` key to the map — it maps a phone for exactly
as long as the current pairing lasts, and when it stops matching the device
silently loses its pubkey rather than erroring.

### Location on the Android 8.1 units

All four Nexus 5X had `settings get secure location_providers_allowed`
populated after Dan toggled location on 2026-08-12. `0253914a45ebaeb0` read
**empty** before that toggle — the state in which the scanner is blind while
the UI can still show location as on. Check this key on all four before every
run; it is one adb read per phone and it is the difference between a mesh and
a phone that only ever answers.

### Clocks: reboot the Nexus 5X

Android 8.1 denies `SET_TIME` to the shell uid, so the four Nexus 5X cannot be
written by `sync_phone_clocks.sh` — it reports `No shell command
implementation.` and leaves them wherever they are. That is not the same as
being stuck: after a power cycle on 2026-08-12 all four came back inside
±0.03 s of NTP on their own, against the +0.36…+0.83 s they had been sitting
at. **Reboot the 5X units, then sync the writable four**; on 2026-08-12 that
put the whole fleet inside ±0.065 s. Manual time does not survive a power
cycle, so sync after every reboot, not before.

## Pairing a phone by hand

Open the app and stay on the **You** tab: it prints the nickname, the
fingerprint and the full public key together. (Settings → Testbed also prints
**This device** with the pubkey, but not the nickname.) Match the first 8 hex
characters against the table and write the serial down. Ten seconds per
phone, once.

The app is a release build, so `adb shell run-as` cannot read the app's
private storage: the nickname can only be read and changed through the UI.

## Checking it

```bash
tools/sync_phone_clocks.sh --check --json /tmp/clocks.json
```

It names every attached device with no pubkey in `fleet_map.json`. When the
list is empty the map is complete, and `analyze.py --clocks` can attribute
each measured offset to the phone the traces know.
