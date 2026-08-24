import 'testbed_config.dart';

/// DEBUG/TESTBED ONLY. Pure builders for the common [FieldPlan] shapes, plus
/// a named preset list for the auto-runner dropdown and a wizard that turns a
/// few answers into a plan. No pubkeys anywhere — every plan here is
/// rosterless (the two-device default: sends target the one identified peer).
class FieldPlanPresets {
  FieldPlanPresets._();

  /// RAW link throughput: MTU-sized unsealed blobs pushed as fast as the
  /// send path drains, one step per GATT leg — notify (our peripheral leg),
  /// write (our central leg), stripe (alternate blobs across both). No seal,
  /// no ACK, no buffering: this measures the naked GATT pipe, and the gap to
  /// the protocol numbers is the measured cost of the stack. The receiver
  /// counts bytes in its wire ledger and drops the blobs before the parser.
  /// `+4` / `-4` / `0` — a signed tag for a step label.

  /// Diluting mesh with a DEDICATED WARM-UP after every join and a QUIET
  /// ACK-drain window after every send — the unified methodology for desk and
  /// field. ROLE-FREE: every phone loads this identical plan; each step
  /// carries [FieldStep.cliqueN] and the runner derives THIS phone's radio
  /// schedule from its own nickname at launch (on iff nickname <= cliqueN),
  /// so there is no per-role entry to pick wrongly. Radios start OFF
  /// everywhere; [scriptedRadio] turns each on only when its device joins.
  ///
  /// Per clique size N = 2..7:
  ///   1. the joining device's radio comes up,
  ///   2. settle — [firstWarmupSec] (60 s) at N=2 while the pair forms, else
  ///      [warmupSec] (30 s) for the one new link — a no-send step so the
  ///      grown clique converges BEFORE it is measured,
  ///   3. for each load level {light 10%, medium 50%, heavy = saturate}, run
  ///      [reps] trials, each [sendSec] s of all-to-all send followed by
  ///      [quietSec] s of silence so late ACKs land in the send step's window
  ///      (delivery is attributed by send step, not arrival).
  ///
  /// The quiet window is the plan's [autoAdvanceGapSec], so it sits after
  /// every step; the per-N settle is a real no-send step on top of it. An
  /// un-joined phone schedules nothing (the runner gates sends on the derived
  /// bleOn). ~3.3 h for the full N=2..7 sweep.
  /// Diluting mesh at the LINE SWEEP'S loads, so the two experiments share
  /// an axis: the same per-destination counts the pair carried on a line ---
  /// probe (2 a trial), moderate (100) and overload (500 offered) --- swept
  /// across clique sizes. The pair experiment is then this sweep's N=2
  /// baseline by construction.
  ///
  /// NO warm-up steps: the joining device's radio comes up as the new clique
  /// size's first trial begins, and convergence happens inside it --- the
  /// first trial of each N is therefore a join trial, and the analysis can
  /// treat it separately or not. Links and sessions stay warm otherwise:
  /// this measures the data plane of a standing mesh, not establishment.
  ///
  /// The quiet drain after every trial is kept: at the overload arm,
  /// acknowledgements outlive the send window by tens of seconds, and
  /// without the drain each trial's tail lands inside the next one's
  /// accounting — the line sweep could afford a short gap only because its
  /// probe and moderate arms acknowledged in under a second.
  ///
  /// ROLE-FREE like the warm-up sweep: every phone loads this identical
  /// plan, and derives its radio schedule from its nickname (on iff
  /// nickname <= cliqueN).
  static FieldPlan dilutingLineLoads({
    String expId = 'dilute-6-line-loads',
    int reps = 10,
    int sendSec = 30,
    int quietSec = 30,
    int sendBytes = 138,
  }) {
    // The line sweep's arms, verbatim: sendCount per destination per trial.
    // 0 = saturate stands in for the 500-offered overload arm on purpose NOT
    // here — the line offered a PACED 500 and measured the queue, and pacing
    // is what keeps the two experiments comparable.
    const levels = [('probe', 2), ('moderate', 100), ('overload', 500)];
    final steps = <FieldStep>[];
    for (final n in const [2, 3, 4, 5, 6, 7]) {
      for (final (name, count) in levels) {
        for (var t = 1; t <= reps; t++) {
          steps.add(FieldStep(
            label: 'N=$n L=$name t$t',
            dwellSec: sendSec,
            cliqueN: n,
            sendTo: 'all',
            sendBytes: sendBytes,
            sendCount: count,
            autoAdvance: steps.isNotEmpty,
          ));
        }
      }
    }
    return FieldPlan(
      expId: expId,
      settleSec: 30,
      autoAdvanceGapSec: quietSec,
      resetSessions: false,
      resetLinks: false,
      // Every trial starts from an empty custody buffer, exactly as on the
      // line: ten independent draws per cell, and no trial ever drains a
      // predecessor's backlog. Store-carry-forward stays observable within
      // a trial's send-plus-drain minute; it does not span trials.
      resetDtnBuffer: true,
      manualJoin: true,
      alignSec: 300,
      placementSec: 120,
      scriptedRadio: true,
      steps: steps,
    );
  }

