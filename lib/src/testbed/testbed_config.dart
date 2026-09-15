import 'package:flutter/foundation.dart';

import '../protocol/fragment_handler.dart';

/// Default synthetic payload size: the largest that still fits ONE sealed
/// packet at the BLE floor MTU. At this size one message *is* one packet, so
/// message counts, delivery ratio and wire bytes all read per-packet with no
/// hidden fragment multiplier. Anything above it is fragmented — a 184-byte
/// message is silently TWO packets, 138 + 46, costing 396 wire bytes to move
/// 184 — which is worth measuring deliberately as a payload arm rather than
/// baking into every experiment.
const int defaultSendBytes = FragmentHandler.fragmentThreshold; // 138

/// DEBUG/TESTBED ONLY. Config models for the evaluation harness:
/// [FieldPlan], the scripted field experiment. Inert/off by default, and
/// never affecting production behaviour. See `docs/testbed_experiments.md`.

/// One label→identity binding in the workload roster. The same roster file is
/// deployed to every device; a device finds its own row by matching
/// [pubkeyHex] against its identity.
/// Refuse a JSON object that carries a key the type does not know. A pasted
/// plan with a typo'd field otherwise parses clean and runs on the default —
/// the wrong plan, silently.
void _rejectUnknownKeys(
    Map<String, dynamic> json, Set<String> known, String where) {
  for (final k in json.keys) {
    if (!known.contains(k)) {
      throw FormatException("unknown field '$k' in $where");
    }
  }
}

@immutable
class WorkloadRosterEntry {
  final String label;
  final String pubkeyHex;

  const WorkloadRosterEntry({required this.label, required this.pubkeyHex});

  Map<String, dynamic> toJson() => {'label': label, 'pubkeyHex': pubkeyHex};

