# Ring-radius conveyance experiment — implementation handover

You are implementing a new testbed experiment for the Grassroots BLE mesh.
Read `CLAUDE.md` at the repo root first — the mesh/session/DTN vocabulary
below is defined there, and its rules (no legacy shims, Redux-only state,
no compatibility decoders) bind everything you write.

## Why this experiment exists

No experiment in the dataset exercises multi-hop conveyance as the
NECESSARY delivery path. The line sweep has two devices (no third party to
relay). The diluting clique is a complete graph — measured at N=7, every
node held 5-6 peers on 10-15 concurrent links, so diameter stayed 1 and
only 0.06% of arrivals came via a third party. The evaluation chapter's
claim that conveyance "becomes the primary delivery method" is untestable
on those setups. This experiment manufactures diameter on a desk by
constraining WHICH links may form, and measures conveyance share, arrival,
hop counts, and latency as connectivity grows from a ring to the complete
graph.

## Design (settled with Dan — do not relitigate these)

**Topology: ring-radius allowlist, NOT a numeric link cap.** The N devices
are ordered into a ring by sorted pubkey; at radius `r`, a node may hold
links only to peers within ring distance `r` (mod N). A numeric "max k
links" cap was considered and rejected: at k=2 the emergent 2-regular
graph is frequently two disjoint cycles — a permanent partition, and
arrival then measures partition luck. The circulant ring is connected by
construction with known diameter at every stage:

| r | links/node | diameter (N=11) |
|---|---|---|
| 1 | 2 | 5 |
| 2 | 4 | 3 |
| 3 | 6 | 2 |
| 4 | 8 | 2 |
| 5 | 10 | 1 (complete = the measured clique baseline) |

r=4 may be dropped if the run is too long — it duplicates r=3's diameter.

**Warm-up is message-free, uncapped, and MANDATORY — sessions are the
point.** A packet may not exist before a session with its target does
(CLAUDE.md invariant), and sessions form only over a direct link during
the Noise handshake. Under the allowlist, non-neighbours can never
handshake — so every pair must handshake BEFORE the allowlist activates.
Warm-up: all devices unconstrained until every node holds N-1 sessions
(gate on session count, not on time). No messages are sent during warm-up.

**Between stages: sever GATT links ONLY.** Sessions and DTN state persist
by design — the session table is keyed by identity and survives link loss.
The line-200 restart window (which also cleans Noise sessions and empties
DTN buffers) is exactly the wrong primitive here; do not reuse it. A new,
lighter primitive is needed: disconnect all GATT links, touch nothing
else.

**Uniform trial windows across ALL r.** Same dwell + same drain at every
radius, sized for the r=1 worst case. Window length that varies with r
bakes an r-dependent censoring bias into the design (drain length controls
how much of the multi-hop tail is counted). Fast topologies finish earlier
INSIDE the same window — that is latency, not truncation. Starting point:
**3 min dwell + 2 min drain**; the drain must cover ~5 hops x the 10 s
announce cadence plus queueing. Tune only after a smoke run, and if tuned,
tune ALL stages together.

**Trials: 10 per r minimum, INTERLEAVED randomized sweeps, not blocked.**
Run 10 full sweeps, each visiting every r once in per-sweep randomized
order. The diluting clique ran blocked (all trials at one N, then the
next) and its condition became inseparable from chronology — a
trace-completeness dropout mid-session was confounded with N and could not
be untangled afterwards. Interleaving makes every r sample the whole
session's battery/thermal/trace-health trajectory. Widening r only ADDS
allowed links (cheap); shrinking needs the prune. Budget ~1 min per
transition. Total: 5 r x 10 trials x 5 min + ~50 transitions ≈ 5 h (~4 h
without r=4).

**Load: low, and prefer non-neighbour recipients.** On the ring every link
carries transit for many pairs, so per-LINK load is what saturates — the
clique broke down well below this fleet's aggregate potential. Starting
point: each node sends one 138 B message every 2 s to a rotating recipient
drawn from its current NON-neighbours (maximizes conveyance measurement
per unit airtime; at r=5 there are no non-neighbours, so rotate over
everyone — that stage reproduces the clique). Tunable after the smoke run.

## Verified constants (do not change them for this experiment)

- `GrassrootsPacket.defaultTtl = 7` (`lib/src/models/packet.dart`) —
  clears the worst diameter (5) with margin. relayHops = 7 - ttl at the
  receiver.
- `announceInterval = 10 s` (`lib/src/grassroots_network.dart`) — the
  per-hop conveyance latency quantum: a carried packet moves at most one
  hop per sync round. Expect ~10 s quantization steps in latency vs hop
  count; that figure is a deliverable, not a bug.

## What to build

