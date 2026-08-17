import 'package:flutter/foundation.dart';

import '../protocol/fragment_handler.dart';

/// Default synthetic payload size: the largest that still fits ONE sealed
/// packet at the BLE floor MTU. At this size one message *is* one packet, so
/// message counts, delivery ratio and wire bytes all read per-packet with no
/// hidden fragment multiplier. Anything above it is fragmented (a 184-byte
/// message, the old default, was silently TWO packets — 132 + 52 — costing
/// 392 wire bytes to move 184), which is worth measuring deliberately as a
/// payload arm rather than baking into every experiment.
const int defaultSendBytes = FragmentHandler.fragmentThreshold; // 136

/// DEBUG/TESTBED ONLY. Config models for the evaluation harnesses:
/// [BulkFlowConfig] (sustained throughput) and [FieldPlan] (scripted field
/// experiment). Stored as nullable fields on `SettingsState` where noted,
/// inert/off by default, and never affecting production behaviour. See
/// `docs/testbed_experiments.md`.

/// Fixed namespace for deterministic UUIDv5 message ids (bulk flows and
/// field-plan sends). Any offline tool using this namespace + the same name
/// string reproduces the exact id set — the delivery-ratio denominator.
const String workloadUuidNamespace = 'b8f4a1e2-1c3d-4b5a-9e7f-677261737372';

/// One label→identity binding in the workload roster. The same roster file is
/// deployed to every device; a device finds its own row by matching
/// [pubkeyHex] against its identity.
@immutable
class WorkloadRosterEntry {
  final String label;
  final String pubkeyHex;

  const WorkloadRosterEntry({required this.label, required this.pubkeyHex});

  Map<String, dynamic> toJson() => {'label': label, 'pubkeyHex': pubkeyHex};

  factory WorkloadRosterEntry.fromJson(Map<String, dynamic> json) =>
      WorkloadRosterEntry(
        label: json['label'] as String,
        pubkeyHex: (json['pubkeyHex'] as String).toLowerCase(),
      );

  @override
  bool operator ==(Object other) =>
      other is WorkloadRosterEntry &&
      other.label == label &&
      other.pubkeyHex == pubkeyHex;

  @override
  int get hashCode => Object.hash(label, pubkeyHex);
}

/// One directed bulk transfer: [srcLabel] saturates toward [dstLabel].
@immutable
class BulkFlow {
  final String srcLabel;
  final String dstLabel;

  const BulkFlow({required this.srcLabel, required this.dstLabel});

  Map<String, dynamic> toJson() => {'src': srcLabel, 'dst': dstLabel};

