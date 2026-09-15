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
  }) {
    final steps = <FieldStep>[];
    for (final n in const [2, 3, 4, 5, 6, 7]) {
      for (var t = 1; t <= reps; t++) {
        steps.add(FieldStep(
          label: 'N=$n L=moderate t$t',
          dwellSec: sendSec,
          cliqueN: n,
          sendTo: 'all',
          sendBytes: sendBytes,
          sendCount: sendCount,
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

  /// Name of the ring sweep in the dropdown. The roster is empty in the preset
  /// (this file holds no pubkeys), so the operator pastes the plan JSON with
  /// the fleet's roster filled in — the ring needs identities, and hardcoding
  /// them here would break the rosterless rule the rest of this file keeps.
  static const ringSweepPresetName = 'Ring-radius sweep r=1..5 (~4.5h)';
  static const ringSmokePresetName = 'Ring-radius desk smoke (4 phones, ~18m)';

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
  /// be dead from that point. [FieldPlan.minSessionsToLaunch] refuses to start
  /// a phone that has not been warmed up.
  ///
  /// [perPair] is messages per ordered pair per trial; the device's total is
  /// `perPair * (n - 1)`, sent one at a time on rotation so each pair's share
  /// is spread evenly and no instant carries a burst.
  static FieldPlan ringSweep({
    String expId = 'ring',
    int n = 11,
    List<int> radii = const [1, 2, 3, 4, 5],
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
    // five has an irreducible floor near 50 s before any queueing. The 4-phone
    // smoke measured the rest of the tail at diameter two — p90 113 s — but
    // did so at ten times this load, where queueing dominated; most of that
    // should fall away here. 180 s is roughly 3.5x the hop floor and is a
    // standing estimate, not a measurement: the fleet run's own latency
    // distribution is what should confirm or move it, and cutting it further
    // on speculation would re-introduce exactly the censoring this replaced.
    int drainSec = 180,
    // Seconds of quiet before a widened trial, for the newly permitted links
    // to form in. It is exactly this long: a settle stage measures nothing and
    // so carries no drain.
    int settleSec = 60,
    int sendBytes = defaultSendBytes,
    int perPair = 10,
    int seed = 20260901,
    // The lattice windows. Left explicit rather than inherited: FieldPlan's
    // defaults (300/600) are sized for a field day where phones are carried to
    // positions, and on a desk they would add a quarter of an hour of standing
    // around to a twelve-minute run.
    int placementSec = 120,
    int alignSec = 300,
    List<WorkloadRosterEntry> roster = const [],
  }) {
    final steps = <FieldStep>[];
    final trialOf = <int, int>{for (final r in radii) r: 0};
    var settleNo = 0;
    // The radius the previous step left in force. Null means unconstrained,
    // which is what warm-up leaves behind: every pair linked. Arming any
    // radius against that is a TIGHTENING, so the first trial needs no settle.
    int? prevRadius;
    for (var sweep = 0; sweep < sweeps; sweep++) {
      // A fresh draw per sweep, derived from the one seed so the whole fleet
      // agrees. The emitted step list IS the schedule, and it rides in the plan
      // JSON every phone loads, so the run is reconstructible from the trace.
      for (final r in _seededShuffle(radii, seed + sweep)) {
        final trial = (trialOf[r] = trialOf[r]! + 1);
        // A quiet stage inserted ONLY where the radius WIDENS, because that is
        // the only direction that has to build anything.
        //
        // Nothing severs links here. Narrowing is already handled the moment
        // the radius lands: the gate's prune tears down exactly the links the
        // new radius disallows and leaves the rest of the topology standing,
        // warm and already converged. Widening tears down nothing — it only
        // grants permission — so the newly allowed pairs must find each other,
        // and that is what this window pays for.
        //
        // An earlier revision severed every link at every stage, to make each
        // trial start from an identical cold state so link age could not
        // co-vary with the direction the radius moved. That uniformity is real
        // but it is bought by destroying a working mesh twice a trial and
        // rebuilding it under time pressure, and the first desk smoke showed
        // what that costs: one permitted edge (366dca50<->44a266c4) never came
        // back inside the window, so two of four nodes held one neighbour
        // instead of two and the trial measured a path rather than a ring.
        // Disturbing less is worth more here than starting identically.
        //
        // The label carries NO `r=` token, so it opens its own segment for
        // inspection without being read as a ring trial, and it is numbered so
        // no two settle stages collapse into one segment.
        //
        // [FieldStep.settle] is what makes it exactly settleSec long: a stage
        // that aired nothing has no tail in flight, so it carries no drain.
        if (prevRadius != null && r > prevRadius) {
          settleNo++;
          steps.add(FieldStep(
            label: 'settle $settleNo',
            dwellSec: settleSec,
            sendCount: 0,
            ringRadius: r,
            settle: true,
            autoAdvance: steps.isNotEmpty,
          ));
        }
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
        prevRadius = r;
      }
    }
    return FieldPlan(
      // The seed rides in the experiment id, so the schedule can be rebuilt
      // from the trace alone.
      expId: '$expId-$n-s$seed',
      steps: steps,
      roster: roster,
      manualJoin: true,
      // Sessions are never cleaned: they are the reason a non-neighbour is
      // addressable at all, and one purge ends the run.
      resetSessions: false,
      resetLinks: false,
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
      // window every trial gets equally. Sessions, links and the seen-set are
      // untouched, so a stage still starts warm and dedup still holds.
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
      minSessionsToLaunch: n - 1,
      resetBudgetSec: 30,
      drainSec: drainSec,
      traceEveryAdvertisement: true,
      placementSec: placementSec,
      alignSec: alignSec,
    );
  }

  /// The desk-sized ring smoke: four phones, two radii, ~12 minutes.
  ///
  /// Four and not three, which is a geometric requirement rather than a
  /// preference: on a 3-ring every pair sits at ring distance 1, so r=1 is
  /// already the complete graph and no message can ever require a relay. On the
  /// 4-ring at r=1 the two opposite pairs are two hops apart, so their messages
  /// MUST be conveyed — and r=2 makes the same graph complete, which is the
  /// contrast that proves the gate.
  ///
  /// Both the dwell and the drain shorten together (they are the same number),
  /// per the rule that a tuned window is tuned at every stage or not at all.
  static FieldPlan ringSmoke({
    String expId = 'ring-smoke',
    List<WorkloadRosterEntry> roster = const [],
  }) =>
      ringSweep(
        expId: expId,
        n: 4,
        radii: const [1, 2],
        sweeps: 2,
        // Same one-message-per-pair-per-sync-round cadence as the sweep, so
        // the smoke measures the tail at the load the sweep will actually run.
        dwellSec: 100,
        // Diameter two needs less than the sweep's five.
        drainSec: 120,
        perPair: 10,
        settleSec: 60,
        // Desk-sized: everyone is standing at the same table, so the windows
        // only have to cover launching four phones by hand.
        placementSec: 60,
        alignSec: 60,
        roster: roster,
      );

  /// The desk fleet's ring roster, for [ringSmokeDesk].
  ///
  /// This file otherwise holds NO pubkeys, and that rule is worth keeping: a
  /// plan is portable and a roster is hardware. The ring is the one shape that
  /// cannot be rosterless — a node derives its own ring position by finding
  /// itself among sorted pubkeys, so without identities there is no topology at
  /// all — and the alternative is pasting plan JSON into the runner's text
  /// field over adb, which has wedged a phone before (braces and quotes need
  /// escaping and a half-entered plan is unrecoverable).
  ///
  /// Verified against each handset's Settings > You > FINGERPRINT on
  /// 2026-09-01; `tools/fleet_map.json` agreed on all four. (`fleet_map.md` did
  /// NOT — it carries a stale identity for 00de4b24, which is what an
  /// uninstall does to a key. Trust the json.)
  ///
  /// Ring order is the sort, so at r=1 the conveyance pairs — the ones two hops
  /// apart, whose messages MUST be relayed — are 07e47335<->366dca50 and
  /// 18130c0f<->44a266c4.
  static const deskRingRoster = [
    // 00de4b24f89021e4, Nexus 5X, nickname 2
    WorkloadRosterEntry(
        label: 'n5x-00de4b',
        pubkeyHex:
            '07e473354009ebe81b22b1c6a79606c8d653558a865c4941c98e4befbfda546c'),
    // 00f8380a3668adb1, Nexus 5X, nickname 4
    WorkloadRosterEntry(
        label: 'n5x-00f838',
        pubkeyHex:
            '18130c0f5a36449cc5c1d5e0c17e83ba4d248625655035b08e971693fb29ae40'),
    // 55281FDCH002QK, Pixel 10 Pro, nickname 5
    WorkloadRosterEntry(
        label: 'pixel-552816',
        pubkeyHex:
            '366dca50d82e71c72a32c234baa7c97b05252841e55f8445ef6f52525d13bbf9'),
    // 0253914a45ebaeb0, Nexus 5X, nickname 3
    WorkloadRosterEntry(
        label: 'n5x-025391',
        pubkeyHex:
            '44a266c4c9912ec34ea7934fbbffae1745ab82df0229f8972440ae3f43862fa4'),
  ];

  /// [ringSmoke] with the desk fleet's roster already in it, so the run is one
  /// dropdown tap on each phone and no pubkey has to be typed at a handset.
  /// [ringSmoke] with the desk fleet's roster already in it, so the run is one
  /// dropdown tap on each phone and no pubkey has to be typed at a handset.
  ///
  /// **Bump [ringSmokeRun] before every run.** The collector refuses a reused
  /// experiment id by suffixing it, which splits one fleet's uploads across
  /// file names and breaks run discovery — and a reused id that merges instead
  /// silently pools two runs' records under one name, which for this preset
  /// would mix loads that differ by more than a factor of ten.
  static const ringSmokeRun = 3;

  static FieldPlan ringSmokeDesk() =>
      ringSmoke(expId: 'ring-smoke$ringSmokeRun', roster: deskRingRoster);

  static Map<String, FieldPlan> get presets => {
        lineSweepPresetName: lineSweepUpTo(),
        'Diluting clique at the line load N=2..7 (~1h)': dilutingLineLoads(),
        dilutingSmokePresetName: dilutingSmoke(),
        advertisementCapturePresetName:
            advertisementCapture(expId: 'adv-capture-3', dwellSec: 60),
        homeMatchPresetName: homeMatch(),
        ringSweepPresetName: ringSweep(),
        ringSmokePresetName: ringSmokeDesk(),
      };
}