  /// Two nodes on stands in an open field, one walked out from touching
  /// distance to out of range. Answers what signal strength a link needs to be
  /// discovered, established and usable, and what the control plane costs in
  /// bytes to build a link and then to hold one.
  ///
  /// Every step is a COLD trial: links, sessions and the DTN buffer are all
  /// reset before it, so each dwell is a full ANNOUNCE -> handshake -> session
  /// ladder measured from the step marker. Nothing survives a trial to bias
  /// the next, which is what makes the direction free — it runs outward
  /// because the pair starts together, where placing them is easiest.
  ///
  /// Sends are deliberately minimal: enough to stamp the link usable and
  /// nothing more. The measurement is the control plane, and application
  /// traffic would bury the ANNOUNCE and sync bytes it is trying to weigh.
  ///
  /// Running it:
  ///
  ///  1. Sync both clocks, turn Wi-Fi off on both, and check each nickname
  ///     parses as an integer — the testbed reads it as the join order and a
  ///     non-numeric one silently becomes node 1.
  ///  2. Mark the twelve positions along the line before starting. Stand both
  ///     phones at the 10 m pair; only the far one ever moves.
  ///  3. Load this preset on both and confirm the expId in the JSON preview
  ///     rather than the dropdown label.
  ///  4. Launch both inside one alignment interval, then check that both
  ///     screens show the SAME `starts at` time. They compute it independently,
  ///     so two different times mean two different schedules — and the run
  ///     gives no other sign of it until the traces are read.
  ///  5. Step well clear of both phones before that instant. A body at 2.4 GHz
  ///     is worth several dB, and it lands straight in the RSSI this measures.
  ///  6. Each segment ends with a walk window: move the far phone to the next
  ///     mark and step away again before the next segment opens. The phones
  ///     advance on the clock and wait for nobody.
  ///  7. After the last distance let it settle and upload, then turn Wi-Fi
  ///     back on.
  /// The dropdown entry whose reach and repeat count the testbed chooses.
  static const String lineSweepPresetName = 'Line sweep (2 phones — pick '
      'reach and repeats below)';

  /// A sweep from [startDistance] out to [maxDistance] in [stepMetres]
  /// steps, [trials] dwells at each.
  ///
  /// Where the sweep starts, how far it reaches and how finely it samples are
  /// all properties of the site, not of the experiment: a corridor may only
  /// allow 60 m, an open field may not be worth sampling below 40, and a
  /// range where the link is about to fail deserves closer steps than one
  /// where it plainly holds. Repeats trade against daylight.
  ///
  /// A start past the reach still yields one position rather than an empty
  /// plan — a sweep of one distance is a legitimate thing to ask for, and a
  /// plan with no steps is not.
  static FieldPlan lineSweepUpTo({
    int startDistance = 10,
    int maxDistance = 120,
    int stepMetres = 10,
    int trials = 10,
    int dwellSec = 30,
    int sendCount = 100,
    String? receiverPrefix,
  }) {
    final step = stepMetres < 1 ? 1 : stepMetres;
    final distances = <int>[
      for (var d = startDistance; d <= maxDistance; d += step) d,
    ];
    // Thesis line design by default: 100 messages per trial (1000 a distance
    // at x10, the July load) in a 30 s dwell, and the operator resets the
    // whole Bluetooth stack at every position during the walk — each
    // distance's trials run on a stack that carries nothing over from the
    // previous one. Both the load and the dwell are chosen per outing.
    // One-way when a receiver prefix is given, exactly the July design: the
    // phone whose pubkey matches receives, every other phone sends 100 a
    // trial toward it, and the receiver itself matches no target and sends
    // nothing. Blank keeps both phones sending.
    // A trial has to be long enough to carry its own load: the sends are
    // spread across the dwell, and whatever has not gone out when the dwell
    // closes is cancelled, which shows up as a trial that quietly sent fewer
    // messages than the plan asked for.
    final base = lineSweep(
      distances: distances.isEmpty ? [startDistance] : distances,
      trials: trials,
      dwellSec: dwellSec < 5 ? 5 : dwellSec,
      sendCount: sendCount < 1 ? 1 : sendCount,
      sendTo: (receiverPrefix == null || receiverPrefix.trim().isEmpty)
          ? 'all'
          : receiverPrefix.trim().toLowerCase(),
    );
    return FieldPlan(
      expId: base.expId,
      steps: base.steps,
      settleSec: base.settleSec,
      roster: base.roster,
      resetSessions: base.resetSessions,
      resetLinks: base.resetLinks,
      linkResetDarkSec: base.linkResetDarkSec,
      resetDtnBuffer: base.resetDtnBuffer,
      autoAdvanceGapSec: base.autoAdvanceGapSec,
      resetBudgetSec: base.resetBudgetSec,
      walkBudgetSec: base.walkBudgetSec,
      manualJoin: true,
      placementSec: 120,
      alignSec: 120,
      scriptedRadio: base.scriptedRadio,
      stackResetPerPosition: true,
    );
  }