  factory BulkFlow.fromJson(Map<String, dynamic> json) => BulkFlow(
        srcLabel: json['src'] as String,
        dstLabel: json['dst'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is BulkFlow &&
      other.srcLabel == srcLabel &&
      other.dstLabel == dstLabel;

  @override
  int get hashCode => Object.hash(srcLabel, dstLabel);
}

/// Sustained-throughput workload for the data-plane evaluation (dilating
/// clique): each listed flow keeps [inFlight] messages of [payloadBytes]
/// outstanding — sending the next only when one is ACKed, never re-sending —
/// for [durationMs] from Start. The same config is deployed to every device;
/// each executes only the flows where it is the source. One flow = the
/// distance-only baseline; all ordered pairs = the contended all-to-all run.
@immutable
class BulkFlowConfig {
  final List<WorkloadRosterEntry> roster;
  final List<BulkFlow> flows;
  final int payloadBytes;
  final int durationMs;
  final int inFlight;

  const BulkFlowConfig({
    required this.roster,
    required this.flows,
    required this.payloadBytes,
    required this.durationMs,
    this.inFlight = 2,
  });

  Map<String, dynamic> toJson() => {
        'roster': roster.map((r) => r.toJson()).toList(),
        'flows': flows.map((f) => f.toJson()).toList(),
        'payloadBytes': payloadBytes,
        'durationMs': durationMs,
        'inFlight': inFlight,
      };

  factory BulkFlowConfig.fromJson(Map<String, dynamic> json) => BulkFlowConfig(
        roster: (json['roster'] as List<dynamic>)
            .map((e) => WorkloadRosterEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        flows: (json['flows'] as List<dynamic>)
            .map((e) => BulkFlow.fromJson(e as Map<String, dynamic>))
            .toList(),
        payloadBytes: json['payloadBytes'] as int,
        durationMs: json['durationMs'] as int,
        inFlight: json['inFlight'] as int? ?? 2,
      );

  @override
  bool operator ==(Object other) =>
      other is BulkFlowConfig &&
      listEquals(other.roster, roster) &&
      listEquals(other.flows, flows) &&
      other.payloadBytes == payloadBytes &&
      other.durationMs == durationMs &&
      other.inFlight == inFlight;

  @override
  int get hashCode => Object.hash(Object.hashAll(roster),
      Object.hashAll(flows), payloadBytes, durationMs, inFlight);
}

/// One step of a field-experiment plan: the experimenter walks into
/// position, taps IN POSITION (which stamps [label] as a ground-truth
/// marker), and the runner holds the dwell for [dwellSec] before advancing.
/// When [bulk] is true the bulk-flow driver runs during the dwell. When
/// [sendCount] > 0 the runner sends that many [sendBytes]-sized messages to
/// every other roster device, spaced evenly through the dwell — the first
/// send doubles as the handshake trigger after a session reset, so the
/// discovered→connected→session→usable ladder runs inside the step.
@immutable
class FieldStep {
  final String label;
  final int dwellSec;
  final bool bulk;
  final int sendCount;
  final int sendBytes;

  /// Which peers this step addresses. `all` (default) sends to every send
  /// target — the broadcast-shaped default. A pubkey-prefix (e.g. `9c46b4f3`)
  /// addresses ONE peer, which is how a multi-hop test aims past the relay at
  /// a node that is out of direct range: the message can only arrive by being
  /// relayed or carried. Matching is case-insensitive on the hex prefix.
  final String sendTo;

  /// Saturating send mode: instead of [sendCount] messages spread through the
  /// dwell, push continuously for the whole dwell. Throughput measurement;
  /// [sendCount] is ignored.
  final bool saturate;

  /// How many sends are pushed CONCURRENTLY while [saturate] is on: that many
  /// independent lanes, each looping "fire one, await it, fire the next".
  /// Nothing is ACK-gated — the ACK never clocks a send — so the offered load
  /// is set purely by lane count and how fast the send path drains.
  ///
  /// This is the saturation knob. One lane keeps exactly one message in the
  /// send path at a time, which in the first arm delivered 100% at every
  /// payload size — proof the sender never outran the link, so those rates are
  /// a LOWER BOUND on capacity, not the ceiling. Raising the lane count raises
  /// offered load until delivery breaks, and that break is the ceiling.
  final int sendLanes;

  /// Set the BLE transport up/down at this step's start (null = leave
  /// as-is). The power-baseline plan uses it to script BLE-off vs BLE-active
  /// segments hands-free; the user's settings toggle is not touched. Applied
  /// before the step marker, so the segment's power samples all see the
  /// requested state.
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

  /// DEBUG raw-throughput mode: non-null selects the GATT leg ('notify',
  /// 'write' or 'stripe') and the step pushes MTU-sized raw blobs — no seal,
  /// no buffering, no ACK; the receiver counts bytes and drops them before the
  /// parser. Measures the naked GATT pipe; [sendCount]/[saturate] are
  /// ignored. Delivery accounting comes from the wire ledger alone.
  final String? rawLeg;

  /// DEBUG raw-throughput mode: how far the blob overshoots or undershoots the
  /// ATT ceiling, in bytes. The blob is written at `MTU - 3 + rawSizeDelta`,
  /// so 0 writes exactly at the ceiling, +1 one byte past it, -8 the margin
  /// the fragment budget currently holds back.
  ///
  /// This is the arm variable of the ATT-ceiling probe: the receiver records
  /// the length that actually ARRIVED, so a write that the stack truncates is
  /// distinguishable from one it refuses outright, and both are
  /// distinguishable from one that lands whole. Ignored unless [rawLeg] is
  /// set.
  final int rawSizeDelta;

  /// Parallel-dial probe: which phone (join order) is the DIALER at this
  /// step. Like [cliqueN] the plan stays ROLE-FREE — every phone loads the
  /// identical JSON — but unlike [cliqueN] this is NOT resolved away by
  /// [FieldPlan.resolvedFor]: the runner compares it against its own
  /// [joinOrder] at step start, so the full rotation survives in every
  /// phone's plan. The phone whose order matches fires the burst; every
  /// other phone holds passive (no automatic central dials) for the whole
  /// run.
  final int? dutOrder;

  /// Parallel-dial probe: how many distinct peers the DUT dials
  /// SIMULTANEOUSLY at this step's start — the burst size N. Ignored on
  /// phones whose join order is not [dutOrder].
  final int? parallelDials;

  /// Begin this step automatically without the IN POSITION tap. Set by the
  /// plan builders when the step's distance equals the previous step's (a
  /// repeat trial at the same position — nothing to walk to). A step at a new
  /// distance leaves this false so the runner waits for the tap.
  final bool autoAdvance;

  const FieldStep({
    required this.label,
    required this.dwellSec,
    this.bulk = false,
    this.sendCount = 0,
    this.sendBytes = defaultSendBytes,
    this.autoAdvance = false,
    this.saturate = false,
    this.sendLanes = 1,
    this.sendTo = 'all',
    this.rawLeg,
    this.rawSizeDelta = 0,
    this.bleOn,
    this.cliqueN,
    this.dutOrder,
    this.parallelDials,
    this.resetSessions,
    this.resetDtnBuffer,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'dwellSec': dwellSec,
        if (bulk) 'bulk': bulk,
        if (sendCount > 0) 'sendCount': sendCount,
        // Saturating steps carry no sendCount but DO have a payload size —
        // it is the arm variable of the throughput experiment.
        if (sendCount > 0 || saturate) 'sendBytes': sendBytes,
        if (autoAdvance) 'autoAdvance': autoAdvance,
        if (saturate) 'saturate': saturate,
        // NOT gated on `saturate`. A step can carry a lane count while its
        // own saturate flag is false — the mesh-scaling plan gives every
        // step the same lanes and flips saturate per device — and gating the
        // write dropped it on the round-trip while `==` still compared it,
        // so a saved plan silently differed from the one built in memory.
        if (sendLanes != 1) 'sendLanes': sendLanes,
        if (sendTo != 'all') 'sendTo': sendTo,
        if (rawLeg != null) 'rawLeg': rawLeg,
        if (rawSizeDelta != 0) 'rawSizeDelta': rawSizeDelta,
        if (bleOn != null) 'bleOn': bleOn,
        if (cliqueN != null) 'cliqueN': cliqueN,
        if (dutOrder != null) 'dutOrder': dutOrder,
        if (parallelDials != null) 'parallelDials': parallelDials,
        if (resetSessions != null) 'resetSessions': resetSessions,
        if (resetDtnBuffer != null) 'resetDtnBuffer': resetDtnBuffer,
      };

  factory FieldStep.fromJson(Map<String, dynamic> json) => FieldStep(
        label: json['label'] as String,
        dwellSec: json['dwellSec'] as int,
        bulk: json['bulk'] as bool? ?? false,
        sendCount: json['sendCount'] as int? ?? 0,
        sendBytes: json['sendBytes'] as int? ?? defaultSendBytes,
        autoAdvance: json['autoAdvance'] as bool? ?? false,
        saturate: json['saturate'] as bool? ?? false,
        sendLanes: json['sendLanes'] as int? ?? 1,
        sendTo: json['sendTo'] as String? ?? 'all',
        rawLeg: json['rawLeg'] as String?,
        rawSizeDelta: json['rawSizeDelta'] as int? ?? 0,
        bleOn: json['bleOn'] as bool?,
        cliqueN: json['cliqueN'] as int?,
        dutOrder: json['dutOrder'] as int?,
        parallelDials: json['parallelDials'] as int?,
        resetSessions: json['resetSessions'] as bool?,
        resetDtnBuffer: json['resetDtnBuffer'] as bool?,
      );

  @override
  bool operator ==(Object other) =>
      other is FieldStep &&
      other.label == label &&
      other.dwellSec == dwellSec &&
      other.bulk == bulk &&
      other.sendCount == sendCount &&
      other.sendBytes == sendBytes &&
      other.autoAdvance == autoAdvance &&
      other.saturate == saturate &&
      other.sendLanes == sendLanes &&
      other.sendTo == sendTo &&
      other.rawLeg == rawLeg &&
      other.rawSizeDelta == rawSizeDelta &&
      other.bleOn == bleOn &&
      other.cliqueN == cliqueN &&
      other.dutOrder == dutOrder &&
      other.parallelDials == parallelDials &&
      other.resetSessions == resetSessions &&
      other.resetDtnBuffer == resetDtnBuffer;

  @override
  int get hashCode =>
      Object.hash(label, dwellSec, bulk, sendCount, sendBytes, autoAdvance,
          saturate, sendLanes, sendTo, rawLeg, rawSizeDelta, bleOn, cliqueN,
          dutOrder, parallelDials, resetSessions, resetDtnBuffer);
}

/// A scripted field experiment: the same plan is loaded on every device and
/// the runner walks the experimenter through it — markers, dwell timing,
/// bulk-flow triggering, and the end-of-run stop/upload are all automated;
/// only the walking and one IN POSITION tap per step stay manual.
@immutable
class FieldPlan {
  final String expId;
  final List<FieldStep> steps;

  /// Post-plan settle window before the recording stops — lets late ACKs and
  /// buffered-packet deliveries land inside the trace.
  final int settleSec;

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
  /// fully independent discovered→connected→session→usable trial. Costs a
  /// few seconds of re-dial per step.
  final bool resetLinks;

  /// Empty the DTN memory buffer at the start of every step (default on):
  /// without it, an overrun step's undelivered backlog survives in the buffer
  /// and drains into the NEXT step's window via the sync exchange — the
  /// steps contaminate each other and `delivery_rate` never dips, because
  /// the buffer eventually heals everything. Clearing makes each step's
  /// delivery its own verdict. Turn OFF for the mesh tests whose subject IS
  /// the buffer surviving across steps (store-carry-forward, multi-hop).
  final bool resetDtnBuffer;

  /// Settle gap before an auto-advancing step ([FieldStep.autoAdvance])
  /// begins, in seconds. A manual tap still skips the remaining gap.
  final int autoAdvanceGapSec;

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
  /// [manualJoin] conflated two separate things: WHEN the run starts (a shared
  /// instant every phone computes) and WHO works the radio. For the join
  /// experiments the operator does it, and the runner must keep its hands off
  /// or it would fight them. A desk plan that scripts a phone going dark needs
  /// the same shared start but no operator at all — hands-free is the point,
  /// since the dark window has to open on every phone at once.
  final bool scriptedRadio;

  const FieldPlan({
    required this.expId,
    required this.steps,
    this.settleSec = 30,
    this.roster = const [],
    this.resetSessions = true,
    this.resetLinks = false,
    this.resetDtnBuffer = true,
    this.autoAdvanceGapSec = 5,
    this.manualJoin = false,
    this.placementSec = 300,
    this.alignSec = 600,
    this.scriptedRadio = false,
  });

  /// Resolve a role-free diluting plan for THIS device: every step carrying
  /// [FieldStep.cliqueN] gets its [FieldStep.bleOn] derived from [joinOrder]
  /// — on iff `joinOrder <= cliqueN` — so the identical plan JSON serves every
  /// phone and the phone's nickname is the ONLY place its join order lives.
  /// Steps without [FieldStep.cliqueN] pass through unchanged; a plan with no
  /// such steps returns itself.
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
                  bulk: s.bulk,
                  sendCount: s.sendCount,
                  sendBytes: s.sendBytes,
                  autoAdvance: s.autoAdvance,
                  saturate: s.saturate,
                  sendLanes: s.sendLanes,
                  sendTo: s.sendTo,
                  rawLeg: s.rawLeg,
                  rawSizeDelta: s.rawSizeDelta,
                  bleOn: joinOrder <= s.cliqueN!,
                  cliqueN: s.cliqueN,
                  // Pass-through only: dutOrder is compared against joinOrder
                  // at RUNTIME by the runner, never resolved into the plan —
                  // every phone keeps the full DUT rotation.
                  dutOrder: s.dutOrder,
                  parallelDials: s.parallelDials,
                  resetSessions: s.resetSessions,
                  resetDtnBuffer: s.resetDtnBuffer,
                ),
      ],
      settleSec: settleSec,
      roster: roster,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      resetDtnBuffer: resetDtnBuffer,
      autoAdvanceGapSec: autoAdvanceGapSec,
      manualJoin: manualJoin,
      placementSec: placementSec,
      alignSec: alignSec,
      scriptedRadio: scriptedRadio,
    );
  }

