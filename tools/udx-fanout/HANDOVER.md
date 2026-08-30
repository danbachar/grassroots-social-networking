# UDX fan-out: measured phone capacity

This answers **how a phone's UDX throughput scales with concurrent peer
count**, for the mesh simulator's Internet-backbone arm (leaders holding a
UDX link to every other leader — a full mesh, ~46 peers at 160 simulated
nodes, 110+ at 480). The number here feeds a modelling decision: if a
handset cannot service that many concurrent UDX peers, the backbone needs
multi-hop forwarding instead of a full mesh, and the oracle-arm result is
partly an artifact of the full-mesh assumption.

## Setup

Nexus 5X (Android 8.1) driving `PEERS` concurrent UDX streams to a
10-core Mac on the same LAN, each stream writing 32KB chunks flat out for
60s, 10 independent repeated runs per data point (`tools/udx-fanout/`,
`run-fanout.sh` / `summarize.py`). LAN, not WAN — no NAT, no carrier
variance, more bandwidth than the Internet path the simulator models.
Treat this as a phone-CPU ceiling, not a WAN throughput prediction.

`grassroots_dart_udx` has **no encryption of its own** (checked the
package source directly — no cipher/AEAD/Noise anywhere in it; the
"handshake" it does is connection-ID setup, not crypto). The app's Noise
session wraps payloads *above* this transport. So every number below is
already encryption-free UDX; there is no separate "with/without crypto"
axis to measure.

## The dominant effect: isolate-splitting, not just cores

Splitting the per-stream write loop across worker isolates
(`ISOLATES=min(6,N)`, one per stream up to the phone's 6 CPU cores) is a
5-6x throughput multiplier over running every stream's write loop on the
single main isolate. Part of this is real parallelism across cores, but
part of it is structural: the single-isolate path shares its isolate
with `IntegrationTestWidgetsFlutterBinding`'s own test-framework
overhead, and moving the write loop to a dedicated isolate removes that
even at N=1 (628.8 kB/s vs 390.9 kB/s, no added parallelism possible at
N=1). **Production (`lib/src/transport/udp_transport_service.dart`)
runs single-isolate today** — the isolate-split numbers are an
achievable ceiling if that transport were restructured to use worker
isolates, not what is currently shipped.

| N | single-isolate kB/s (current production shape) | isolates=min(6,N) kB/s (achievable ceiling) |
|---|---|---|
| 1 | 390.9 | 628.8 |
| 2 | 378.1 | 1,321.3 |
| 3 | 360.8 | 1,757.0 |
| 4 | 346.3 | 1,952.6 |
| 5 | 333.2 | 1,738.7 |
| 6 | 320.1 | 1,634.9 |
| 7 | 325.1 | 1,561.3 |
| 8 | 328.1 | 1,552.8 |

The two shapes differ in where they peak. The isolate-split curve peaks
at N=4. The single-isolate curve — the one production ships — peaks at
**N=1** and declines monotonically to N=6 (390.9 down to 320.1), with a
slight recovery at 7-8 that stays below its N=1 value. There is no
efficient range at 3-4 in the shipped shape: the first additional peer
already costs throughput. Both shapes decline afterward — fan-out has a real
per-stream cost regardless of isolate count, isolates just raise the
whole curve. Neither shape shows a cliff or starved streams; the
decline is fair degradation, not failure (0 stalled streams, 0 write
errors, 0 open failures across the entire final dataset).

## UDX vs. a pure-UDP ceiling (same isolate count)

To separate "cost of UDX's reliability/congestion-control/multiplexing"
from "cost of N concurrent flows on one phone," the same sweep was run
over raw fire-and-forget UDP (no stream, no ACK, no retransmission, no
congestion control — MTU-safe 1400B writes to avoid IP-fragmentation
loss, receiver-confirmed bytes not sender-claimed):

| N | UDX kB/s | pure-UDP kB/s (receiver-confirmed) | UDP loss % | UDP/UDX ratio |
|---|---|---|---|---|
| 1 | 628.8 | 10,175.7 | 0.2 | 16.2x |
| 2 | 1,321.3 | 19,300.3 | 0.7 | 14.6x |
| 3 | 1,757.0 | 25,653.0 | 1.1 | 14.6x |
| 4 | 1,952.6 | 31,113.0 | 2.8 | 15.9x |
| 5 | 1,738.7 | 31,146.2 | 2.2 | 17.9x |
| 6 | 1,634.9 | 31,902.8 | 3.0 | 19.5x |
| 7 | 1,561.3 | 30,449.4 | 1.4 | 19.5x |
| 8 | 1,552.8 | 30,443.3 | 2.4 | 19.6x |

UDX costs 15-20x pure UDP throughput at every matched N. Since UDX has
no encryption, that entire cost is congestion control (cwnd/pacing tied
to RTT), retransmission/ACK bookkeeping, and stream multiplexing
overhead — not crypto. Pure UDP's own loss (0.2-3.0%, receiver-confirmed
against sender-claimed bytes) is the real LAN floor after eliminating
self-inflicted IP-fragmentation loss and receive-buffer overflow; it is
not zero and cannot be made zero without adding back some form of
acknowledgment and retry, which is what UDX exists for.