  static FieldPlan lineSweep({
    String expId = 'line-1',
    List<int> distances = const [
      10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120
    ],
    int trials = 10,
    int dwellSec = 30,
    int sendCount = 2,
    String sendTo = 'all',
    int darkSec = 3,
    int resetBudgetSec = 5,
    int walkBudgetSec = 120,
  }) {
    return FieldPlan(
      expId: expId,
      // Nothing survives a run to drain: the buffer, the sessions and the
      // radio are all reset on both sides of every one, including the last.
      // A settle window would only record events belonging to no segment.
      settleSec: 0,
      // No settle gap: the wall-clock schedule counts down to each step's own
      // instant, so a gap between steps is dead time rather than a settle.
      autoAdvanceGapSec: 0,
      walkBudgetSec: walkBudgetSec,
      // The measured links-reset on both run phones is 3.1 s, worst case 3.15
      // over 30 resets each; 5 s reserves that with headroom so the dwell
      // opens on its instant at a full length.
      resetBudgetSec: resetBudgetSec,
      resetSessions: true,
      resetLinks: true,
      linkResetDarkSec: darkSec,
      resetDtnBuffer: true,
      steps: [
        for (final d in distances)
          for (var t = 1; t <= trials; t++)
            FieldStep(
              // `d=<n>` is what the analyzer reads the distance out of; the
              // trial suffix keeps repeat dwells at one position distinct.
              label: 'd=$d t$t',
              dwellSec: dwellSec,
              sendCount: sendCount,
              sendTo: sendTo,
              // Only the first trial at a distance waits for the operator —
              // the repeats have nothing to walk to.
              autoAdvance: t > 1,
            ),
      ],
    );
  }

  /// Rebuild [p] under the manual running logic: wall-clock-anchored start.
  /// This is the ONE flow every experiment runs under; walk-driven plans no
  /// longer exist. The lone exception is the bounce-stress diagnostic, whose
  /// subject IS the app-level toggle.
  ///
  /// Who works the radio is the PLAN's property and is carried through
  /// untouched: anchoring a plan on the clock says nothing about whether its
  /// steps toggle BLE themselves. Dropping [FieldPlan.scriptedRadio] here
  /// turned every hands-free ladder into one that stops and asks an operator
  /// for a toggle the plan was built to perform.
  ///
  /// Only valid for stationary plans, where every step can open on the
  /// clock.
  static FieldPlan manualized(FieldPlan p,
      {int alignSec = 120, int placementSec = 60}) {
    return FieldPlan(
      expId: p.expId,
      steps: p.steps,
      settleSec: p.settleSec,
      roster: p.roster,
      resetSessions: p.resetSessions,
      resetLinks: p.resetLinks,
      linkResetDarkSec: p.linkResetDarkSec,
      resetDtnBuffer: p.resetDtnBuffer,
      autoAdvanceGapSec: p.autoAdvanceGapSec,
      resetBudgetSec: p.resetBudgetSec,
      walkBudgetSec: p.walkBudgetSec,
      manualJoin: true,
      scriptedRadio: p.scriptedRadio,
      stackResetPerPosition: p.stackResetPerPosition,
      placementSec: placementSec,
      alignSec: alignSec,
    );
  }

  /// The launchable experiments. Only what the thesis runs: the line sweep
  /// (reach, repeats, dwell and load chosen in the pickers) and the diluting
  /// clique at the line sweep's loads.
  static Map<String, FieldPlan> get presets => {
        lineSweepPresetName: lineSweepUpTo(),
        'Diluting clique at line loads N=2..7 (~3h)': dilutingLineLoads(),
      };
}
