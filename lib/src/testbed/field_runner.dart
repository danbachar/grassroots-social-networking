import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../trace/experiment_recorder.dart';
import '../models/block.dart';
import 'testbed_config.dart';

/// The runner's user-visible phase.
enum FieldPhase {
  /// Manual-join mode: phones are being carried to their marks; the run
  /// begins for every phone at the same wall-clock instant.
  placement,

  /// Waiting for the experimenter to reach the current step's position.
  positioning,

  /// Holding the current step's dwell window (countdown running).
  dwelling,

  /// All steps done — settle window before the recording stops.
  settling,

  /// Recording stopped (and upload attempted). Terminal.
  finished,
}

/// DEBUG/TESTBED ONLY. Drives a [FieldPlan] end to end:
///
///   Start → recording on → per step: [positioning] —IN POSITION→ marker +
///   [dwelling] (bulk flows run here when the step asks) → next step … →
///   `end` marker → [settling] → recording off → upload → [finished].
///
/// Pure sequencing — the screen renders [phase]/[remainingSec] and calls
/// [start] / [inPosition] / [abort]. All side effects go through injected
/// callbacks so the machine is testable with fake timers.
class FieldRunner extends ChangeNotifier {
  final ExperimentRecorder recorder;
  final VoidCallback? onStartBulk;
  final VoidCallback? onStopBulk;

  /// This device's identity, matched against the plan roster to find its
  /// label (send source) and its send targets (every other roster row).
  final String? myPubkeyHex;

  /// This device's ANNOUNCE nickname, stamped into the placement marker.
  /// The join order is OPERATOR INPUT typed before every run; the nickname
  /// is set once and shown on screen. Recording both makes a mistyped order
  /// contradict itself in the trace instead of silently mapping a phone onto
  /// another phone's geometry row — which is how a field day ends with two
  /// devices claiming one node and none claiming its neighbour.
  final String? myNickname;

  /// Message send hook (the coordinator's `send`). A send to a sessionless
  /// peer triggers the lazy handshake — which is exactly the point after a
  /// per-step session reset.
  final Future<String?> Function(Uint8List recipient, Uint8List payload,
      {String? messageId})? send;

  /// Drops all Noise sessions (per-step, when the plan asks) so each step
  /// measures the full establishment ladder.
  final VoidCallback? onResetSessions;

  /// Bounces the BLE transport (per-step, when the plan asks) so each step
  /// re-runs discovery + connect from a cold start. Awaited: the step's
  /// marker and sends wait until the transport is back up. [darkSec] is the
  /// plan's [FieldPlan.linkResetDarkSec] — null leaves the coordinator's
  /// default gap.
  final Future<void> Function(int? darkSec, {void Function()? whileDark})?
      onResetLinks;

  /// Empties the DTN memory buffer (per-step, when the plan asks) so a prior
  /// step's undelivered backlog cannot drain into this step's window.
  final VoidCallback? onResetDtnBuffer;

  /// Sets the BLE transport up/down for steps that script it
  /// ([FieldStep.bleOn]). Awaited before the step marker so every power
  /// sample inside the segment sees the requested state.
  final Future<void> Function(bool on)? onSetBle;

  /// Monotonic tx+rx bytes on the BLE transport. Counted at the GATT choke
  /// points, so it only moves while a peer is connected — see
  /// [_armBleWatchdog] for why that makes it a secondary signal, not the
  /// primary one.
  final int Function()? bleWireBytes;

  /// Whether the BLE transport is up and usable. Holds with no peer in range,
  /// which is what makes it the primary liveness check for a scripted radio
  /// bring-up: a ladder step can legitimately bring the radio up ALONE.
  final bool Function()? bleUsable;

  /// BLE-usability TRANSITIONS, emitted at the transport-state change
  /// itself. The `bt-on`/`bt-off` markers are stamped exclusively from this
  /// stream: a marker timestamp is the instant the BLE service became
  /// ready (or died), never the instant a poll noticed it. Analysis code
  /// may treat bt-on as exact — no session can predate its own bt-on.
  final Stream<bool>? bleUsableChanges;

  /// How long a scripted `bleOn: true` segment may move zero bytes before the
  /// run aborts. Long enough for init plus the first ANNOUNCE (the interval is
  /// 10s), short enough to lose one step rather than the whole run.
  final int bleWatchdogSec;

  /// DEBUG raw-throughput send: one MTU-sized raw blob to [peer] over the
  /// step's [FieldStep.rawLeg]. Returns the blob size, or null when that leg
  /// is not currently available.
  final Future<int?> Function(Uint8List peer,
      {required String leg,
      required int seq,
      int sizeDelta})? sendRaw;

  /// Peers a message can be addressed to — those with a live session —
  /// consulted when the plan has NO roster. Labels are the 8-hex pubkey
  /// prefixes, so the two-device case needs no manual pubkey entry.
  ///
  /// Sessioned rather than merely identified: the two sets differ, and the
  /// gap between them is a real window in which a peer is known and cannot be
  /// sent to. Resolved lazily at each send, so a peer whose session forms
  /// mid-step is picked up as soon as it can receive.
  final List<Uint8List> Function()? knownPeers;

  /// Whether the pair with a peer is settled for data (session + converged
  /// dual-leg link). When provided, each step's sends wait for a settled
  /// target and then spread across the REMAINING dwell — messages never race
  /// a re-forming link. If no target settles within the dwell, no sends fire
  /// (correct at an out-of-range step). Null: legacy fixed-offset schedule.
  final bool Function(Uint8List peer)? linkSettled;

  /// Whether a Noise session with this peer exists. This is what a send is
  /// gated on — a session is the whole requirement for addressing a peer, and
  /// [linkSettled] additionally wants both GATT legs, which a pair at the far
  /// end of a line sweep may never get. Gating sends on convergence there
  /// records a runner that declined to send as a range the radio could not
  /// reach.
  final bool Function(Uint8List peer)? sessionUp;

  /// Dial grid: cap the transport's in-flight central dials at [maxParallel]
  /// (null restores the production cap) and stamp [popN] on the
  /// establishments that follow, so each one is attributable to its cell.
  ///
  /// The grid does not script dials. The transport dials greedily on its
  /// own and tops up as slots free; this hook only moves the bound the
  /// transport already enforces, which is why M is a real independent
  /// variable and not a burst size we chose.
  final void Function({int? maxParallel, int? popN})? onSetDialParallelism;

  /// Dial grid: central legs that reached GATT-usable since
  /// [onResetEstablishmentCount]. Read at the step's end so the per-step
  /// establishment count is a recorded fact.
  final int Function()? establishmentCount;
  final VoidCallback? onResetEstablishmentCount;

  static const _uuid = Uuid();

  /// Uploads the experiment files; returns a user-facing status line.
  /// Null when this build has no upload destination.
  final Future<String> Function()? upload;