## For the simulator

- **Current production shape** (single-isolate): use the first column
  above as the realistic per-node UDX capacity today. It peaks at
  390.9 kB/s with a single peer and *declines* from the second one on —
  a node holding a full-mesh backbone at N=46+ is on the flat/declining
  tail of this curve, well past its efficient range.
- **Isolate-split ceiling**: the second column is what's achievable if
  the transport were restructured (not proposed for production as part
  of this work) — still peaks near N=3-4 and declines, just ~5x higher.
  Even at this ceiling, the curve is still declining by N=8, not flat —
  there is no evidence a real handset holds constant-cost concurrent
  UDX connections at any measured isolate count.
- Neither curve was measured past N=8 concurrent UDX peers. Extrapolating
  the decline out to N=46-110 (the actual full-mesh backbone sizes) is
  unverified — the honest statement is "throughput per peer keeps
  falling through N=8 with no sign of flattening," not a specific
  number at N=46.
- This is a LAN measurement (no NAT, no WAN RTT/loss/carrier variance).
  The Internet backbone arm's real conditions are strictly worse than
  what's measured here — treat these numbers as an optimistic ceiling
  for the WAN case, not a prediction of it.

## What is built

`tools/udx-fanout/`, in the app repo on branch
`claude/grassroots-mesh-simulation-95bcfb`.

- `bin/responder.dart` — N UDX peers, one per UDP port, all in ONE
  process, speaking the app's own stack (`grassroots_dart_udx`).
  `UDX_PORTS` takes a range. Sinks by default; `ECHO=true` echoes.
  `REPORT_S` reports aggregate and per-stream rates on a timer.
  `SILENCE_PROBE_S` is the mapping-lifetime run. Each bind is guarded and
  the `ready` line names any port it could not take.
- `bin/udp_responder.dart` — the raw UDP counterpart.
- `bin/probe_client.dart` — opens the same streams from any machine.
  Check a deployment with this before involving a phone.
- `phone/` — a Flutter `integration_test` that runs on the handset.
  `CHUNK_BYTES>0` writes flat out; `CHUNK_BYTES=0` holds idle and
  keepalives, which is the mapping-lifetime and latency run. `ISOLATES`
  splits the write loop across worker isolates.
- `run-fanout.sh` — sweeps fan-out and repeats, sampling power alongside.
  `--transport udx|udp`, `--isolates`, `--reps`, `--chunk`.
- `summarize.py`, `analyze.py`, `analyze_udp_delivery.py`.

Each run is its own `flutter test` process, so its socket, multiplexer
and streams are built and destroyed inside it: repeats share no transport
state. The phone closes everything explicitly and waits before exiting,
and logs `closed` so it can be confirmed.

## What is NOT measured yet