  Map<String, dynamic> toJson() => {
        'expId': expId,
        'steps': steps.map((s) => s.toJson()).toList(),
        'settleSec': settleSec,
        if (roster.isNotEmpty)
          'roster': roster.map((r) => r.toJson()).toList(),
        'resetSessions': resetSessions,
        if (resetLinks) 'resetLinks': resetLinks,
        'resetDtnBuffer': resetDtnBuffer,
        'autoAdvanceGapSec': autoAdvanceGapSec,
        if (manualJoin) 'manualJoin': true,
        if (manualJoin) 'placementSec': placementSec,
        if (manualJoin) 'alignSec': alignSec,
        if (scriptedRadio) 'scriptedRadio': true,
      };

  factory FieldPlan.fromJson(Map<String, dynamic> json) => FieldPlan(
        expId: json['expId'] as String,
        steps: (json['steps'] as List<dynamic>)
            .map((e) => FieldStep.fromJson(e as Map<String, dynamic>))
            .toList(),
        settleSec: json['settleSec'] as int? ?? 30,
        roster: (json['roster'] as List<dynamic>?)
                ?.map((e) =>
                    WorkloadRosterEntry.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        resetSessions: json['resetSessions'] as bool? ?? true,
        resetLinks: json['resetLinks'] as bool? ?? false,
        resetDtnBuffer: json['resetDtnBuffer'] as bool? ?? true,
        autoAdvanceGapSec: json['autoAdvanceGapSec'] as int? ?? 5,
        manualJoin: json['manualJoin'] as bool? ?? false,
        placementSec: json['placementSec'] as int? ?? 300,
        alignSec: json['alignSec'] as int? ?? 600,
        scriptedRadio: json['scriptedRadio'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is FieldPlan &&
      other.expId == expId &&
      listEquals(other.steps, steps) &&
      other.settleSec == settleSec &&
      listEquals(other.roster, roster) &&
      other.resetSessions == resetSessions &&
      other.resetLinks == resetLinks &&
      other.resetDtnBuffer == resetDtnBuffer &&
      other.autoAdvanceGapSec == autoAdvanceGapSec &&
      other.manualJoin == manualJoin &&
      other.placementSec == placementSec &&
      other.alignSec == alignSec &&
      other.scriptedRadio == scriptedRadio;

  @override
  int get hashCode => Object.hash(expId, Object.hashAll(steps), settleSec,
      Object.hashAll(roster), resetSessions, resetLinks, resetDtnBuffer,
      autoAdvanceGapSec, manualJoin, placementSec, alignSec,
      scriptedRadio);
}
