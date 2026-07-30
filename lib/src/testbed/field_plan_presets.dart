import 'testbed_config.dart';

/// DEBUG/TESTBED ONLY. Pure builders for the common [FieldPlan] shapes, plus
/// a named preset list for the auto-runner dropdown and a wizard that turns a
/// few answers into a plan. No pubkeys anywhere — every plan here is
/// rosterless (the two-device default: sends target the one identified peer).
class FieldPlanPresets {
  FieldPlanPresets._();

  /// Stationary soak: [repeat] dwells at fixed distance (labels stay unique
  /// so the analyzer keeps every trial as its own segment). All trials share
  /// one position, so only the first waits for the tap — the rest
  /// auto-advance. With [resetLinks]/[resetSessions] on and repeat > 1 this
  /// doubles as the link-cycle check: N back-to-back teardown→re-establish
  /// ladders, hands-free after the first tap.
  static FieldPlan homeSoak({
    String expId = 'home-soak-1',
    int dwellMin = 40,
    int sends = 40,
    int sendBytes = defaultSendBytes,
    int repeat = 1,
    bool resetSessions = true,
    bool resetLinks = false,
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    return FieldPlan(
      expId: expId,
      settleSec: 60,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      steps: [
        for (var i = 1; i <= trials; i++)
          FieldStep(
            label: trials > 1 ? 'c$i d=3 soak' : 'd=3 home soak',
            dwellSec: dwellMin * 60,
            sendCount: sends,
            sendBytes: sendBytes,
            autoAdvance: i > 1, // same position as the previous trial
          ),
      ],
    );
  }

  /// Control-plane line sweep: near anchors, then approach to the range edge
  /// and (optionally) retreat back for the hysteresis. Sessions reset per
  /// step so each distance measures the full establishment ladder.
  static FieldPlan lineSweep({
    String expId = 'cp-line-1',
    List<int> distances = const [1, 5, 10, 20, 40, 80, 120],
    int dwellSec = 180,
    int anchorDwellSec = 120,
    int sendsPerStep = 5,
    int sendBytes = defaultSendBytes,
    bool retreat = true,
    int repeat = 1,
    bool resetSessions = true,
    bool resetLinks = true,
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    // Build the ordered (distance, label) sequence first, then derive each
    // step's autoAdvance from whether its distance repeats the previous one.
    final seq = <(int, String)>[];
    void add(int d, String dir) {
      for (var i = 1; i <= trials; i++) {
        seq.add((d, trials > 1 ? 'd=$d $dir t$i' : 'd=$d $dir'));
      }
    }

    final approach = [...distances]..sort();
    for (final d in approach) {
      add(d, 'approach');
    }
    if (retreat) {
      // Exclude the two nearest anchors from the retreat — the hysteresis is
      // at the range edge, and skipping them keeps the run shorter.
      final back = approach.where((d) => d > 5).toList()
        ..sort((a, b) => b.compareTo(a));
      for (final d in back) {
        add(d, 'retreat');
      }
    }
    return FieldPlan(
      expId: expId,
      steps: _stepsFrom(seq, sendsPerStep, sendBytes,
          (d) => d <= 5 ? anchorDwellSec : dwellSec),
      settleSec: 30,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
    );
  }

  /// Turn an ordered (distance, label) sequence into steps, marking a step
  /// [FieldStep.autoAdvance] when its distance repeats the previous step's
  /// (a same-position trial → no walk → no IN POSITION tap).
  static List<FieldStep> _stepsFrom(List<(int, String)> seq, int sendCount,
      int sendBytes, int Function(int d) dwellFor) {
    int? prev;
    final steps = <FieldStep>[];
    for (final (d, label) in seq) {
      steps.add(FieldStep(
        label: label,
        dwellSec: dwellFor(d),
        sendCount: sendCount,
        sendBytes: sendBytes,
        autoAdvance: prev == d,
      ));
      prev = d;
    }
    return steps;
  }

  /// Data-plane throughput: each side length is a bulk-flow dwell. Sessions
  /// stay warm (throughput, not establishment); load the bulk-flow config
  /// separately. Dwell runs a little longer than the flow window.
  static FieldPlan dataPlane({
    String expId = 'dp-tri-baseline',
    List<int> sideLengths = const [10, 20, 40],
    int dwellSec = 150,
    int repeat = 1,
    bool resetSessions = false,
    bool resetLinks = false,
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    int? prev;
    final steps = <FieldStep>[];
    for (final s in sideLengths) {
      for (var i = 1; i <= trials; i++) {
        steps.add(FieldStep(
          label: trials > 1 ? 'side=$s t$i' : 'side=$s',
          dwellSec: dwellSec,
          bulk: true,
          autoAdvance: prev == s, // same side length as the previous trial
        ));
        prev = s;
      }
    }
    return FieldPlan(
      expId: expId,
      settleSec: 30,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      steps: steps,
    );
  }

  /// Throughput: saturate the link for [dwellSec] on [sendLanes] concurrent
  /// send lanes, none of them ACK-gated. Sessions/links stay warm (this
  /// measures the data plane, not establishment).
  ///
  /// [payloadSizes] is the PAYLOAD ARM: one saturating step per size, so the
  /// per-message cost of fragmentation is a measured result instead of a
  /// hidden constant. [defaultSendBytes] (132 B) is exactly one sealed packet;
  /// 264 B is exactly two; 1200 B is ten. Every step runs from the same spot,
  /// so only the very first waits for the tap — a whole arm is hands-free
  /// after one press. Labels carry the size (`p=264B`) so the analyzer
  /// segments the arms apart.
  static FieldPlan throughput({
    String expId = 'throughput-1',
    int dwellSec = 60,
    List<int> payloadSizes = const [defaultSendBytes],
    int sendLanes = 1,
    int repeat = 1,
    bool resetSessions = false,
    bool resetLinks = false,
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    final sizes = payloadSizes.isEmpty ? const [defaultSendBytes] : payloadSizes;
    final steps = <FieldStep>[];
    for (final bytes in sizes) {
      for (var i = 1; i <= trials; i++) {
        final size = sizes.length > 1 ? 'p=${bytes}B' : 'saturate';
        steps.add(FieldStep(
          label: trials > 1 ? '$size t$i' : size,
          dwellSec: dwellSec,
          sendBytes: bytes,
          saturate: true,
          sendLanes: sendLanes,
          // Stationary experiment: nothing to walk to between steps.
          autoAdvance: steps.isNotEmpty,
        ));
      }
    }
    return FieldPlan(
      expId: expId,
      settleSec: 30,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      steps: steps,
    );
  }

  /// Throughput CEILING: the same saturating step at rising lane counts, so
  /// offered load climbs until the link stops carrying it.
  ///
  /// The payload arm answered "what does a message cost"; this answers "how
  /// much fits". One lane delivered 100% at every payload size, which proves
  /// the sender never outran the link and makes those rates a lower bound, not
  /// a capacity. Each step here doubles down until `delivery_rate` falls below
  /// 1.0 and goodput stops rising — that knee is the ceiling. Labels carry the
  /// lane count (`lanes=16`) so the analyzer segments them apart.
  ///
  /// Fixed payload (one sealed packet by default) so lanes are the only
  /// variable. Stationary and warm, so one tap runs the whole sweep.
  static FieldPlan throughputCeiling({
    String expId = 'throughput-ceiling-1',
    int dwellSec = 60,
    int payloadBytes = defaultSendBytes,
    List<int> lanes = const [1, 4, 16, 64],
    int repeat = 1,
    bool resetSessions = false,
    bool resetLinks = false,
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    final counts = lanes.isEmpty ? const [1] : lanes;
    final steps = <FieldStep>[];
    for (final n in counts) {
      for (var i = 1; i <= trials; i++) {
        steps.add(FieldStep(
          label: trials > 1 ? 'lanes=$n t$i' : 'lanes=$n',
          dwellSec: dwellSec,
          sendBytes: payloadBytes,
          saturate: true,
          sendLanes: n,
          autoAdvance: steps.isNotEmpty,
        ));
      }
    }
    return FieldPlan(
      expId: expId,
      // Longer than usual: an overrun leaves a backlog of custody and ACKs
      // still draining when the dwell ends, and cutting the recording there
      // would score those sends as lost when they were merely late.
      settleSec: 90,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      steps: steps,
    );
  }

  /// TIER 1 — multi-hop relay. Run on the SOURCE (A). B sits between A and
  /// C, in range of both; C is out of A's range. Every step addresses C
  /// alone ([FieldStep.sendTo] = C's pubkey prefix), so a delivery proves
  /// the message crossed B. B and C record only. Offline, joining `relay`
  /// records on packetId reconstructs A→B→C and the hop count.
  static FieldPlan multiHop({
    String expId = 'mesh-hop-1',
    required String targetPrefix,
    int dwellSec = 120,
    int sends = 30,
    int repeat = 1,
    bool resetSessions = false,
    bool resetLinks = false,
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    return FieldPlan(
      expId: expId,
      settleSec: 60, // relayed paths deliver later than direct ones
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      // Custody surviving across steps IS the subject of this test.
      resetCustody: false,
      steps: [
        for (var i = 1; i <= trials; i++)
          FieldStep(
            label: trials > 1 ? 'hop t$i' : 'hop',
            dwellSec: dwellSec,
            sendCount: sends,
            sendTo: targetPrefix,
            autoAdvance: i > 1,
          ),
      ],
    );
  }

  /// TIER 1 — store-carry-forward (the mule). Run on the SOURCE (A), with C
  /// far away and NO relay in between: sends enter custody with nowhere to
  /// go. A mule device (B) then walks A→C, picking the packets up and
  /// delivering them. Steps: send into the void, then a long hold while the
  /// mule travels. Offline: `custody` store→convey→end plus C's `recv`
  /// timestamps give the carry latency.
  static FieldPlan storeCarry({
    String expId = 'mesh-dtn-1',
    required String targetPrefix,
    int sends = 20,
    int holdMin = 5,
    bool resetSessions = false,
    bool resetLinks = false,
  }) =>
      FieldPlan(
        expId: expId,
        settleSec: 60,
        resetSessions: resetSessions,
        resetLinks: resetLinks,
        // The seeded custody must survive into the hold step for the mule.
        resetCustody: false,
        steps: [
          FieldStep(
            label: 'seed custody (C unreachable)',
            dwellSec: 60,
            sendCount: sends,
            sendTo: targetPrefix,
          ),
          FieldStep(
            label: 'mule carries',
            dwellSec: holdMin * 60,
            autoAdvance: true, // nothing to walk to on the source
          ),
        ],
      );

  /// Pre-field validation: five back-to-back link-teardown→re-establish
  /// cycles at desk distance (~6 min). Success = five complete
  /// drop→discovered→connected→session→usable ladders in the trace.
  static FieldPlan cycleCheck({String expId = 'cycle-check-1'}) => homeSoak(
        expId: expId,
        dwellMin: 1,
        sends: 2,
        repeat: 5,
        resetLinks: true,
      );

  /// Named presets for the dropdown (label → ready-to-run plan).
  static Map<String, FieldPlan> get presets => {
        'Home soak (stationary, 40 min)': homeSoak(),
        'Link-cycle check (5×1 min)': cycleCheck(),
        'Throughput (saturate 60s)': throughput(),
        'Throughput: payload arm (132/264/1200 B)': throughput(
            expId: 'throughput-arm-1',
            payloadSizes: const [defaultSendBytes, 264, 1200]),
        'Throughput: ceiling sweep (1/4/16/64 lanes)': throughputCeiling(),
        'Control-plane line sweep': lineSweep(),
        'Mesh: multi-hop relay (set target!)':
            multiHop(targetPrefix: '<peer-prefix>'),
        'Mesh: store-carry-forward (set target!)':
            storeCarry(targetPrefix: '<peer-prefix>'),
        'Data-plane dilating clique': dataPlane(),
      };
}

/// The experiment shapes the wizard can build.
enum FieldPlanKind {
  homeSoak,
  throughput,
  throughputCeiling,
  multiHop,
  storeCarry,
  lineSweep,
  dataPlane
}

extension FieldPlanKindLabel on FieldPlanKind {
  String get label => switch (this) {
        FieldPlanKind.homeSoak => 'Home soak (stationary)',
        FieldPlanKind.throughput => 'Throughput (saturate)',
        FieldPlanKind.throughputCeiling => 'Throughput: ceiling sweep',
        FieldPlanKind.multiHop => 'Mesh: multi-hop relay',
        FieldPlanKind.storeCarry => 'Mesh: store-carry-forward',
        FieldPlanKind.lineSweep => 'Control-plane line sweep',
        FieldPlanKind.dataPlane => 'Data-plane dilating clique',
      };
}

/// Wizard answers → a [FieldPlan]. Kept pure and separate from the dialog UI
/// so it is unit-testable.
class FieldPlanWizard {
  /// Kind-appropriate defaults for the wizard's reset toggles.
  static (bool sessions, bool links) resetDefaults(FieldPlanKind kind) =>
      switch (kind) {
        FieldPlanKind.homeSoak => (true, false),
        FieldPlanKind.throughput => (false, false),
        FieldPlanKind.throughputCeiling => (false, false),
        FieldPlanKind.multiHop => (false, false),
        FieldPlanKind.storeCarry => (false, false),
        FieldPlanKind.lineSweep => (true, true),
        FieldPlanKind.dataPlane => (false, false),
      };

  static FieldPlan build({
    required FieldPlanKind kind,
    required String expId,
    int dwellMin = 40,
    int sends = 40,
    List<int> distances = const [1, 5, 10, 20, 40, 80, 120],
    bool retreat = true,
    int sendsPerStep = 5,
    int dwellSec = 180,
    List<int> sideLengths = const [10, 20, 40],
    int repeat = 1,
    bool? resetSessions,
    bool? resetLinks,
    List<int> payloadSizes = const [defaultSendBytes],
    List<int> laneCounts = const [1, 4, 16, 64],
    int sendLanes = 1,
    String targetPrefix = '',
    int holdMin = 5,
  }) {
    final id = expId.trim().isEmpty ? 'exp' : expId.trim();
    final (defSessions, defLinks) = resetDefaults(kind);
    final sessions = resetSessions ?? defSessions;
    final links = resetLinks ?? defLinks;
    switch (kind) {
      case FieldPlanKind.homeSoak:
        return FieldPlanPresets.homeSoak(
          expId: id,
          dwellMin: dwellMin,
          sends: sends,
          repeat: repeat,
          resetSessions: sessions,
          resetLinks: links,
        );
      case FieldPlanKind.throughput:
        return FieldPlanPresets.throughput(
          expId: id,
          dwellSec: dwellSec,
          payloadSizes: payloadSizes,
          sendLanes: sendLanes,
          repeat: repeat,
          resetSessions: sessions,
          resetLinks: links,
        );
      case FieldPlanKind.throughputCeiling:
        return FieldPlanPresets.throughputCeiling(
          expId: id,
          dwellSec: dwellSec,
          payloadBytes: payloadSizes.isEmpty ? defaultSendBytes : payloadSizes.first,
          lanes: laneCounts,
          repeat: repeat,
          resetSessions: sessions,
          resetLinks: links,
        );
      case FieldPlanKind.multiHop:
        return FieldPlanPresets.multiHop(
          expId: id,
          targetPrefix: targetPrefix,
          dwellSec: dwellSec,
          sends: sendsPerStep,
          repeat: repeat,
          resetSessions: sessions,
          resetLinks: links,
        );
      case FieldPlanKind.storeCarry:
        return FieldPlanPresets.storeCarry(
          expId: id,
          targetPrefix: targetPrefix,
          sends: sendsPerStep,
          holdMin: holdMin,
          resetSessions: sessions,
          resetLinks: links,
        );
      case FieldPlanKind.lineSweep:
        return FieldPlanPresets.lineSweep(
          expId: id,
          distances: distances,
          dwellSec: dwellSec,
          sendsPerStep: sendsPerStep,
          retreat: retreat,
          repeat: repeat,
          resetSessions: sessions,
          resetLinks: links,
        );
      case FieldPlanKind.dataPlane:
        return FieldPlanPresets.dataPlane(
          expId: id,
          sideLengths: sideLengths,
          dwellSec: dwellSec,
          repeat: repeat,
          resetSessions: sessions,
          resetLinks: links,
        );
    }
  }

  /// Parse a comma/space-separated distance list; falls back to [fallback].
  static List<int> parseInts(String raw, List<int> fallback) {
    final out = <int>[];
    for (final tok in raw.split(RegExp(r'[\s,]+'))) {
      final n = int.tryParse(tok.trim());
      if (n != null && n > 0) out.add(n);
    }
    return out.isEmpty ? fallback : out;
  }
}
