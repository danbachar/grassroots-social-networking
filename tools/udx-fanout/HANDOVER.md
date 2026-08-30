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

Both shapes peak around N=3-4 and decline afterward — fan-out has a real
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
  ~346-390 kB/s aggregate and *declines* as peer count grows past ~4 —
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