  /// Fires when a dwell or settle window elapses — the screen uses it for
  /// haptics/sound so the experimenter feels the step end pocket-blind.
  final VoidCallback? onWindowElapsed;

  /// Peers this phone currently holds a Noise session with. Stamped into
  /// every step marker as `sessions`, so each rep carries its own formation
  /// evidence: "was the topology up when this window opened" becomes a field
  /// on the marker instead of an inference from link records.
  final int Function()? sessionPeerCount;

  /// Sessions held in the Noise table itself, stamped as `sessionTable`.
  ///
  /// [sessionPeerCount] counts only sessions whose peer is still listed in
  /// Redux, and a quiet non-friend peer is pruned from that list while its
  /// session lives on — so `sessions` is a LOWER BOUND that dips when links
  /// go quiet, which is precisely when a field run is most interesting. The
  /// pair of numbers separates a lost session from a delisted peer; one of
  /// them alone cannot.
  final int Function()? sessionTableCount;

  /// THIS phone's join order, read from its own nickname.
  ///
  /// The join order is the nickname and nothing else. It does not ride in the
  /// plan as `deviceOrder`, which the presets set to the plan ROLE — so the
  /// traveller of a store-carry-forward run stamped and displayed `#1`
  /// whatever its nickname was, and the sender `#2`, seven times over. The
  /// marker's `order` and `nick` then disagreed on every phone but one, and
  /// `order` is what the analysis joins geometry on.
  ///
  /// A plan is shared by the whole fleet, so it cannot know which phone is
  /// which; the nickname is per-device and is the one thing that can. Strict
  /// parse, deliberately: a nickname like "pixel-2" is NOT node 2, and a
  /// phone whose nickname is not a plain positive integer has no join order
  /// at all rather than a guessed one.
  int? get joinOrder {
    final n = int.tryParse(myNickname?.trim() ?? '');
    return (n != null && n > 0) ? n : null;
  }

  /// Epoch-ms clock, injectable so the wall-clock schedule is testable
  /// under fakeAsync. Production default is the real clock.
  final int Function() nowMs;

  static int _realNowMs() => DateTime.now().millisecondsSinceEpoch;

  FieldRunner({
    required this.recorder,
    this.nowMs = _realNowMs,
    this.sessionPeerCount,
    this.sessionTableCount,
    this.onStartBulk,
    this.onStopBulk,
    this.myPubkeyHex,
    this.myNickname,
    this.send,
    this.onResetSessions,
    this.onResetLinks,
    this.onResetDtnBuffer,
    this.onSetBle,
    this.bleWireBytes,
    this.bleUsable,
    this.bleUsableChanges,
    this.bleWatchdogSec = 30,
    this.sendRaw,
    this.knownPeers,
    this.linkSettled,
    this.sessionUp,
    this.onSetDialParallelism,
    this.establishmentCount,
    this.onResetEstablishmentCount,
    this.upload,
    this.onWindowElapsed,
  });

  FieldPlan? _plan;

  /// Identifies THIS run among runs sharing an experiment id.
  ///
  /// Stamped on every step marker so an analysis can segment two runs that
  /// were recorded under one id — the recorder appends, so that happens
  /// whenever an id is reused. It does NOT seed message ids: those are v4,
  /// the same as production. Deterministic ids would repeat across runs of
  /// the same plan, and the receiver's packetId bloom then dropped the second
  /// run's messages as duplicates — a testbed-only id scheme that changed
  /// delivery behaviour and corrupted the measurement it was there to serve.
  ///
  /// The value is the shared anchor for a wall-clock run and the start instant
  /// otherwise.
  int? _runId;

  FieldPhase _phase = FieldPhase.finished;
  int _stepIndex = 0;
  int _remainingSec = 0;
  bool _running = false;
  String? _uploadResult;
  Timer? _tick;
  final List<Timer> _sendTimers = [];
  int _sentCount = 0;

  /// Sends not attempted because the target pair was not settled yet. Reported
  /// so a step that fired few messages is distinguishable from one whose
  /// messages failed.
  int _skippedSends = 0;
  bool _resetting = false;
  /// Saturating mode: outstanding messageIds and the next sequence number.
  final Set<String> _outstanding = {};
  int _satSeq = 0;
  int _ackedCount = 0;
  int _rawBlobs = 0;
  int _rawBytes = 0;
  Timer? _bleWatchdog;
  String? _abortReason;

  /// Manual-join wall-clock schedule: the shared start instant and each
  /// step's absolute start, precomputed so 61 steps cannot accumulate the
  /// drift of chained one-second timers.
  int? _anchorMs;
  List<int>? _stepStartMs;
  Timer? _absFire;
  Timer? _btProbe;
  StreamSubscription<bool>? _btSub;
  bool _btOnSeen = false;
  bool _radioUp = false;

  /// ACKed sends in the current saturating step (throughput numerator).
  int get ackedCount => _ackedCount;

  /// Messages fired by the plan so far (all steps).
  int get sentCount => _sentCount;

  /// Sends held back because the target pair had no session yet.
  int get skippedSends => _skippedSends;

  /// Why the run aborted itself, or null if it did not. The screen shows this
  /// instead of a finished state, because an abort that looks like a normal
  /// finish is how bad data gets analysed as if it were good.
  String? get abortReason => _abortReason;

  /// True while a step's BLE bounce is in flight (the dark gap + cold
  /// re-init) — the screen shows a "resetting" notice instead of a stuck
  /// positioning view.
  bool get resetting => _resetting;

  FieldPlan? get plan => _plan;
  FieldPhase get phase => _phase;
  int get stepIndex => _stepIndex;
  int get remainingSec => _remainingSec;
  bool get isRunning => _running;
  String? get uploadResult => _uploadResult;
  FieldStep? get currentStep {
    final plan = _plan;
    if (plan == null || _stepIndex >= plan.steps.length) return null;
    return plan.steps[_stepIndex];
  }

  // ===== Manual-join mode (wall-clock anchored) =====

  bool get manualJoin => _plan?.manualJoin ?? false;

  /// The shared wall-clock start instant, or null outside manual mode.
  int? get startTargetMs => _anchorMs;

  /// When THIS phone's radio is scheduled to be on: the absolute start of
  /// its first joined step. Null until a manual run is started.
  int? get myJoinAtMs {
    final plan = _plan, starts = _stepStartMs;
    if (plan == null || starts == null) return null;
    for (var i = 0; i < plan.steps.length && i < starts.length; i++) {
      if (plan.steps[i].bleOn == true) return starts[i];
    }
    return null;
  }

  /// When the whole plan is over: the last step's dwell end plus the settle
  /// window. This is what a phone with nothing to do counts down to, so the
  /// screen answers "how long until this is finished" rather than timing a
  /// step boundary nobody has to act on. Null outside a manual run, where
  /// there is no wall-clock schedule to read it off.
  int? get planEndMs {
    final plan = _plan, starts = _stepStartMs;
    if (plan == null || starts == null || starts.isEmpty) return null;
    return starts.last + (plan.steps.last.dwellSec + plan.settleSec) * 1000;
  }

