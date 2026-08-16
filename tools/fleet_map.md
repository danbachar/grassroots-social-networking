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

## The fleet as of 2026-08-14 — RENUMBERED 1-6, a six-phone clique

The clique is six phones, numbered 1-6 contiguously. Each nickname below was
read off that phone's own You screen on 2026-08-14, with the pubkey verified
first; the Pixel 10 confirmed "5 peers in reach" (the full clique) on the same
screen. Three earlier handsets are detached and out of the fleet (listed after
the table); their serial↔pubkey bindings stay in `fleet_map.json` so they
recover their identity the moment they re-attach.

| join | serial | phone | Android | pubkey | was |
|---|---|---|---|---|---|
| 1 | `8DM0218B02000956` | Huawei HMA-L09 | 9 | `be3a5ef5…` | 2 |
| 2 | `RF8M337Q3FE` | Galaxy S10e | 12 | `929a022c…` | 3 |
| 3 | `56261FDCH00B50` | Pixel 10 Pro | 16 | `f5aee069…` | 1 |
| 4 | `00f8380a3668adb1` | Nexus 5X | 8.1 | `18130c0f…` | 4 |
| 5 | `0253914a45ebaeb0` | Nexus 5X | 8.1 | `44a266c4…` | 6 |
| 6 | `00d98aa1795bc454` | Nexus 5X | 8.1 | `d5aedd63…` | 7 |

Detached, not in the clique:

| serial | phone | Android | pubkey | note |
|---|---|---|---|---|
| `00de4b24f89021e4` | Nexus 5X | 8.1 | `b7d04acb…` | was 5, dropped off adb |
| `HT7AG1A00486` | Pixel 2 | 11 | `c3cba742…` | was 3, OFF ADB (pairing lost) |
| `31311JEHN12328` | Pixel 7a | — | `6b819f64…` | ninth handset, not attached since 2026-08-11 |

**The traveller is the Pixel 10 Pro, now node 3** (`f5aee069…`) — the phone that
goes dark in a store-carry-forward run. It carries the role because it is the
only handset with no GATT exhaustion and no Bluetooth stack crashes (the Pixel 2
that once held it crashed its stack seven times in one day). The join number no
longer marks the traveller — the pubkey does; a run's traveller is set by the
plan, not by whoever happens to be node 1.

A peer's Nearby list LAGS a rename — during a renumber several phones show two
peers claiming one number. The authoritative value is the phone's own You
screen, never a neighbour's list of it.

**Every trace recorded before 2026-08-14 uses an OLD numbering** (the fleet was
renumbered on 2026-08-13 and again here), and scf-rearm-1..5 additionally ran
with eight phones. Join order is only meaningful alongside the numbering that was
live when the run was recorded; the pubkey is the only identifier that never
moves.

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
