# Fleet map — adb serial ↔ Grassroots pubkey

`tools/sync_phone_clocks.sh --json` measures a clock offset per **adb serial**;
every trace is keyed by **pubkey**. Nothing on the phone bridges the two: the
recordings live in app-private storage, so adb cannot read the identity, and
four handsets share one model (Nexus 5X) so the model does not disambiguate
them either. Hence this file, filled in once — serials are stable.

`tools/fleet_map.json` is the machine-readable half:

```json
{
  "<adb serial>": "<full pubkey hex>"
}
```

## The seven pubkeys recorded on 2026-08-08

Confirmed against the handsets by Dan (nickname = join order):

| pubkey | phone | nickname |
|---|---|---|
| `6b819f64b80724df3023daf45b665c8a7b8554b7084fb1c0a2479c0fb08738a3` | Pixel 7a | 1 |
| `f5aee069c6a61bf8ad6c908af35356d89cdaf26ec0246f69993a9cf9414a619c` | Pixel 10 Pro | 2 |
| `c3cba74287fbc882e762e4746064c773a2c0aed36d1130c887e453fc29921e33` | Pixel 2 | 3 |
| `be3a5ef56240eb49764a9be72930f5a2fbc0c2fe99dbd04a13a19944a26ec4d8` | Huawei HMA-L09 | 4 |
| `18130c0f5a36449cc5c1d5e0c17e83ba4d248625655035b08e971693fb29ae40` | Nexus 5X* | 5 |
| `b7d04acb9336998acae81afd20b42895b035f3fea83f1e2dd73d0f54799e7997` | Nexus 5X* | 6 |
| `44a266c4c9912ec34ea7934fbbffae1745ab82df0229f8972440ae3f43862fa4` | Nexus 5X* | 7 |

\* Slots 5–7 are inferred, not read off the handsets: slot 4 turned out to be
the Huawei, which leaves the three remaining Nexus 5X units for 5–7 and
matches their serial format. Confirm on the phone before relying on it.

## The eighth and ninth handsets

Two more phones carry keys and appear in later runs, so the fleet is not
seven:

| pubkey | phone | nickname |
|---|---|---|
| `d5aedd63c7ff00e66c30d6b4274c2ec79b2c6e1afcb5553017621423d348ee12` | Nexus 5X | 8 |
| `929a022c32a603e468f7e8d6f049c13afafcedfd8bc87530ce14862acf478208` | Galaxy S10e | `User_929a022c` |

The S10e's nickname is **not** a number, and the nickname IS the join order
the testbed screen reads (`int.tryParse`, strict — `pixel-2` must not
silently become node 2). A non-numeric nickname falls back to 1, which is how
`load-sweep-1` ended up with several phones believing they were node 1 and
only 45 of its 300 steps ever reaching `connected`. Rename it to a free
number before any plan whose steps gate on `role <= n`.

## Verified on 2026-08-12

Read off each handset's own **You** screen (nickname, fingerprint and public
key are all on it) rather than inferred:

| serial | phone | pubkey | nickname |
|---|---|---|---|
| `00d98aa1795bc454` | Nexus 5X | `d5aedd63…` | 8 |
| `56261FDCH00B50` | Pixel 10 Pro | `f5aee069…` | 2 |
| `8DM0218B02000956` | Huawei HMA-L09 | `be3a5ef5…` | 4 |

All three agree with `fleet_map.json`.

## The eight attached on 2026-08-12, with models read over adb

Every phone in `fleet_map.json` except the Pixel 7a (node 1) was attached.
Model and Android version come from the handsets themselves
(`ro.product.model`, `ro.build.version.release`); the pubkeys are the map's.

| serial | phone | Android | pubkey |
|---|---|---|---|
| `56261FDCH00B50` | Pixel 10 Pro | 16 | `f5aee069…` |
| `HT7AG1A00486` | Pixel 2 | 11 | `c3cba742…` |
| `8DM0218B02000956` | Huawei HMA-L09 | 9 | `be3a5ef5…` |
| `RF8M337Q3FE` | Galaxy S10e | 12 | `929a022c…` |
| `00f8380a3668adb1` | Nexus 5X | 8.1 | `18130c0f…` |
| `00de4b24f89021e4` | Nexus 5X | 8.1 | `b7d04acb…` |
| `0253914a45ebaeb0` | Nexus 5X | 8.1 | `44a266c4…` |
| `00d98aa1795bc454` | Nexus 5X | 8.1 | `d5aedd63…` |

This settles what the slot 5–7 footnote left open in one direction: there are
**four** Nexus 5X units, not three, and the eighth handset (`d5aedd63`) is the
fourth of them. The *join order* of slots 5–7 is still inferred — the models
match, but the model cannot tell three identical 5X units apart. Read the
**You** screen before trusting a numbered role on those three.

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