  /// Whether this phone joins after the run start (roles 4+): the ones whose
  /// Bluetooth the operator must turn on mid-run.
  bool get joinsLater =>
      myJoinAtMs != null && _anchorMs != null && myJoinAtMs! > _anchorMs!;

  /// True from the run start until this phone's TURN ON window opens. The
  /// screen shows nothing but the countdown then: step progression is
  /// somebody else's run for a phone that has not joined the mesh yet, and
  /// what its operator needs is when to act.
  bool get waitingToJoin {
    if (!manualJoin || !_running || !joinsLater) return false;
    final j = myJoinAtMs;
    if (j == null || _plan == null) return false;
    return nowMs() < j - _plan!.autoAdvanceGapSec * 1000;
  }

  /// Whether the radio has been OBSERVED usable at any point this run.
  bool get radioSeenUp => _btOnSeen;

  /// The radio's current observed state (manual mode; updated every 2 s).
  bool get radioUp => _radioUp;

  /// What the operator must do to the radio RIGHT NOW, or null when the
  /// observed state matches the schedule's intent: 'on' / 'off'. This is the
  /// single source for every screen prompt, so an off-step's TURN OFF and a
  /// join-step's TURN ON cannot drift apart.
  String? get radioAction {
    // A scripted-radio plan works the radio itself, so prompting the operator
    // asks for something they cannot do and did not need to: the instruction
    // appears in the gap between the step wanting the radio down and
    // `bleUsableChanges` reporting it down, and reads as a failure. The prompt
    // belongs only to plans where a human genuinely owns the toggle.
    if (!manualJoin || !_running) return null;
    if (_plan?.scriptedRadio ?? false) return null;
    final want = currentStep?.bleOn;
    if (want == null) return null;
    if (want && !_radioUp) return 'on';
    if (!want && _radioUp) return 'off';
    return null;
  }

  /// Begin the plan: starts the experiment recording and enters the first
  /// step's positioning phase. No-op while already running.
  /// Set by [dispose]. A run's countdown is a periodic timer, and a step
  /// boundary can land after the widget that owns this runner is gone — the
  /// timer then drives `_finish` into `notifyListeners()` on a disposed
  /// ChangeNotifier, which throws. It surfaced as a test that passed or
  /// failed depending on which won the race.
  bool _disposed = false;

  /// Every notify goes through here: after dispose there is nobody to tell,
  /// and telling them is an error rather than a no-op.
  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  Future<void> start(FieldPlan plan) async {
    if (_running || plan.steps.isEmpty) return;
    // Role-free diluting plan: derive THIS phone's schedule from its nickname
    // before anything is recorded. The nickname is the only place the join
    // order lives — there is no per-role preset to pick wrongly (the field
    // run lost its whole N=2 phase to exactly that mistake). A nickname that
    // is not a number cannot join anywhere, so refuse loudly instead of
    // running a phone that would silently sit out every phase.
    if (plan.steps.any((s) => s.cliqueN != null)) {
      final order = joinOrder;
      if (order == null) {
        _abortReason = 'nickname "${myNickname ?? ''}" is not a join order — '
            'set it to this phone\'s number (1..N) and relaunch';
        _notify();
        return;
      }
      plan = plan.resolvedFor(order);
    }
    // A discharge plan ends on state of charge, not on the clock: its step
    // dwell is deliberately longer than the battery can last, and this is
    // what actually stops it.
    recorder.onBatteryFloor = (level) => unawaited(_finishAtFloor(level));
    _plan = plan;
    _stepIndex = 0;
    _uploadResult = null;
    _abortReason = null;
    _batteryFloorLevel = null;
    _finishing = false;
    _finishingWhat = '';
    _uploadChunks = 0;
    _uploadFraction = null;
    _running = true;
    _anchorMs = null;
    _stepStartMs = null;
    _runId = nowMs();
    _btOnSeen = false;
    _radioUp = false;
    await recorder.startExperiment(plan.expId);
    if (plan.manualJoin) {
      // Anchor on the wall clock, not the tap: every phone rounds up to the
      // same alignment boundary, so the start skew collapses to clock-sync
      // error instead of the spread of the taps. The boundary granularity
      // must exceed that spread.
      final alignMs = plan.alignSec * 1000;
      final resetMs = plan.resetBudgetSec * 1000;
      final minStart = nowMs() + plan.placementSec * 1000;
      final anchor = ((minStart + alignMs - 1) ~/ alignMs) * alignMs;
      _anchorMs = anchor;
      // Every phone computes the same anchor, so it also gives every phone the
      // same run id — ids stay comparable across the fleet, as they must be.
      _runId = anchor;
      _stepStartMs = stepStarts(plan, anchor);
      // The target in the trace is the alignment proof: after the run, one
      // query shows whether all phones computed the same instant.
      await recorder.logMarker('placement', extra: {
        'targetMs': anchor,
        if (joinOrder != null) 'order': joinOrder,
        if (myNickname != null && myNickname!.isNotEmpty) 'nick': myNickname,
      });
      _startRadioObserver();
      _phase = FieldPhase.placement;
      _countdownToMs(anchor - resetMs, () => inPosition());
      _notify();
      return;
    }
    _enterPositioning();
  }

  /// Stamp `bt-on` / `bt-off` on every radio transition — the measured join
  /// (and outage) instants, as opposed to the scheduled ones. The stamps are
  /// EVENT-DRIVEN: [bleUsableChanges] delivers the transport-state change
  /// itself, so the marker's timestamp is the moment the BLE service became
  /// ready, not the moment a poll noticed. (A 2 s poll here once put stamps
  /// up to 2 s late, and a session formed inside that lag was analysed as a
  /// peer that never formed. Never stamp measurements from a poll.) The
  /// initial state is stamped too, so every manual run opens with explicit
  /// radio ground truth instead of an implied one.
  ///
  /// The periodic timer that remains does recovery ONLY, never stamping:
  /// while the schedule wants the radio ON and it is down, bounce the
  /// app-level service every other tick — init with system Bluetooth off
  /// leaves a service object that never started, and only a fresh init picks
  /// the adapter up after the operator toggles it on. While the schedule
  /// wants it OFF, never bounce — a down radio is the plan, and fighting the
  /// operator's toggle would be a bug wearing a recovery mechanism's clothes.
  void _startRadioObserver() {
    _btProbe?.cancel();
    _btSub?.cancel();
    final usable = bleUsable;
    if (usable == null) return;

    Future<void> stamp(bool up) async {
      if (up == _radioUp) return;
      _radioUp = up;
      if (up) _btOnSeen = true;
      await recorder.logMarker(up ? 'bt-on' : 'bt-off', extra: {
        if (joinOrder != null) 'order': joinOrder,
      });
      _notify();
    }

    // Initial state, stamped from a direct read at observer start.
    _radioUp = !usable();
    unawaited(stamp(!_radioUp));

    // Transitions, stamped as they happen.
    _btSub = bleUsableChanges?.listen((up) => unawaited(stamp(up)));

    var tick = 0;
    _btProbe = Timer.periodic(const Duration(seconds: 2), (_) {
      final wantOn = currentStep?.bleOn == true;
      if (!usable() && wantOn && onSetBle != null && tick.isEven) {
        unawaited(() async {
          await onSetBle!.call(false);
          await onSetBle!.call(true);
        }());
      }
      tick++;
    });
  }

