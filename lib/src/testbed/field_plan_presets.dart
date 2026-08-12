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
  /// hidden constant. [defaultSendBytes] (136 B) is exactly one sealed packet;
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
      deviceOrder: role,
      manualJoin: true,
      placementSec: placementSec,
      alignSec: alignSec,
      sampleGps: false,
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
      deviceOrder: role,
      manualJoin: true,
      placementSec: placementSec,
      alignSec: alignSec,
      sampleGps: false,
      steps: steps,
    );
  }

  /// LOAD SWEEP: delivery as a function of mesh size AND offered rate.
  ///
  /// The two-variable baseline. [nRange] members participate (the rest hold
  /// their radios down), each participant offers [rates] messages per second,
  /// and every (n, rate) cell repeats [repeat] times so a cell is a
  /// distribution rather than an anecdote. A rate of 0 means SATURATE — push
  /// as fast as the send path drains, which is the overload tail.
  ///
  /// The rate is PER DESTINATION: at 1/s with six peers up a device puts six
  /// messages a second on the air, and the same 1/s at n=2 puts one. The
  /// send rate itself is what stays fixed across the sweep — the fleet's
  /// total naturally rises with n, and that rise is the thing being measured.
  ///
  /// So `sendCount` is simply `rate x dwell`, and nothing here divides by a
  /// target count. The previous form divided by (n-1) to hold the per-device
  /// TOTAL flat, which was both the wrong quantity to fix and unsound: the
  /// runner fans out to however many peers are identified at fire time, and
  /// in load-sweep-1 phones the plan had dark were still linked, so the real
  /// rate was off by that ratio. Never scale a load by a number the plan
  /// merely assumes to be true of the radios.
  ///
  /// Each cell clears the DTN buffer at its first step so a cell never drains
  /// its predecessor's backlog, while sessions and links stay warm: this
  /// measures the data plane, not establishment.
  static FieldPlan loadSweep({
    String expId = 'load-sweep-1',
    required int role,
    List<int> nRange = const [2, 3, 4, 5, 6, 7],
    // 0 = saturate. Density matters more at the bottom than the top: the
    // medium carried ~207 sealed packets/s across the whole fleet, so at n=7
    // even 5 msg/s per device is already ~30 msg/s offered and fanning out
    // six ways. The knee is expected between 1 and 5, not near 20.
    List<int> rates = const [1, 5, 10, 20, 0],
    int repeat = 10,
    int dwellSec = 60,
    int sendBytes = defaultSendBytes,
    int sendLanes = 1,
    int placementSec = 60,
    int alignSec = 300,
  }) {
    final trials = repeat < 1 ? 1 : repeat;
    final steps = <FieldStep>[];
    for (final n in nRange) {
      final joined = role <= n;
      for (final rate in rates) {
        final saturating = rate == 0;
        // Sends per dwell at the wanted rate. Each one fans out to every
        // peer, so this is the per-destination rate and it holds across n.
        final ticks =
            saturating ? 0 : (rate * dwellSec).clamp(1, 1 << 20);
        for (var t = 1; t <= trials; t++) {
          final tag = saturating ? 'sat' : '${rate}ps';
          steps.add(FieldStep(
            label: 'n=$n r=$tag t$t',
            dwellSec: dwellSec,
            bleOn: joined,
            saturate: joined && saturating,
            sendLanes: sendLanes,
            sendBytes: sendBytes,
            sendCount: (joined && !saturating) ? ticks : 0,
            // First rep of a cell starts from an empty buffer; the rest carry
            // on, so a cell measures its own load and not the last one's tail.
            resetDtnBuffer: t == 1,
            autoAdvance: steps.isNotEmpty,
          ));
        }
      }
    }
    return FieldPlan(
      expId: expId,
      settleSec: 60,
      autoAdvanceGapSec: 10,
      // Warm throughout: this is the data plane, not establishment.
      resetSessions: false,
      resetLinks: false,
      resetDtnBuffer: false,
      deviceOrder: role,
      manualJoin: true,
      alignSec: alignSec,
      placementSec: placementSec,
      scriptedRadio: true,
      sampleGps: false,
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
  ///   high    — the field-day setting (saturate, ONE lane, one sealed packet
  ///             per message), so a desk result is comparable to
  ///             mesh-scale-30m-2. The packet header lost its unused 4-byte
  ///             timestamp after that run, so the payload is 136 B where the
  ///             field day sent 132 B — the packet on the wire is 236 B in
  ///             both, which is what contention actually sees.
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
    return FieldPlan(
      expId: expId,
      settleSec: 60,
      autoAdvanceGapSec: 10,
      resetSessions: false,
      resetLinks: false,
      resetDtnBuffer: false,
      deviceOrder: role,
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
      sampleGps: false,
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

  /// Rebuild [p] under the manual running logic: operator-toggled system
  /// Bluetooth, wall-clock-anchored start, no GPS. This is the ONE flow every
  /// experiment runs under; walk-driven plans no longer exist. The lone
  /// exception is the bounce-stress diagnostic, whose subject IS the
  /// app-level toggle.
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
      resetDtnBuffer: p.resetDtnBuffer,
      autoAdvanceGapSec: p.autoAdvanceGapSec,
      deviceOrder: p.deviceOrder,
      manualJoin: true,
      placementSec: placementSec,
      alignSec: alignSec,
      sampleGps: false,
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
        // scf-rearm-1 is already recorded and the recorder APPENDS, so this
        // is -2: re-using the id would merge two runs into one file and one
        // upload. Its numbers are not comparable with scf-rearm-1 anyway —
        // that run had the per-neighbour relay cap in the build (lifted for
        // the arm), this one has no cap at all, and it ran on three phones
        // rather than eight.
        'SCF re-arm check — TRAVELLER (1 rep, ~17 min)':
            storeCarryForward(expId: 'scf-rearm-2', role: 1),
        'SCF re-arm check — sender (1 rep, ~17 min)':
            storeCarryForward(expId: 'scf-rearm-2', role: 2),
        // A FRESH id per campaign: the recorder appends, so reusing an id
        // merges runs into one file and one upload. The shakedown runs live
        // under scf-desk-1; this is the measured one.
        'SCF desk — TRAVELLER (this phone goes dark)':
            storeCarryForward(expId: 'scf-desk-2', role: 1, repeat: 10),
        'SCF desk — sender (everyone else)':
            storeCarryForward(expId: 'scf-desk-2', role: 2, repeat: 10),
        'Home soak (stationary, 40 min)': manualized(homeSoak()),
        'Link-cycle check (5×1 min)': manualized(cycleCheck()),
        'Throughput (saturate 60s)': manualized(throughput()),
        'Throughput: payload arm (132/264/1200 B)': manualized(throughput(
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
        // Full ladder, ~2h41. Every quantity measured on BOTH devices.
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
        // LOAD SWEEP, one entry per device order. n=2..7 x {1,5,10,20,sat}
        // msg/s per device x 10 reps at a 30 s dwell = 300 cells, ~3.4 h.
        // The role decides which n this phone joins at: #1 and #2 are in every
        // cell, #7 only in the n=7 cells.
        for (var r = 1; r <= 7; r++)
          'Load sweep n=2..7 x rate (~3.4 h) — this phone is #$r':
              loadSweep(expId: 'load-sweep-1', role: r, dwellSec: 30,
                  repeat: 10),
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
