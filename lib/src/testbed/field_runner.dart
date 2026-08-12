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
  /// marker and sends wait until the transport is back up.
  final Future<void> Function()? onResetLinks;

  /// Empties the DTN memory buffer (per-step, when the plan asks) so a prior
  /// step's undelivered backlog cannot drain into this step's window.
  final VoidCallback? onResetDtnBuffer;

  /// DEBUG/TESTBED ONLY. Lift or restore the per-neighbour relay cap for the
  /// run, from [FieldPlan.relayBudgetDisabled]. Applied once at start and
  /// stamped as a marker, so the trace says which arm it is.
  final void Function(bool disabled)? onSetRelayBudgetDisabled;

  /// Sets the BLE transport up/down for steps that script it
  /// ([FieldStep.bleOn]). Awaited before the step marker so every power
  /// sample inside the segment sees the requested state.
  final Future<void> Function(bool on)? onSetBle;

  /// Takes ONE GPS fix, returning `{lat, lon, accM}` or null if location is
  /// unavailable or refused. Called only when the phone was actually placed
  /// (see [inPosition]), never on a timer, so it costs one radio wake per
  /// run rather than showing up in the power measurements. A null result is
  /// not an error: the run continues without a position, and the topology
  /// viewer falls back to a schematic layout.
  final Future<Map<String, Object?>?> Function()? onSampleLocation;

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
      {required String leg, required int seq})? sendRaw;

  /// Currently identified peers (pubkeys), consulted when the plan has NO
  /// roster: every known peer becomes a send target and labels are the 8-hex
  /// pubkey prefixes — the two-device case needs no manual pubkey entry.
  /// Resolved lazily at each send so a peer discovered mid-run still counts.
  final List<Uint8List> Function()? knownPeers;

  /// Whether the pair with a peer is settled for data (session + converged
  /// dual-leg link). When provided, each step's sends wait for a settled
  /// target and then spread across the REMAINING dwell — messages never race
  /// a re-forming link. If no target settles within the dwell, no sends fire
  /// (correct at an out-of-range step). Null: legacy fixed-offset schedule.
  final bool Function(Uint8List peer)? linkSettled;

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
    this.onSetRelayBudgetDisabled,
    this.onSetBle,
    this.onSampleLocation,
    this.bleWireBytes,
    this.bleUsable,
    this.bleUsableChanges,
    this.bleWatchdogSec = 30,
    this.sendRaw,
    this.knownPeers,
    this.linkSettled,
    this.upload,
    this.onWindowElapsed,
  });

  FieldPlan? _plan;

  /// Identifies THIS run among runs sharing an experiment id.
  ///
  /// Stamped on every step marker so an analysis can segment two runs that
  /// were recorded under one id — the recorder appends, so that happens
  /// whenever an id is reused. It does NOT seed message ids: those are v4,
  /// the same as production. Deterministic ids used to repeat across runs of
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

  /// DEBUG/TESTBED. Wait for a peer's run-start signal instead of a tap.
  ///
  /// A field run puts phones hundreds of metres apart. Tapping each is
  /// impractical, and tapping them in sequence skews their timelines by the
  /// walk itself, which smears the mesh composition at every step boundary.
  /// Arming holds the plan; the coordinator's signal handler calls
  /// [remoteStart], which begins the run AND passes the first step
  /// immediately — the phone is already where it is going to be.
  ///
  /// The armed id is checked against the signal's, so a stray or stale
  /// broadcast cannot launch a run nobody asked for, and an unarmed device
  /// ignores the signal entirely.
  void armForRemoteStart(FieldPlan plan) {
    if (_running) return;
    _armed = plan;
    // The signal arrives over BLE, so the radio must be UP to hear it — even
    // on a device whose first step will immediately turn it off again
    // (roles 4+ are not in the mesh at n=3). A previous run that ended with
    // the radio down would otherwise leave this phone permanently deaf to
    // the start, and it would sit armed forever while the others ran.
    unawaited(onSetBle?.call(true) ?? Future<void>.value());
    notifyListeners();
  }

  void disarm() {
    _armed = null;
    notifyListeners();
  }

  /// The plan waiting for a peer's signal, or null.
  FieldPlan? get armedPlan => _armed;
  FieldPlan? _armed;

  /// A peer signalled a start. Runs only when armed for this exact
  /// experiment. Returns whether it took effect.
  Future<bool> remoteStart(String expId) async {
    final plan = _armed;
    if (plan == null || _running) return false;
    if (plan.expId != expId) {
      debugPrint('[testbed] ignoring start for "$expId" — armed for '
          '"${plan.expId}"');
      return false;
    }
    _armed = null;
    _remotelyStarted = true;
    await start(plan);
    // No tap is coming: the signal IS the tap, and every phone is already
    // in position.
    await inPosition();
    return true;
  }

  /// Whether this run was begun by a peer's signal rather than a tap —
  /// shown on screen so an unexpected launch is never a mystery.
  bool get remotelyStarted => _remotelyStarted;
  bool _remotelyStarted = false;

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
    // A discharge plan ends on state of charge, not on the clock: its step
    // dwell is deliberately longer than the battery can last, and this is
    // what actually stops it.
    recorder.onBatteryFloor = (level) => unawaited(_finishAtFloor(level));
    _plan = plan;
    _stepIndex = 0;
    _uploadResult = null;
    _abortReason = null;
    _batteryFloorLevel = null;
    _armed = null;
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
    if (onSetRelayBudgetDisabled != null) {
      onSetRelayBudgetDisabled!.call(plan.relayBudgetDisabled);
      if (plan.relayBudgetDisabled) {
        await recorder.logMarker('relay-budget-disabled');
      }
    }
    if (plan.manualJoin) {
      // Anchor on the wall clock, not the tap: every phone rounds up to the
      // same 10-minute boundary, so the start skew collapses to clock-sync
      // error instead of the spread of eight taps. The boundary granularity
      // must exceed the tap spread — 10 min covers taps a few minutes apart.
      final alignMs = plan.alignSec * 1000;
      final minStart = nowMs() + plan.placementSec * 1000;
      final anchor = ((minStart + alignMs - 1) ~/ alignMs) * alignMs;
      _anchorMs = anchor;
      // Every phone computes the same anchor, so it also gives every phone the
      // same run id — ids stay comparable across the fleet, as they must be.
      _runId = anchor;
      final starts = <int>[];
      var t = anchor;
      for (final st in plan.steps) {
        starts.add(t);
        t += (st.dwellSec + plan.autoAdvanceGapSec) * 1000;
      }
      _stepStartMs = starts;
      // The target in the trace is the alignment proof: after the run, one
      // query shows whether all phones computed the same instant.
      await recorder.logMarker('placement', extra: {
        'targetMs': anchor,
        if (plan.deviceOrder != null) 'order': plan.deviceOrder,
        if (myNickname != null && myNickname!.isNotEmpty) 'nick': myNickname,
      });
      _startRadioObserver();
      _phase = FieldPhase.placement;
      _countdownToMs(anchor, () => inPosition(manual: false));
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
        if (_plan?.deviceOrder != null) 'order': _plan!.deviceOrder,
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
      // The gap counts down to the next step's ABSOLUTE start. This gap is
      // also the join window: the phone whose first joined step is next
      // shows TURN ON BLUETOOTH for exactly this long.
      _countdownToMs(_stepStartMs![_stepIndex], () => inPosition(manual: false));
    } else if (currentStep?.autoAdvance ?? false) {
      // A timer firing is not the operator putting the phone down, so it
      // must not be mistaken for one when deciding to take a GPS fix.
      _startCountdown(_plan!.autoAdvanceGapSec, () => inPosition(manual: false));
    }
    _notify();
  }

  /// The experimenter reached the current step's position: drop sessions
  /// (when the plan asks), stamp the ground-truth marker, hold the dwell,
  /// and run the step's sends spread through it.
  /// [manual] distinguishes the operator tapping IN POSITION from the
  /// auto-advance timer firing. Only the former means the phone was just
  /// placed or moved, which is the only time a GPS fix is worth taking.
  Future<void> inPosition({bool manual = true}) async {
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
    if (_plan!.resetLinks && onResetLinks != null) {
      _resetting = true;
      _notify();
      await onResetLinks!.call(); // BLE bounce; wait for the transport back up
      _resetting = false;
      _notify();
      await recorder.logMarker('links-reset');
    }
    if ((step.resetSessions ?? _plan!.resetSessions) &&
        onResetSessions != null) {
      onResetSessions!.call();
      await recorder.logMarker('sessions-reset');
    }
    if ((step.resetDtnBuffer ?? _plan!.resetDtnBuffer) &&
        onResetDtnBuffer != null) {
      onResetDtnBuffer!.call();
      await recorder.logMarker('custody-reset');
    }
    // ONE fix, at placement. The first measured step is the moment the phone
    // is finally where it belongs (the `distribute` walk-out is when it is
    // still being carried), and a manual tap after that means it was moved.
    // Never on an auto-advanced step: the phone has not moved, and a GPS
    // radio waking 60 times would show up in the power numbers.
    // Never on the walk-out: a manual tap THERE starts the walk, it does not
    // end it. Otherwise: the first measured step (just placed), or any later
    // manual tap (moved).
    final placed = step.label != 'distribute' && (manual || _locationFixes == 0);
    if (onSampleLocation != null && placed && _plan!.sampleGps) {
      _locationFixes++;
      _locationFixing = true;
      _notify();
      // NOT awaited. A good fix can take a minute of acquisition, and the
      // step must not wait for it — the position is metadata about where the
      // phone is, not a precondition for measuring.
      unawaited(onSampleLocation!.call().then((fix) async {
        _locationFixing = false;
        _lastFix = fix;
        _notify();
        if (fix != null) {
          await recorder.log({
            'type': 'location',
            't': DateTime.now().millisecondsSinceEpoch,
            'step': step.label,
            ...fix,
          });
        }
      }));
    }

    // The step marker carries this phone's CONFIGURED intent, not just the
    // step name: which join slot it was assigned and whether it believed it
    // was in the mesh for this step. Analysis can then tell a misconfigured
    // phone from one that was configured right and failed to join — from the
    // marker alone, without inferring it from when links first appear.
    await recorder.logMarker(step.label, extra: {
      if (_plan!.deviceOrder != null) 'order': _plan!.deviceOrder,
      if (step.bleOn != null) 'joined': step.bleOn,
      if (sessionPeerCount != null) 'sessions': sessionPeerCount!(),
      if (sessionTableCount != null)
        'sessionTable': sessionTableCount!(),
      if (_runId != null) 'run': _runId,
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

  String get _srcLabel {
    final me = myPubkeyHex?.toLowerCase();
    final plan = _plan!;
    if (plan.roster.isNotEmpty && me != null) {
      final mine =
          plan.roster.where((r) => r.pubkeyHex.toLowerCase() == me).firstOrNull;
      if (mine != null) return mine.label;
    }
    return me == null ? 'src' : me.substring(0, 8);
  }

  /// Schedule [FieldStep.sendCount] messages for this step. With a
  /// [linkSettled] predicate: poll until some target's pair is settled
  /// (session + converged dual-leg), stamp a `link-settled` marker, then
  /// spread the sends across the REMAINING dwell — data never races a
  /// re-forming link, and an out-of-range step sends nothing. Without the
  /// predicate: legacy fixed offsets from dwell start. Targets resolve at
  /// fire time; message ids are v4, matching production.
  void _scheduleSends(FieldStep step) {
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
    final settled = linkSettled;
    if (settled == null) {
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
          _sendTargets().any((target) => settled(target.$2));
      if (!ready) return;
      t.cancel();
      unawaited(recorder.logMarker('link-settled'));
      // Spread the step's sends across what remains of the dwell.
      final windowSec = _remainingSec > 2 ? _remainingSec - 2 : _remainingSec;
      for (var seq = 0; seq < step.sendCount; seq++) {
        _queueSend(step, seq, (seq * windowSec) ~/ step.sendCount);
      }
      _notify();
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
    final settled = linkSettled;
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
      unawaited(recorder.logMarker('link-settled'));
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
        final size =
            await doSendRaw(pubkey, leg: step.rawLeg!, seq: seq);
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
    for (final (dstLabel, pubkey) in _sendTargets()) {
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
      for (final (_, pubkey) in _sendTargets()) {
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
    // Last step done — settle, then stop + upload.
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
  /// How many GPS fixes this run has taken — the guard that keeps placement
  /// sampling from becoming a stream.
  int get locationFixes => _locationFixes;
  int _locationFixes = 0;

  /// One line about this phone's position, for the runner screen. Whether a
  /// fix was taken is otherwise invisible until the data is on a server,
  /// which is far too late to notice that eight phones recorded nothing.
  String get locationStatus {
    if (onSampleLocation == null) return '';
    if (_locationFixing) return 'getting a GPS fix…';
    if (_lastFix == null) {
      return _locationFixes == 0
          ? 'position: taken when this phone is placed'
          : 'position: NO FIX — check location permission';
    }
    final acc = _lastFix!['accM'];
    return 'position fixed'
        '${acc is num ? ' ±${acc.round()} m' : ''}';
  }

  /// Whether this runner was wired to sample position at all.
  bool get hasLocation => onSampleLocation != null;

  Map<String, Object?>? get lastFix => _lastFix;
  Map<String, Object?>? _lastFix;
  bool _locationFixing = false;

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
    // Captured BEFORE the stop clears it: the abandoned file has to be set
    // aside under its own id, or the next arm appends the real run to it.
    final abandoned = recorder.experimentId;
    await recorder.stopExperiment();
    if (abandoned != null) {
      final moved = await recorder.archiveAbortedExperiment(abandoned);
      if (moved != null) debugPrint('[field] aborted run set aside: $moved');
    }
    _phase = FieldPhase.finished;
    _running = false;
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