  factory WorkloadRosterEntry.fromJson(Map<String, dynamic> json) {
    _rejectUnknownKeys(json, const {'label', 'pubkeyHex'}, 'roster entry');
    return WorkloadRosterEntry(
      label: json['label'] as String,
      pubkeyHex: (json['pubkeyHex'] as String).toLowerCase(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is WorkloadRosterEntry &&
      other.label == label &&
      other.pubkeyHex == pubkeyHex;

  @override
  int get hashCode => Object.hash(label, pubkeyHex);
}

/// [sendCount] > 0 the runner sends that many [sendBytes]-sized messages to
/// every other roster device, spaced evenly through the dwell — the first
/// send doubles as the handshake trigger after a session reset, so the
/// discovered→connected→session→usable ladder runs inside the step.
@immutable
class FieldStep {
  final String label;
  final int dwellSec;
  final int sendCount;
  final int sendBytes;

  /// Which peers this step addresses. `all` (default) sends to every send
  /// target — the broadcast-shaped default. A pubkey-prefix (e.g. `9c46b4f3`)
  /// addresses ONE peer, which is how a multi-hop test aims past the relay at
  /// a node that is out of direct range: the message can only arrive by being
  /// relayed or carried. Matching is case-insensitive on the hex prefix.
  final String sendTo;



  /// Set the BLE transport up/down at this step's start (null = leave
  /// as-is). It scripts BLE-off vs BLE-active segments hands-free; the user's
  /// settings toggle is not touched. Applied before the step marker, so the
  /// segment's power samples all see the requested state.
  final bool? bleOn;

  /// Diluting-clique membership: the clique size this step belongs to. When
  /// set, the plan is ROLE-FREE — every phone loads the identical plan, and
  /// the runner derives this device's [bleOn] at launch from its own nickname
  /// (join order): on iff `joinOrder <= cliqueN`. This exists because baking
  /// the role into which preset the operator picks put the join order in two
  /// places — the nickname and the chosen entry — and the field run lost its
  /// whole N=2 phase to a phone that had a >=3 entry loaded. One shared plan
  /// makes the wrong-role mistake unrepresentable. Mutually exclusive with an
  /// explicit [bleOn]; resolved by [FieldPlan.resolvedFor].
  final int? cliqueN;

  /// Per-step override of [FieldPlan.resetSessions] (null = inherit). The
  /// frontier toggler needs it: sessions must be dropped while its radio is
  /// DOWN (the off step), so every one of its joins measures cold XX
  /// handshakes — a plan-wide reset would also fire at the join step's start
  /// and kill handshakes that legitimately began in the toggle window.
  final bool? resetSessions;

  /// Per-step override of [FieldPlan.resetLinks] (null = inherit). The
  /// diluting test's FIRST run sets it: one link bounce at the test's
  /// start, paired with the one session purge riding its dark window, so
  /// nothing from staging — links or sessions — survives into the test.
  /// Every later run inherits the plan's false and the mesh stays warm.
  final bool? resetLinks;

  /// Per-step override of [FieldPlan.resetDtnBuffer] (null = inherit).
  ///
  /// The plan-level flag fires at the start of EVERY step, which is useless
  /// for a store-carry-forward run: clearing at `return` would delete the
  /// very backlog that window exists to measure, so the plan has to leave it
  /// off and the buffer then never resets at all — one arm's leftovers get
  /// counted as the next arm's delivery. Set it on the arm's FIRST step
  /// instead. Clearing the buffer touches nothing else: sessions and links
  /// survive, so an arm still starts warm.
  final bool? resetDtnBuffer;



  /// Dial grid: the most central dials this phone may have IN FLIGHT during
  /// the step — the grid's M. Null leaves the production cap in place.
  ///
  /// This is a CAP ON ORDINARY BEHAVIOUR, not a scripted burst. The
  /// transport already dials greedily (every discovered peer, topped up
  /// automatically as slots free); the step just moves the bound and counts
  /// what gets established. Every phone runs it — there is no device under
  /// test and no rotation — so each phone measures its own dialing at M and
  /// the whole fleet is a sample.
  final int? maxParallelDials;

  /// Begin this step automatically without the IN POSITION tap. Set by the
  /// plan builders when the step's distance equals the previous step's (a
  /// repeat run at the same position — nothing to walk to). A step at a new
  /// distance leaves this false so the runner waits for the tap.
  final bool autoAdvance;

  /// DEBUG/TESTBED. The ring-radius gate's radius for this step: a node may
  /// hold links only to peers within this many hops around the ring (see
  /// `testbed/ring_topology.dart`). Null leaves the gate unarmed, which is
  /// what a warm-up or any non-ring step wants.
  final int? ringRadius;

  /// DEBUG/TESTBED. Sever every GATT link at this step's start, keeping Noise
  /// sessions, DTN buffers and seen-sets.
  ///
  /// NOT [resetLinks], which bounces the whole BLE transport behind a dark
  /// window and takes discovery down with it. The ring sweep needs the links to
  /// re-form under the step's new radius while the state that survives link
  /// loss — sessions above all — is carried across stages untouched.
  final bool? severLinks;

  /// This stage exists only to let the mesh reach a state — it measures
  /// nothing, sends nothing, and therefore has no tail to drain.
  ///
  /// A measured step is followed by a drain because its own late arrivals and
  /// acknowledgements are still landing; that is the whole reason
  /// [FieldPlan.gapAfterSec] derives one from the dwell. A settle aired no
  /// message, so there is nothing in flight to wait for and the stage is
  /// exactly as long as its dwell.
  ///
  /// Declared explicitly rather than inferred from `sendCount == 0`, which was
  /// tried and reverted: sendCount is what THIS device sends, and in a
  /// role-free plan a phone that has not joined yet has none while every other
  /// phone is sending. Zeroing that phone's drain slid it off the absolute
  /// lattice the whole fleet shares, with nothing on screen to say so.
  final bool settle;

  /// DEBUG/TESTBED. Give every peer this device holds a session with its OWN
  /// send timer, instead of firing one round at all of them together.
  ///
  /// [sendCount] keeps its per-destination meaning either way; what changes is
  /// the shape of the traffic. A round that fires every target puts N-1
  /// messages on the queue in a single instant, and on a ring — where a node
  /// may hold two links carrying transit for everyone — that burst is what
  /// saturates. Per-pair timers, phase-staggered, give each pair exactly its
  /// own cadence while the device's aggregate comes out evenly spread.
  ///
  /// It also ties the offered load to the sessions actually held rather than
  /// to the roster: a peer with no session gets no timer, so the pairs that do
  /// exist keep their cadence instead of pacing around a gap.
  final bool perPairPacing;

  /// Saturating send mode: instead of [sendCount] messages paced across the
  /// dwell, push continuously for the whole of it. [sendCount] is ignored.
  ///
  /// This is the throughput instrument. Paced sending measures whatever rate
  /// the plan asked for; saturating measures the rate the send path can
  /// actually drain, which is the only way to find a ceiling rather than
  /// confirm an offered load.
  final bool saturate;

  /// How many sends are pushed CONCURRENTLY while [saturate] is on: that many
  /// independent lanes, each looping "fire one, await it, fire the next".
  ///
  /// Nothing is ACK-gated — an ACK never clocks a send — so offered load is
  /// set purely by lane count and by how fast the send path drains. Clocking
  /// on acknowledgements would cap the rate at lanes/RTT and measure the
  /// window instead of the link.
  ///
  /// One lane keeps exactly one message in the send path at a time, so its
  /// rate is what the pipe carries. The plugin holds ONE GATT op per path, so
  /// a second lane's write meets a taken slot and is retried on the pair's
  /// other leg — which is what makes two lanes a test of whether a converged
  /// pair is two usable pipes. Beyond two there is nothing left to find: more
  /// lanes only manufacture write-busy refusals.
  final int sendLanes;

  /// Milliseconds between consecutive fragment writes for this step, or null
  /// to leave the production spacing alone.
  ///
  /// Only a fragmented payload feels it. Zero measures the link; the default
  /// 20 ms measures the spacing, which at ten fragments is 180 ms of a
  /// message's life. Per STEP rather than per plan so one run can carry both
  /// and the difference is measured under the same conditions.
  final int? fragmentDelayMs;

  const FieldStep({
    required this.label,
    required this.dwellSec,
    this.sendCount = 0,
    this.sendBytes = defaultSendBytes,
    this.autoAdvance = false,
    this.sendTo = 'all',
    this.bleOn,
    this.cliqueN,
    this.maxParallelDials,
    this.resetSessions,
    this.resetLinks,
    this.resetDtnBuffer,
    this.ringRadius,
    this.severLinks,
    this.perPairPacing = false,
    this.settle = false,
    this.saturate = false,
    this.sendLanes = 1,
    this.fragmentDelayMs,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'dwellSec': dwellSec,
        if (sendCount > 0) 'sendCount': sendCount,
        if (sendCount > 0 || saturate) 'sendBytes': sendBytes,
        if (autoAdvance) 'autoAdvance': autoAdvance,
        if (sendTo != 'all') 'sendTo': sendTo,
        if (bleOn != null) 'bleOn': bleOn,
        if (cliqueN != null) 'cliqueN': cliqueN,
        if (maxParallelDials != null) 'maxParallelDials': maxParallelDials,
        if (resetSessions != null) 'resetSessions': resetSessions,
        if (resetLinks != null) 'resetLinks': resetLinks,
        if (resetDtnBuffer != null) 'resetDtnBuffer': resetDtnBuffer,
        if (ringRadius != null) 'ringRadius': ringRadius,
        if (severLinks != null) 'severLinks': severLinks,
        if (perPairPacing) 'perPairPacing': perPairPacing,
        if (settle) 'settle': settle,
        if (saturate) 'saturate': saturate,
        if (saturate) 'sendLanes': sendLanes,
        if (fragmentDelayMs != null) 'fragmentDelayMs': fragmentDelayMs,
      };

  factory FieldStep.fromJson(Map<String, dynamic> json) {
    _rejectUnknownKeys(
        json,
        const {
          'label', 'dwellSec', 'sendCount', 'sendBytes', 'autoAdvance',
          'sendTo', 'bleOn', 'cliqueN', 'maxParallelDials', 'resetSessions',
          'resetLinks', 'resetDtnBuffer', 'ringRadius', 'severLinks',
          'perPairPacing', 'settle', 'saturate', 'sendLanes',
          'fragmentDelayMs',
        },
        "step '${json['label'] ?? '?'}'");
    return FieldStep(
        label: json['label'] as String,
        dwellSec: json['dwellSec'] as int,
        sendCount: json['sendCount'] as int? ?? 0,
        sendBytes: json['sendBytes'] as int? ?? defaultSendBytes,
        autoAdvance: json['autoAdvance'] as bool? ?? false,
        sendTo: json['sendTo'] as String? ?? 'all',
        bleOn: json['bleOn'] as bool?,
        cliqueN: json['cliqueN'] as int?,
        maxParallelDials: json['maxParallelDials'] as int?,
        resetSessions: json['resetSessions'] as bool?,
        resetLinks: json['resetLinks'] as bool?,
        resetDtnBuffer: json['resetDtnBuffer'] as bool?,
        ringRadius: json['ringRadius'] as int?,
        severLinks: json['severLinks'] as bool?,
        perPairPacing: json['perPairPacing'] as bool? ?? false,
        settle: json['settle'] as bool? ?? false,
        saturate: json['saturate'] as bool? ?? false,
        sendLanes: json['sendLanes'] as int? ?? 1,
        fragmentDelayMs: json['fragmentDelayMs'] as int?,
      );
  }

  @override
  bool operator ==(Object other) =>
      other is FieldStep &&
      other.label == label &&
      other.dwellSec == dwellSec &&
      other.sendCount == sendCount &&
      other.sendBytes == sendBytes &&
      other.autoAdvance == autoAdvance &&
      other.sendTo == sendTo &&
      other.bleOn == bleOn &&
      other.cliqueN == cliqueN &&
      other.maxParallelDials == maxParallelDials &&
      other.resetSessions == resetSessions &&
      other.resetLinks == resetLinks &&
      other.resetDtnBuffer == resetDtnBuffer &&
      other.ringRadius == ringRadius &&
      other.severLinks == severLinks &&
      other.perPairPacing == perPairPacing &&
      other.settle == settle &&
      other.saturate == saturate &&
      other.sendLanes == sendLanes &&
      other.fragmentDelayMs == fragmentDelayMs;

  @override
  int get hashCode =>
      Object.hash(label, dwellSec, sendCount, sendBytes, autoAdvance,
          sendTo, bleOn, cliqueN,
          maxParallelDials, resetSessions, resetLinks, resetDtnBuffer,
          ringRadius, severLinks, perPairPacing, settle, saturate,
          sendLanes, fragmentDelayMs);
}

/// A scripted field experiment: the same plan is loaded on every device and
/// the runner walks the experimenter through it — markers, dwell timing,
/// and the end-of-run stop/upload are all automated;
/// only the walking and one IN POSITION tap per step stay manual.
@immutable
class FieldPlan {
  final String expId;
  final List<FieldStep> steps;

  /// Label→identity bindings for per-step sends. A device finds its own row
  /// by pubkey and sends to every OTHER row; a device not in the roster is
  /// receive-only. EMPTY roster (the two-device default): sends target every
  /// currently identified peer instead, labeled by 8-hex pubkey prefix — no
  /// manual pubkey entry needed.
  final List<WorkloadRosterEntry> roster;

  /// Drop all Noise sessions at the start of every step (default on): each
  /// step then measures the full establishment ladder from a cold handshake
  /// instead of reusing a session formed at setup range.
  final bool resetSessions;

  /// Also tear down every BLE link at the start of every step (default off):
  /// the step then re-runs discovery + connect too, making each distance a
  /// fully independent discovered→connected→session→usable run. Costs a
  /// few seconds of re-dial per step.
  final bool resetLinks;

  /// Dark gap of the per-step BLE bounce ([resetLinks]), in seconds. Null
  /// keeps the coordinator's default (two announce cycles + 10 s, ~30 s),
  /// which is sized for a bounce only THIS device performs: the peer has to
  /// notice the link died, and the gap outlasts that discovery.
  ///
  /// Set it short only when every device bounces simultaneously at the step
  /// boundary — then both sides dispose their transports together, no stale
  /// path survives on either, and there is nothing to wait for. The dial
  /// grid does exactly that, so it spends ~5 s per step here instead of ~30.
  final int? linkResetDarkSec;

  /// Empty the DTN memory buffer at the start of every step (default on):
  /// without it, an overrun step's undelivered backlog survives in the buffer
  /// and drains into the NEXT step's window via the sync exchange — the
  /// steps contaminate each other and `delivery_rate` never dips, because
  /// the buffer eventually heals everything. Clearing makes each step's
  /// delivery its own verdict. Turn OFF for the mesh tests whose subject IS
  /// the buffer surviving across steps (store-carry-forward, multi-hop).
  final bool resetDtnBuffer;

  /// The quiet drain that follows [step], in seconds — DERIVED, never a
  /// parameter. A warm plan (links kept) drains for one dwell so a run's
  /// tail (late arrivals, ACKs) lands inside its own segment; a plan that
  /// resets links between steps drains zero, because the reset itself is
  /// what cuts the tail and a gap would only record events belonging to no
  /// segment.
  ///
  /// A [FieldStep.settle] stage drains zero: it aired no message, so nothing
  /// is in flight to wait for and the stage lasts exactly its dwell. That is
  /// declared on the step, never inferred from `sendCount == 0` — see the
  /// field's own comment for the lattice bug that inference caused.
  ///
  /// [drainSec] overrides the derivation for every sending step.
  int gapAfterSec(FieldStep step) => resetLinks || step.settle
      ? 0
      : (drainSec ?? step.dwellSec);

  /// Seconds reserved BEFORE a step's start instant for the resets to run in,
  /// under [manualJoin]. The step's own window then holds nothing but the
  /// dwell: the marker is stamped at the start instant, not after a reset of
  /// unpredictable length, so a step measures a full [FieldStep.dwellSec].
  ///
  /// It has to be a reservation rather than however long the resets happen to
  /// take, because the schedule is an absolute lattice shared by every phone.
  /// A phone that finished resetting early waits for the instant; one that
  /// overruns stamps late, which the trace shows rather than hides.
  ///
  /// Zero puts the resets inside the step window, where they cost the dwell
  /// whatever they take. A plan opts in by reserving the time its own resets
  /// measure — the value is a property of what the plan resets, not a global.
  ///
  /// The slot is charged only ahead of steps that bounce links (per-step
  /// [FieldStep.resetLinks] or the plan-wide flag) — the one reset slow
  /// enough to need it. The buffer clear and session purge are store writes;
  /// a plan that bounces once must not pay the slot before every run.
  final int resetBudgetSec;

  /// Lattice gap ahead of every step that grows the clique (its cliqueN
  /// differs from the previous step's): the previous N's last run drains,
  /// then EVERY device waits this long, then the new N's first dwell opens.
  ///
  /// It is bring-up time for the joining phone's radio. On a scripted-radio
  /// plan that phone's BLE transport is DISPOSED until its step opens, so at
  /// the boundary it has to be built, start advertising, be discovered, and
  /// complete a Noise handshake before a send to it can go anywhere. Measured
  /// at seven phones: linked 0.6 s and receiving 2.2 s after its instant. The
  /// gap buys that out of the drain rather than out of the dwell, so the
  /// joining run measures a mesh rather than an establishment.
  ///
  /// Every device waits it, not just the joiner — the schedule is one shared
  /// lattice, and a gap only some phones took would put them in different
  /// steps. It is also the last stretch in which a phone whose SYSTEM
  /// Bluetooth is off can be noticed and fixed: the app can raise and drop
  /// its own transport, but it cannot turn the adapter on.
  ///
  /// Zero on plans without clique growth.
  final int joinGapSec;

  /// Seconds the operator is guaranteed to walk a device to the next position
  /// in, under [manualJoin]. A step that opens a new position lands on the
  /// first alignment boundary at least this far past the previous dwell.
  ///
  /// Without it the walk is whatever the lattice leaves over — a remainder
  /// that shrinks to seconds whenever the runs happen to fill a boundary
  /// interval, which is not a budget anyone chose.
  final int walkBudgetSec;

  /// Manual-join mode: system Bluetooth is toggled BY THE OPERATOR in the
  /// phone's settings, never by the app. The run is anchored to a shared
  /// wall-clock instant (the next 10-minute boundary at least [placementSec]
  /// after the tap), so eight hand-tapped phones start with clock-sync
  /// error instead of tap spread. bleOn on a step becomes pure intent — it
  /// drives the `joined` marker and the on-screen join prompts, and the app
  /// never touches the radio. Exists because Android 13+ ignores
  /// programmatic Bluetooth enable anyway, and because the app-level toggle
  /// leaves the chip on — the operator flipping settings-BT is the only real
  /// radio silence.
  final bool manualJoin;

  /// Minimum seconds between the start tap and the shared wall-clock anchor:
  /// the time to carry phones to their marks. The actual wait is this plus
  /// however long until the next 10-minute boundary.
  /// DEBUG/TESTBED. Silence everything that is not payload for the whole run:
  /// advertising, scanning, the periodic ANNOUNCE and its stale sweep, and the
  /// DTN buffer, which retires a message as soon as it is aired instead of
  /// holding it for an acknowledgement.
  ///
  /// This is what turns a throughput run into a measurement of the RADIO
  /// rather than of the protocol around it. A one-way run without it came out
  /// slower than the duplex run it was meant to beat, because with nothing
  /// acknowledged the buffer grew to 8,700 packets and the sender spent more
  /// managing it than the acknowledgements had cost.
  ///
  /// Links already up are untouched, but nothing can re-form one: a run that
  /// loses its link is over.
  final bool quietLink;

  /// DEBUG/TESTBED. Deliver without acknowledging, for a one-directional
  /// throughput measurement.
  ///
  /// Every acknowledgement is a packet back down the same radio, so a duplex
  /// run reports duplex capacity. With this set the receiver takes delivery
  /// and says nothing, and the only honest measure becomes the RECEIVER's own
  /// arrival records — the sender's flow record will report zero acked, by
  /// construction rather than by failure.
  final bool suppressAcks;

  /// Ask the radio for CONNECTION_PRIORITY_HIGH on every central leg for the
  /// whole run, or leave the interval where it is (null).
  ///
  /// Applied at launch on every phone that loads the plan, not per step:
  /// Android lets only the CENTRAL request an interval, and in a converged
  /// pair each phone is central on one leg, so both must ask or only one
  /// direction speeds up. Moving it mid-plan would blur the boundary between
  /// the arm that has it and the arm that does not, which is why the
  /// throughput experiment runs it as a separate launch.
  final bool? connectionPriorityHigh;

  final int placementSec;

  /// Wall-clock alignment granularity for the manual-join anchor, seconds.
  /// Every phone rounds its start UP to the next multiple of this, so taps
  /// spread over less than (alignSec - placementSec) all land on the same
  /// instant. 600 for a field run (taps minutes apart while phones are
  /// handed out); a table preflight uses less, because waiting most of ten
  /// minutes for a five-minute test means the preflight never gets run.
  final int alignSec;

  /// Let the runner drive [FieldStep.bleOn] even though the start is
  /// wall-clock anchored.
  ///
  /// [manualJoin] conflated two separate things: WHEN the test starts (a shared
  /// instant every phone computes) and WHO works the radio. For the join
  /// experiments the operator does it, and the runner must keep its hands off
  /// or it would fight them. A desk plan that scripts a phone going dark needs
  /// the same shared start but no operator at all — hands-free is the point,
  /// since the dark window has to open on every phone at once.
  final bool scriptedRadio;

  /// Record EVERY advertisement sighting, instead of at most one per path
  /// per ~900 ms.
  ///
  /// The transport rate-limits `rssi` trace records because a busy mesh
  /// sees many sightings a second and the clique runs do not need them.
  /// A line sweep does: RSSI against distance IS its measurement, and each
  /// sighting is also one trial of "was this beacon received", which is the
  /// reception-rate curve — the thing that keeps falling after RSSI has
  /// flattened into the receiver floor. Under the limiter that curve cannot
  /// be computed at all, because the sighting count measures the limiter.
  ///
  /// Off by default so ordinary app use never pays for it; every testbed
  /// preset turns it on. Phones advertise at ~100 ms, so this can be ~10x
  /// the `rssi` records — tens of KB per step against a flush already
  /// several hundred KB, and the flush lands between measurement windows.
  final bool traceEveryAdvertisement;

  /// The operator resets the whole OS Bluetooth stack at every position,
  /// during the walk window — the thesis line design: each distance starts
  /// from a stack that carries nothing over. The runner PROMPTS the toggle;
  /// the radio observer's bt-off/bt-on markers are the record of whether it
  /// actually happened, position by position.
  final bool stackResetPerPosition;

  /// DEBUG/TESTBED. Plan-wide default for [FieldStep.severLinks].
  final bool severLinks;

  /// The drain after each sending step, in seconds. Null keeps the derivation
  /// (one dwell), which is right whenever a run's tail is short relative to
  /// its window.
  ///
  /// Decoupled because the ring sweep's tail is not short. A carried packet
  /// advances at most ONE HOP per sync round, and rounds ride the 10 s
  /// announce, so a delivery that has to cross the mesh cannot be quick: at
  /// diameter TWO the 4-phone smoke measured relayed deliveries at p50 42 s,
  /// p90 68 s, with a tail past 500 s. A 60 s drain clipped it — 103 of 400
  /// far-pair messages were still in flight when the window shut, and only
  /// arrived once a later stage widened the radius and handed them a direct
  /// link. Those are censored, not lost, and a censored tail that varies with
  /// radius is exactly the bias uniform windows exist to prevent.
  ///
  /// Lengthening the dwell instead would not do: that is the SEND window, so
  /// it would change the offered load rather than the time allowed to deliver
  /// it.
  final int? drainSec;

  /// Testbed override for the DTN buffer's byte cap.
  ///
  /// Carried in the PLAN so the trace records the bound the run was made
  /// under: a buffer's behaviour is meaningless without knowing what it was
  /// bounded by, and a value set out of band is invisible to anyone reading
  /// the recording afterwards. Null leaves the store's own default.
  final int? dtnMaxBytes;

  /// Flush the trace buffer every this many percentage points of battery
  /// drop. Null or zero leaves it OFF, which is what every run except a
  /// discharge measurement wants: the flush lands a disk write inside a
  /// measurement window, and the recorder is built so that never happens.
  final int? flushEverySocDrop;

  /// DEBUG/TESTBED. Refuse to start unless this device already holds at least
  /// this many Noise sessions.
  ///
  /// The ring sweep's warm-up is an OPERATOR precondition, not a runner phase:
  /// under the ring gate non-neighbours can never handshake, so every pair must
  /// have a session BEFORE the topology is constrained, and the operator brings
  /// the fleet there by toggling Bluetooth on subsets until every phone reads a
  /// full session table. A phase that waited on the count instead would end at
  /// a different instant on every phone and break the one absolute schedule
  /// every device shares.
  ///
  /// This is the guard that stops a half-warmed fleet silently starting a
  /// five-hour run whose non-neighbour messages could never be created at all.
  /// Zero (the default) disables it.
  ///
  /// A FLOOR and nothing else. How many phones a ring plan is built for is
  /// [ringSize], which is a separate field precisely so this one keeps a
  /// single meaning: a fleet size read off `this + 1` would ride on whatever a
  /// preset happened to set here — absent entirely at zero, and wrong for any
  /// plan using this as the floor it says it is.
  final int minSessionsToLaunch;

  /// DEBUG/TESTBED. How many phones the ring plan was built for.
  ///
  /// [ringRosterFromSessions] lets the room decide WHICH phones are in the
  /// ring; this declares HOW MANY the radii and the per-pair send counts were
  /// chosen for. Declared rather than inferred because the two facts have
  /// different sources: the fleet is whoever warmed up, the size is a number
  /// the preset author chose and knows (`n`, where the preset is built).
  ///
  /// It is what lets the runner refuse a launch whose ring is not the one the
  /// plan means — a table one short and the run is missing a node, one too long
  /// and a stray warmed phone silently turns an N=4 run into N=5. That is a
  /// cardinality test, which is all a phone can decide for itself; see
  /// [ringRosterFromSessions] for the half it cannot.
  ///
  /// Required whenever [ringRosterFromSessions] is set, meaningless otherwise.
  final int? ringSize;

  /// Build the ring roster at launch from this device's Noise session table
  /// (plus itself) instead of from [roster].
  ///
  /// The ring is defined by a list of pubkeys — sorted order IS ring order —
  /// and every phone must derive the SAME list or the gate is incoherent: one
  /// side thinks a pair is adjacent and dials, the other thinks it is two
  /// hops away and refuses. That is why the list cannot be each node's local
  /// view of who is nearby, and at r=1 it would also be circular, since the
  /// gate's whole job is to stop a node seeing most of the fleet.
  ///
  /// A hand-maintained list satisfies "identical" but not "correct": on
  /// 2026-09-01 the compiled roster named a phone that was not on the desk
  /// and omitted the one that was, which cost the run — three usable phones,
  /// and at N=3 every pair sits at ring distance 1, so r=1 is already the
  /// complete graph and there is nothing to convey.
  ///
  /// The session table fixes exactly that, because it cannot name an absent
  /// phone. Sessions are held in memory and never persisted, so the table can
  /// only contain peers this process actually handshaked with; a Noise
  /// session is pairwise, so if A holds one with B then B holds one with A;
  /// and the operator warm-up precondition already requires every phone to
  /// reach a full table before launch. Those three together make
  /// `self + sessions` the same set on every phone, and that set is the
  /// phones in the room.
  ///
  /// Frozen ONCE at launch, never re-derived: a session lost mid-run must not
  /// reshape the ring under the gate.
  ///
  /// **A phone cannot check that the fleet agreed, and the runner does not
  /// pretend to.** It knows its own session table and nothing about anyone
  /// else's, so identical MEMBERSHIP is not locally decidable: with five phones
  /// warmed, one holding {B,C,D} and another {A,C,E} derive different four-node
  /// rings, and neither table shows the difference. What is locally decidable
  /// is the SIZE, against [ringSize], and that is exactly as much as the launch
  /// guard claims.
  ///
  /// Membership is made DETECTABLE instead: the derived ring and an 8-hex
  /// fingerprint over the full pubkeys ride on EVERY marker, so the operator
  /// compares one short token across the phones still in their hands at launch,
  /// and the analysis proves agreement afterwards (one distinct `ringFp` per
  /// run) rather than assuming it.
  final bool ringRosterFromSessions;

  const FieldPlan({
    required this.expId,
    required this.steps,
    this.roster = const [],
    this.resetSessions = true,
    this.resetLinks = false,
    this.linkResetDarkSec,
    this.resetDtnBuffer = true,
    this.resetBudgetSec = 0,
    this.joinGapSec = 0,
    this.walkBudgetSec = 0,
    this.manualJoin = false,
    this.connectionPriorityHigh,
    this.suppressAcks = false,
    this.quietLink = false,
    this.placementSec = 300,
    this.alignSec = 600,
    this.scriptedRadio = false,
    this.traceEveryAdvertisement = false,
    this.stackResetPerPosition = false,
    this.severLinks = false,
    this.drainSec,
    this.dtnMaxBytes,
    this.flushEverySocDrop,
    this.minSessionsToLaunch = 0,
    this.ringRosterFromSessions = false,
    this.ringSize,
  });

  /// Resolve a role-free diluting plan for THIS device: every step carrying
  /// [FieldStep.cliqueN] gets its [FieldStep.bleOn] derived from [joinOrder]
  /// — on iff `joinOrder <= cliqueN` — so the identical plan JSON serves every
  /// phone and the phone's nickname is the ONLY place its join order lives.
  /// Steps without [FieldStep.cliqueN] pass through unchanged; a plan with no
  /// such steps returns itself.
  ///
  /// Every field but `bleOn` is carried over. A field added to [FieldStep]
  /// and forgotten here is dropped on EVERY phone, silently — the plan the
  /// runner executes is this rebuild, not the preset. The round-trip test
  /// compares the two step by step so the omission fails a test instead of
  /// a field day.
  FieldPlan resolvedFor(int joinOrder) {
    if (!steps.any((s) => s.cliqueN != null)) return this;
    return FieldPlan(
      expId: expId,
      steps: [
        for (final s in steps)
          s.cliqueN == null
              ? s
              : FieldStep(
                  label: s.label,
                  dwellSec: s.dwellSec,
                  sendCount: s.sendCount,
                  sendBytes: s.sendBytes,
                  autoAdvance: s.autoAdvance,
                  sendTo: s.sendTo,
                  bleOn: joinOrder <= s.cliqueN!,
                  cliqueN: s.cliqueN,
                  // Pass-through: the dial cap is the same on every phone,
                  // so unlike bleOn there is nothing per-device to resolve.
                  maxParallelDials: s.maxParallelDials,
                  resetSessions: s.resetSessions,
                  resetLinks: s.resetLinks,
                  resetDtnBuffer: s.resetDtnBuffer,
                  // Pass-through, like maxParallelDials: the ring topology is
                  // a fleet-wide property and every phone derives its own
                  // position from the roster, so there is nothing per-device
                  // to resolve here. Dropping them would silently disarm the
                  // gate on every phone that resolved a plan.
                  ringRadius: s.ringRadius,
                  severLinks: s.severLinks,
                  perPairPacing: s.perPairPacing,
                  settle: s.settle,
                  saturate: s.saturate,
                  sendLanes: s.sendLanes,
                  fragmentDelayMs: s.fragmentDelayMs,
                ),
      ],
      roster: roster,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      linkResetDarkSec: linkResetDarkSec,
      resetDtnBuffer: resetDtnBuffer,
      resetBudgetSec: resetBudgetSec,
      joinGapSec: joinGapSec,
      walkBudgetSec: walkBudgetSec,
      manualJoin: manualJoin,
      placementSec: placementSec,
      alignSec: alignSec,
      scriptedRadio: scriptedRadio,
      traceEveryAdvertisement: traceEveryAdvertisement,
      stackResetPerPosition: stackResetPerPosition,
      severLinks: severLinks,
      drainSec: drainSec,
      dtnMaxBytes: dtnMaxBytes,
      flushEverySocDrop: flushEverySocDrop,
      minSessionsToLaunch: minSessionsToLaunch,
      ringRosterFromSessions: ringRosterFromSessions,
      ringSize: ringSize,
      connectionPriorityHigh: connectionPriorityHigh,
      suppressAcks: suppressAcks,
      quietLink: quietLink,
    );
  }

  Map<String, dynamic> toJson() => {
        'expId': expId,
        'steps': steps.map((s) => s.toJson()).toList(),
        if (roster.isNotEmpty)
          'roster': roster.map((r) => r.toJson()).toList(),
        'resetSessions': resetSessions,
        if (resetLinks) 'resetLinks': resetLinks,
        if (linkResetDarkSec != null) 'linkResetDarkSec': linkResetDarkSec,
        'resetDtnBuffer': resetDtnBuffer,
        if (manualJoin) 'resetBudgetSec': resetBudgetSec,
        if (joinGapSec != 0) 'joinGapSec': joinGapSec,
        if (manualJoin) 'walkBudgetSec': walkBudgetSec,
        if (manualJoin) 'manualJoin': true,
        if (manualJoin) 'placementSec': placementSec,
        if (manualJoin) 'alignSec': alignSec,
        if (scriptedRadio) 'scriptedRadio': true,
        if (traceEveryAdvertisement) 'traceEveryAdvertisement': true,
        if (stackResetPerPosition) 'stackResetPerPosition': true,
        if (severLinks) 'severLinks': severLinks,
        if (drainSec != null) 'drainSec': drainSec,
        if (dtnMaxBytes != null) 'dtnMaxBytes': dtnMaxBytes,
        if (flushEverySocDrop != null)
          'flushEverySocDrop': flushEverySocDrop,
        if (minSessionsToLaunch > 0)
          'minSessionsToLaunch': minSessionsToLaunch,
        if (ringRosterFromSessions) 'ringRosterFromSessions': true,
        if (ringSize != null) 'ringSize': ringSize,
        if (connectionPriorityHigh != null)
          'connectionPriorityHigh': connectionPriorityHigh,
        if (suppressAcks) 'suppressAcks': true,
        if (quietLink) 'quietLink': true,
      };

  factory FieldPlan.fromJson(Map<String, dynamic> json) {
    _rejectUnknownKeys(
        json,
        const {
          'expId', 'steps', 'roster', 'resetSessions',
          'resetLinks', 'linkResetDarkSec', 'resetDtnBuffer',
          'resetBudgetSec', 'joinGapSec', 'walkBudgetSec',
          'manualJoin', 'placementSec', 'alignSec', 'scriptedRadio',
          'traceEveryAdvertisement', 'stackResetPerPosition', 'severLinks',
          'minSessionsToLaunch', 'ringRosterFromSessions', 'ringSize',
          'connectionPriorityHigh', 'suppressAcks', 'quietLink',
          'drainSec',
          'dtnMaxBytes',
          'flushEverySocDrop',
        },
        'plan');
    // A plan that derives its ring but declares no size is not a smaller
    // check, it is no check: nothing then compares the derived ring against
    // the fleet the plan was built for. Refuse it at the parse, which is where
    // a hand-pasted plan enters.
    if ((json['ringRosterFromSessions'] as bool? ?? false) &&
        json['ringSize'] == null) {
      throw const FormatException(
          "a plan with 'ringRosterFromSessions' must declare 'ringSize'");
    }
    return FieldPlan(
        expId: json['expId'] as String,
        steps: (json['steps'] as List<dynamic>)
            .map((e) => FieldStep.fromJson(e as Map<String, dynamic>))
            .toList(),
        roster: (json['roster'] as List<dynamic>?)
                ?.map((e) =>
                    WorkloadRosterEntry.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        resetSessions: json['resetSessions'] as bool? ?? true,
        resetLinks: json['resetLinks'] as bool? ?? false,
        linkResetDarkSec: json['linkResetDarkSec'] as int?,
        resetDtnBuffer: json['resetDtnBuffer'] as bool? ?? true,
        resetBudgetSec: json['resetBudgetSec'] as int? ?? 0,
        joinGapSec: json['joinGapSec'] as int? ?? 0,
        walkBudgetSec: json['walkBudgetSec'] as int? ?? 0,
        manualJoin: json['manualJoin'] as bool? ?? false,
        placementSec: json['placementSec'] as int? ?? 300,
        alignSec: json['alignSec'] as int? ?? 600,
        scriptedRadio: json['scriptedRadio'] as bool? ?? false,
        traceEveryAdvertisement:
            json['traceEveryAdvertisement'] as bool? ?? false,
        stackResetPerPosition:
            json['stackResetPerPosition'] as bool? ?? false,
        severLinks: json['severLinks'] as bool? ?? false,
        drainSec: json['drainSec'] as int?,
        dtnMaxBytes: json['dtnMaxBytes'] as int?,
        flushEverySocDrop: json['flushEverySocDrop'] as int?,
        minSessionsToLaunch: json['minSessionsToLaunch'] as int? ?? 0,
        ringRosterFromSessions:
            json['ringRosterFromSessions'] as bool? ?? false,
        ringSize: json['ringSize'] as int?,
        connectionPriorityHigh: json['connectionPriorityHigh'] as bool?,
        suppressAcks: json['suppressAcks'] as bool? ?? false,
        quietLink: json['quietLink'] as bool? ?? false,
      );
  }

  @override
  bool operator ==(Object other) =>
      other is FieldPlan &&
      other.expId == expId &&
      listEquals(other.steps, steps) &&
      listEquals(other.roster, roster) &&
      other.resetSessions == resetSessions &&
      other.resetLinks == resetLinks &&
      other.linkResetDarkSec == linkResetDarkSec &&
      other.resetDtnBuffer == resetDtnBuffer &&
      other.resetBudgetSec == resetBudgetSec &&
      other.joinGapSec == joinGapSec &&
      other.walkBudgetSec == walkBudgetSec &&
      other.manualJoin == manualJoin &&
      other.placementSec == placementSec &&
      other.alignSec == alignSec &&
      other.scriptedRadio == scriptedRadio &&
      other.traceEveryAdvertisement == traceEveryAdvertisement &&
      other.stackResetPerPosition == stackResetPerPosition &&
      other.severLinks == severLinks &&
      other.drainSec == drainSec &&
      other.dtnMaxBytes == dtnMaxBytes &&
      other.flushEverySocDrop == flushEverySocDrop &&
      other.minSessionsToLaunch == minSessionsToLaunch &&
      other.ringRosterFromSessions == ringRosterFromSessions &&
      other.ringSize == ringSize;

  // hashAll rather than hash: the plan has more fields than Object.hash takes
  // positionally, and a field left out of the digest is one that two unequal
  // plans can collide on.
  @override
  int get hashCode => Object.hashAll([
        expId, Object.hashAll(steps),
        Object.hashAll(roster), resetSessions, resetLinks, linkResetDarkSec,
        resetDtnBuffer, resetBudgetSec, joinGapSec, walkBudgetSec,
        manualJoin, placementSec, alignSec, scriptedRadio,
        traceEveryAdvertisement, stackResetPerPosition, severLinks,
        minSessionsToLaunch, ringRosterFromSessions, ringSize, drainSec,
        dtnMaxBytes, flushEverySocDrop,
      ]);
}