1. **Ring allowlist gate in the BLE transport.** Config carries the full
   roster of N pubkeys (testbed config, like the fleet map) and the active
   radius r. Link formation is allowed iff ring_distance(own, peer) <= r.
   Enforce on BOTH sides: refuse to dial a non-allowed peer AND refuse an
   inbound connection from one (a one-sided gate leaks links through the
   other side's dial). On r decrease, prune now-disallowed links. The gate
   applies to LINK formation only — never to ANNOUNCE processing, session
   logic, or the send path. Dual-role pairs count as ONE neighbour (two
   legs), consistent with the dual-role mandate: an allowed pair still
   converges to both legs.
2. **Links-only reset primitive.** Sever every GATT link; keep sessions,
   DTN buffers, seen-sets untouched.
3. **Testbed preset** (`lib/src/testbed/field_plan_presets.dart` family):
   message-free warm-up gated on session count; then the staged schedule —
   markers per trial following the existing label convention so
   `marker_segments` parses (use `r=<radius> t<trial>` exactly as `d=` and
   `N=` are used today; note `trace_server/analyze.py` gates its figures
   on `d=`/`N=` regexes, so the new `r=` prefix needs a matching segment
   pattern there); per-trial send window then drain (the `t1_drain`
   convention); randomized per-sweep r order, seeded and LOGGED so the
   schedule is reconstructible.
4. **Tests** for ring distance, both gate directions, prune-on-shrink, and
   the links-only reset preserving sessions. Follow the existing test
   idiom in `test/transport/` and `test/testbed_*`.

No new trace record types are needed: `relay` already carries
hop/ttlIn/ttlOut/dwellMs (dwellMs is single-clock, per-hop — the latency
decomposition is built from it and needs no cross-device clock sync);
`recv` carries relayHops/fromPeer; `custody` covers store/convey/end.

## Known hazards, each one already measured

- **Trace-volume dropout.** Custody/relay are the highest-volume record
  types and their completeness degraded silently mid-session in the clique
  run (one N=3 block lost its convey records entirely while message
  records stayed perfect). This run is longer and larger. Verify the trace
  upload path's headroom BEFORE the run, and afterwards check per-trial
  custody/relay counts for cliff-shaped drops before trusting any
  conveyance-share number.
- **Send-windowed attribution.** Deliveries land after their trial's
  window (measured: median last relay activity 11.7 s past run-end at
  diameter ONE). Analysis must window the SEND and count the receive
  wherever it lands (`_clique_sent_ids` in `trace_server/analyze.py` is
  the convention; getting it wrong cost 68.9% vs 91.5% arrival at N=3).
- **Sessions must never be cleaned mid-run.** One accidental full restart
  makes every later message to a non-neighbour FAIL at creation (no
  session, no packet) and the run is dead from that point. If a phone's
  app must be restarted mid-run, that run is over — mark it and stop.
- **Stage starts send into zero links, by design.** The runner's send
  ticker gates on `sessionUp`, and sessions survive the links-only reset —
  so at every stage start it fires at full rate before any link has
  re-formed. Those sends fall to the DTN buffer and go out via the sync
  exchange once links land: this is the mechanism under test, not a bug,
  but expect a `noPath` drop burst per transition and remember stage-start
  delivery latency includes link formation.

## Fleet and logistics (standing rules — from Dan, non-negotiable)

- 11 devices: 4x Nexus 5X, 2x Pixel Pro, Huawei, Pixel 2, Pixel 7,
  Galaxy S10e, Galaxy Note. Dan's iPhone stays off/excluded.
- **One agent per phone** when driving the testbed. Never a single serial
  loop.
- **Wireless-adb phones** (Pixel 7, both Galaxys): never disable their
  Wi-Fi, never reboot them; exclude them from any wifi-off step.
- **Clock sync FIRST**: `tools/sync_phone_clocks.sh` (works on Android
  9+; the 8.1 Nexus 5X refuse — known). Sync before, check after: the run
  is hours long and cross-device latency legs need it. Never reboot a
  phone with auto_time=0.
- **Chargers on all phones** — this is a 4-5 h run and the 5X will not
  survive it on battery, and thermal drift skews late trials.
- BT stack reset if a phone's stack refuses everything: force-stop the app
  first, then com.android.bluetooth. The svc/cmd routes are blocked.
- Nexus `00d98aa1` is the known reset-cost outlier (15 s resets on ~20% of
  attempts) — check it before blaming a hardware class.
- Commit locally on a branch; **never push and never launch the 11-phone
  run without Dan's explicit go**. Scope ends at: code + tests + preset +
  a small desk smoke run (2-3 phones, one short sweep) to prove the gate,
  the reset primitive, and the markers — then stop and report.

## Deliverables checklist

- [ ] Allowlist gate (dial + accept + prune), tests passing
- [ ] Links-only reset primitive, test proving sessions survive
- [ ] Staged preset with `r=` markers, randomized-sweep schedule logged
- [ ] `analyze.py` segment support for `r=` labels
- [ ] Smoke run (2-3 phones) showing: gate holds, non-neighbour message
      arrives via conveyance with relayHops >= 1, markers parse
- [ ] Report: what was built, smoke-run trace evidence, open questions
