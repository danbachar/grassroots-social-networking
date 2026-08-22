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

  /// Throughput: saturate the link for [dwellSec] on [sendLanes] concurrent
  /// send lanes, none of them ACK-gated. Sessions/links stay warm (this
  /// measures the data plane, not establishment).
  ///
  /// [payloadSizes] is the PAYLOAD ARM: one saturating step per size, so the
  /// per-message cost of fragmentation is a measured result instead of a
  /// hidden constant. [defaultSendBytes] (138 B) is exactly one sealed packet;
  /// 264 B is two and 1200 B is nine, so the arm walks the fragment boundary
  /// and then well past it. Every step runs from the same spot,
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
      // Longer than usual: an overrun leaves a backlog of buffered messages
      // and ACKs
      // still draining when the dwell ends, and cutting the recording there
      // would score those sends as lost when they were merely late.
      settleSec: 90,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      steps: steps,
    );
  }

  /// RAW link throughput: MTU-sized unsealed blobs pushed as fast as the
  /// send path drains, one step per GATT leg — notify (our peripheral leg),
  /// write (our central leg), stripe (alternate blobs across both). No seal,
  /// no ACK, no buffering: this measures the naked GATT pipe, and the gap to
  /// the protocol numbers is the measured cost of the stack. The receiver
  /// counts bytes in its wire ledger and drops the blobs before the parser.
  /// `+4` / `-4` / `0` — a signed tag for a step label.
  static String _signed(int v) => v > 0 ? '+$v' : '$v';

  static FieldPlan rawLink({
    String expId = 'raw-link-1',
    int dwellSec = 30,
    List<String> legs = const ['notify', 'write', 'stripe'],
    // Byte offsets from the ATT ceiling (`MTU - 3`) to write at. The default
    // single 0 is the plain throughput run: write exactly at the ceiling.
    // A multi-value sweep turns the plan into the ATT-ceiling probe — the
    // measurement the fragment budget's 8-byte margin has never had.
    List<int> sizeDeltas = const [0],
    int repeat = 1,
    bool resetSessions = false,
    // Default ON, unlike every other warm-link plan: the plugin's per-path
    // GATT op queue is unbounded and the Dart send future completes at
    // ENQUEUE, so a blast step leaves megabytes still draining on air after
    // its dwell ends — raw-link-1 measured a step receiving 39 KB/s while
    // sending nothing new. No app-level reset can touch that queue; only a
    // link teardown discards it. The bounce costs ~35 s/step and buys step
    // independence.
    bool resetLinks = true,
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    final arms = legs.isEmpty ? const ['notify'] : legs;
    final deltas = sizeDeltas.isEmpty ? const [0] : sizeDeltas;
    final steps = <FieldStep>[];
    for (final leg in arms) {
      for (final delta in deltas) {
        for (var i = 1; i <= trials; i++) {
          // The delta belongs in the label as well as the step, because the
          // label is what the analysis segments on and what the operator
          // reads on the phone mid-run.
          final tag = delta == 0 ? 'leg=$leg' : 'leg=$leg d=${_signed(delta)}';
          steps.add(FieldStep(
            label: trials > 1 ? '$tag t$i' : tag,
            dwellSec: dwellSec,
            rawLeg: leg,
            rawSizeDelta: delta,
            autoAdvance: steps.isNotEmpty,
          ));
        }
      }
    }
    return FieldPlan(
      expId: expId,
      // Nothing is in flight after the dwell at the APP layer (no ACKs, no
      // buffered), but the OS queue may still be draining: the settle window
      // plus the next step's link bounce absorb it.
      settleSec: 15,
      resetSessions: resetSessions,
      resetLinks: resetLinks,
      resetDtnBuffer: false,
      steps: steps,
    );
  }

  /// POWER BASELINE: screen-constant desk ladder isolating the BLE stack's
  /// standing and active cost. Both phones run the SAME labels on
  /// complementary roles, so each 10-min segment is a condition on both:
  ///
  ///   base   — BLE down on both          (screen + app + sampling floor)
  ///   solo   — role-1 up alone           (advertise+scan, no peer)
  ///   solo2  — role-2 up alone
  ///   linked — both up, session, silent  (connection + ANNOUNCE upkeep)
  ///   light  — role-1 sends paced        (~1 msg/s marginal cost)
  ///   light2 — role-2 sends paced
  ///   heavy  — role-1 saturates, 1 sender (active ceiling: radio + seal CPU)
  ///   heavy2 — role-2 saturates
  ///
  /// One tap starts it; every later step auto-advances and the runner toggles
  /// BLE itself ([FieldStep.bleOn]). Repeats interleave the ladder so battery
  /// and thermal drift average out instead of biasing one condition. Run
  /// UNPLUGGED at fixed minimum brightness; deltas between conditions are the
  /// result, absolute draw is screen-dominated.
  /// DIAGNOSTIC. Bounces BLE off and back on at increasing down-times to
  /// find where the bring-up stops working.
  ///
  /// Exists because a 2h power ladder was recorded against a radio that never
  /// returned after its first `bleOn: false`, while the 60s pre-check bounced
  /// the same code path fine. The only obvious difference was how long BLE
  /// stayed down, and nothing tested that. Each `down` step holds the radio
  /// off for a different span; each `up` step turns it back on and dwells
  /// 60s — long enough for the runner's dead-radio watchdog to fire, so a
  /// failure aborts the run and names the step instead of being inferred from
  /// silence hours later.
  ///
  /// Run on BOTH phones simultaneously (they need each other to move bytes).
  /// ~22 minutes. A clean pass clears BLE bouncing; an abort gives the
  /// threshold directly.
  static FieldPlan bounceStress({
    String expId = 'bounce-1',
    List<int> downSec = const [60, 120, 300, 600],
    int upSec = 60,
  }) {
    final steps = <FieldStep>[];
    for (final down in downSec) {
      steps.add(FieldStep(
        label: 'down=${down}s',
        dwellSec: down,
        bleOn: false,
        autoAdvance: steps.isNotEmpty,
      ));
      steps.add(FieldStep(
        label: 'up after ${down}s',
        dwellSec: upSec,
        bleOn: true,
        autoAdvance: true,
      ));
    }
    return FieldPlan(
      expId: expId,
      settleSec: 15,
      resetSessions: false,
      resetLinks: false,
      // The app-level toggle is the subject here, so the runner works it.
      scriptedRadio: true,
      steps: steps,
    );
  }

  /// A REAL discharge curve: hold one condition until the battery reaches the
  /// floor where Android's battery saver engages (default 15%).
  ///
  /// The ladder measures a rate and the battery-life figures extrapolate it
  /// as a straight line. That extrapolation is sound in the middle of a
  /// Li-ion curve — the ladder's own 96->66% trajectory is linear to within
  /// 2 percentage points — but it runs straight through the bottom knee,
  /// where voltage sags and draw is no longer constant. This measures that
  /// region instead of assuming it.
  ///
  /// Stops at [floorPct] rather than at empty on purpose: below the saver
  /// threshold the OS throttles CPU and radio, so the system under
  /// measurement is no longer the one being characterised.
  ///
  /// The saturating variant is the efficient one — [condition] `heavy` has
  /// P1 sending while P2 receives, so ONE run yields two different real
  /// curves at once. Run on both phones with matching roles.
  ///
  /// [dwellSec] is deliberately longer than any battery can last; the run
  /// ends on state of charge (ExperimentRecorder.onBatteryFloor), never on
  /// the clock.
  static FieldPlan dischargeRun({
    String expId = 'discharge-1',
    required int role, // 1 or 2 — which phone this plan runs on
    String condition = 'heavy', // base | linked | light | heavy
    int dwellSec = 20 * 3600,
    int sendCount = 20000,
  }) {
    final one = role == 1;
    final step = switch (condition) {
      'base' => FieldStep(label: 'discharge base', dwellSec: dwellSec, bleOn: false),
      'linked' => FieldStep(label: 'discharge linked', dwellSec: dwellSec, bleOn: true),
      'light' => FieldStep(
          label: 'discharge light',
          dwellSec: dwellSec,
          bleOn: true,
          sendCount: one ? sendCount : 0),
      _ => FieldStep(
          label: 'discharge heavy',
          dwellSec: dwellSec,
          bleOn: true,
          saturate: one),
    };
    return FieldPlan(
      expId: expId,
      settleSec: 30,
      resetSessions: false,
      resetLinks: false,
      // Hours of unattended discharge: the condition's radio state is the
      // plan's to hold, not something to ask a human for.
      scriptedRadio: true,
      steps: [step],
    );
  }

  static FieldPlan powerBaseline({
    String expId = 'pw-base-1',
    required int role, // 1 or 2 — which phone this plan runs on
    int dwellSec = 600,
    int reps = 2,
    int lightSends = 600,
    int settleSec = 30,
    /// Which conditions to run, in canonical order regardless of the order
    /// given. Null runs the full ladder; a subset is how the screen-off
    /// pre-check stays short while exercising the SAME code path as the real
    /// run (BLE toggling, step advance, sends) rather than a separate toy
    /// plan that could pass while the real one fails.
    List<String>? conditions,
  }) {
    final r = reps < 1 ? 1 : reps;
    final one = role == 1;
    final want = conditions?.toSet();
    // Canonical order. Each entry configures the one FieldStep it owns; the
    // role decides who is radio-up during solo and who sends under load, so
    // both phones stamp identical labels for the same wall-clock condition.
    final ladder = <String, FieldStep Function(String label)>{
      'base': (l) => FieldStep(label: l, dwellSec: dwellSec, bleOn: false),
      'solo': (l) => FieldStep(label: l, dwellSec: dwellSec, bleOn: one),
      'solo2': (l) => FieldStep(label: l, dwellSec: dwellSec, bleOn: !one),
      'linked': (l) => FieldStep(label: l, dwellSec: dwellSec, bleOn: true),
      'light': (l) => FieldStep(
          label: l, dwellSec: dwellSec, sendCount: one ? lightSends : 0),
      'light2': (l) => FieldStep(
          label: l, dwellSec: dwellSec, sendCount: one ? 0 : lightSends),
      'heavy': (l) => FieldStep(label: l, dwellSec: dwellSec, saturate: one),
      'heavy2': (l) => FieldStep(label: l, dwellSec: dwellSec, saturate: !one),
    };

    final steps = <FieldStep>[];
    for (var i = 1; i <= r; i++) {
      final suffix = r > 1 ? ' r$i' : '';
      for (final entry in ladder.entries) {
        if (want != null && !want.contains(entry.key)) continue;
        final step = entry.value('${entry.key}$suffix');
        // Only the very first step of the whole plan waits for the tap.
        steps.add(FieldStep(
          label: step.label,
          dwellSec: step.dwellSec,
          sendCount: step.sendCount,
          saturate: step.saturate,
          bleOn: step.bleOn,
          autoAdvance: steps.isNotEmpty,
        ));
      }
    }
    return FieldPlan(
      expId: expId,
      settleSec: settleSec,
      resetSessions: false,
      resetLinks: false,
      // Each rung IS a radio condition, so the runner sets it and the ladder
      // runs hands-free.
      scriptedRadio: true,
      steps: steps,
    );
  }

  /// TIER 2 — the dilating clique: mesh PERFORMANCE as membership grows.
  /// The mesh gains one phone per block (the operator turns its Bluetooth on
  /// at the prompt); every phone that is up saturates throughout, and each
  /// size holds for [repeat] stable reps before the next phone joins.
  ///
  /// Deliberately NO toggling inside a block: a flapping neighbour makes the
  /// standing phones spend their airtime on discovery, connection and
  /// handshakes instead of carrying load, so churn and throughput would
  /// contaminate each other. Join/establishment behaviour is the SEPARATE
  /// [joinTime] run — split by design.
  static FieldPlan meshScale({
    String expId = 'mesh-scale-1',
    required int role,
    int maxDevices = 8,
    int dwellSec = 120,
    int sends = 60,
    int repeat = 10,
    bool saturate = true,
    // ONE lane, from the ceiling sweep: 1 lane delivered 29.5 and 26.6 msg/s
    // at 100%/97% while 4 lanes delivered 20.0 and 15.1 — extra lanes only
    // deepened the queue on a single link, and in an 8-phone shared medium
    // they multiply RF contention for negative return. One lane is also
    // closed-loop: each phone self-paces to what the mesh around it actually
    // drains, which is the sustainable-load curve, not an overload artifact.
    int sendLanes = 1,
    int placementSec = 300,
    int alignSec = 600,
  }) {
    final top = maxDevices < 3 ? 3 : maxDevices;
    final trials = repeat < 1 ? 1 : repeat;
    final steps = <FieldStep>[];
    for (var n = 3; n <= top; n++) {
      final joined = role <= n;
      for (var t = 1; t <= trials; t++) {
        steps.add(FieldStep(
          label: trials > 1 ? 'n=$n t$t' : 'n=$n',
          dwellSec: dwellSec,
          saturate: joined && saturate,
          sendLanes: sendLanes,
          sendCount: (joined && !saturate) ? sends : 0,
          bleOn: joined,
          autoAdvance: steps.isNotEmpty,
        ));
      }
    }
    return FieldPlan(
      expId: expId,
      settleSec: 60, // relayed paths deliver later than direct ones
      autoAdvanceGapSec: 30,
      resetSessions: false,
      resetLinks: false,
      // Buffer persistence across steps is part of what is measured: a
      // packet held while the mesh was too sparse may deliver once density
      // rises, and clearing between steps would erase exactly that effect.
      resetDtnBuffer: false,
      manualJoin: true,
      // The population is the variable: each step's bleOn decides who is in
      // the mesh, so the runner works every radio.
      scriptedRadio: true,
      placementSec: placementSec,
      alignSec: alignSec,
      steps: steps,
    );
  }

  /// TIER 2 — session ESTABLISHMENT as membership grows: the frontier run.
  /// The mesh grows one phone per block, and within each block the newest
  /// phone — the frontier — cycles system Bluetooth off/on [repeat] times:
  /// that many COLD joins per (N, spacing), each re-running discovery,
  /// connection and the XX handshakes (sessions are dropped while its radio
  /// is down). When its block ends it anneals into the topology and the next
  /// phone becomes the frontier.
  ///
  /// The standing mesh stays QUIET — no saturating workload — because this
  /// run measures link formation, and formation under load belongs to a
  /// different experiment than formation itself. The performance question is
  /// the separate [meshScale] run; the split is deliberate. The joiner sends
  /// a handful of messages per rep so the `usable` stage is exercised.
  ///
  /// Establishment is measured by the joining phone alone (bt-on ->
  /// per-peer session), so no cross-device clock is involved.
  static FieldPlan joinTime({
    String expId = 'join-time-1',
    required int role,
    int maxDevices = 8,
    int joinDwellSec = 60,
    int offDwellSec = 15,
    int repeat = 5,
    int gapSec = 20,
    int placementSec = 60,
    int alignSec = 120,
  }) {
    final top = maxDevices < 4 ? 4 : maxDevices;
    final trials = repeat < 1 ? 1 : repeat;
    final steps = <FieldStep>[];
    for (var k = 4; k <= top; k++) {
      for (var t = 1; t <= trials; t++) {
        if (role == k) {
          steps.add(FieldStep(
            label: 'off n=$k t$t',
            dwellSec: offDwellSec,
            bleOn: false,
            // Reset while DARK, so the next join is cold — never at the
            // join step, which would kill handshakes that legitimately
            // began in the toggle window.
            resetSessions: true,
          ));
          steps.add(FieldStep(
            label: 'n=$k t$t',
            dwellSec: joinDwellSec,
            bleOn: true,
            sendCount: 5,
          ));
        } else {
          steps.add(FieldStep(
            label: 'n=$k t$t',
            dwellSec: offDwellSec + gapSec + joinDwellSec,
            bleOn: role < k || role <= 3,
          ));
        }
      }
    }
    return FieldPlan(
      expId: expId,
      settleSec: 30,
      autoAdvanceGapSec: gapSec,
      resetSessions: false,
      // Leftover sends would otherwise drain into the next rep's window via
      // the sync exchange and blur its usable stage.
      resetDtnBuffer: true,
      manualJoin: true,
      // A join is exactly a radio coming up on schedule; the runner owns it.
      scriptedRadio: true,
      placementSec: placementSec,
      alignSec: alignSec,
      steps: steps,
    );
  }

  /// TIER 3 — store-carry-forward under load, on a desk.
  ///
  /// One phone is the TRAVELLER: its radio goes down, everyone else keeps
  /// messaging it, and then it comes back. What is measured is what survives
  /// the absence — how much of the backlog is delivered on reunion and how
  /// long each message was carried. Nothing here needs distance, so it runs on
  /// a desk: the variable is OFFERED LOAD, not geometry.
  ///
  /// Three arms, run back to back:
  ///   low     — a trickle; the buffer holds tens of packets
  ///   medium  — steady traffic
  ///   high    — saturate, ONE lane, one sealed packet per message, which is
  ///             the shape mesh-scale-30m-2 ran under and what makes a desk
  ///             result comparable to it. The payload tracks the header, so
  ///             what stays fixed across runs is the packet on the wire —
  ///             which is what contention actually sees.
  ///
  /// Each arm is three steps. `warm` lets sessions form (SEALING NEEDS A
  /// SESSION — a recipient never paired with is held unsealed and is a
  /// different measurement). `dark` drops the traveller's radio while the
  /// senders push. `return` brings it back and sends NOTHING, so every
  /// delivery in that window came out of a buffer rather than off the wire.
  ///
  /// The DTN buffer is deliberately NOT reset between the steps of an arm —
  /// carrying the backlog across the dark step IS the experiment — but it is
  /// reset at each arm's `warm` step so one arm's leftovers cannot be counted
  /// as the next arm's delivery.
  /// [travellerPrefix] concentrates the load on the absent phone. Leave it
  /// empty and the senders address EVERYONE, which is both easier to set up
  /// (no pubkey to type on six phones) and closer to the field day: every
  /// phone messaging every other, with one member away. The absent peer's
  /// share is the part that has to be carried, and it is identified in the
  /// trace by recipient, not by how the load was aimed.
  static FieldPlan storeCarryForward({
    String expId = 'scf-desk-1',
    required int role,
    String travellerPrefix = '',
    int warmSec = 60,
    int darkSec = 120,
    int returnSec = 120,
    int lowSends = 10,
    int mediumSends = 60,
    int repeat = 1,
  }) {
    final traveller = role == 1;
    final steps = <FieldStep>[];
    final trials = repeat < 1 ? 1 : repeat;
    for (final arm in const ['low', 'medium', 'high']) {
      for (var t = 1; t <= trials; t++) {
        final tag = trials > 1 ? '$arm t$t' : arm;
        steps.add(FieldStep(
          label: 'warm $tag',
          dwellSec: warmSec,
          bleOn: true,
          // Clear the buffer where it is safe to: the arm's first step, before
          // anything it will measure has been sent. The plan-level flag cannot
          // express this (it fires on every step, which would wipe the backlog
          // at `return`), so without this an arm inherits the previous arm's
          // undelivered packets and scores them as its own deliveries.
          // Sessions and links are untouched, so the arm still starts warm.
          resetDtnBuffer: true,
          autoAdvance: steps.isNotEmpty,
        ));
        steps.add(FieldStep(
          label: 'dark $tag',
          dwellSec: darkSec,
          // The traveller is unreachable; everyone else keeps sending TO it,
          // addressed by prefix so the load lands on the absent peer rather
          // than being shared out among the phones that are present.
          bleOn: traveller ? false : true,
          sendTo: (traveller || travellerPrefix.isEmpty)
              ? 'all'
              : travellerPrefix,
          saturate: !traveller && arm == 'high',
          sendLanes: 1,
          sendCount: traveller
              ? 0
              : switch (arm) {
                  'low' => lowSends,
                  'medium' => mediumSends,
                  _ => 0,
                },
          autoAdvance: true,
        ));
        steps.add(FieldStep(
          label: 'return $tag',
          dwellSec: returnSec,
          bleOn: true,
          // Nobody sends: every delivery inside this window came from a
          // buffer, which is the whole measurement.
          autoAdvance: true,
        ));
      }
    }
    // A trailing DISCARDED step, so the last arm is measured on the same
    // terms as the others. What closes an arm's delivery window is the buffer
    // reset at the NEXT warm step, and without this the last arm would have no
    // following warm: its window would run to the `end` marker and on into the
    // settle — a longer drain under quieter air for the arm carrying the
    // heaviest load. Same shape, same reset; its label is excluded from the
    // per-arm tables.
    steps.add(FieldStep(
      label: 'drain',
      dwellSec: warmSec,
      bleOn: true,
      resetDtnBuffer: true,
      autoAdvance: true,
    ));
    return FieldPlan(
      expId: expId,
      settleSec: 60,
      autoAdvanceGapSec: 10,
      resetSessions: false,
      resetLinks: false,
      resetDtnBuffer: false,
      // Wall-clock anchored so every phone opens the dark window at the same
      // instant — a stagger would let a sender push while the traveller was
      // still up, and those messages would deliver instead of being carried.
      // A 5-minute grid is enough to tap six phones without a second pair of
      // hands, and `scriptedRadio` keeps the toggling with the runner: nobody
      // is standing over the desk to work the radio at the boundary.
      manualJoin: true,
      alignSec: 300,
      placementSec: 60,
      scriptedRadio: true,
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
  static FieldPlan dilutingWarmupSweep({
    String expId = 'dilute-5-warmup-quiet-drain',
    int reps = 10,
    int sendSec = 30,
    int quietSec = 30,
    int warmupSec = 30,
    int firstWarmupSec = 60,
    double nominalSatPerDest = 20.0,
  }) {
    const levels = [
      ('light', 0.10),
      ('medium', 0.50),
      ('heavy', 1.0), // heavy = saturate
    ];
    final steps = <FieldStep>[];
    for (final n in const [2, 3, 4, 5, 6, 7]) {
      // Warm-up: the joining device's radio just came on; no sends while the
      // clique converges. First join (N=2) gets longer — both radios are new.
      steps.add(FieldStep(
        label: 'N=$n settle',
        dwellSec: n == 2 ? firstWarmupSec : warmupSec,
        cliqueN: n,
        sendCount: 0,
        autoAdvance: steps.isNotEmpty,
      ));
      for (final (name, frac) in levels) {
        final heavy = name == 'heavy';
        final count = (frac * nominalSatPerDest * sendSec).round();
        for (var t = 1; t <= reps; t++) {
          steps.add(FieldStep(
            label: 'N=$n L=$name t$t',
            dwellSec: sendSec,
            cliqueN: n,
            sendTo: 'all',
            saturate: heavy,
            sendLanes: 1,
            sendCount: heavy ? 0 : count,
            autoAdvance: true,
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
      resetDtnBuffer: false,
      manualJoin: true,
      alignSec: 300,
      placementSec: 120,
      scriptedRadio: true,
      steps: steps,
    );
  }

  /// DIAL GRID: how many central legs does a phone actually establish per
  /// window, as a function of how many dials it is allowed to have in
  /// flight and how crowded the room is?
  ///
  /// Two independent variables:
  ///
  ///   N — the POPULATION: how many phones have their radio up. Scripted
  ///       through [FieldStep.cliqueN], exactly like the diluting sweep, so
  ///       the runner derives this phone's radio schedule from its own
  ///       nickname (on iff `joinOrder <= cliqueN`) and every phone loads
  ///       the identical plan.
  ///   M — the DIAL CAP: the most central dials a phone may have IN FLIGHT
  ///       at once, M = 1..N-1 (it cannot dial itself). Set through
  ///       [FieldStep.maxParallelDials].
  ///
  /// M IS A CAP ON ORDINARY BEHAVIOUR, NOT A SCRIPTED BURST. The transport
  /// already dials every peer it discovers and already tops up as slots free
  /// — the step only moves the bound it enforces
  /// (`BleTransportService.maxInFlightCentralDials`, 7 in production) and
  /// counts what the ordinary dial path establishes. That is the whole
  /// redesign: the previous version fired a one-shot burst of M dials from a
  /// rotating device-under-test and had to EXEMPT itself from the cap and
  /// the failed-dial cooldown to do it, which measured a mechanism no
  /// production dial ever takes. Here nothing is exempt, every phone is
  /// measured at once (no DUT rotation), and the answer is a rate —
  /// establishments per window — rather than the fate of one hand-picked
  /// sweep.
  ///
  /// Per population N = 2..[maxPop], the radios for join orders 1..N come up
  /// and the plan holds a CONVERGE step — no cap, [convergeSec] (or
  /// [firstConvergeSec] at N=2, where the first pair forms from nothing) —
  /// so every pair reaches dual-leg with a negotiated MTU and a Noise
  /// session BEFORE anything is measured. That step is the fix for the
  /// deadlock that killed the first run: identity needs ANNOUNCE, ANNOUNCE
  /// needs a workable MTU, and MTU 247 is requested by a CENTRAL — so a
  /// fleet where nobody dials first sits at the 23-byte default forever and
  /// cannot even put a packet header on the air.
  ///
  /// Then, for every M, [reps] repeat steps at [dwellSec]. Each begins with
  /// the plan's per-step BLE bounce ([FieldPlan.resetLinks]): every enabled
  /// device disposes its transport, stays dark for
  /// [FieldPlan.linkResetDarkSec], and comes back up, so the window opens
  /// with nothing established and the count is a clean per-window rate. The
  /// dark gap is SHORT here (~5 s against the ~30 s default) and that is
  /// sound precisely because every device bounces simultaneously at the step
  /// boundary: both sides of every pair dispose together, so no stale path
  /// survives on either side and there is nothing to wait out. The default
  /// gap exists for the one-sided case, where the peer has to notice the
  /// link died on its own.
  ///
  /// ROLE-FREE: every phone loads this identical plan and the nickname is
  /// the only per-device input. Every establishment is attributable without
  /// any offline inference — the transport stamps `inFlight` (dials still
  /// underway), `maxParallel` (M) and `popN` (N) onto each central
  /// `connected` link record, and the runner logs one `dialcell` record per
  /// step with the window's establishment count.
  ///
  /// Sessions and the buffer are never reset; only the links are, and that
  /// IS the measurement's reset.
  ///
  /// sum(N=2..8) of (N-1) = 28 cells x [reps]=1 = 28 measured steps at
  /// (120 s dwell + 5 s dark + 5 s gap), plus 7 converge steps ~= 1.3 h.
  /// [reps] is the knob to raise for the measured campaign; the cell count
  /// and step labels scale with it.
  static FieldPlan dialGridProbe({
    String expId = 'dial-3-cap-greedy-establish',
    // ONE rep: this is a correctness shakedown of the grid, not the measured
    // campaign. Raise it once the traces are confirmed to carry inFlight /
    // maxParallel / popN on every establishment.
    int reps = 1,
    int dwellSec = 120,
    int convergeSec = 60,
    int firstConvergeSec = 90,
    int maxPop = 8,
    int darkSec = 5,
  }) {
    final trials = reps < 1 ? 1 : reps;
    final steps = <FieldStep>[];
    for (var n = 2; n <= maxPop; n++) {
      // The joining device's radio just came up; run uncapped while the
      // population converges to dual-leg + MTU + sessions.
      steps.add(FieldStep(
        label: 'N=$n converge',
        dwellSec: n == 2 ? firstConvergeSec : convergeSec,
        cliqueN: n,
        sendCount: 0,
        autoAdvance: steps.isNotEmpty,
      ));
      for (var m = 1; m <= n - 1; m++) {
        for (var t = 1; t <= trials; t++) {
          steps.add(FieldStep(
            label: 'N=$n M=$m t$t',
            dwellSec: dwellSec,
            cliqueN: n,
            maxParallelDials: m,
            autoAdvance: true,
          ));
        }
      }
    }
    return FieldPlan(
      expId: expId,
      settleSec: 60,
      autoAdvanceGapSec: 5,
      resetSessions: false,
      // The step's own reset: everyone goes dark together, so each window
      // starts from zero established legs and its count is a rate.
      resetLinks: true,
      linkResetDarkSec: darkSec,
      resetDtnBuffer: false,
      manualJoin: true,
      alignSec: 300,
      placementSec: 120,
      // The population IS a variable here, so the radios are scripted: each
      // phone's own nickname decides when it joins.
      scriptedRadio: true,
      steps: steps,
    );
  }

  /// SESSION CHURN: five short windows, each starting from no sessions and no
  /// links.
  ///
  /// Built to answer one question quickly — does a pair form a Noise session
  /// and move a message — after a change to the transport. Five windows rather
  /// than one because the failure it is aimed at is per-connection: a
  /// peripheral leg that misses its MTU exchange is dead for that link's whole
  /// life, so a single window either hits the case or says nothing about it.
  /// Clearing the links as well as the sessions is what makes each window an
  /// independent draw: sessions alone would re-handshake over legs that were
  /// already proven good in window one.
  ///
  /// [sendCount] messages per window make the result end-to-end. A session
  /// that establishes but cannot carry a payload is not a working pair, and
  /// delivery is the only evidence that separates the two.
  ///
  /// ~3 minutes including settle. Run it on every phone that should be in the
  /// clique; nothing is scripted, so the radios stay up throughout.
  static FieldPlan sessionChurn({
    String expId = 'session-churn-1',
    int windows = 5,
    int dwellSec = 30,
    int sendCount = 10,
    int darkSec = 3,
  }) {
    return FieldPlan(
      expId: expId,
      settleSec: 15,
      autoAdvanceGapSec: 5,
      resetSessions: true,
      resetLinks: true,
      linkResetDarkSec: darkSec,
      resetDtnBuffer: true,
      steps: [
        for (var w = 1; w <= windows; w++)
          FieldStep(
            label: 'churn w$w',
            dwellSec: dwellSec,
            sendCount: sendCount,
            autoAdvance: w > 1,
          ),
      ],
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
    int trials = 3,
    String? receiverPrefix,
  }) {
    final step = stepMetres < 1 ? 1 : stepMetres;
    final distances = <int>[
      for (var d = startDistance; d <= maxDistance; d += step) d,
    ];
    // Thesis line design: 100 messages per trial (1000 a distance at x10,
    // the July load), and the operator resets the whole Bluetooth stack at
    // every position during the walk — each distance's trials run on a
    // stack that carries nothing over from the previous one.
    // One-way when a receiver prefix is given, exactly the July design: the
    // phone whose pubkey matches receives, every other phone sends 100 a
    // trial toward it, and the receiver itself matches no target and sends
    // nothing. Blank keeps both phones sending.
    final base = lineSweep(
      distances: distances.isEmpty ? [startDistance] : distances,
      trials: trials,
      sendCount: 100,
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

  /// Named presets for the dropdown (label → ready-to-run plan).
  static Map<String, FieldPlan> get presets => {
        // Two entries because the traveller runs a different script from
        // everyone else; picking the right one IS the per-phone setup, which
        // is what makes this launchable from the dropdown with no typing.
        // 10 reps per arm. One rep per arm is a single draw from a spread
        // that the power ladder already showed is where the uncertainty
        // lives; ten gives a distribution instead of an anecdote. Windows
        // stay fixed at 60/120/120 s so every arm gets the same wall-clock
        // exposure and the arms differ ONLY in offered load. ~2h45m.
        // A one-rep shakedown of the SAME plan shape, under its own id: ~17
        // min to prove the traveller really goes dark and comes back, the
        // backlog moves, and the analysis reads it — before committing 2h45m.
        // Its own id keeps the check out of the measured data.
        // Shakedown on the full fleet, under its own id so it can never
        // merge into the measured run. Three things to read off it:
        // `sync/staleOffer` collapses, carried deliveries report a non-zero
        // hop count now that conveyance pays TTL, and `message re-delivery`
        // is zero under age-only dedup.
        //
        // A FRESH id each attempt, because the recorder APPENDS: re-using one
        // merges two runs into a single file and a single upload. -1 is
        // recorded (3 phones, and only one of them recorded anything useful);
        // -2 was launched and killed ~16 s after its anchor when the presets
        // turned out to be stamping the plan ROLE as the join order; -3 is
        // recorded on all 8 and is what the TTL-attribution and drain-step
        // changes came out of. Nothing here is comparable with -1: that run
        // had the per-neighbour relay cap in the build and this one has no
        // cap at all.
        //
        // -6 is a straight repeat of -5 — same plan, no flood, offers are
        // id lists — on a rebooted six-phone fleet, this time with the build
        // that drops a discovered address the moment a central dial fails.
        // The question it answers is narrow: is the GATT exhaustion storm
        // gone, or was the dead address only part of it?
        //
        // -7 changes three things at once, so it gets its own id: the fleet
        // runs CLOSED (friends-only, ghost excluded by the scan filter), the
        // build offers direct-recipient packets before the relay backlog
        // (buildSyncOffers/carriedPacketIdsFor), and node 4 is a degraded unit
        // whose GATT discovery wedges — so the 4<->6 edge is absent and node 4
        // may contribute little. Read: does closed-mode SCF still deliver via
        // the hub with one node down and no ghost in the trace.
        // -11 is ARM C with the filter advertising what a node has SEEN, not
        // what it still HOLDS. -10 (age-bounded seen set) balanced the load and
        // lifted delivery 1%->6%, but redundancy stayed ~12.76x: a held-filter
        // re-pushes the backlog to a node that already delivered and dropped a
        // message ("I hold nothing, send everything"). -11 advertises the seen
        // set instead ("do not resend me these"), so a responder conveys only
        // what the peer has never seen. Read redundancy against -10 (should
        // fall toward ~1) and offer airtime against -7 (the saving should hold;
        // the seen filter is larger than the held one but still windowed).
        // -12 is ARM C again — same GCS seen-set filter as -11 — with the
        // direct-deliver fast path added: a message to a peer we are connected
        // to now goes out on the raw leg the moment it is sealed, without
        // waiting for that peer's next sync offer. -11 proved the seen filter
        // drops redundancy toward 1x; the open question -12 answers is whether
        // firing directly on connect lifts delivery (which -11 left load-bound)
        // without bringing redundancy back up — the fast-path copy and the
        // later sync copy must dedup on the receiver's packetId bloom, not
        // double-count. Read delivery against -11 (should rise) and redundancy
        // against -11 (should stay ~1x).
        'SCF re-arm check — TRAVELLER (1 rep, ~17 min)':
            storeCarryForward(expId: 'scf-rearm-12-direct-deliver-connected', role: 1),
        'SCF re-arm check — sender (1 rep, ~17 min)':
            storeCarryForward(expId: 'scf-rearm-12-direct-deliver-connected', role: 2),
        // Unified per-N warmup + quiet ACK-drain sweep (desk or field), one
        // SHARED entry for every phone: the join order is the nickname, and
        // the runner derives each phone's schedule from it at launch. Radios
        // off at start; each turns on at its join. N=2..7, 3 levels, 10 reps.
        'Warmup sweep N=2..7 (shared plan, ~3h20)': dilutingWarmupSweep(),
        // ONE shared entry for the whole fleet: the population lives in the
        // steps' cliqueN (resolved from the nickname at launch) and M in
        // their maxParallelDials, which every phone applies identically —
        // there is no per-role entry to pick wrongly.
        // EIGHT phones, nicknamed 1..8: the nickname IS the join order, so the
        // fleet has to carry every slot up to maxPop. maxPop MUST match the
        // phones actually present — a plan asking for N=11 with eight radios
        // silently relabels an eight-phone population as eleven.
        // Eleven nicknamed slots: 4x Nexus 5X, Galaxy S10e, Huawei, Pixel 2,
        // Pixel 10 Pro, then the three wireless-adb phones (Pixel 7a, Galaxy
        // A72, Galaxy Note20) — those three keep Wi-Fi ON, since it is their
        // only link, so the run prep must not switch it off for them.
        // Two reps per cell, so a per-cell figure carries a spread rather
        // than one sample.
        // A FRESH id per population: the recorder APPENDS, so re-using an id
        // would merge two different populations into one analysis.
        // 55 cells x 2 reps = 110 measured x 120 s + (90 + 9x60) converge +
        // 120 x (5 s dark + 5 s gap) + (60 settle + 300 align + 120 placement)
        // = 15510 s ~= 4.3 h.
        'Dial grid N x M (11 phones, 2 reps, ~4.3h)':
            dialGridProbe(expId: 'dial-8-n11', maxPop: 11, reps: 2),
        // A FRESH id per campaign: the recorder appends, so reusing an id
        // merges runs into one file and one upload.
        'SCF desk — TRAVELLER (this phone goes dark)':
            storeCarryForward(expId: 'scf-desk-2', role: 1, repeat: 10),
        'SCF desk — sender (everyone else)':
            storeCarryForward(expId: 'scf-desk-2', role: 2, repeat: 10),
        // Wall-clock anchored: both phones compute the same step start
        // times from their synced clocks, so the pair advances in lockstep
        // with no taps. Each distance opens on an alignment boundary, which
        // is the window the operator walks one device to the next position
        // in. The placement window covers the initial walk out to 120 m.
        // Reach and repeat count are the two things a sweep is planned
        // around -- how far the site allows, and how long the daylight does.
        // The testbed picks them; this entry is what the defaults look like.
        lineSweepPresetName: lineSweepUpTo(),
        // Ten one-minute windows for reset-recovery measurement: the harness
        // kills the OS Bluetooth stack in each window's dark gap, and the
        // question is how fast the service is back and established from a
        // genuinely cold controller.
        'Session churn RESET (10 x 60s, ~11 min)': manualized(sessionChurn(
            expId: 'reset-min-1', windows: 10, dwellSec: 60)),
        // 1000 messages per phone per run: the establishment windows double
        // as a load test, and delivery under churn is measured against real
        // traffic rather than a trickle. 84 x 12 = 1008 sends a run.
        'Session churn LONG (12 x 30s, ~8 min)': manualized(sessionChurn(
            expId: 'churn-long-1', windows: 12, sendCount: 84)),
        'Session churn (5 x 30s, sessions reset, ~3 min)':
            manualized(sessionChurn()),
        'Home soak (stationary, 40 min)': manualized(homeSoak()),
        'Link-cycle check (5×1 min)': manualized(cycleCheck()),
        'Throughput (saturate 60s)': manualized(throughput()),
        'Throughput: payload arm (138/264/1200 B)': manualized(throughput(
            expId: 'throughput-arm-1',
            payloadSizes: const [defaultSendBytes, 264, 1200])),
        'Throughput: ceiling sweep (1/4/16/64 lanes)': manualized(throughputCeiling()),
        'Raw link throughput (notify/write/stripe)': manualized(rawLink()),
        // Prices the fragment budget's 8-byte margin, which has never been
        // measured. Each step writes a raw blob at `MTU - 3 + d` on ONE leg
        // and the receiver records the length that arrived, so the three
        // outcomes separate: arrives whole, arrives short (the stack
        // truncated it), never arrives (the stack refused it). d=0 is the
        // ceiling, d=-8 is where the fragment budget sits today, and d=+1 is
        // the first byte that should not survive. Notify only — it is the leg
        // floods actually use, and one leg keeps the sweep to ~2.5 min.
        'Raw link: ATT ceiling probe (−8/−4/0/+1/+4 B)': manualized(rawLink(
          expId: 'att-ceiling-1',
          legs: const ['notify'],
          sizeDeltas: const [-8, -4, 0, 1, 4],
        )),
        // Full ladder, ~2h41. Every quantity taken on BOTH devices.
        'Power baseline P1 (full, ~2h41)': manualized(powerBaseline(role: 1)),
        'Power baseline P2 (full, ~2h41)': manualized(powerBaseline(role: 2)),
        // ~1h36. Same 8 conditions, shorter steps, 3 reps instead of 2 —
        // between-rep spread is the dominant uncertainty (it ran to 20mA on
        // the same condition), and two reps give a difference rather than a
        // variance you can trust. Halves the readings per rep to buy that.
        'Power baseline P1 (short, ~1h36)':
            manualized(powerBaseline(
                role: 1, dwellSec: 240, reps: 3, lightSends: 240)),
        'Power baseline P2 (short, ~1h36)':
            manualized(powerBaseline(
                role: 2, dwellSec: 240, reps: 3, lightSends: 240)),
        // ~1h00. Drops the mirrored conditions: each quantity is then
        // measured on ONE device only (send cost on P1, receive cost on P2,
        // discovery cost on P1 alone), so within-device role comparisons are
        // gone. Take it only if wall-clock is the binding constraint.
        'Power baseline P1 (minimal, ~1h00)': manualized(powerBaseline(
            role: 1,
            dwellSec: 240,
            reps: 3,
            lightSends: 240,
            conditions: const ['base', 'solo', 'linked', 'light', 'heavy'])),
        'Power baseline P2 (minimal, ~1h00)': manualized(powerBaseline(
            role: 2,
            dwellSec: 240,
            reps: 3,
            lightSends: 240,
            conditions: const ['base', 'solo', 'linked', 'light', 'heavy'])),
        // Screen-off smoke test: the same ladder code, three conditions, one
        // rep, 60s each — the ladder's own segment granularity, so a segment
        // that behaves here behaves the same way in the long run. Proves
        // timers still tick, BLE still toggles and sends still fire with the
        // display off, before committing to the long run.
        'Power PRE-CHECK P1 (~3.5 min, screen off)': manualized(powerBaseline(
            expId: 'pw-pre',
            role: 1,
            dwellSec: 60,
            reps: 1,
            settleSec: 10,
            lightSends: 60,
            conditions: const ['base', 'linked', 'light'])),
        'Power PRE-CHECK P2 (~3.5 min, screen off)': manualized(powerBaseline(
            expId: 'pw-pre',
            role: 2,
            dwellSec: 60,
            reps: 1,
            settleSec: 10,
            lightSends: 60,
            conditions: const ['base', 'linked', 'light'])),
        // Real discharge curves, ending at the 15% battery-saver floor.
        // The saturating pair yields the sending AND receiving curve at once.
        'Discharge P1 (saturating sender, ~4-5h)':
            manualized(dischargeRun(role: 1, condition: 'heavy')),
        'Discharge P2 (saturating receiver, ~5-6h)':
            manualized(dischargeRun(role: 2, condition: 'heavy')),
        'Discharge P1 (link idle, ~11h)': manualized(
            dischargeRun(expId: 'discharge-linked', role: 1, condition: 'linked')),
        'Discharge P2 (link idle, ~11h)': manualized(
            dischargeRun(expId: 'discharge-linked', role: 2, condition: 'linked')),
        'BLE bounce stress (~22 min, DIAGNOSTIC)': bounceStress(),
        // Pre-flight for a field day, on 4 phones at a table (~7 min
        // including the wall-clock wait): the exact manual-join flow of the
        // real run — typed-id wizard aside — with its own experiment id so a
        // rehearsal never lands in a real run's file. Aligns to 2 minutes
        // instead of 10, because waiting most of ten minutes for a
        // five-minute test means the preflight never gets run.
        for (var r = 1; r <= 4; r++)
          'PREFLIGHT 4 devices, manual join (~7 min) — this phone is #$r':
              meshScale(
            expId: 'mesh-preflight',
            role: r,
            maxDevices: 4,
            dwellSec: 45,
            repeat: 2,
            placementSec: 60,
            alignSec: 120,
          ),
      };
}

/// The experiment shapes the wizard can build.
enum FieldPlanKind {
  meshScale,
  joinTime,
  storeCarryForward,
  homeSoak,
  throughput,
  throughputCeiling,
  rawLink,
  powerBaseline,
}

extension FieldPlanKindLabel on FieldPlanKind {
  String get label => switch (this) {
        FieldPlanKind.meshScale => 'Mesh: scale N devices (all send)',
        FieldPlanKind.joinTime => 'Establishment: frontier join (quiet mesh)',
        FieldPlanKind.storeCarryForward =>
          'Store-carry-forward vs load (desk)',
        FieldPlanKind.homeSoak => 'Home soak (stationary)',
        FieldPlanKind.throughput => 'Throughput (saturate)',
        FieldPlanKind.throughputCeiling => 'Throughput: ceiling sweep',
        FieldPlanKind.rawLink => 'Raw link throughput (GATT pipe)',
        FieldPlanKind.powerBaseline => 'Power baseline (desk, unplugged)',
      };
}

/// Wizard answers → a [FieldPlan]. Kept pure and separate from the dialog UI
/// so it is unit-testable.
class FieldPlanWizard {
  /// Kind-appropriate defaults for the wizard's reset toggles.
  static (bool sessions, bool links) resetDefaults(FieldPlanKind kind) =>
      switch (kind) {
        // Sessions and links stay warm: the mesh is grown by devices
        // joining, not by tearing down what is already established.
        FieldPlanKind.meshScale => (false, false),
        FieldPlanKind.joinTime => (false, false),
        FieldPlanKind.storeCarryForward => (false, false),
        FieldPlanKind.homeSoak => (true, false),
        FieldPlanKind.throughput => (false, false),
        FieldPlanKind.throughputCeiling => (false, false),
        FieldPlanKind.rawLink => (false, true),
        FieldPlanKind.powerBaseline => (false, false),
      };

  static FieldPlan build({
    required FieldPlanKind kind,
    required String expId,
    int dwellMin = 40,
    int sends = 40,
    int dwellSec = 180,
    int repeat = 1,
    bool? resetSessions,
    bool? resetLinks,
    List<int> payloadSizes = const [defaultSendBytes],
    List<int> laneCounts = const [1, 4, 16, 64],
    List<String> rawLegs = const ['notify', 'write', 'stripe'],
    int powerRole = 1,
    int sendLanes = 1,
    /// Mesh scaling: how many devices take part in total, and which join
    /// order THIS phone has (1..maxDevices).
    int maxDevices = 8,
    int meshRole = 1,
    bool saturate = true,
    bool manualJoin = false,

    /// Store-carry-forward: the pubkey prefix of the traveller (join order 1),
    /// so senders address the absent phone rather than each other.
    String travellerPrefix = '',
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
      case FieldPlanKind.rawLink:
        return FieldPlanPresets.rawLink(
          expId: id,
          dwellSec: dwellSec,
          legs: rawLegs,
          repeat: repeat,
          resetSessions: sessions,
          resetLinks: links,
        );
      case FieldPlanKind.powerBaseline:
        return FieldPlanPresets.powerBaseline(
          expId: id,
          role: powerRole,
          dwellSec: dwellSec,
          reps: repeat,
          lightSends: sends,
        );
      case FieldPlanKind.meshScale:
        return FieldPlanPresets.meshScale(
          expId: id,
          role: meshRole,
          maxDevices: maxDevices,
          dwellSec: dwellSec,
          sends: sends,
          repeat: repeat,
          saturate: saturate,
          sendLanes: sendLanes,
        );
      case FieldPlanKind.joinTime:
        // The id carries the spacing (join-time-30m): the sweep is repeated
        // per distance, and one file per distance is what makes the
        // distance x N comparison possible.
        return FieldPlanPresets.joinTime(
          expId: id,
          role: meshRole,
          maxDevices: maxDevices,
          joinDwellSec: dwellSec,
          repeat: repeat,
        );
      case FieldPlanKind.storeCarryForward:
        return FieldPlanPresets.storeCarryForward(
          expId: id,
          role: meshRole,
          travellerPrefix: travellerPrefix,
          darkSec: dwellSec,
          returnSec: dwellSec,
          mediumSends: sends,
          repeat: repeat,
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
