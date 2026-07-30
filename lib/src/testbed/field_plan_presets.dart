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
        'Control-plane line sweep': lineSweep(),
        'Data-plane dilating clique': dataPlane(),
      };
}

/// The experiment shapes the wizard can build.
enum FieldPlanKind { homeSoak, lineSweep, dataPlane }

extension FieldPlanKindLabel on FieldPlanKind {
  String get label => switch (this) {
        FieldPlanKind.homeSoak => 'Home soak (stationary)',
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
