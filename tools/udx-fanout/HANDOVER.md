# Handover: UDX fan-out tests

You are taking over an experiment that asks **how a phone's UDX throughput
degrades as it holds more concurrent peers**. Everything below is measured
unless it says otherwise.

## Why it exists

The mesh simulator has an arm where leaders route to each other over the
Internet, and its backbone is a **full mesh**: every leader holds a UDX link
to every other. At 160 simulated nodes that is ~46 concurrent peers per
leader, and it grows with the network — at 480 nodes, 110+. Nobody had
checked whether a handset can actually service that many at once. If it
cannot, the arm's result is partly an artifact of an assumption, and the
backbone needs multi-hop forwarding instead of a full mesh.

So the number this produces feeds a modelling decision. It is not a
benchmark for its own sake.

## What is built

`tools/udx-fanout/` in the app repo (branch
`claude/grassroots-mesh-simulation-95bcfb`, several unpushed commits).

- `bin/responder.dart` — N UDX peers, one per UDP port, all in ONE process.
  Speaks the app's own stack (`grassroots_dart_udx`). `UDX_PORTS` takes a
  range. Sinks by default; `ECHO=true` echoes. `REPORT_S` makes it report
  aggregate and per-stream rates on a timer. Each bind is guarded, and the
  `ready` line names any port it could not take.
- `bin/probe_client.dart` — opens the same streams from any machine. Use it
  to check a deployment before involving a phone.
- `phone/` — a Flutter `integration_test` that runs on the handset. Opens
  PEERS streams, then either writes flat out (`CHUNK_BYTES>0`) or holds idle
  and keepalives (`CHUNK_BYTES=0`). Emits JSON lines that `flutter test`
  carries back to the host.
- `run-fanout.sh` — sweeps fan-out and repeats, sampling power in parallel.
- `summarize.py`, `analyze.py` — read the results.

Read `README.md` first; it carries the constraints that change the answer.

## The measured results so far

**Over the Internet, against an ECHOING responder on a 1-core 2 GB host,
one run per point, 300 s each** (`~/fanout-results/throughput-0830-1008`):

| N | aggregate kB/s | per-stream | slowest | stalled/N |
|---|---|---|---|---|
| 1 | 395 | 395 | 395 | 0 |
| 4 | **514** | 129 | 84 | 0 |
| 16 | 181 | 11.3 | 4.7 | 1/16 |
| 32 | 197 | 6.2 | 0.2 | 16/32 |
| 64 | 233 | 3.6 | 0.0 | 35/64 |
| 128 | 213 | 1.7 | 0.0 | 86/128 |

Aggregate peaks at N=4 and drops ~65%, then sits flat. No write errors and
no permanently starved stream at any N — there is no cliff where the phone
refuses peers. What collapses is fairness: at N=128 the total looks stable
only because a shrinking subset carries it.

**Treat all of that as provisional.** Three confounds, in the order they
matter:

1. **The responder had one CPU core.** A single-threaded Dart process
   serving 128 UDX streams on one core may well have been the bottleneck,
   not the phone. This is the open question — the numbers may be measuring
   the wrong end of the link.
2. **It echoed.** Every byte came back, doubling radio load.
3. **One run per point.** Two identical 2-stream runs later measured 437
   and 301 kB/s — a third apart. One run cannot separate fan-out from
   whatever the radio was doing that minute.

## What is running now

A sweep against a responder on the **Mac** (10 cores, LAN, sink mode),
N=1..8, **10 independent runs each**, 60 s of load per run, 32 KB writes.
Output under `~/fanout-results/lan-sink-*`. Summarise with
`tools/udx-fanout/summarize.py <dir>`.

This is deliberately the control for confound 1: if the LAN curve keeps its
shape, the collapse is the phone; if it flattens out, the earlier numbers
were the 1-core responder giving up. It also removes WAN variance and NAT.
It is NOT a substitute for the Internet run — it has no NAT and far more
bandwidth — so the Internet sweep has to be repeated in sink mode once the
server is reachable.

Each run is its own `flutter test` process, so its socket, multiplexer and
streams are built and destroyed inside it; repeats share no transport
state. The phone closes everything explicitly and waits before exiting, and
logs `closed` so you can confirm.

## The blocker

SSH to `trace-server` (178.105.61.162) **times out**, and a reboot did not
fix it. Diagnosis: TCP 22 is dropped while 443 and UDP 41000-41127 are
allowed, and unallowed ports time out rather than refuse — a default-drop
allowlist in front of the machine, i.e. the **Hetzner Cloud Firewall**, not
the box. Either adding the UDP range displaced the SSH rule, or its source
is pinned to an address the user's CGNAT has rotated away from (their exit
alternates between 5.29.10.136 and 37.142.158.93).

The responders there are alive and answering UDP — they survived a reboot —
but they are still the ECHO build. The fix is one inbound rule (TCP 22,
source 0.0.0.0/0 and ::/0) in the Hetzner console; the user has to do it.

## Deploying, once SSH works

```bash
rsync -a --delete --exclude .dart_tool --exclude build --exclude android \
  --exclude .metadata tools/udx-fanout/ trace-server:~/udx-fanout/
ssh trace-server 'cd ~/udx-fanout && ./gen-compose.py -n 8 && \
  docker compose up -d --build && sleep 20 && \
  docker compose logs --no-color --tail 200 | grep ready'
```

Expect `"bound":8,"requested":8,"unavailable":[]`. **Do not run one
container per peer** — 128 of them needs ~1.3 GB and that host has ~1.1 GB
free while running the user's trace server. One process serving 128 ports
measures 21 MB. Host networking is required: Docker's bridge rewrites
inbound UDP source addresses, which erases the NAT measurement.

## The second experiment, not yet run

`--silence-probe T` on the responder makes it go quiet for T seconds after
the last byte, then send unsolicited data. If the phone logs `probe_recv`,
the NAT mapping survived T seconds of silence; its absence is the finding.
Binary-search T for the keepalive interval every peer must pay for. Run it
with `--chunk 0` and a long `--keepalive`, so the phone is genuinely idle.

Also unread: the `open` lines in the responder log carry the source port the
phone's NAT presented. **All peers sharing one source port** means the
fan-out costs one NAT mapping; **one port per peer** means N mappings and N
keepalives. That distinction decides whether a wide backbone is cheap, and
it belongs to the carrier, not the app. Pull it with `analyze.py`.

## Practical notes

- Phone is a **Nexus 5X, Android 8.1**, serial `0253914a45ebaeb0`, also on
  wireless adb at `192.168.1.13:5555`. It exposes **no readable
  `current_now`** at any path tried, so power can only come from
  `charge_counter` deltas.
- **Never use `cmd battery unplug` on it.** It reconfigures USB, takes adb
  down mid-run, and leaves the phone believing it is unplugged after adb is
  gone — so the reset never lands and it sits there not charging. Unplug
  the cable by hand over wireless adb instead. The script now only checks
  and warns.
- Its Wi-Fi is often left disabled by BLE testbed runs. `svc wifi enable`.
- Do not disable Wi-Fi on the Pixel 7a or the two Galaxys — they are
  wireless-adb only and you will lose them.
- The user's standing rules: never `git push` without asking, never delete
  anything on the trace-upload server, and launch long compute only when
  asked.
