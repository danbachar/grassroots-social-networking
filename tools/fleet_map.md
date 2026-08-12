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
| `be3a5ef56240eb49764a9be72930f5a2fbc0c2fe99dbd04a13a19944a26ec4d8` | — | 4 |
| `18130c0f5a36449cc5c1d5e0c17e83ba4d248625655035b08e971693fb29ae40` | — | 5 |
| `b7d04acb9336998acae81afd20b42895b035f3fea83f1e2dd73d0f54799e7997` | — | 6 |
| `44a266c4c9912ec34ea7934fbbffae1745ab82df0229f8972440ae3f43862fa4` | — | 7 |

The four unnamed ones are the Nexus 5X units (and whichever other handset
filled slot 4). They are indistinguishable by model, so their serials have to
be paired by reading each phone's own key.

## Pairing the remaining phones

Open the app on the phone, Settings → Testbed: the screen prints **This
device** with its pubkey. Match the first 8 hex characters against the table
and write the serial down. Ten seconds per phone, once.

## Checking it

```bash
tools/sync_phone_clocks.sh --check --json /tmp/clocks.json
```

It names every attached device with no pubkey in `fleet_map.json`. When the
list is empty the map is complete, and `analyze.py --clocks` can attribute
each measured offset to the phone the traces know.