  /// Enter the positioning phase for the current step. When the step
  /// auto-advances (same distance as the previous — nothing to walk to), a
  /// short settle-gap countdown fires [inPosition] automatically; a manual
  /// tap still skips the remaining gap. Otherwise the runner waits for the
  /// tap that marks "I reached the new position".
  void _enterPositioning() {
    _phase = FieldPhase.positioning;
    if (manualJoin && _stepStartMs != null) {
      // The gap counts down to the instant the next step's resets open, which
      // is its absolute start less the reset reservation. This gap is also the
      // join window: the phone whose first joined step is next shows TURN ON
      // BLUETOOTH for exactly this long.
      _countdownToMs(_stepStartMs![_stepIndex] - _plan!.resetBudgetSec * 1000,
          () => inPosition());
    } else if (currentStep?.autoAdvance ?? false) {
      _startCountdown(_plan!.autoAdvanceGapSec, () => inPosition());
    }
    _notify();
  }

  /// Empty the buffer, bounce the radio with the session purge inside the dark
  /// window, and restore the step's dial context.
  ///
  /// A run is bracketed by these on both sides: one ahead of it, so it opens
  /// cold, and one behind it, so whatever the run left cannot be counted. The
  /// trailing one is what makes the LAST run of a plan like every other — a
  /// segment ends at the next step marker, so every run but the last already
  /// had its tail cut by the following reset.
  Future<void> _runResets(FieldStep step) async {
    // The buffer goes first, with the radio still up: emptying it is what
    // stops this phone generating anything new, and it has to happen before
    // the link goes away rather than after.
    if ((step.resetDtnBuffer ?? _plan!.resetDtnBuffer) &&
        onResetDtnBuffer != null) {
      onResetDtnBuffer!.call();
      await recorder.logMarker('custody-reset');
    }
    final wantSessionReset =
        (step.resetSessions ?? _plan!.resetSessions) && onResetSessions != null;
    var sessionsResetWhileDark = false;
    if (_plan!.resetLinks && onResetLinks != null) {
      _resetting = true;
      _notify();
      // BLE bounce; wait for the transport back up. The session purge rides
      // INSIDE the dark window: pairing is eager, so a handshake completes on
      // its own the moment the radio returns, and purging after that hands the
      // step a session it was supposed to start without.
      await onResetLinks!.call(_plan!.linkResetDarkSec, whileDark: () {
        if (!wantSessionReset) return;
        onResetSessions!.call();
        sessionsResetWhileDark = true;
      });
      _resetting = false;
      _notify();
      if (sessionsResetWhileDark) {
        await recorder.logMarker('sessions-reset');
      }
      await recorder.logMarker('links-reset');
    }
    // AFTER the bounce, which builds a fresh transport: the cap and the step
    // context have to land on the service the step will actually dial with.
    // Null restores the production cap, so a step without a cap is not
    // running under the previous step's.
    onSetDialParallelism?.call(
        maxParallel: step.maxParallelDials, popN: step.cliqueN);
    onResetEstablishmentCount?.call();
    // Only when the bounce did not already carry the purge — a plan that does
    // not reset links has no dark window to put it in.
    if (wantSessionReset && !sessionsResetWhileDark) {
      onResetSessions!.call();
      await recorder.logMarker('sessions-reset');
    }
  }

  /// The experimenter reached the current step's position: drop sessions
  /// (when the plan asks), stamp the ground-truth marker, hold the dwell,
  /// and run the step's sends spread through it.
  Future<void> inPosition() async {
    final step = currentStep;
    if (!_running ||
        (_phase != FieldPhase.positioning && _phase != FieldPhase.placement) ||
        step == null) {
      return;
    }
    _tick?.cancel(); // a manual tap pre-empts any auto-advance gap countdown
    _tick = null;
    _absFire?.cancel();
    _absFire = null;
    // Manual-join mode never touches the radio: system Bluetooth belongs to
    // the operator, and bleOn is intent for the marker, not a command.
    // Wall-clock anchored AND hands-free: `scriptedRadio` says the plan, not
    // an operator, works the radio, so the anchor and the toggling stop being
    // one decision.
    if (step.bleOn != null &&
        onSetBle != null &&
        (!manualJoin || _plan!.scriptedRadio)) {
      _resetting = true;
      _notify();
      await onSetBle!.call(step.bleOn!);
      _resetting = false;
      _notify();
    }
    await _runResets(step);
    // The resets ran in the slot reserved ahead of the step. Hold here until
    // the step's own instant so the marker opens a full dwell and every phone
    // opens it together; a phone whose resets overran is already past it and
    // falls through, stamping late rather than silently shortening the run.
    if (manualJoin && _stepStartMs != null) {
      final wait = _stepStartMs![_stepIndex] - nowMs();
      if (wait > 0) {
        await Future<void>.delayed(Duration(milliseconds: wait));
        if (!_running || currentStep != step) return;
      }
    }
    // The step marker carries this phone's CONFIGURED intent, not just the
    // step name: which join slot it was assigned and whether it believed it
    // was in the mesh for this step. Analysis can then tell a misconfigured
    // phone from one that was configured right and failed to join — from the
    // marker alone, without inferring it from when links first appear.
    await recorder.logMarker(step.label, extra: {
      if (joinOrder != null) 'order': joinOrder,
      if (step.bleOn != null) 'joined': step.bleOn,
      if (sessionPeerCount != null) 'sessions': sessionPeerCount!(),
      if (sessionTableCount != null)
        'sessionTable': sessionTableCount!(),
      if (_runId != null) 'run': _runId,
      // Sends held back for want of a session, so a window that fired little
      // traffic is distinguishable from one whose traffic failed.
      if (_skippedSends > 0) 'skippedSends': _skippedSends,
      // Dial-grid cell, on the marker that OPENS the window, so the analyzer
      // reads M / N / rep off the segment instead of re-parsing the label.
      if (step.maxParallelDials != null) 'maxParallel': step.maxParallelDials,
      if (step.maxParallelDials != null && step.cliqueN != null)
        'popN': step.cliqueN,
      if (step.maxParallelDials != null) 'rep': _repOf(step.label),
    });
    if (step.bulk) onStartBulk?.call();
    _phase = FieldPhase.dwelling;
    // No dead-radio watchdog in manual mode: the radio being down is the
    // operator's schedule (or their fumble), and either way the right
    // response is to keep recording, not to abort seven other phones' run.
    if (!manualJoin) _armBleWatchdog(step);
    _scheduleSends(step);
    if (manualJoin && _stepStartMs != null) {
      _countdownToMs(
          _stepStartMs![_stepIndex] + step.dwellSec * 1000, _endDwell);
    } else {
      _startCountdown(step.dwellSec, _endDwell);
    }
    _notify();
  }