Everything above is LAN. The Internet leg has never been run in sink
mode, and two questions are open because of it.

**The NAT question, which decides whether a wide backbone is cheap at
all.** Each responder logs the source address and port it sees, which is
the phone's mapping after its NAT rewrote it. Every responder reporting
the SAME port means the whole fan-out costs ONE mapping and one
keepalive; a DIFFERENT port per responder means N mappings and N
keepalives. That distinction belongs to the carrier, not the app, and a
same-subnet LAN run cannot answer it — there is no NAT in the path, so
those source ports are just local ephemerals. `analyze.py` reads it out
of a WAN run's `open` lines.

**Mapping lifetime.** `--silence-probe T` makes a responder go quiet for
T seconds after the last byte it received, then send unsolicited data. A
`probe_recv` line on the phone means the mapping survived T seconds of
silence; its absence is the finding. Binary-search T for the keepalive
interval every peer has to pay for. Run it with `--chunk 0` and a long
`--keepalive`, so the phone is genuinely idle.

## Deploying the Internet leg

SSH to `trace-server` works again — the Hetzner Cloud Firewall was
missing its inbound TCP 22 rule, which is why it timed out while 443 and
the UDP range answered. The responders at 178.105.61.162 (ports
41000-41127) are still the ECHO build and have never been redeployed from
current source, so the WAN numbers that exist are all from a responder
that echoed every byte back and doubled the radio load.

```bash
rsync -a --delete --exclude .dart_tool --exclude build --exclude android \
  --exclude .metadata tools/udx-fanout/ trace-server:~/udx-fanout/
ssh trace-server 'cd ~/udx-fanout && ./gen-compose.py -n 8 && \
  docker compose up -d --build && sleep 20 && \
  docker compose logs --no-color --tail 200 | grep ready'
```

Expect `"bound":8,"requested":8,"unavailable":[]`. **Do not run one
container per peer** — 128 of them needs ~1.3 GB and that host has ~1.1
GB free while running the trace server. One process serving 128 ports
measures 21 MB. Host networking is required: Docker's bridge rewrites
inbound UDP source addresses, which erases the NAT measurement.

## Practical notes

- Phone is a **Nexus 5X, Android 8.1**, serial `0253914a45ebaeb0`, also
  reachable over wireless adb at `192.168.1.13:5555`. It exposes **no
  readable `current_now`** at any path tried, so power can only come from
  `charge_counter` deltas.
- **Never use `cmd battery unplug` on it.** It reconfigures USB, takes
  adb down mid-run, and leaves the phone believing it is unplugged after
  adb is gone — so the reset never lands and it sits there not charging.
  Unplug by hand over wireless adb instead; the script only checks and
  warns.
- Its Wi-Fi is often left disabled by BLE testbed runs: `svc wifi enable`.
- Do not disable Wi-Fi on the Pixel 7a or the two Galaxys — they are
  wireless-adb only and you will lose them.
- Run nothing heavy on the Mac without checking what else is on it; it
  has 10 cores and 16 GB and other work shares them.
- Standing rules: never `git push` without asking, never delete anything
  on the trace-upload server, and launch long compute only when asked.

## Why the number matters

The simulator's aggregation arm reaches oracle-level delivery — 0.9931 at
480 nodes against the oracle's 0.9998 — at less than half the oracle's
relay cost (5.7 relays per delivery against 12.3). But its backbone is a
full mesh, and the measured degree distribution is bimodal, not spread:
members hold zero UDX links and every leader holds exactly *(leaders −
1)*, which is **44 at 160 nodes, 109 at 320, 168 at 480**, growing
linearly with the network. The relay split says almost exactly one UDX
transmission per message (p25 through p99 all equal 1), so a leader is
not lightly using a wide mesh — any given message needs one specific peer
out of those 168.

Against that, the measurement above says throughput per peer is already
falling by the second peer and has not flattened by eight. That gap is
the case for capping backbone degree and adding multi-hop forwarding
between leaders, and it is now measured from both ends.
