import 'testbed_config.dart';

/// DEBUG/TESTBED ONLY. Pure builders for the common [FieldPlan] shapes, plus
/// a named preset list for the auto-runner dropdown. No pubkeys anywhere —
/// every plan here is rosterless (the two-device default: sends target the
/// one identified peer).
class FieldPlanPresets {
  FieldPlanPresets._();

  /// Diluting mesh at ONE load: the line's moderate 100 per destination a
  /// run --- the load its last field test carried --- swept across clique
  /// sizes. The pair experiment is then this sweep's N=2 baseline by
  /// construction.
  ///
  /// One arm on purpose. The overload arm's transmit queue outlives its
  /// run: writes the stack accepted keep draining through the following
  /// drain and into the next cell's radio time, so consecutive cells stop
  /// being independent draws --- the desk sweep showed the tail still
  /// transmitting twenty seconds past its dwell. A probe arm adds little a
  /// moderate arm does not already show. One load keeps every run's
  /// radio its own.
  ///
  /// NO warm-up steps: the joining device's radio comes up as the new clique
  /// size's first run begins, and convergence happens inside it --- the
  /// first run of each N is therefore a join run, and the analysis can
  /// treat it separately or not. Every clique growth carries a 5 s lattice
  /// gap ([FieldPlan.joinGapSec]) between the old N's drain and the new N's
  /// first dwell — all devices wait it together, and it is where the joining
  /// phone's transport is built, advertises, is discovered and handshakes,
  /// so none of that is charged to the dwell that follows. The test's first run resets links
  /// and sessions once, on every device — nothing from staging survives —
  /// and from there both stay warm: this measures the data plane of a
  /// standing mesh, not establishment.
  ///
  /// The quiet drain after every run is kept: at the overload arm,
  /// acknowledgements outlive the send window by tens of seconds, and
  /// without the drain each run's tail lands inside the next one's
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
    int sendBytes = 138,
    int sendCount = 100,
    int placementSec = 120,
    int alignSec = 300,
    // Offer as much as the radio will take instead of a fixed count, so a
    // cell reports the link's CEILING rather than the load the plan chose.
    // At moderate load every clique size below five is an offered-load
    // floor: the mesh delivered what it was given and was never asked for
    // more, so nothing in that data says what a radio can carry at k links.
    // [FieldStep.sendCount] is ignored while this is on, so every other
    // parameter here keeps its meaning and the two arms differ in exactly
    // the three fields the label names.
    bool saturating = false,
    // A saturating dwell ends with acknowledgements still in flight, and
    // one lane in flight is not a queue tail — but the confirmations still
    // outlive the window, so the drain is longer than the dwell rather
    // than equal to it, as on the throughput arms.
    int saturatingDrainSec = 60,
  }) {
    final steps = <FieldStep>[];
    for (final n in const [2, 3, 4, 5, 6, 7]) {
      for (var t = 1; t <= reps; t++) {
        steps.add(FieldStep(
          label: 'N=$n L=${saturating ? 'sat' : 'moderate'} t$t',
          dwellSec: sendSec,
          cliqueN: n,
          sendTo: 'all',
          sendBytes: sendBytes,
          sendCount: sendCount,
          saturate: saturating,
          // One write in flight per lane: `_fireSaturating` awaits each
          // send, so a single lane cannot leave a backlog that spills into
          // the next step and charges its dwell for this one's traffic.
          sendLanes: 1,
          autoAdvance: steps.isNotEmpty,
          // The test's FIRST run resets links and sessions, once, on
          // every device: both form at the desk during staging and
          // otherwise survive into the test, so phones create messages
          // for peers whose radio is still down — half the created load
          // at N=2 queued and died at the next buffer clear. The session
          // purge rides the link bounce's dark window; a phone whose
          // radio is scripted off for this step has no transport to
          // bounce and just purges. After this once, the mesh stays warm
          // for the whole test — an N boundary resets nothing; the wait
          // there is the plan's [FieldPlan.joinGapSec], which is radio
          // bring-up for the joining phone.
          resetSessions: steps.isEmpty ? true : null,
          resetLinks: steps.isEmpty ? true : null,
        ));
      }
    }
    return FieldPlan(
      expId: expId,
      resetSessions: false,
      resetLinks: false,
      // Only the test's first run bounces (its per-step override), and
      // every phone that bounces does so at the same lattice instant, so no
      // peer holds a stale path worth waiting out. The length is set by what
      // the dark window now CARRIES rather than by the bounce: the trace
      // flush runs here, because it is the only moment nothing can transmit
      // or receive. Ten seconds covers a several-hundred-KB write on the
      // slowest phone in the fleet with room to spare; the 3 s the bounce
      // alone needed did not. The default gap (2 announce cycles + 10 s =
      // 30 s) would still spend a whole dwell dark.
      linkResetDarkSec: 10,
      // Charged only ahead of the one bouncing step (stepStarts skips the
      // slot everywhere else, so no N boundary pays it), and taken out of
      // placement, so t1 opens on the anchor at full length instead of
      // stamping late by the bounce. It has to cover the whole dark window
      // — now 10 s, since the flush runs inside it — plus transport re-init.
      resetBudgetSec: 15,
      // Every run starts from an empty custody buffer, exactly as on the
      // line: ten independent draws per cell, and no run ever drains a
      // predecessor's backlog. Store-carry-forward stays observable within
      // a run's send-plus-drain minute; it does not span runs.
      resetDtnBuffer: true,
      // Between Ns: the old N's last run drains, then every device waits
      // these 5 s with no dwell running anywhere, which is what the joining
      // phone's radio needs to come up — its transport is disposed until its
      // step opens, so it must advertise, be discovered and handshake before
      // a send to it can land. Measured at seven phones: linked 0.6 s and
      // receiving 2.2 s after its instant.
      joinGapSec: 5,
      drainSec: saturating ? saturatingDrainSec : null,
      manualJoin: true,
      alignSec: alignSec,
      placementSec: placementSec,
      scriptedRadio: true,
      // Every testbed plan records every sighting: the volume is affordable
      // and the alternative is a discovery metric that measures the limiter.
      traceEveryAdvertisement: true,
      steps: steps,
    );
  }

  /// Two nodes on stands in an open field, one walked out from touching
  /// distance to out of range. Answers what signal strength a link needs to be
  /// discovered, established and usable, and what the control plane costs in
  /// bytes to build a link and then to hold one.
  ///
  /// Every step is a COLD run: links, sessions and the DTN buffer are all
  /// reset before it, so each dwell is a full ANNOUNCE -> handshake -> session
  /// ladder measured from the step marker. Nothing survives a run to bias
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
  ///     so two different times mean two different schedules — and the test
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
  /// steps, [runs] dwells at each.
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
    int runs = 10,
    int dwellSec = 30,
    int sendCount = 100,
    String? receiverPrefix,
  }) {
    final step = stepMetres < 1 ? 1 : stepMetres;
    final distances = <int>[
      for (var d = startDistance; d <= maxDistance; d += step) d,
    ];
    // Thesis line design by default: 100 messages per run (1000 a distance
    // at x10, the July load) in a 30 s dwell, and the operator resets the
    // whole Bluetooth stack at every position during the walk — each
    // distance's runs run on a stack that carries nothing over from the
    // previous one. Both the load and the dwell are chosen per outing.
    // One-way when a receiver prefix is given, exactly the July design: the
    // phone whose pubkey matches receives, every other phone sends 100 a
    // run toward it, and the receiver itself matches no target and sends
    // nothing. Blank keeps both phones sending.
    // A run has to be long enough to carry its own load: the sends are
    // spread across the dwell, and whatever has not gone out when the dwell
    // closes is cancelled, which shows up as a run that quietly sent fewer
    // messages than the plan asked for.
    final base = lineSweep(
      distances: distances.isEmpty ? [startDistance] : distances,
      runs: runs,
      dwellSec: dwellSec < 5 ? 5 : dwellSec,
      sendCount: sendCount < 1 ? 1 : sendCount,
      sendTo: (receiverPrefix == null || receiverPrefix.trim().isEmpty)
          ? 'all'
          : receiverPrefix.trim().toLowerCase(),
    );
    return FieldPlan(
      expId: base.expId,
      steps: base.steps,
      roster: base.roster,
      resetSessions: base.resetSessions,
      resetLinks: base.resetLinks,
      linkResetDarkSec: base.linkResetDarkSec,
      resetDtnBuffer: base.resetDtnBuffer,
      resetBudgetSec: base.resetBudgetSec,
      traceEveryAdvertisement: base.traceEveryAdvertisement,
      joinGapSec: base.joinGapSec,
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
    int runs = 10,
    int dwellSec = 30,
    int sendCount = 2,
    String sendTo = 'all',
    int darkSec = 10,
    int resetBudgetSec = 15,
    int walkBudgetSec = 120,
  }) {
    return FieldPlan(
      expId: expId,
      walkBudgetSec: walkBudgetSec,
      // The measured links-reset on both run phones is 3.1 s, worst case 3.15
      // over 30 resets each; 5 s reserves that with headroom so the dwell
      // opens on its instant at a full length.
      resetBudgetSec: resetBudgetSec,
      resetSessions: true,
      resetLinks: true,
      linkResetDarkSec: darkSec,
      resetDtnBuffer: true,
      // RSSI against distance IS this experiment; every sighting counts.
      traceEveryAdvertisement: true,
      steps: [
        for (final d in distances)
          for (var t = 1; t <= runs; t++)
            FieldStep(
              // `d=<n>` is what the analyzer reads the distance out of; the
              // run suffix keeps repeat dwells at one position distinct.
              label: 'd=$d t$t',
              dwellSec: dwellSec,
              sendCount: sendCount,
              sendTo: sendTo,
              // Only the first run at a distance waits for the operator —
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
      roster: p.roster,
      resetSessions: p.resetSessions,
      resetLinks: p.resetLinks,
      linkResetDarkSec: p.linkResetDarkSec,
      resetDtnBuffer: p.resetDtnBuffer,
      resetBudgetSec: p.resetBudgetSec,
      joinGapSec: p.joinGapSec,
      walkBudgetSec: p.walkBudgetSec,
      manualJoin: true,
      scriptedRadio: p.scriptedRadio,
      traceEveryAdvertisement: p.traceEveryAdvertisement,
      stackResetPerPosition: p.stackResetPerPosition,
      placementSec: placementSec,
      alignSec: alignSec,
    );
  }

  /// The launchable experiments: the line sweep (reach, repeats, dwell and
  /// load chosen in the pickers), the diluting clique at the line sweep's
  /// loads, and a smoke variant of the clique — the same steps at the SAME
  /// dwell and half the repeats, so a fresh build can be checked end to end
  /// (joins, pacing, resets, upload) at a desk in half an hour instead of an
  /// hour, at the load the field run will offer.
  ///
  /// The smoke entry, whose RUNS PER CLIQUE SIZE come from the screen's
  /// picker rather than a constant here.
  ///
  /// How many runs a cell needs is a question about the measurement, not
  /// about the plan: comparing two builds needs enough repeats to quote a
  /// spread (repeats of one unchanged build have differed by ~7 points of
  /// delivery and by half a dozen pairs that aired a hundred messages and
  /// delivered none, so one or two cannot separate a change from noise),
  /// while checking that a fresh build joins, paces, resets and uploads at
  /// all needs one. Both are the same plan at a different repeat count, so
  /// the count is picked at launch instead of edited into the source.
  static const String linkChurnPresetName =
      'Link churn + throughput at N=8 (~2h40m — the k=7 row)';

  /// The one clique size the simulator cannot get from `clique-final`.
  ///
  /// Every simulated node holds the seven-link cap, and the surviving clique
  /// reductions already carry k=1..6, so the only missing row is k=7 --- which
  /// is N=8, since a node's link count is N-1. The clique's RAW records are
  /// gone, so nothing per-device can be recovered from it below k=7; that is
  /// a limit of the archive, not something more phones fix.
  ///
  /// Three arms in one plan, run in this order because each leaves the mesh
  /// in the state the next one wants:
  ///
  ///  1. **fixed load** --- 60 s of [sendCount] messages to every session,
  ///     then a 60 s drain, then links broken and the DTN buffer purged.
  ///     Sessions are KEPT, so each run measures link establishment against
  ///     warm sessions and the handshake never sits on the latency path. The
  ///     operator establishes sessions by hand before the first run; a
  ///     `session` stage inside a run is therefore a session LOSS, except on
  ///     the joining phone at a clique-size boundary, of which this plan has
  ///     none.
  ///  2. **saturating** --- the same, offering as much as the radio takes
  ///     rather than a fixed count, which is the only way to read a CEILING.
  ///     A fixed-load arm reports what it was given, never what it could
  ///     carry, so the two arms answer different questions and both are
  ///     needed.
  ///  3. **long hold** --- ten [holdReps] ten-minute runs with NO in-run
  ///     resets, so a
  ///     dropped link is watched until it comes back. Outage durations
  ///     elsewhere are censored by the run length: on 120 s runs against
  ///     outage means of one to five minutes, most durations are cut off and
  ///     the mean is a lower bound of unknown tightness.
  ///
  /// There is no N=10 cap arm. The seven-link cap is settled by direct
  /// observation --- nine devices in range for over an hour at ZERO load,
  /// with no Nexus 5X above seven --- and zero load is what makes that
  /// decisive, since it removes the one confound a loaded run cannot
  /// exclude: that the phones were too busy dialling to reach more peers.
  /// A loaded N=10 arm could only weaken it.
  static FieldPlan linkChurn({
    String expId = 'churn-n8-1',
    int reps = 10,
    int holdReps = 10,
    int sendSec = 60,
    int holdSec = 600,
    int sendBytes = 138,
    int sendCount = 100,
  }) {
    final steps = <FieldStep>[];
    void arm(String load, int n, int count, int dwell,
        {required bool saturating, required bool breakLinks}) {
      for (var t = 1; t <= count; t++) {
        // Purged on the FIRST run of each arm and never again inside it.
        //
        // Not per run: that is what truncated latency, since a message still
        // in flight when a run ends was deleted and the distribution cut off
        // at about dwell-plus-drain. Not never, either: the arms offer
        // DIFFERENT loads, so each has its own steady state, and an arm that
        // inherits the previous arm's backlog starts outside its own. The
        // saturating arm is the case that matters --- inherited transit goes
        // straight into the ceiling it exists to measure, so it has to
        // generate the buffer it works against rather than borrow one.
        //
        // Arms independent of each other, runs independent inside an arm by
        // reaching a common steady state under one constant offered rate.
        final firstOfArm = t == 1;
        steps.add(FieldStep(
          label: 'N=$n L=$load t$t',
          dwellSec: dwell,
          cliqueN: n,
          sendTo: 'all',
          sendBytes: sendBytes,
          // Scaled to the dwell so every arm offers the SAME RATE. Sends are
          // paced evenly across the window, so a fixed count over a ten-minute
          // dwell would offer a tenth of what the one-minute arms do, and the
          // long hold would measure outages under a load the rest of the run
          // never sees.
          sendCount: (sendCount * dwell / sendSec).round(),
          saturate: saturating,
          sendLanes: 1,
          resetDtnBuffer: firstOfArm,
          // Links go down between runs so establishment is measured each
          // time --- except in the long hold, whose whole point is to let an
          // outage run its course rather than be ended by the harness.
          resetLinks: breakLinks,
          autoAdvance: steps.isNotEmpty,
        ));
      }
    }
    arm('moderate', 8, reps, sendSec, saturating: false, breakLinks: true);
    arm('sat', 8, reps, sendSec, saturating: true, breakLinks: true);
    arm('hold', 8, holdReps, holdSec, saturating: false, breakLinks: false);
    return FieldPlan(
      expId: expId,
      // Sessions are NEVER reset, on any step including the first: the
      // testbed starts warm with the operator having established them by
      // hand, and this plan has no clique-size growth to form new ones.
      resetSessions: false,
      // Seven, because a node's session count is N-1 and this plan never
      // forms one. A phone launching short cannot create a packet for the
      // peers it is missing --- the send path gates on `hasSession` --- so
      // those ordered pairs would contribute nothing for the whole run and
      // the shortfall would surface only in the reduction. Refusing to launch
      // costs a relaunch; launching short costs the row.
      minSessionsToLaunch: 7,
      // FALSE at plan level, with the real value carried per step. This is
      // not a preference: `FieldPlan.gapAfterSec` reads the PLAN flag and
      // short-circuits the drain to zero when it is true, so a plan-level
      // `true` silently discards every drain in the run --- and a saturating
      // dwell ends with acknowledgements still in flight, which is exactly
      // the tail that would be lost. The steps set it explicitly, and every
      // reset site (`_runResets`, `resetSlotMs`, `stepStarts`) reads the
      // per-step override, so behaviour is unchanged where it matters.
      resetLinks: false,
      resetDtnBuffer: false,
      // NO cap override: the store's default is left in place, so eviction
      // never fires. A cap plus a uniform offered rate would make the SLOWER
      // phones fill and evict more, and eviction is oldest-first, so the loss
      // would land on exactly the devices whose write capability this run is
      // measuring --- the Nexus refuses about a third of its conveyance
      // attempts and airs half the bytes of a modern phone. Buffer occupancy
      // is left free to differ by device, where it is an OBSERVATION of that
      // difference rather than a mechanism distorting it.
      linkResetDarkSec: 10,
      resetBudgetSec: 15,
      // Acknowledgements outlive a 60 s send window, so the drain is longer
      // than the dwell rather than derived from it.
      drainSec: 60,
      joinGapSec: 5,
      manualJoin: true,
      alignSec: 300,
      placementSec: 120,
      scriptedRadio: true,
      traceEveryAdvertisement: true,
      steps: steps,
    );
  }

  /// The dropdown entry for the saturating arm of the diluting clique.
  static const String dilutingSaturatingPresetName =
      'Diluting clique SATURATING N=2..7 (~1.5h — per-link ceilings)';

  /// The diluting clique offering as much as each radio will take, so every
  /// clique size reports a carrying ceiling rather than the load the plan
  /// chose. Identical to [dilutingLineLoads] in every other respect --- same
  /// sizes, repeats, dwell, join order and warm mesh --- because it IS that
  /// preset with its saturating flag set, not a second copy of it.
  ///
  /// Its own expId: the label distinguishes the arms inside a run, and the
  /// id keeps them in separate files so neither can overwrite the other.
  static FieldPlan dilutingSaturating({
    String expId = 'clique-sat-1',
    int reps = 10,
  }) =>
      dilutingLineLoads(expId: expId, reps: reps, saturating: true);

  static const String dilutingSmokePresetName =
      'Diluting clique smoke test (N=2..7, field dwell — pick runs)';

  /// The smoke plan at [reps] runs per clique size. Desk-sized
  /// placement/align: nothing to walk to, so the field preset's 2 min walk +
  /// 5 min boundary would only add dead air — the smoke starts on the next
  /// MINUTE, not the next 5 minutes.
  ///
  /// The DWELL is the field's 30 s, not a shrunken one: 100 messages per
  /// destination in 10 s is three times the rate the field plan offers, so a
  /// shortened dwell does not rehearse the field run -- it measures a
  /// different, heavier one. A run at 30 s also leaves the acknowledgements
  /// room to land inside their own run: at 10 s the slower cells were still
  /// acknowledging after the window closed.
  static FieldPlan dilutingSmoke({int reps = 5}) => dilutingLineLoads(
        expId: 'dilute-smoke-18',
        reps: reps,
        placementSec: 20,
        alignSec: 60,
      );

  /// The dropdown entry for [homeMatch].
  static const String homeMatchPresetName =
      'RSSI match check (2 phones, desk — compare against a field distance)';

  /// Three runs at ONE desk position, shaped like a single [lineSweep] cell:
  /// cold-reset every run, the field's own message load, not a shrunken
  /// desk-only one. The purpose is narrow -- put two phones at a candidate
  /// indoor separation and check whether the resulting advertisement RSSI
  /// distribution matches a specific field distance's, before trusting the
  /// desk stand-in for anything further.
  ///
  /// [matchDistance] is a LABEL, not a real separation -- it names the field
  /// distance this desk run is meant to stand in for (`d=$matchDistance` in
  /// every step, so the trace reads the same way a real sweep cell would).
  /// The actual physical distance is whatever the operator set the phones to
  /// get a matching RSSI; the plan has no way to know it and does not need
  /// to, since the comparison is done from the recorded RSSI, not the tape
  /// measure. [expId] defaults away from `line-1`/`line-200` so this can
  /// never merge with real field data.
  ///
  /// [dwellSec]/[sendCount] default to what line-200 actually ran (45 s,
  /// 100), not this file's field-sweep defaults (30 s) -- the point is to
  /// reproduce that trial's shape, not the sweep's.
  ///
  /// [resetBudgetSec] defaults higher than [lineSweep]'s 15 s: one Nexus 5X
  /// in the fleet has a measured 15.1 s mode on ~20% of its link resets,
  /// which a 15 s budget cuts off mid-bounce one run in five, opening that
  /// run late into its own dwell.
  ///
  /// [placementSec] is desk-sized like [dilutingSmoke]'s -- both phones are
  /// already in position, so the field preset's 2-minute walk allowance would
  /// only add dead air. [alignSec] is NOT shrunk to match: every phone rounds
  /// its own tap up to the same wall-clock boundary independently
  /// (`FieldRunner.start`'s `anchor`), so two phones tapping Launch even
  /// tens of seconds apart still share a start UNLESS their taps straddle a
  /// boundary -- a straddle's odds are `tapSpread / alignSec`, so a 60 s
  /// window turns an ordinary manual-launch delay between two operators (or
  /// two adb-driven agents) into good-than-not odds of a split. Measured
  /// once: two agents tapping 41 s apart against a 60 s boundary landed on
  /// different anchors, one full window off, for the whole plan -- the
  /// phones still found each other at the overlap margins (91% delivery
  /// instead of the field run's 100%), which is what made it look like it
  /// had worked rather than failing loudly. 120 s is deliberately generous
  /// against that failure mode; synchronizing the actual taps (fire both
  /// from one shell call, not two independent agents racing) removes it
  /// almost entirely, but the wide window is cheap insurance against a
  /// pre-flight check being skipped.
  static FieldPlan homeMatch({
    String expId = 'home-desk-match',
    int matchDistance = 20,
    int runs = 3,
    int dwellSec = 45,
    int sendCount = 100,
    int resetBudgetSec = 25,
    int placementSec = 20,
    int alignSec = 120,
  }) =>
      manualized(
        lineSweep(
          expId: expId,
          distances: [matchDistance],
          runs: runs,
          dwellSec: dwellSec,
          sendCount: sendCount,
          resetBudgetSec: resetBudgetSec,
        ),
        placementSec: placementSec,
        alignSec: alignSec,
      );

  /// The dropdown entry for [advertisementCapture].
  static const String advertisementCapturePresetName =
      'Advertisement capture (2 phones — one scans, one advertises)';

  /// Raw ADV reception, isolated from everything else the radio normally
  /// does at the same time: no GATT link ever forms, no session, no sync
  /// exchange, no application traffic. This is the field-side half of a
  /// same-hardware comparison against the GR paper's Pi testbed, which
  /// measured passive-scan capture with nothing else running on the radio.
  ///
  /// Getting there needs THREE independent things, none of them new:
  ///
  /// 1. **Which role each phone plays is a per-device SETTING, not a step
  ///    in this plan** — [FieldStep.bleOn] toggles the radio on/off
  ///    wholesale, but scan-vs-advertise-only is `BleRoleMode`
  ///    (`Settings -> BLE role (debug)`), which persists across runs and
  ///    is not scriptable per step. Before launching, set the SCANNING
  ///    phone to **Central** and the ADVERTISING phone to **Peripheral**.
  ///    A plan cannot do this for you; get it wrong and both phones just
  ///    run the production default.
  ///
  /// 2. **`BleRoleMode.centralOnly` stops a phone from ADVERTISING, not
  ///    from DIALING what it sees** — the scanner would otherwise open a
  ///    GATT link on every sighting like it does in production, which is
  ///    exactly the confound this test exists to remove. `maxParallelDials:
  ///    0` closes that gap: `connectToDevice`'s own admission check is
  ///    `_inFlightCentralDials() >= maxInFlightCentralDials`, and with the
  ///    cap at 0 that is true before any dial is attempted, so it refuses
  ///    every one, unconditionally — "no dial is ever exempt from it" per
  ///    the cap's own contract. The advertising phone needs no matching
  ///    setting: nothing ever dials it, so its peripheral GATT server is
  ///    never even approached.
  ///
  /// 3. **[FieldPlan.traceEveryAdvertisement]** disables the RSSI trace's
  ///    900 ms-per-path throttle, so every sighting is logged rather than
  ///    at most one per path per 900 ms. `lineSweep` sets this too, for
  ///    the same reason: a rate comparison against a system with no
  ///    throttle at all (the Pi's Bleak scanner) is only honest if this
  ///    side has none either.
  ///
  /// Every run is COLD, exactly like [lineSweep]: `resetSessions`/
  /// `resetLinks`/`resetDtnBuffer` are plan-level defaults (true), with no
  /// per-step override, so EVERY step bounces the BT service ahead of its
  /// own dwell rather than only the first. Each `cap tN` therefore measures
  /// capture from a freshly-brought-up radio — ten independent draws,
  /// rather than one continuously-running scan session cut into ten labels.
  /// `sendCount: 0` and `maxParallelDials: 0` still hold on every step:
  /// there is still nothing to seal or ACK, and the scanner still must not
  /// dial what it sees.
  ///
  /// Twenty 60-second dwells: enough repeats to quote a spread on the
  /// rate, at the GR paper's own window length (its windows were a
  /// minute), so the per-window comparison is like for like. The RATE is
  /// what this arm exists to pin; longer windows tighten it but cannot
  /// raise the capture fraction, which is the scanner's, not the plan's.
  ///
  /// The schedule: [FieldRunner.stepStarts] charges `resetBudgetSec` (15 s)
  /// ahead of every step now, not just the first, since every step bounces
  /// — and charges no drain after any step, since [FieldPlan.gapAfterSec]
  /// is 0 once the plan's own `resetLinks` is true (the following step's own
  /// dark window is the settle). Runs therefore open `resetBudgetSec +
  /// dwellSec` apart — 45 s at the defaults — and the whole plan spans
  /// `(runs - 1) * 45 + dwellSec`: 885 s / about 14 minutes 45 seconds for
  /// twenty 30 s dwells (verified via [FieldRunner.stepStarts], not the
  /// naive `runs * (15 + dwellSec)`, which double-counts a reset the
  /// schedule never actually reserves past the last dwell). Each `cap tN`
  /// marker's own segment is still a clean, unbroken `dwellSec` of scanning.
  ///
  /// [alignSec] is 120, not the desk-usual 60: both phones bounce their
  /// radio before EVERY step on their own lattice, so landing one window
  /// apart puts the advertiser's dark windows inside the scanner's dwells
  /// and silently deflates every capture count. Two phones tapping tens of
  /// seconds apart straddle a 60 s boundary more often than not (odds are
  /// tapSpread/alignSec — measured once at 41 s spread and paid a full
  /// window of stagger); 120 s halves the odds, and firing both Launch taps
  /// from one shell removes the spread almost entirely.
  static FieldPlan advertisementCapture({
    String expId = 'adv-capture-2',
    int runs = 20,
    int dwellSec = 30,
  }) {
    return FieldPlan(
      expId: expId,
      resetSessions: true,
      resetLinks: true,
      resetDtnBuffer: true,
      traceEveryAdvertisement: true,
      // Every plan runs on the ONE wall-clock-anchored lattice — [start]
      // refuses outright without this, since [placementSec]/[alignSec]
      // are meaningless without it. Placement stays desk-sized (nothing to
      // walk to); the alignment window is wide for the straddle reason in
      // the doc comment above.
      manualJoin: true,
      placementSec: 20,
      alignSec: 120,
      // Every step bounces (plan-level resetLinks above), on every device
      // at the same lattice instant — same shape as lineSweep's own
      // per-run bounce, so the same values apply. Short, because a
      // SIMULTANEOUS bounce needs nothing hunted for: both sides drop
      // their transport together and there is no stale path on either to
      // wait out. Without a reserved slot the bounce runs INSIDE the
      // dwell instead of ahead of it, silently eating into it — the run
      // would then measure a shorter, still-reconnecting radio.
      linkResetDarkSec: 10,
      resetBudgetSec: 15,
      steps: [
        for (var t = 1; t <= runs; t++)
          FieldStep(
            label: 'cap t$t',
            dwellSec: dwellSec,
            sendCount: 0,
            maxParallelDials: 0,
            autoAdvance: t > 1,
          ),
      ],
    );
  }

  /// Name of the ring sweep in the dropdown. It carries no roster and needs
  /// none: the ring is derived on each phone from its own session table
  /// ([FieldPlan.ringRosterFromSessions]), so the identities come from the
  /// room and only the SIZE ([FieldPlan.ringSize]) is declared here.
  static const ringSweepPresetName = 'Ring-radius sweep r=1..diameter';
  static const ringSmokePresetName = 'Ring-radius desk smoke (~30m)';

  /// A deterministic shuffle, so every phone materialises a byte-identical
  /// schedule from the same seed.
  ///
  /// Explicitly NOT `dart:math`'s Random(seed): its sequence is not a
  /// contract, and the whole fleet must agree on the order. A tiny LCG written
  /// out here cannot drift between Dart versions or platforms. (Numerical
  /// Recipes' constants; the low bits are poor, so the high bits pick.)
  static List<int> _seededShuffle(List<int> items, int seed) {
    final out = List<int>.of(items);
    var state = (seed & 0x7fffffff) | 1;
    int next(int bound) {
      state = (state * 1664525 + 1013904223) & 0xffffffff;
      return (state >> 16) % bound;
    }

    for (var i = out.length - 1; i > 0; i--) {
      final j = next(i + 1);
      final tmp = out[i];
      out[i] = out[j];
      out[j] = tmp;
    }
    return out;
  }

  /// The ring-radius conveyance sweep.
  ///
  /// Manufactures network DIAMETER on a desk: the devices are ordered into a
  /// ring by sorted pubkey and at radius r a node may hold links only to peers
  /// within r hops around it. Sweeping r walks the graph from a 2-regular ring
  /// (diameter 5 at N=11) to the complete graph, so conveyance goes from being
  /// the ONLY delivery path to being unnecessary — which no existing experiment
  /// does: the line sweep has no third party to relay, and the diluting clique
  /// kept diameter 1, so only 0.06% of its arrivals came via a third party.
  ///
  /// **Interleaved, not blocked.** Each sweep visits every radius once in a
  /// seeded random order. The clique ran blocked — all trials at one N, then
  /// the next — and its condition became inseparable from chronology: a
  /// trace-completeness dropout mid-session could not be untangled from N
  /// afterwards. Interleaving makes every radius sample the whole session's
  /// battery, thermal and trace-health trajectory.
  ///
  /// **Uniform windows at every radius.** The dwell is also the drain
  /// ([FieldPlan.gapAfterSec] returns the dwell when links are not bounced), so
  /// every trial is the same length whatever r is. A window that varied with r
  /// would bake an r-dependent censoring bias into the design, because drain
  /// length is exactly what decides how much of the multi-hop tail is counted.
  ///
  /// **Sessions are never cleaned.** Not by the plan, not by any step. Under
  /// the gate a non-neighbour can never handshake, so one purge would make
  /// every later message to a non-neighbour fail at creation and the run would
  /// be dead from that point. [FieldPlan.ringSize] refuses to start a phone
  /// whose session table is not the size of the fleet, which is what a phone
  /// that has not been warmed up looks like.
  ///
  /// [perPair] is messages per ordered pair per trial; the device's total is
  /// `perPair * (n - 1)`, sent one at a time on rotation so each pair's share
  /// is spread evenly and no instant carries a burst.
  static FieldPlan ringSweep({
    String expId = 'ring',
    int n = 11,
    // Null means every radius from 1 to the ring's diameter, n ~/ 2. Past the
    // diameter every radius is the complete graph again, so a longer list
    // would spend trials measuring one topology under several names.
    List<int>? radii,
    int sweeps = 10,
    // 100 s against perPair 10 puts one message per ordered pair per 10 s —
    // exactly one ANNOUNCE/sync round, which is the mesh's own conveyance
    // quantum. A pair therefore offers the mesh one packet per opportunity to
    // move it, which is the natural rate for this experiment rather than a
    // number picked by feel.
    int dwellSec = 100,
    // Time allowed for delivery after sending stops.
    //
    // Conveyance advances at most ONE HOP per 10 s sync round, so diameter
    // five has an irreducible floor near 50 s before any queueing. On top of
    // that the sync sweep offers a peer one 106-id frame per round, so at
    // N=11 and r=1 the hundred packets a trial leaves on a ring edge need ten
    // rounds just to be offered once per hop, before any queueing behind
    // earlier trials. 300 s is a standing estimate, not a measurement: the
    // fleet run's own latency distribution is what should confirm or move it,
    // and cutting it on speculation would re-introduce exactly the censoring
    // the drain exists to prevent.
    int drainSec = 300,
    // Seconds of quiet before a widened trial, for the newly permitted links
    // to form in. It is exactly this long: a settle stage measures nothing and
    // so carries no drain.
    int settleSec = 90,
    int sendBytes = defaultSendBytes,
    int perPair = 10,
    int seed = 20260901,
    // The lattice windows. Left explicit rather than inherited: FieldPlan's
    // defaults (300/600) are sized for a field day where phones are carried to
    // positions, and on a desk they would add a quarter of an hour of standing
    // around to a twelve-minute run.
    int placementSec = 120,
    int alignSec = 300,
  }) {
    radii ??= [for (var r = 1; r <= n ~/ 2; r++) r];
    final steps = <FieldStep>[];
    final trialOf = <int, int>{for (final r in radii) r: 0};
    var settleNo = 0;
    for (var sweep = 0; sweep < sweeps; sweep++) {
      // A fresh draw per sweep, derived from the one seed so the whole fleet
      // agrees. The emitted step list IS the schedule, and it rides in the plan
      // JSON every phone loads, so the run is reconstructible from the trace.
      for (final r in _seededShuffle(radii, seed + sweep)) {
        final trial = (trialOf[r] = trialOf[r]! + 1);
        // Every trial opens on a mesh it built itself, inside a quiet stage
        // that precedes it.
        //
        // The stage BOUNCES THE LINKS and then waits, and both halves are
        // load bearing. Without the bounce a trial inherits whatever the
        // previous one left — its leg count, its stale addresses, its wear —
        // so two trials at one radius are a single trajectory sampled twice
        // rather than two draws, and a decay measured across them cannot be
        // told from the mesh simply ageing. Without the wait the rebuild
        // happens INSIDE the dwell, and the trial measures convergence
        // instead of the data plane it exists to measure.
        //
        // [settleSec] must cover three things in series: the dark window, the
        // reset budget, and convergence. Convergence from cold is about 20 s
        // to roughly ten legs at N=10, so the default leaves margin over that
        // sum rather than matching it — a reset that runs long otherwise
        // opens the dwell mid-rebuild, which is the failure the wait exists
        // to prevent.
        //
        // THE RISK THIS CARRIES: a bounced mesh has to find every permitted
        // pair again, and a pair that does not come back inside the window
        // silently shrinks the topology. At r=1 one missing edge turns the
        // ring into a path and the trial measures a shape nobody chose — a
        // 4-phone desk smoke lost exactly one permitted edge that way. The
        // settle-end leg count is what says whether it happened, and it has
        // to be read before any trial is trusted.
        //
        // Sessions are NOT touched: they are why a non-neighbour is
        // addressable at all, and one purge ends the run.
        //
        // The label carries NO `r=` token, so it opens its own segment for
        // inspection without being read as a ring trial, and it is numbered so
        // no two settle stages collapse into one segment.
        //
        // [FieldStep.settle] is what makes it exactly settleSec long: a stage
        // that aired nothing has no tail in flight, so it carries no drain.
        settleNo++;
        steps.add(FieldStep(
          label: 'settle $settleNo',
          dwellSec: settleSec,
          sendCount: 0,
          ringRadius: r,
          settle: true,
          resetLinks: true,
          autoAdvance: steps.isNotEmpty,
        ));
        steps.add(FieldStep(
          // `r=<radius> t<trial>` exactly, with no token before the `r`:
          // analyze.py splits labels on " r" for the power ladder's legacy
          // repeat convention, and its position regex would read a `d=` token
          // here as a line-sweep distance.
          label: 'r=$r t$trial',
          dwellSec: dwellSec,
          // Per DESTINATION, which is what the field has always meant: with
          // per-pair pacing each session gets its own timer firing this many
          // times across the dwell.
          sendCount: perPair,
          sendBytes: sendBytes,
          sendTo: 'all',
          perPairPacing: true,
          ringRadius: r,
          autoAdvance: steps.isNotEmpty,
        ));
      }
    }
    return FieldPlan(
      // The seed rides in the experiment id, so the schedule can be rebuilt
      // from the trace alone.
      expId: '$expId-$n-s$seed',
      steps: steps,
      manualJoin: true,
      // Sessions are never cleaned: they are the reason a non-neighbour is
      // addressable at all, and one purge ends the run.
      resetSessions: false,
      // Bouncing is a per-settle act, never a plan-wide one: the plan-level
      // flag fires at the start of EVERY step, which would tear the links
      // down at the top of each trial as well.
      resetLinks: false,
      // The bounce gets a reserved slot inside the settle rather than eating
      // into it. Both sides drop at the same lattice instant, so neither
      // holds a stale path the other has to wait out.
      linkResetDarkSec: 10,
      // The DTN buffer IS cleared, at the start of every stage, and that is a
      // deliberate reversal of what a store-carry-forward run wants.
      //
      // Without it a trial's stragglers keep being conveyed while the NEXT
      // trial runs, so every trial gets a bonus delivery window made of its
      // successors' time and the last trial gets none. The 4-phone smoke
      // measured that asymmetry directly: one trial had 301 s of recording
      // left after its final undelivered send and the closing trial had 60 s,
      // which is not a difference in the mesh, only in when the run happened
      // to stop. Delivery ratios across radii are the headline result here and
      // they cannot be compared on windows of different length.
      //
      // Clearing makes each trial's delivery its own verdict, decided inside
      // its own dwell plus drain. It is affordable precisely because the drain
      // is now sized for the conveyance tail rather than derived from the
      // dwell; what it discards is the residue that failed to arrive in a
      // window every trial gets equally. The seen-set goes with it, so the
      // sync sweep offers a fresh trial's packets without first re-walking
      // every id the previous trials left behind; sessions and links are
      // untouched, so a stage still starts warm.
      //
      // The cost, stated: originators buffer their confirmations too, so a
      // pending ACK is discarded with everything else and the acked column
      // reads slightly low. It reads low by the same rule in every trial.
      resetDtnBuffer: true,
      // Nothing severs. The gate's prune is the only teardown, and it removes
      // exactly what the new radius disallows — a narrowing needs no help and
      // a widening destroys nothing. severAllLinks remains available as an
      // operator primitive; this sweep simply has no use for it.
      severLinks: false,
      // The ring is whoever is in the room, not whoever a constant in this
      // file remembers: the session table cannot name an absent phone, and it
      // decides the topology AND the send targets, so no compiled roster is
      // carried at all.
      //
      // The plan still declares how many phones it was built for, because
      // that is the one thing the room cannot say and it is the launch guard's
      // only local assertion — the radii and the per-pair counts were chosen
      // for exactly n. No [FieldPlan.minSessionsToLaunch] sits beside it: a
      // session floor says strictly less than the size check does, and two
      // numbers for one fleet are two numbers that can disagree.
      ringRosterFromSessions: true,
      ringSize: n,
      resetBudgetSec: 30,
      drainSec: drainSec,
      traceEveryAdvertisement: true,
      placementSec: placementSec,
      alignSec: alignSec,
    );
  }

  /// The desk-sized ring smoke: [n] phones, two radii, ~30 minutes.
  ///
  /// The two radii are the ring (r=1) and the complete graph (the diameter,
  /// n ~/ 2), which is the contrast that proves the gate. Four is the floor,
  /// and a geometric one rather than a preference: on a 3-ring every pair sits
  /// at ring distance 1, so r=1 is already the complete graph and no message
  /// can ever require a relay. On the 4-ring at r=1 the two opposite pairs are
  /// two hops apart, so their messages MUST be conveyed.
  ///
  /// The drain is longer than the sweep's, not shorter, because the load is
  /// ten times higher: the tail is what this run measures, and a drain that
  /// cuts it off would report slow mail as lost mail.
  static FieldPlan ringSmoke({String expId = 'ring-smoke', int n = 10}) =>
      ringSweep(
        expId: expId,
        n: n,
        // The ring and the complete graph: r=1 and the diameter.
        radii: [1, n ~/ 2],
        sweeps: 2,
        // Same one-message-per-pair-per-sync-round cadence as the sweep, so
        // the smoke measures the tail at the load the sweep will actually run.
        dwellSec: 100,
        // Ten times the sweep's cadence: one message per ordered pair per
        // SECOND rather than per sync round. The sweep's rate offers the mesh
        // one packet per opportunity to move it, which measures the mechanism
        // at rest; this measures it under queueing, where the ask window has to
        // keep up with a seen-set growing ten times faster. That is the regime
        // the prefix frame's floor is shallowest in — a filter holds one
        // filter's worth of ids however fast they arrive, so at this rate the
        // floor is seconds deep instead of a minute, and whatever the forward
        // sweep is worth shows up here or nowhere.
        drainSec: 300,
        perPair: 100,
        settleSec: 90,
        // Desk-sized: everyone is standing at the same table, so placement
        // only has to cover reaching the handsets.
        placementSec: 60,
        // What a tap spread may be and still land on one anchor is
        // `alignSec - placementSec`, so these two were equal and the
        // guarantee was zero — every launch relied on the taps happening to
        // fall inside one bucket. Ten handsets take appreciably longer to
        // work through than four, and a phone that lands on the next anchor
        // starts a whole alignment period late, which at these radii is a
        // trial it spends outside the ring the others formed.
        alignSec: 180,
      );

  /// [ringSmoke] under a numbered experiment id, so the run is one dropdown
  /// tap on each phone and nothing has to be typed at a handset.
  ///
  /// It carries NO roster, and this file holds no pubkeys at all. A compiled
  /// roster would be dead twice over here — the derived ring decides both the
  /// topology and the send targets, so nothing reads one — and it would still
  /// ride into the plan JSON and every trace, naming a fleet that is not
  /// necessarily the one running. A list of handsets kept in source goes stale
  /// the first time a phone leaves the desk or an uninstall changes its key,
  /// and that silent staleness is the whole reason the ring derives itself
  /// from the session table.
  ///
  /// **Bump [ringSmokeRun] before every run.** The collector refuses a reused
  /// experiment id by suffixing it, which splits one fleet's uploads across
  /// file names and breaks run discovery — and a reused id that merges instead
  /// silently pools two runs' records under one name, which for this preset
  /// would mix loads that differ by more than a factor of ten.
  static const ringSmokeRun = 7;

  static FieldPlan ringSmokeDesk({int n = 10}) =>
      ringSmoke(expId: 'ring-smoke$ringSmokeRun', n: n);

  /// The dropdown entry for [mtuCheck].
  static const String mtuCheckPresetName =
      'MTU check (every phone present, desk — both legs of every pair, ~11m)';

  /// **Bump before every run.** Same collector rule as [ringSmokeRun]: a
  /// reused experiment id is either suffixed, splitting one fleet's uploads
  /// across file names, or merged, pooling two runs under one name.
  static const int mtuCheckRun = 2;

  /// Does every leg of a converged pair know the ATT MTU its link actually
  /// negotiated?
  ///
  /// A pair converges by attaching its second GATT leg to the ACL that is
  /// already up, so both legs share one ATT bearer and one MTU, exchanged
  /// once by whichever side reaches it first. The leg that did NOT do the
  /// exchange gets no report of its own — its GATT server has nothing to fire
  /// a callback about — and a leg left believing the 23-byte ATT default, or
  /// a floor inferred from the largest packet that happened to arrive,
  /// refuses every data-sized frame while the link reports healthy.
  ///
  /// The run is establishment, repeated: every step bounces the links on every
  /// phone at the same lattice instant, so each step is an independent
  /// convergence of every pair, and an independent chance for any leg to
  /// settle on the wrong number.
  ///
  /// It is rosterless, so it sizes itself to the room: every phone addresses
  /// every peer it holds a session with. Pairs go up with the square of the
  /// fleet and legs at twice that, which is the whole reason to run it on more
  /// than two handsets — a fault that shows on a few percent of legs is a coin
  /// flip over one pair's handful and unmissable over a fleet's.
  /// [sendBytes] sits deliberately above an ANNOUNCE, because an ANNOUNCE is
  /// the largest thing that reaches a peripheral leg once control traffic is
  /// the only thing written to it — a leg whose belief comes from what it
  /// receives can never learn more than that by itself, so only a payload
  /// bigger than one separates a correct leg from a self-limiting one.
  ///
  /// **How to read it**, per (device, path, role):
  /// - Every `link` record carries that leg's `mtu`, at every stage. Both
  ///   roles of a pair must report the same negotiated value. One role at 517
  ///   and the other at 23 or ~185 is the failure, whatever the run's
  ///   delivery numbers look like.
  /// - `oversized`, `mtuPending` and `mtuTooSmall` must all be absent. They
  ///   are the same fault seen from the send path: a frame refused by a leg
  ///   that underestimates itself, and the pair's other leg rescuing it.
  static FieldPlan mtuCheck({
    String? expId,
    int runs = 8,
    // Long enough for every pair to converge dual-role inside the dwell after
    // a fleet-wide simultaneous bounce: reverse-leg discovery alone is several
    // seconds per pair, and they contend. A leg that never reaches `connected`
    // reports nothing about its MTU, so a dwell too short to converge does not
    // measure a smaller sample — it measures none.
    int dwellSec = 60,
    int sendBytes = 200,
    int sendCount = 30,
  }) {
    return FieldPlan(
      expId: expId ?? 'mtu-check$mtuCheckRun',
      // Links bounce every step; SESSIONS do not. An MTU is negotiated while
      // a link comes up, which is a GATT-layer event with nothing to do with
      // Noise, so purging the session table buys this test nothing and costs
      // it twice: no phone can send until its handshakes complete, so the
      // early part of every dwell carries no data — and data is the whole
      // discriminator, since an ANNOUNCE alone never proves a leg carries
      // more than an ANNOUNCE. It also leaves the fleet cold for whatever
      // runs next.
      resetSessions: false,
      resetLinks: true,
      resetDtnBuffer: true,
      traceEveryAdvertisement: true,
      manualJoin: true,
      // Desk-sized: both phones are already on the table, and the alignment
      // window only has to cover launching two of them by hand.
      placementSec: 20,
      alignSec: 60,
      linkResetDarkSec: 10,
      // Wider than the other desk presets'. This run is ABOUT establishment,
      // and one Nexus 5X in the fleet has a 15.1 s mode on about a fifth of
      // its link resets; a budget that cuts a bounce short opens the step
      // late into its own dwell, which is the part being measured.
      resetBudgetSec: 25,
      steps: [
        for (var t = 1; t <= runs; t++)
          FieldStep(
            label: 'mtu t$t',
            dwellSec: dwellSec,
            sendCount: sendCount,
            sendBytes: sendBytes,
            autoAdvance: t > 1,
          ),
      ],
    );
  }

  static const bleThroughputSenderPresetName =
      'BLE throughput — SENDER (2 phones, ~62m)';
  static const bleThroughputReceiverPresetName =
      'BLE throughput — RECEIVER (2 phones, ~62m)';
  static const bleThroughputHighSenderPresetName =
      'BLE throughput HIGH interval — SENDER (~22m)';
  static const bleThroughputHighReceiverPresetName =
      'BLE throughput HIGH interval — RECEIVER (~22m)';

  /// The three throughput arms, as step labels. Order is fixed; the SWEEP
  /// shuffles which arm runs first within each pass.
  ///
  /// A is the measurement: 138 B is exactly one sealed packet
  /// (`FragmentHandler.fragmentThreshold`), so a message is one write and the
  /// rate is the pipe's. B asks whether a converged pair's second leg is a
  /// second pipe or only a source of write-busy refusals. C is what a
  /// multi-packet message really costs — and its ceiling is
  /// `FragmentHandler.fragmentDelay`, a constant of ours, not the radio's.
  static const List<(int, int)> _throughputArms = [
    (138, 1),
    (138, 2),
    (1380, 1),
  ];

  /// One directed BLE throughput run: how many bytes per second one warm link
  /// between two phones actually carries through this stack.
  ///
  /// Nothing in the dataset measures a saturated link — every line-sweep step
  /// ran at the offered rate and delivered all of it — so the simulator's link
  /// capacity is a calculation from a path-loss fit and an assumed noise
  /// floor, unchecked in the direction that flatters flooding. This measures
  /// the ceiling that calculation stands in for.
  ///
  /// [saturating] false builds the RECEIVER's copy: identical labels and
  /// timing so the two phones' segments line up on the server, but no sends.
  /// A step's sends otherwise target every known peer, so a receiver that ran
  /// the sender's plan would push back down the link being measured.
  ///
  /// Sessions and links stay warm — this measures the data plane, not
  /// establishment — but the DTN buffer is cleared every step: a write refused
  /// in one step is otherwise conveyed by a sync round inside the next and
  /// counted there.
  ///
  /// The arms are INTERLEAVED across [sweeps] passes in a seeded random order,
  /// for the same reason the ring sweep interleaves: thermal drift over half
  /// an hour would otherwise land entirely on whichever arm ran last.
  static FieldPlan bleThroughput({
    String expId = 'ble-tp-1',
    bool saturating = true,
    int sweeps = 10,
    int dwellSec = 60,
    // As long as the dwell. A saturating step leaves far more in flight than a
    // paced one, and what has not been acknowledged when the dwell closes is
    // still moving: a short drain would count it as loss and charge the link
    // for the analyser's impatience.
    int drainSec = 60,
    bool? connectionPriorityHigh,
    // Which of [_throughputArms] to run. The connection-interval launch runs
    // arm A alone: the lever is a property of the link, so one arm measures
    // it, and three would triple a run whose only comparison is against A.
    List<int> arms = const [0, 1, 2],
    int seed = 20260906,
  }) {
    final steps = <FieldStep>[];
    final trialOf = <int, int>{for (final a in arms) a: 0};
    for (var sweep = 0; sweep < sweeps; sweep++) {
      final order = _seededShuffle(arms, seed + sweep);
      for (final arm in order) {
        final (bytes, lanes) = _throughputArms[arm];
        final trial = (trialOf[arm] = trialOf[arm]! + 1);
        steps.add(FieldStep(
          label: 'p=${bytes}B lanes=$lanes'
              '${connectionPriorityHigh == true ? ' prio=high' : ''} t$trial',
          dwellSec: dwellSec,
          sendBytes: bytes,
          saturate: saturating,
          sendLanes: lanes,
          // Cleared every step; links and sessions are not touched.
          resetDtnBuffer: true,
          autoAdvance: steps.isNotEmpty,
        ));
      }
    }
    return FieldPlan(
      expId: expId,
      steps: steps,
      resetSessions: false,
      resetLinks: false,
      resetDtnBuffer: true,
      connectionPriorityHigh: connectionPriorityHigh,
      manualJoin: true,
      // The deliverable includes advertisement RSSI per step, and a
      // rate-limited sample would report the limiter rather than the link.
      traceEveryAdvertisement: true,
      // A desk run: both phones are already where they will stay.
      placementSec: 60,
      alignSec: 60,
      drainSec: drainSec,
    );
  }

  static const bleOneWaySenderPresetName =
      'BLE one-way ceiling — SENDER (2 phones, ~33m)';
  static const bleOneWayReceiverPresetName =
      'BLE one-way ceiling — RECEIVER (2 phones, ~33m)';

  /// Payload sweep for the one-way ceiling, in 138 B fragments: 10, 30, 100,
  /// 200, 400. It starts where the duplex run's goodput was still climbing
  /// and goes until it stops or delivery does.
  static const List<int> _oneWayPayloads = [1380, 4140, 13800, 27600, 55200];

  /// The ONE-WAY goodput ceiling: what one link carries when nothing comes
  /// back and nothing else is on the air.
  ///
  /// The duplex run found 23.6 kB/s at 13.8 kB messages with the fragment
  /// spacing off, and goodput was still rising at the largest payload — so
  /// that run never bracketed the ceiling. It also measured a link carrying
  /// an acknowledgement back for every message, which is a packet on the same
  /// radio: a duplex measurement reported as capacity.
  ///
  /// Here the receiver takes delivery and says nothing ([FieldPlan.suppressAcks]),
  /// so the only measure is the RECEIVER's own arrival records. The sender's
  /// flow record will read zero acked — by construction, not by failure, and
  /// anyone reading `delivery_rate` from the sender will see zero. Read the
  /// receiver.
  ///
  /// Spacing is off throughout: the duplex run showed it pins goodput near
  /// 4.2 kB/s at every size, so a paced arm here would only re-measure it.
  static FieldPlan bleOneWayCeiling({
    String expId = 'ble-oneway-1',
    bool saturating = true,
    int sweeps = 4,
    int dwellSec = 60,
    int drainSec = 30,
    int seed = 20260907,
  }) {
    final steps = <FieldStep>[];
    final trialOf = <int, int>{for (var i = 0; i < _oneWayPayloads.length; i++) i: 0};
    for (var sweep = 0; sweep < sweeps; sweep++) {
      for (final i in _seededShuffle(
          [for (var i = 0; i < _oneWayPayloads.length; i++) i], seed + sweep)) {
        final bytes = _oneWayPayloads[i];
        final trial = (trialOf[i] = trialOf[i]! + 1);
        steps.add(FieldStep(
          label: 'p=${bytes}B lanes=1 pace=0 oneway t$trial',
          dwellSec: dwellSec,
          sendBytes: bytes,
          saturate: saturating,
          sendLanes: 1,
          fragmentDelayMs: 0,
          resetDtnBuffer: true,
          autoAdvance: steps.isNotEmpty,
        ));
      }
    }
    return FieldPlan(
      expId: expId,
      steps: steps,
      resetSessions: false,
      resetLinks: false,
      resetDtnBuffer: true,
      suppressAcks: true,
      // The whole point of this run: the radio carries payload and nothing
      // else. Without it the buffer, not the link, is what gets measured.
      quietLink: true,
      manualJoin: true,
      traceEveryAdvertisement: true,
      placementSec: 60,
      alignSec: 120,
      drainSec: drainSec,
    );
  }

  static const bleCeilingSenderPresetName =
      'BLE goodput ceiling — SENDER (2 phones, ~83m)';
  static const bleCeilingReceiverPresetName =
      'BLE goodput ceiling — RECEIVER (2 phones, ~83m)';

  /// Payload sizes for the ceiling hunt, in fragments of 138 B: one, ten,
  /// thirty, a hundred. Larger messages amortise the per-message send path
  /// over more writes, which is the only lever left once the spacing is off
  /// and lanes are known not to help.
  static const List<int> _ceilingPayloads = [138, 1380, 4140, 13800];

  /// The goodput CEILING: how many payload bytes per second one warm link
  /// carries when nothing of ours is pacing it.
  ///
  /// The arms above measured 3.8 kB/s at one packet per message and 4.2 kB/s
  /// at ten — but the ten-fragment arm spent 180 ms of every message in
  /// [FragmentHandler.fragmentDelay], so what it measured was our own spacing.
  /// The spacing was introduced when a write was fire-and-forget and could
  /// outrun the radio's buffer; the send path now awaits each write's
  /// acknowledgement and the plugin holds one GATT op per path, and an hour of
  /// saturating traffic produced a single write-busy refusal. So the spacing
  /// is very likely dead weight, and this run is what decides it.
  ///
  /// Every payload runs twice: once with the spacing off and once with it at
  /// its production value, so the difference is measured under the same
  /// conditions rather than against a previous run. Lanes stay at one — two
  /// carried no more than one and produced one refusal in an hour, so the
  /// lane sweep has nothing left to find.
  ///
  /// DELIVERY IS THE GUARD. A fragmented message needs every fragment, so a
  /// payload that starts losing them is the ceiling announcing itself. Read
  /// `delivery_rate` before reading any rate: the first payload where it
  /// falls below 1.0 is the answer, and the rates above it are not capacity.
  static FieldPlan bleGoodputCeiling({
    String expId = 'ble-ceil-1',
    bool saturating = true,
    int sweeps = 5,
    int dwellSec = 60,
    int drainSec = 60,
    int seed = 20260906,
  }) {
    // (payload, pacing off?) — the control rides beside its own arm.
    final arms = <(int, bool)>[
      for (final p in _ceilingPayloads) ...[(p, true), (p, false)],
    ];
    final steps = <FieldStep>[];
    final trialOf = <int, int>{for (var i = 0; i < arms.length; i++) i: 0};
    for (var sweep = 0; sweep < sweeps; sweep++) {
      for (final i in _seededShuffle(
          [for (var i = 0; i < arms.length; i++) i], seed + sweep)) {
        final (bytes, unpaced) = arms[i];
        final trial = (trialOf[i] = trialOf[i]! + 1);
        steps.add(FieldStep(
          label: 'p=${bytes}B lanes=1 '
              '${unpaced ? 'pace=0' : 'pace=20'} t$trial',
          dwellSec: dwellSec,
          sendBytes: bytes,
          saturate: saturating,
          sendLanes: 1,
          fragmentDelayMs: unpaced ? 0 : null,
          resetDtnBuffer: true,
          autoAdvance: steps.isNotEmpty,
        ));
      }
    }
    return FieldPlan(
      expId: expId,
      steps: steps,
      resetSessions: false,
      resetLinks: false,
      resetDtnBuffer: true,
      manualJoin: true,
      traceEveryAdvertisement: true,
      placementSec: 60,
      // Twice the tap tolerance of the throughput plans. At 60 s two phones
      // must tap inside one wall-clock minute, and a smoke run was lost to a
      // pair of taps either side of a boundary.
      alignSec: 120,
      drainSec: drainSec,
    );
  }

  static Map<String, FieldPlan> get presets => {
        lineSweepPresetName: lineSweepUpTo(),
        'Diluting clique at the line load N=2..7 (~1h)': dilutingLineLoads(),
        dilutingSaturatingPresetName: dilutingSaturating(),
        linkChurnPresetName: linkChurn(),
        dilutingSmokePresetName: dilutingSmoke(),
        advertisementCapturePresetName:
            advertisementCapture(expId: 'adv-capture-3', dwellSec: 60),
        homeMatchPresetName: homeMatch(),
        ringSweepPresetName: ringSweep(),
        ringSmokePresetName: ringSmokeDesk(),
        mtuCheckPresetName: mtuCheck(),
        bleThroughputSenderPresetName: bleThroughput(),
        bleThroughputReceiverPresetName:
            bleThroughput(saturating: false),
        bleThroughputHighSenderPresetName: bleThroughput(
            expId: 'ble-tp-hi-1', arms: const [0], connectionPriorityHigh: true),
        bleOneWaySenderPresetName: bleOneWayCeiling(),
        bleOneWayReceiverPresetName: bleOneWayCeiling(saturating: false),
        bleCeilingSenderPresetName: bleGoodputCeiling(),
        bleCeilingReceiverPresetName: bleGoodputCeiling(saturating: false),
        bleThroughputHighReceiverPresetName: bleThroughput(
            expId: 'ble-tp-hi-1',
            arms: const [0],
            saturating: false,
            connectionPriorityHigh: true),
      };
}