  /// The absolute instant each step's DWELL opens, under [FieldPlan.manualJoin].
  /// Every phone computes this from the same anchor and the same plan, which is
  /// what lets a pair advance together with nobody tapping anything.
  ///
  /// A step that does not auto-advance opens a new position the operator has to
  /// walk a device to, so it lands on the first alignment boundary at least
  /// [FieldPlan.walkBudgetSec] past the previous dwell — the walk is a
  /// reservation, and the phones re-converge on the boundary instead of
  /// carrying the previous position's remainder forward. Repeats at one
  /// position follow immediately.
  static List<int> stepStarts(FieldPlan plan, int anchor) {
    final alignMs = plan.alignSec * 1000;
    final resetMs = plan.resetBudgetSec * 1000;
    final walkMs = plan.walkBudgetSec * 1000;
    final starts = <int>[];
    var t = anchor;
    for (var i = 0; i < plan.steps.length; i++) {
      final st = plan.steps[i];
      if (!st.autoAdvance) {
        // The walk runs until the next step's RESETS open, not until its
        // dwell does, so the reservation is measured to that instant.
        final earliest = i == 0 ? t : t + walkMs;
        t = ((earliest + alignMs - 1) ~/ alignMs) * alignMs;
      }
      starts.add(t);
      t += resetMs + (st.dwellSec + plan.autoAdvanceGapSec) * 1000;
    }
    return starts;
  }

