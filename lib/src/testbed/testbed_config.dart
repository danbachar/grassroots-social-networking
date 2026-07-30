import 'package:flutter/foundation.dart';

import '../protocol/fragment_handler.dart';

/// Default synthetic payload size: the largest that still fits ONE sealed
/// packet at the BLE floor MTU. At this size one message *is* one packet, so
/// message counts, delivery ratio and wire bytes all read per-packet with no
/// hidden fragment multiplier. Anything above it is fragmented (a 184-byte
/// message, the old default, was silently TWO packets — 132 + 52 — costing
/// 392 wire bytes to move 184), which is worth measuring deliberately as a
/// payload arm rather than baking into every experiment.
const int defaultSendBytes = FragmentHandler.fragmentThreshold; // 132

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
        if (saturate) 'sendLanes': sendLanes,
        if (sendTo != 'all') 'sendTo': sendTo,
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
      other.sendTo == sendTo;

  @override
  int get hashCode =>
      Object.hash(label, dwellSec, bulk, sendCount, sendBytes, autoAdvance,
          saturate, sendLanes, sendTo);
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
  /// custody deliveries land inside the trace.
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

  /// Settle gap before an auto-advancing step ([FieldStep.autoAdvance])
  /// begins, in seconds. A manual tap still skips the remaining gap.
  final int autoAdvanceGapSec;

  const FieldPlan({
    required this.expId,
    required this.steps,
    this.settleSec = 30,
    this.roster = const [],
    this.resetSessions = true,
    this.resetLinks = false,
    this.autoAdvanceGapSec = 5,
  });

  Map<String, dynamic> toJson() => {
        'expId': expId,
        'steps': steps.map((s) => s.toJson()).toList(),
        'settleSec': settleSec,
        if (roster.isNotEmpty)
          'roster': roster.map((r) => r.toJson()).toList(),
        'resetSessions': resetSessions,
        if (resetLinks) 'resetLinks': resetLinks,
        'autoAdvanceGapSec': autoAdvanceGapSec,
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
        autoAdvanceGapSec: json['autoAdvanceGapSec'] as int? ?? 5,
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
      other.autoAdvanceGapSec == autoAdvanceGapSec;

  @override
  int get hashCode => Object.hash(expId, Object.hashAll(steps), settleSec,
      Object.hashAll(roster), resetSessions, resetLinks, autoAdvanceGapSec);
}
