import 'package:flutter/foundation.dart';

import '../protocol/fragment_handler.dart';

/// Default synthetic payload size: the largest that still fits ONE sealed
/// packet at the BLE floor MTU. At this size one message *is* one packet, so
/// message counts, delivery ratio and wire bytes all read per-packet with no
/// hidden fragment multiplier. Anything above it is fragmented — a 184-byte
/// message is silently TWO packets, 132 + 52, costing 392 wire bytes to move
/// 184 — which is worth measuring deliberately as a payload arm rather than
/// baking into every experiment.
const int defaultSendBytes = FragmentHandler.fragmentThreshold; // 130

/// DEBUG/TESTBED ONLY. Config models for the evaluation harness:
/// [FieldPlan], the scripted field experiment. Inert/off by default, and
/// never affecting production behaviour. See `docs/testbed_experiments.md`.

/// Fixed namespace for deterministic UUIDv5 message ids (field-plan
/// sends). Any offline tool using this namespace + the same name
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

/// /// [sendCount] > 0 the runner sends that many [sendBytes]-sized messages to
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
  /// repeat trial at the same position — nothing to walk to). A step at a new
  /// distance leaves this false so the runner waits for the tap.
  final bool autoAdvance;

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
    this.resetDtnBuffer,
  });

  Map<String, dynamic> toJson() => {
        'label': label,
        'dwellSec': dwellSec,
        if (sendCount > 0) 'sendCount': sendCount,
        // Saturating steps carry no sendCount but DO have a payload size —
        // it is the arm variable of the throughput experiment.
        if (sendCount > 0) 'sendBytes': sendBytes,
        if (autoAdvance) 'autoAdvance': autoAdvance,
        if (sendTo != 'all') 'sendTo': sendTo,
        if (bleOn != null) 'bleOn': bleOn,
        if (cliqueN != null) 'cliqueN': cliqueN,
        if (maxParallelDials != null) 'maxParallelDials': maxParallelDials,
        if (resetSessions != null) 'resetSessions': resetSessions,
        if (resetDtnBuffer != null) 'resetDtnBuffer': resetDtnBuffer,
      };

  factory FieldStep.fromJson(Map<String, dynamic> json) => FieldStep(
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
        resetDtnBuffer: json['resetDtnBuffer'] as bool?,
      );

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
      other.resetDtnBuffer == resetDtnBuffer;

  @override
  int get hashCode =>
      Object.hash(label, dwellSec, sendCount, sendBytes, autoAdvance,
          sendTo, bleOn, cliqueN,
          maxParallelDials, resetSessions, resetDtnBuffer);
}

/// A scripted field experiment: the same plan is loaded on every device and
/// the runner walks the experimenter through it — markers, dwell timing,
/// and the end-of-run stop/upload are all automated;
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

  /// Settle gap before an auto-advancing step ([FieldStep.autoAdvance])
  /// begins, in seconds. A manual tap still skips the remaining gap.
  final int autoAdvanceGapSec;

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
  final int resetBudgetSec;

  /// Seconds the operator is guaranteed to walk a device to the next position
  /// in, under [manualJoin]. A step that opens a new position lands on the
  /// first alignment boundary at least this far past the previous dwell.
  ///
  /// Without it the walk is whatever the lattice leaves over — a remainder
  /// that shrinks to seconds whenever the trials happen to fill a boundary
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

  /// The operator resets the whole OS Bluetooth stack at every position,
  /// during the walk window — the thesis line design: each distance starts
  /// from a stack that carries nothing over. The runner PROMPTS the toggle;
  /// the radio observer's bt-off/bt-on markers are the record of whether it
  /// actually happened, position by position.
  final bool stackResetPerPosition;

  const FieldPlan({
    required this.expId,
    required this.steps,
    this.settleSec = 30,
    this.roster = const [],
    this.resetSessions = true,
    this.resetLinks = false,
    this.linkResetDarkSec,
    this.resetDtnBuffer = true,
    this.autoAdvanceGapSec = 5,
    this.resetBudgetSec = 0,
    this.walkBudgetSec = 0,
    this.manualJoin = false,
    this.placementSec = 300,
    this.alignSec = 600,
    this.scriptedRadio = false,
    this.stackResetPerPosition = false,
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
                  resetDtnBuffer: s.resetDtnBuffer,
                ),
      ],
      settleSec: settleSec,
      roster: roster,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      linkResetDarkSec: linkResetDarkSec,
      resetDtnBuffer: resetDtnBuffer,
      autoAdvanceGapSec: autoAdvanceGapSec,
      resetBudgetSec: resetBudgetSec,
      walkBudgetSec: walkBudgetSec,
      manualJoin: manualJoin,
      placementSec: placementSec,
      alignSec: alignSec,
      scriptedRadio: scriptedRadio,
      stackResetPerPosition: stackResetPerPosition,
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
        if (linkResetDarkSec != null) 'linkResetDarkSec': linkResetDarkSec,
        'resetDtnBuffer': resetDtnBuffer,
        'autoAdvanceGapSec': autoAdvanceGapSec,
        if (manualJoin) 'resetBudgetSec': resetBudgetSec,
        if (manualJoin) 'walkBudgetSec': walkBudgetSec,
        if (manualJoin) 'manualJoin': true,
        if (manualJoin) 'placementSec': placementSec,
        if (manualJoin) 'alignSec': alignSec,
        if (scriptedRadio) 'scriptedRadio': true,
        if (stackResetPerPosition) 'stackResetPerPosition': true,
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
        linkResetDarkSec: json['linkResetDarkSec'] as int?,
        resetDtnBuffer: json['resetDtnBuffer'] as bool? ?? true,
        autoAdvanceGapSec: json['autoAdvanceGapSec'] as int? ?? 5,
        resetBudgetSec: json['resetBudgetSec'] as int? ?? 0,
        walkBudgetSec: json['walkBudgetSec'] as int? ?? 0,
        manualJoin: json['manualJoin'] as bool? ?? false,
        placementSec: json['placementSec'] as int? ?? 300,
        alignSec: json['alignSec'] as int? ?? 600,
        scriptedRadio: json['scriptedRadio'] as bool? ?? false,
        stackResetPerPosition:
            json['stackResetPerPosition'] as bool? ?? false,
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
      other.linkResetDarkSec == linkResetDarkSec &&
      other.resetDtnBuffer == resetDtnBuffer &&
      other.autoAdvanceGapSec == autoAdvanceGapSec &&
      other.resetBudgetSec == resetBudgetSec &&
      other.walkBudgetSec == walkBudgetSec &&
      other.manualJoin == manualJoin &&
      other.placementSec == placementSec &&
      other.alignSec == alignSec &&
      other.scriptedRadio == scriptedRadio &&
      other.stackResetPerPosition == stackResetPerPosition;

  @override
  int get hashCode => Object.hash(expId, Object.hashAll(steps), settleSec,
      Object.hashAll(roster), resetSessions, resetLinks, linkResetDarkSec,
      resetDtnBuffer, autoAdvanceGapSec, resetBudgetSec, walkBudgetSec,
      manualJoin, placementSec, alignSec, scriptedRadio);
}
