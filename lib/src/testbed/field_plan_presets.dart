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
    int sendBytes = 184,
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
    int sendBytes = 184,
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

  /// Throughput: saturate the link for [dwellSec] — keep [inFlight] messages
  /// outstanding and fire the next on every ACK, as many as the link carries.
  /// Sessions/links stay warm (this measures the data plane, not
  /// establishment); repeat trials at the same spot auto-advance.
  static FieldPlan throughput({
    String expId = 'throughput-1',
    int dwellSec = 60,
    int payloadBytes = 184,
    int inFlight = 8,
    int repeat = 1,
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    return FieldPlan(
      expId: expId,
      settleSec: 30,
      resetSessions: false,
      resetLinks: false,
      steps: [
        for (var i = 1; i <= trials; i++)
          FieldStep(
            label: trials > 1 ? 't$i saturate' : 'saturate',
            dwellSec: dwellSec,
            sendBytes: payloadBytes,
            saturate: true,
            inFlight: inFlight,
            autoAdvance: i > 1,
          ),
      ],
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
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    return FieldPlan(
      expId: expId,
      settleSec: 60, // relayed paths deliver later than direct ones
      resetSessions: false,
      resetLinks: false,
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
  }) =>
      FieldPlan(
        expId: expId,
        settleSec: 60,
        resetSessions: false,
        resetLinks: false,
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
        'Control-plane line sweep': lineSweep(),
        'Mesh: multi-hop relay (set target!)':
            multiHop(targetPrefix: '<peer-prefix>'),
        'Mesh: store-carry-forward (set target!)':
            storeCarry(targetPrefix: '<peer-prefix>'),
        'Data-plane dilating clique': dataPlane(),
      };
}

/// The experiment shapes the wizard can build.
enum FieldPlanKind { homeSoak, throughput, multiHop, storeCarry, lineSweep, dataPlane }

extension FieldPlanKindLabel on FieldPlanKind {
  String get label => switch (this) {
        FieldPlanKind.homeSoak => 'Home soak (stationary)',
        FieldPlanKind.throughput => 'Throughput (saturate)',
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
    int payloadBytes = 184,
    int inFlight = 8,
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
          payloadBytes: payloadBytes,
          inFlight: inFlight,
          repeat: repeat,
        );
      case FieldPlanKind.multiHop:
        return FieldPlanPresets.multiHop(
          expId: id,
          targetPrefix: targetPrefix,
          dwellSec: dwellSec,
          sends: sendsPerStep,
          repeat: repeat,
        );
      case FieldPlanKind.storeCarry:
        return FieldPlanPresets.storeCarry(
          expId: id,
          targetPrefix: targetPrefix,
          sends: sendsPerStep,
          holdMin: holdMin,
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