  /// Countdown to an ABSOLUTE instant: the display ticks once a second, the
  /// callback fires from a one-shot timer aimed at the target itself, and
  /// remaining time is recomputed from the clock each tick — so neither
  /// timer jitter nor a long run accumulates drift.
  void _countdownToMs(int targetMs, Future<void> Function() onDone) {
    _tick?.cancel();
    _absFire?.cancel();
    void show() {
      final rem = targetMs - nowMs();
      _remainingSec = rem <= 0 ? 0 : (rem + 999) ~/ 1000;
      _notify();
    }

    show();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => show());
    final delay = targetMs - nowMs();
    _absFire = Timer(Duration(milliseconds: delay < 0 ? 0 : delay), () {
      _tick?.cancel();
      _tick = null;
      _absFire = null;
      unawaited(onDone());
    });
  }

  /// Watch a scripted radio bring-up. `setBleActiveForTestbed(true)` has
  /// several early returns that leave BLE down without throwing, so a
  /// successful-looking await is not evidence the radio is running.
  ///
  /// Two signals, in this order, because neither alone is correct:
  ///
  ///  * **Transport usable** — the primary check. It holds even when the
  ///    radio is up ALONE, which a ladder step can legitimately ask for (one
  ///    phone's radio on, the peer's deliberately off). Bytes cannot test
  ///    that case at all.
  ///  * **Bytes moved** — checked only when a peer is currently known.
  ///    [bleWireBytes] counts at the GATT choke points, so advertising and
  ///    scanning are invisible to it and a lone radio reads zero no matter
  ///    how healthy it is. Requiring bytes unconditionally would abort every
  ///    solo segment in the power ladder.
  void _armBleWatchdog(FieldStep step) {
    _bleWatchdog?.cancel();
    _bleWatchdog = null;
    if (step.bleOn != true) return;
    if (bleUsable == null && bleWireBytes == null) return;
    if (step.dwellSec <= bleWatchdogSec) return; // step ends first; nothing to catch
    final before = bleWireBytes?.call() ?? 0;
    _bleWatchdog = Timer(Duration(seconds: bleWatchdogSec), () {
      _bleWatchdog = null;
      if (!_running || _phase != FieldPhase.dwelling) return;
      if (bleUsable?.call() == false) {
        unawaited(_abortDead(step, 'the transport is not usable'));
        return;
      }
      final peers = knownPeers?.call() ?? const <Uint8List>[];
      if (peers.isEmpty) return; // alone on purpose: bytes prove nothing
      if ((bleWireBytes?.call() ?? 0) - before > 0) return;
      unawaited(_abortDead(
          step, 'a peer is in range but 0 bytes moved'));
    });
  }

  Future<void> _abortDead(FieldStep step, String detail) async {
    _abortReason = 'BLE dead: step "${step.label}" asked for the radio and '
        '$detail after ${bleWatchdogSec}s. '
        'The rest of this run would be recorded against a dead radio.';
    await recorder.log({
      'type': 'runner',
      't': DateTime.now().millisecondsSinceEpoch,
      'event': 'bleDead',
      'step': step.label,
      'detail': detail,
      'watchdogSec': bleWatchdogSec,
    });
    // Same alert the step boundaries use, so it lands even pocket-blind.
    onWindowElapsed?.call();
    await abort();
  }

  /// Send targets for the current instant. With a roster: this device must
  /// be a member (else receive-only) and targets are every other row, roster
  /// labels naming the id set. Without a roster: every currently identified
  /// peer, labeled by 8-hex pubkey prefix — the two-device case with no
  /// manual pubkey entry.
  List<(String, Uint8List)> _sendTargets() {
    final targets = _allSendTargets();
    final want = currentStep?.sendTo.toLowerCase() ?? 'all';
    if (want == 'all') return targets;
    // Address ONE peer by pubkey prefix: the multi-hop case, where the
    // recipient may not be a direct neighbour at all. An unmatched prefix
    // sends nothing rather than silently broadcasting.
    return targets
        .where((t) => _hex(t.$2).toLowerCase().startsWith(want))
        .toList();
  }

  List<(String, Uint8List)> _allSendTargets() {
    final me = myPubkeyHex?.toLowerCase();
    final plan = _plan!;
    if (plan.roster.isNotEmpty) {
      if (me == null) return const [];
      final mine =
          plan.roster.where((r) => r.pubkeyHex.toLowerCase() == me).firstOrNull;
      if (mine == null) return const []; // not in the roster: receive-only
      return [
        for (final dst in plan.roster)
          if (dst.pubkeyHex.toLowerCase() != me)
            if (_hexToBytes(dst.pubkeyHex) case final pk?)
              (dst.label, pk),
      ];
    }
    return [
      for (final pk in knownPeers?.call() ?? const <Uint8List>[])
        (_hex(pk).substring(0, 8), pk),
    ];
  }


  /// Schedule [FieldStep.sendCount] messages for this step. With a
  /// [sessionUp] predicate: poll until some target has a session, then spread
  /// the sends across the REMAINING dwell — data never races a re-forming
  /// link, and an out-of-range step sends nothing. Without the predicate:
  /// fixed offsets from dwell start. Targets resolve at fire time; message
  /// ids are v4, matching production.
  ///
  /// Convergence is watched separately and marked when it happens, so the
  /// trace still carries when the pair got both legs without that being what
  /// holds the sends back.
  void _scheduleSends(FieldStep step) {
    // A step whose radio THIS phone holds down sends nothing — in a resolved
    // diluting plan every step carries the full send config and membership
    // lives in the derived [FieldStep.bleOn], so an un-joined phone must not
    // schedule sends that would only fail into the trace. Explicit false
    // only: bleOn == null means the plan does not script the radio.
    if (step.bleOn == false) return;
    // Raw mode first: it uses [sendRaw], not [send] — gating it behind the
    // message-send hook silently disabled it (caught by test).
    if (step.rawLeg != null) {
      _scheduleRaw(step); // raw mode ignores sendCount/saturate
      return;
    }
    final doSend = send;
    if (doSend == null) return;
    if (step.saturate) {
      _scheduleSaturating(step); // saturating mode ignores sendCount
      return;
    }
    if (step.sendCount <= 0) return;
    _watchConvergence();
    final ready0 = sessionUp;
    if (ready0 == null) {
      final windowSec = step.dwellSec > 2 ? step.dwellSec - 2 : step.dwellSec;
      for (var seq = 0; seq < step.sendCount; seq++) {
        _queueSend(step, seq, 1 + (seq * windowSec) ~/ step.sendCount);
      }
      return;
    }
    final poll = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!_running || _phase != FieldPhase.dwelling) {
        t.cancel();
        return;
      }
      final ready =
          _sendTargets().any((target) => ready0(target.$2));
      if (!ready) return;
      t.cancel();
      unawaited(recorder.logMarker('session-up'));
      // Spread the step's sends across what remains of the dwell.
      final windowSec = _remainingSec > 2 ? _remainingSec - 2 : _remainingSec;
      for (var seq = 0; seq < step.sendCount; seq++) {
        _queueSend(step, seq, (seq * windowSec) ~/ step.sendCount);
      }
      _notify();
    });
    _sendTimers.add(poll);
  }

  /// Mark the moment a target's pair converges to both GATT legs.
  ///
  /// Convergence no longer gates anything — sends go out on the session — but
  /// it is still the fact the establishment ladder calls "established", so it
  /// has to reach the trace on its own. The watcher stops at the first
  /// converged target: one marker per step is what the analysis reads.
  void _watchConvergence() {
    final settled = linkSettled;
    if (settled == null) return;
    final poll = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!_running || _phase != FieldPhase.dwelling) {
        t.cancel();
        return;
      }
      if (!_sendTargets().any((target) => settled(target.$2))) return;
      t.cancel();
      unawaited(recorder.logMarker('link-settled'));
    });
    _sendTimers.add(poll);
  }

  /// Saturating throughput mode: wait for the link to settle, then push for
  /// the rest of the dwell on [FieldStep.sendLanes] concurrent lanes, each
  /// looping "fire one, await it, fire the next".
  ///
  /// Nothing is ACK-gated — an ACK never clocks a send — so offered load is
  /// set purely by the lane count and how fast the send path drains. `sent`
  /// vs `delivered` therefore measures offered load against carried load, and
  /// the gap is the overrun, which is the honest way to find capacity: raise
  /// the lanes until delivery breaks.
  void _scheduleSaturating(FieldStep step) {
    _outstanding.clear();
    _satSeq = 0;
    _ackedCount = 0;
    _watchConvergence();
    final settled = sessionUp;
    void begin() {
      unawaited(recorder.logMarker('saturate-start'));
      final lanes = step.sendLanes < 1 ? 1 : step.sendLanes;
      for (var i = 0; i < lanes; i++) {
        unawaited(_pushLane(step));
      }
      _notify();
    }

    if (settled == null) {
      begin();
      return;
    }
    final poll = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!_running || _phase != FieldPhase.dwelling) {
        t.cancel();
        return;
      }
      if (!_sendTargets().any((target) => settled(target.$2))) return;
      t.cancel();
      unawaited(recorder.logMarker('session-up'));
      begin();
    });
    _sendTimers.add(poll);
  }

  /// Raw-throughput mode: wait for the link to settle, then push MTU-sized
  /// raw blobs on the step's leg for the rest of the dwell — one await-loop
  /// (the send path serializes at the platform channel anyway). No seal, no
  /// ACK, no buffering: offered bytes come from this counter, carried bytes
  /// from the RECEIVER's wire ledger.
  void _scheduleRaw(FieldStep step) {
    _rawBlobs = 0;
    _rawBytes = 0;
    final settled = linkSettled;
    void begin() {
      unawaited(recorder.logMarker('raw-start'));
      unawaited(_pushRaw(step));
      _notify();
    }

    if (settled == null) {
      begin();
      return;
    }
    final poll = Timer.periodic(const Duration(milliseconds: 500), (t) {
      if (!_running || _phase != FieldPhase.dwelling) {
        t.cancel();
        return;
      }
      if (!_sendTargets().any((target) => settled(target.$2))) return;
      t.cancel();
      unawaited(recorder.logMarker('link-settled'));
      begin();
    });
    _sendTimers.add(poll);
  }

  Future<void> _pushRaw(FieldStep step) async {
    final doSendRaw = sendRaw;
    if (doSendRaw == null) return;
    var seq = 0;
    while (_running && _phase == FieldPhase.dwelling && currentStep == step) {
      final targets = _sendTargets();
      var sentAny = false;
      for (final (_, pubkey) in targets) {
        final size = await doSendRaw(pubkey,
            leg: step.rawLeg!, seq: seq, sizeDelta: step.rawSizeDelta);
        if (size != null) {
          _rawBlobs++;
          _rawBytes += size;
          sentAny = true;
        }
      }
      seq++;
      // Same event-loop yield as the saturating lanes: a target-less or
      // failing send must not starve the dwell countdown (see _pushLane).
      await Future<void>.delayed(
          sentAny ? Duration.zero : const Duration(milliseconds: 200));
    }
  }

  /// One push lane: keep sending until the dwell ends, awaiting each send so
  /// the lane runs at exactly the rate the send path drains it. N lanes run
  /// concurrently, so N messages are in the send path at once.
  Future<void> _pushLane(FieldStep step) async {
    while (_running && _phase == FieldPhase.dwelling && currentStep == step) {
      await _fireSaturating(step);
      // Yield to the EVENT LOOP, not just the microtask queue. Awaiting a
      // send that never touches real I/O (no targets yet, an early return)
      // resolves as a microtask, and microtasks run ahead of timers — an
      // unbroken chain of them would starve the dwell countdown and the UI,
      // i.e. hang the app for the rest of the step. A zero-duration delay is
      // a timer, so the loop can always be interrupted. It costs one
      // event-loop turn (sub-millisecond) per message, which is ~1000/s —
      // far above anything BLE carries, so it does not cap the measurement.
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _fireSaturating(FieldStep step) async {
    final doSend = send;
    final plan = _plan;
    if (doSend == null || plan == null) return;
    if (!_running || _phase != FieldPhase.dwelling) return;
    final seq = _satSeq++;
    for (final (_, pubkey) in _sendTargets()) {
      final messageId = _uuid.v4();
      final payload = Uint8List(step.sendBytes);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (seq + i) & 0xff;
      }
      // Reserved first byte: testbed traffic must never look like a real
      // block class in the wire-byte breakdown.
      if (payload.isNotEmpty) payload[0] = testbedPayloadMarker;
      _outstanding.add(messageId);
      _sentCount++;
      // Awaited: in unlimited mode this IS the clock. In window mode the
      // caller does not await, so it behaves exactly as before.
      await doSend(pubkey, payload, messageId: messageId);
    }
  }

  /// End-to-end ACK feed from the coordinator. In saturating mode each ACK
  /// frees a window slot and immediately fires the next message.
  void onAck(String messageId) {
    if (!_outstanding.remove(messageId)) return;
    _ackedCount++;
    // An ACK only COUNTS here. It never triggers a send: clocking sends on
    // ACKs would cap the rate at lanes/RTT and make the experiment measure
    // its own window instead of the link.
    _notify();
  }

  void _queueSend(FieldStep step, int seq, int offsetSec) {
    _sendTimers.add(Timer(Duration(seconds: offsetSec), () {
      // One scheduled send is one message to EVERY target. The step's send
      // count is therefore a rate PER DESTINATION: at 1/s with seven peers a
      // device puts seven messages a second on the air, which is the load
      // model these experiments mean by "rate".
      final settled = sessionUp;
      for (final (_, pubkey) in _sendTargets()) {
        // Only at a target that can actually receive. The send path refuses a
        // peer with no session and records the refusal, which is correct for
        // it and wrong to provoke: a message aimed at a pair that has not
        // finished handshaking measures the runner's own timing, and lands in
        // the results as a delivery failure indistinguishable from one the
        // transport caused. The step waits for A target to settle before
        // sending, but settling is per pair — the rest of the clique can still
        // be mid-handshake when the first one is ready.
        if (settled != null && !settled(pubkey)) {
          _skippedSends++;
          continue;
        }
        final messageId = _uuid.v4();
        final payload = Uint8List(step.sendBytes);
        for (var i = 0; i < payload.length; i++) {
          payload[i] = (seq + i) & 0xff;
        }
        // Reserved first byte: testbed traffic must never look like a real
        // block class in the wire-byte breakdown.
        if (payload.isNotEmpty) payload[0] = testbedPayloadMarker;
        _sentCount++;
        unawaited(send!(pubkey, payload, messageId: messageId));
      }
      _notify();
    }));
  }

  /// Trailing rep suffix in a dial-grid label ('N=6 M=4 t7' -> 7).
  static final RegExp _repSuffix = RegExp(r'\bt(\d+)$');

  static int _repOf(String label) =>
      int.tryParse(_repSuffix.firstMatch(label)?.group(1) ?? '') ?? 1;

  /// The dial-grid cell's verdict, logged when its dwell closes: how many
  /// central legs this phone got to GATT-usable while the cap was M.
  ///
  /// The analyzer could count `link` records inside the marker window
  /// instead, and it does — but the two variables and the count belong
  /// together on one record, so a cell that established nothing is a row
  /// that SAYS zero rather than an absence indistinguishable from a phone
  /// that never ran the step.
  Future<void> _logDialCell(FieldStep step) async {
    final count = establishmentCount;
    if (count == null) return;
    await recorder.log({
      'type': 'dialcell',
      't': nowMs(),
      'step': step.label,
      if (joinOrder != null) 'order': joinOrder,
      if (step.cliqueN != null) 'popN': step.cliqueN,
      'maxParallel': step.maxParallelDials,
      'rep': _repOf(step.label),
      'dwellSec': step.dwellSec,
      'established': count(),
      // Whether the radio was actually up for this cell. Without it a zero is
      // ambiguous: `established: 0` from a cell with no working transport
      // reads identically to a cell where every dial was refused. A cell with radioUp false is not a
      // measurement and must be discarded, not averaged in.
      'radioUp': _radioUp,
    });
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _cancelSends() {
    for (final t in _sendTimers) {
      t.cancel();
    }
    _sendTimers.clear();
  }

  Future<void> _endDwell() async {
    _cancelSends();
    if (currentStep?.rawLeg != null) {
      await recorder.log({
        'type': 'flow',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'stop',
        'flow': 'raw',
        'leg': currentStep!.rawLeg,
        // The arm variable travels with the step summary so the analysis can
        // key sent-vs-arrived on it without re-deriving it from the label.
        'sizeDelta': currentStep!.rawSizeDelta,
        'sent': _rawBlobs,
        'sentBytes': _rawBytes,
      });
    }
    if ((currentStep?.saturate ?? false)) {
      await recorder.log({
        'type': 'flow',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'stop',
        'flow': 'saturate',
        'payloadBytes': currentStep!.sendBytes,
        'sendLanes': currentStep!.sendLanes,
        'sent': _satSeq,
        'acked': _ackedCount,
        'ackedBytes': _ackedCount * currentStep!.sendBytes,
      });
      _outstanding.clear();
    }
    _bleWatchdog?.cancel();
    _bleWatchdog = null;
    final step = currentStep;
    if (step != null && step.maxParallelDials != null) {
      await _logDialCell(step);
    }
    if (step != null && step.bulk) onStopBulk?.call();
    onWindowElapsed?.call();
    // Persist at the step boundary: between measurement windows, so the I/O
    // never lands inside one, and a killed run loses at most this step. The
    // state-of-charge flush only fires on long discharge runs — a stepped
    // run barely moves the battery and would otherwise hold everything in
    // memory until stop.
    await recorder.flush();
    final plan = _plan!;
    if (_stepIndex + 1 < plan.steps.length) {
      _stepIndex++;
      _enterPositioning();
      return;
    }
    // Last step done. Reset once more BEFORE stamping `end`: the segment a
    // step marker opens runs to the next marker, so every other run's tail was
    // already cut by the following reset, and closing this one without the
    // same cut would leave the last run the only one whose tail still counted.
    await _runResets(plan.steps.last);
    await recorder.logMarker('end');
    _phase = FieldPhase.settling;
    _startCountdown(plan.settleSec, _finish);
    _notify();
  }

  /// The battery reached the floor where Android's saver engages. This is a
  /// SUCCESSFUL end — the run collected what it came for — so it settles and
  /// uploads like a normal finish rather than aborting.
  Future<void> _finishAtFloor(int level) async {
    if (!_running) return;
    _batteryFloorLevel = level;
    _cancelSends();
    _bleWatchdog?.cancel();
    _bleWatchdog = null;
    _tick?.cancel();
    _tick = null;
    _absFire?.cancel();
    _absFire = null;
    _btProbe?.cancel();
    _btProbe = null;
    _btSub?.cancel();
    _btSub = null;
    final step = currentStep;
    if (step != null && step.bulk) onStopBulk?.call();
    onWindowElapsed?.call();
    await recorder.logMarker('end');
    await _finish();
  }

  /// State of charge at which a discharge run ended, or null if it did not
  /// end that way. The screen shows it instead of a plain completion.
  int? get batteryFloorLevel => _batteryFloorLevel;
  int? _batteryFloorLevel;

  /// True from the moment the settle window closes until the run is fully
  /// wrapped up. Stopping writes the whole buffered run to disk and the
  /// upload chunks it to the server, which on a large trace takes minutes —
  /// during which the phase is still `settling` and the countdown reads
  /// 00:00. Without this the screen looks wedged, so the UI renders a
  /// distinct state and offers [forceFinish].
  bool get finishing => _finishing;
  bool _finishing = false;

  /// What the wrap-up is doing right now, for the screen.
  String get finishingWhat => _finishingWhat;
  String _finishingWhat = '';

  /// Upload progress: chunks that have landed, and the fraction of the file
  /// consumed. Null fraction means no upload is running yet.
  int get uploadChunks => _uploadChunks;
  double? get uploadFraction => _uploadFraction;
  int _uploadChunks = 0;
  double? _uploadFraction;

  /// Put the transport's dial cap back where production keeps it. Called on
  /// EVERY exit — normal finish, battery floor, forced finish, abort, dispose
  /// — because a run that ended with the cap left at 1 would leave the phone
  /// dialing one peer at a time until the app is restarted, and nothing else
  /// ever writes that field back.
  void _restoreDialCap() {
    onSetDialParallelism?.call(maxParallel: null, popN: null);
  }

  Future<void> _finish() async {
    recorder.onBatteryFloor = null;
    _finishing = true;
    _finishingWhat = 'writing the recording to disk';
    _notify();
    await recorder.stopExperiment();
    if (!_running) return; // forceFinish won the race
    onWindowElapsed?.call();
    final doUpload = upload;
    if (doUpload != null) {
      _finishingWhat = 'uploading';
      _uploadFraction = 0;
      _notify();
      // Progress in bytes read, not chunks: the chunk total is not knowable
      // in advance because the file is streamed. The bar is honest from the
      // first chunk; the chunk count beside it shows work actually landing.
      recorder.onUploadProgress = (file, chunks, fraction) {
        _uploadChunks = chunks;
        _uploadFraction = fraction;
        _finishingWhat = 'uploading — chunk $chunks, '
            '${(fraction * 100).clamp(0, 100).toStringAsFixed(0)}%';
        _notify();
      };
      try {
        _uploadResult = await doUpload();
      } catch (_) {
        _uploadResult = 'Upload failed — files kept on device';
      } finally {
        recorder.onUploadProgress = null;
      }
    } else {
      _uploadResult = 'No upload configured — share files manually';
    }
    if (!_running) return;
    _finishing = false;
    _phase = FieldPhase.finished;
    _running = false;
    _restoreDialCap();
    _notify();
  }

  /// Stop waiting for the wrap-up and mark the run finished.
  ///
  /// The recording is already on disk by the time an upload is running, so
  /// this only abandons the WAIT — never the data. Anything still in flight
  /// completes in the background and its result is discarded; the files stay
  /// on the device and can be uploaded or shared from the testbed screen.
  /// Exists because a phone showing `SETTLING 00:00` mid-upload is
  /// indistinguishable from a wedged one, and a field day cannot wait to
  /// find out which.
  Future<void> forceFinish() async {
    if (!_running) return;
    _cancelSends();
    _bleWatchdog?.cancel();
    _bleWatchdog = null;
    _tick?.cancel();
    _tick = null;
    _absFire?.cancel();
    _absFire = null;
    _btProbe?.cancel();
    _btProbe = null;
    _btSub?.cancel();
    _btSub = null;
    recorder.onBatteryFloor = null;
    recorder.onUploadProgress = null;
    // Stop the recording if the wrap-up had not got that far, so the buffer
    // reaches disk either way.
    try {
      await recorder.stopExperiment();
    } catch (_) {/* already stopped */}
    _uploadResult ??= 'Finished early — files kept on device, upload from '
        'the testbed screen';
    _finishing = false;
    _phase = FieldPhase.finished;
    _running = false;
    _restoreDialCap();
    _notify();
  }

  /// Abandon the run: marker the abort, stop bulk + recording. Files stay.
  Future<void> abort() async {
    if (!_running) return;
    _cancelSends();
    _bleWatchdog?.cancel();
    _bleWatchdog = null;
    _tick?.cancel();
    _tick = null;
    _absFire?.cancel();
    _absFire = null;
    _btProbe?.cancel();
    _btProbe = null;
    _btSub?.cancel();
    _btSub = null;
    final step = currentStep;
    if (step != null && step.bulk && _phase == FieldPhase.dwelling) {
      onStopBulk?.call();
    }
    recorder.onBatteryFloor = null;
    await recorder.logMarker('aborted');
    // Captured BEFORE the stop clears it, and it is the id the recorder
    // actually used rather than the plan's: the abandoned file has to go or
    // it uploads alongside real runs under the same id prefix.
    final abandoned = recorder.experimentId;
    await recorder.stopExperiment();
    if (abandoned != null) {
      final gone = await recorder.discardAbortedExperiment(abandoned);
      if (gone != null) debugPrint('[field] aborted run deleted: $gone');
    }
    _phase = FieldPhase.finished;
    _running = false;
    _restoreDialCap();
    _notify();
  }

  void _startCountdown(int seconds, Future<void> Function() onDone) {
    _tick?.cancel();
    _absFire?.cancel();
    _absFire = null;
    _remainingSec = seconds;
    if (seconds <= 0) {
      unawaited(onDone());
      return;
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      _remainingSec--;
      if (_remainingSec <= 0) {
        t.cancel();
        _tick = null;
        unawaited(onDone());
      }
      _notify();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelSends();
    _bleWatchdog?.cancel();
    _bleWatchdog = null;
    _tick?.cancel();
    _tick = null;
    _absFire?.cancel();
    _absFire = null;
    _btProbe?.cancel();
    _btProbe = null;
    _btSub?.cancel();
    _btSub = null;
    _restoreDialCap();
    super.dispose();
  }
}

Uint8List? _hexToBytes(String hex) {
  final clean = hex.trim().toLowerCase();
  if (clean.isEmpty || clean.length.isOdd || clean.length < 64) return null;
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final b = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}
