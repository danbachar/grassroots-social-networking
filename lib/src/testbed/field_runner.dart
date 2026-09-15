import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../trace/experiment_recorder.dart';
import '../models/block.dart';
import 'ring_topology.dart';
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
///   [dwelling] → next step … →
///   `end` marker → [settling] → recording off → upload → [finished].
///
/// Pure sequencing — the screen renders [phase]/[remainingSec] and calls
/// [start] / [inPosition] / [abort]. All side effects go through injected
/// callbacks so the machine is testable with fake timers.
class FieldRunner extends ChangeNotifier {
  final ExperimentRecorder recorder;

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

  /// Message send hook (the coordinator's `send`). Only ever called for a
  /// peer holding a session — the round skips the rest, because the send
  /// path refuses a sessionless peer and creates nothing.
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
  final Future<void> Function(int? darkSec,
      {Future<void> Function()? whileDark, int? untilMs})?
      onResetLinks;

  /// Empties the DTN memory buffer (per-step, when the plan asks) so a prior
  /// step's undelivered backlog cannot drain into this step's window.
  final VoidCallback? onResetDtnBuffer;

  /// DEBUG/TESTBED. Arm or disarm the ring-radius link gate for a step.
  ///
  /// Called with the plan's roster and the step's [FieldStep.ringRadius]; a
  /// null radius disarms. Applied BEFORE [onSeverLinks], so the prune runs
  /// while the gate is armed and surviving links cannot re-dial under the old
  /// radius in the gap.
  final Future<void> Function(List<String> rosterHex, int? radius)?
      onSetRingGate;

  /// DEBUG/TESTBED. Sever every GATT link, keeping sessions, DTN buffers and
  /// seen-sets. NOT the BLE bounce ([onResetLinks]).
  final Future<void> Function()? onSeverLinks;

  /// Sets the BLE transport up/down for steps that script it
  /// ([FieldStep.bleOn]). Awaited before the step marker so every power
  /// sample inside the segment sees the requested state.
  final Future<void> Function(bool on)? onSetBle;

  /// The SYSTEM Bluetooth toggle's last known state (null = never learned).
  /// The one radio state the app cannot fix itself — the waiting screen
  /// warns the operator off it, BEFORE the join it would ruin.
  final bool? Function()? systemBtOn;

  /// One-shot refresh of [systemBtOn]'s source, called at schedule instants
  /// (placement, every positioning entry) — never on a timer.
  final Future<void> Function()? refreshSystemBt;

  /// [systemBtOn], for the screens.
  bool? get systemBt => systemBtOn?.call();

  /// Whether the BLE transport is up and usable. Holds with no peer in range,
  /// which is what makes it the primary liveness check for a scripted radio
  /// bring-up: a ladder step can legitimately bring the radio up ALONE.
  final bool Function()? bleUsable;

  /// Whether the radio is up but not on the air. Surfaced on the runner
  /// screen: a phone nobody can find looks identical to a phone out of range
  /// until the files come back, and by then the run is spent.
  final bool Function()? bleUndiscoverable;

  /// How many BLE legs this phone currently holds ready, or null where the
  /// host cannot say.
  ///
  /// Surfaced on the runner screen because it is the one number that says
  /// whether a trial is measuring the topology it asked for. A radius permits
  /// a leg count; the radio delivers whatever it can hold under the traffic,
  /// and the two have been measured a factor of three apart. Reading it off
  /// the phone is what lets a sweep be abandoned in its first trial rather
  /// than its last.
  final int Function()? legsReady;

  /// BLE-usability TRANSITIONS, emitted at the transport-state change
  /// itself. The `bt-on`/`bt-off` markers are stamped exclusively from this
  /// stream: a marker timestamp is the instant the BLE service became
  /// ready (or died), never the instant a poll noticed it. Analysis code
  /// may treat bt-on as exact — no session can predate its own bt-on.
  final Stream<bool>? bleUsableChanges;

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
  /// target and then run at the FULL dwell's pace until the dwell ends —
  /// messages never race a re-forming link, and a late settle sends FEWER,
  /// never faster. If no target settles within the dwell, no sends fire
  /// (correct at an out-of-range step). Null: legacy fixed-offset schedule.
  final bool Function(Uint8List peer)? linkSettled;

  /// Fires the instant a peer's pair becomes settled. Completes
  /// [linkSettled] the way [sessionEvents] completes [sessionUp]: without it
  /// the `link-settled` stamp carries the poll period rather than the
  /// convergence. Null falls back to polling.
  final Stream<Uint8List>? linkSettledEvents;

  /// Whether a Noise session with this peer exists. This is what a send is
  /// gated on — a session is the whole requirement for addressing a peer, and
  /// [linkSettled] additionally wants both GATT legs, which a pair at the far
  /// end of a line sweep may never get. Gating sends on convergence there
  /// records a runner that declined to send as a range the radio could not
  /// reach.
  final bool Function(Uint8List peer)? sessionUp;

  /// Fires the instant a Noise session is established with any peer.
  ///
  /// [sessionUp] answers "does a session exist now?"; this says when one
  /// starts existing. Without it a waiter has to poll, which costs the step
  /// up to a poll period of send time and — worse — puts that period into
  /// the `session-up` stamp, so establishment latency reads back quantised
  /// to the poll grid instead of measured. Null falls back to polling.
  final Stream<Uint8List>? sessionEvents;

  /// Dial grid: cap the transport's in-flight central dials at [maxParallel]
  /// (null restores the production cap) and stamp [popN] on the
  /// establishments that follow, so each one is attributable to its cell.
  ///
  /// The grid does not script dials. The transport dials greedily on its
  /// own and tops up as slots free; this hook only moves the bound the
  /// transport already enforces, which is why M is a real independent
  /// variable and not a burst size we chose.
  final void Function({int? maxParallel, int? popN})? onSetDialParallelism;

  /// Record every advertisement sighting for the duration of the test, per
  /// [FieldPlan.traceEveryAdvertisement]. Set once at start and restored at
  /// finish — it is a property of the TEST, not of a step, so it must not
  /// change between runs and become a variable nobody declared.
  final void Function(bool every)? onSetTraceEveryAdvertisement;

  /// Ask the radio for the fast connection interval, or hand it back.
  ///
  /// Raised for a SETTLE step and lowered for every other one. A settle is
  /// the window where newly permitted links have to form, and establishment
  /// — MTU, discovery, subscribe, ANNOUNCE, the Noise flights — is a chain of
  /// round trips costing one connection interval each, so the fast interval
  /// is what makes it quick. It is not worth its price for the traffic
  /// afterwards: the cost is the controller's, paid on every leg holding it
  /// for as long as it holds it, and a fleet that held it on every leg for a
  /// whole run had dials refused with status 133 against live advertised
  /// addresses for tens of minutes at a time.
  final void Function(bool high)? onSetConnectionPriority;

  /// Set the fragment spacing for a step, or restore the production default
  /// when the step does not ask for one. See [FieldStep.fragmentDelayMs].
  final void Function(int? ms)? onSetFragmentDelay;

  /// Deliver without acknowledging, for a one-directional run. Applied once
  /// at launch from [FieldPlan.suppressAcks].
  final void Function(bool on)? onSetSuppressAcks;

  /// Silence everything that is not payload for the run. See
  /// [FieldPlan.quietLink].
  final Future<void> Function(bool on)? onSetQuietLink;

  /// Suspend eviction of quiet peers for the whole run. See
  /// [FieldPlan.quietLink].
  final void Function(bool on)? onSetStaleSweepSuspended;

  /// Message ids whose end-to-end acknowledgement came home. Feeds [onAck],
  /// which is how a saturating step reports carried load against offered.
  final Stream<String>? ackEvents;

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

  /// Apply [FieldPlan.dtnMaxBytes] to the DTN store when a plan starts.
  ///
  /// A run that never purges its buffer needs a bound, and the bound has to
  /// be the one the plan declares rather than whatever the build shipped, or
  /// the recording cannot say what the buffer was held to.
  final void Function(int bytes)? onSetDtnMaxBytes;

  /// Peers this phone holds a ready LINK to, stamped into every step marker
  /// as `links`.
  ///
  /// Distinct from [sessionPeerCount]: a session outlives the link that
  /// formed it, so the two diverge exactly when a run is interesting, and a
  /// link count reconstructed afterwards from link records is wrong in both
  /// directions -- an open that carries no peer is missed, a close that is
  /// never logged is never applied. The transport knows its own answer, so
  /// the marker carries it.
  final int Function()? linkPeerCount;

  /// Sessions held in the Noise table itself, stamped as `sessionTable`.
  ///
  /// [sessionPeerCount] counts only sessions whose peer is still listed in
  /// Redux, and a quiet non-friend peer is pruned from that list while its
  /// session lives on — so `sessions` is a LOWER BOUND that dips when links
  /// go quiet, which is precisely when a field run is most interesting. The
  /// pair of numbers separates a lost session from a delisted peer; one of
  /// them alone cannot.
  final int Function()? sessionTableCount;

  /// The identities this device holds a Noise session with, lowercase hex —
  /// the ring roster's source when [FieldPlan.ringRosterFromSessions] is set.
  final Iterable<String> Function()? sessionPeerHexes;

  /// The ring the gate is being driven with: either the plan's compiled
  /// roster, or the one frozen from the session table at launch.
  ///
  /// Read on every reset slot rather than recomputed, so a session dropped
  /// mid-run cannot reshape the topology under the gate.
  List<String> _ringRoster = const [];

  String _ringFp = '';

  /// The frozen ring's fingerprint: 8 hex characters over the FULL pubkeys,
  /// empty when no ring is in force.
  ///
  /// Whether the fleet derived the same ring is not decidable on one phone
  /// (see [FieldPlan.ringRosterFromSessions]), so this is the cross-check that
  /// IS available — every phone shows one short token at launch and the
  /// operator compares them while the fleet is still in their hands. Comparing
  /// the ring lists themselves works too, and is what the trace does; a person
  /// holding four phones will not reliably diff four lists of eight-hex
  /// prefixes, and will spot two tokens that differ.
  String get ringFingerprint => _ringFp;

  /// The ring fields every marker carries: the ring as 8-hex labels and the
  /// fingerprint over the full pubkeys.
  ///
  /// On EVERY marker rather than only the launch one, because a run that dies
  /// before its first step still has to say what ring it froze, and because a
  /// per-marker field makes the fleet-agreement check one query over whatever
  /// records survived.
  Map<String, Object?> _ringMarkerFields() => _ringRoster.isEmpty
      ? const {}
      : {
          // Truncated defensively rather than with a bare substring: an entry
          // is normally a 64-hex pubkey, but nothing here enforces that and a
          // short one must not take the whole marker — and so the step — down.
          'ring': [
            for (final h in _ringRoster) h.length <= 8 ? h : h.substring(0, 8),
          ],
          'ringFp': _ringFp,
        };

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
    this.onSetDtnMaxBytes,
    this.linkPeerCount,
    this.sessionTableCount,
    this.sessionPeerHexes,
    this.myPubkeyHex,
    this.myNickname,
    this.send,
    this.onResetSessions,
    this.onResetLinks,
    this.onResetDtnBuffer,
    this.onSetRingGate,
    this.onSeverLinks,
    this.onSetBle,
    this.systemBtOn,
    this.refreshSystemBt,
    this.bleUsable,
    this.bleUndiscoverable,
    this.legsReady,
    this.bleUsableChanges,
    this.knownPeers,
    this.linkSettled,
    this.sessionUp,
    this.sessionEvents,
    this.linkSettledEvents,
    this.onSetDialParallelism,
    this.onSetTraceEveryAdvertisement,
    this.onSetConnectionPriority,
    this.onSetFragmentDelay,
    this.onSetSuppressAcks,
    this.onSetQuietLink,
    this.onSetStaleSweepSuspended,
    this.ackEvents,
    this.establishmentCount,
    this.onResetEstablishmentCount,
    this.upload,
    this.onWindowElapsed,
  });

  FieldPlan? _plan;

  /// Identifies THIS run among runs sharing an experiment id.
  ///
  /// Stamped on every step marker so an analysis can segment two runs that
  /// were recorded under one id — the recorder refuses a reused id by
  /// suffixing to a free one, so ids stay one-run. It does NOT seed message ids: those are v4,
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

  /// The one pacing timer of the current dwell (see [_runSendTicker]).
  Timer? _sendTicker;

  /// Send-phase jitter for [_runPerPairTickers]. Deliberately NOT seeded: the
  /// point is to decorrelate each pair's sends from the announce cycle, and
  /// from every other device's, which a shared seed would undo.
  final math.Random _sendJitter = math.Random();

  /// Absolute end of the current dwell, set before sends are scheduled so
  /// the pacing window never reads a stale countdown.
  int? _dwellEndsAtMs;

  /// A dwell wants the radio on and still holds no session well past
  /// establishment time. Two distinct causes end up here: the service
  /// reports usable but is deaf (a zombie — up, no peer reached), or the
  /// service never reports usable at all (most often system Bluetooth is
  /// off — the app cannot turn that on, only the operator can). Surfaced on
  /// screen and as a marker either way, never an abort: one phone's trouble
  /// must not end a seven-phone run. [radioSuspectReason] tells the two
  /// apart for the banner and the trace.
  bool _radioSuspect = false;
  bool get radioSuspect => _radioSuspect;
  String? _radioSuspectReason; // 'adapterOff' | 'sessionless'
  String? get radioSuspectReason => _radioSuspectReason;
  static const int _radioSuspectGraceSec = 20;
  bool _radioSuspectStamped = false;
  final List<StreamSubscription<Uint8List>> _sessionWaits = [];
  int _sentCount = 0;

  /// Saturating mode only: messages fired, acknowledged, and still in flight.
  ///
  /// `_outstanding` is what makes `sent` against `acked` meaningful — offered
  /// load against carried load — and the gap between them is the overrun that
  /// finds the ceiling.
  int _satSeq = 0;
  int _ackedCount = 0;
  final Set<String> _outstanding = {};

  /// Sends not attempted because the target pair was not settled yet. Reported
  /// so a step that fired few messages is distinguishable from one whose
  /// messages failed.
  int _skippedSends = 0;

  /// [_sentCount] at the current segment's start; run-end logs the delta.
  int _sentAtSegStart = 0;
  bool _resetting = false;
  String? _abortReason;

  /// Manual-join wall-clock schedule: the shared start instant and each
  /// step's absolute start, precomputed so 61 steps cannot accumulate the
  /// drift of chained one-second timers.
  int? _anchorMs;
  List<int>? _stepStartMs;
  Timer? _absFire;
  /// One recovery bounce per down-edge; re-armed by the next up-edge.
  bool _bounced = false;

  /// The zombie-radio deadline of the current dwell (see
  /// [_armRadioSuspectCheck]) and the session listener that clears the
  /// banner.
  Timer? _radioSuspectTimer;

  StreamSubscription<Uint8List>? _suspectClear;
  StreamSubscription<bool>? _btSub;
  StreamSubscription<String>? _ackSub;
  bool _btOnSeen = false;
  bool _radioUp = false;
  // Operator stack-reset verification for the open placement/walk window:
  // down then up observed while the window is open. The runner's own
  // scripted resets are excluded via [_resetting].
  bool _resetDownSeen = false;
  bool _resetCycleDone = false;

  /// ACKed sends in the current saturating step (throughput numerator).

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
  /// its first joined step. Null until a manual test is started.
  int? get myJoinAtMs {
    final plan = _plan, starts = _stepStartMs;
    if (plan == null || starts == null) return null;
    for (var i = 0; i < plan.steps.length && i < starts.length; i++) {
      if (plan.steps[i].bleOn == true) return starts[i];
    }
    return null;
  }

  /// When the whole plan is over: the last step's dwell end plus its
  /// derived drain. This is what a phone with nothing to do counts down to,
  /// so the screen answers "how long until this is finished" rather than
  /// timing a step boundary nobody has to act on. Null outside a manual
  /// run, where there is no wall-clock schedule to read it off.
  int? get planEndMs {
    final plan = _plan, starts = _stepStartMs;
    if (plan == null || starts == null || starts.isEmpty) return null;
    final last = plan.steps.last;
    return starts.last + (last.dwellSec + plan.gapAfterSec(last)) * 1000;
  }

  /// Whether the plan asks the operator to cycle the whole Bluetooth stack
  /// at every position, and whether the radio currently reads up — the
  /// screens pair the instruction with live feedback so a toggle that did
  /// not register is visible before the window closes. The bt-off/bt-on
  /// markers the radio observer stamps are the per-position record of
  /// whether the reset actually happened.
  bool get wantsStackReset => _plan?.stackResetPerPosition ?? false;

  /// Whether the operator's full off-then-on Bluetooth cycle has been
  /// observed during the current placement/walk window. The screen flips
  /// the reset prompt to DONE on this, so a completed reset cannot be
  /// mistaken for one still owed.
  bool get stackResetDone => _resetCycleDone;

  /// When the operator has to be standing somewhere new, and where.
  ///
  /// A step the plan does not auto-advance is one it considers a new
  /// position, so the next of those is the next thing to walk to. The walk
  /// has to be finished before that step's resets open, not when its dwell
  /// does, which is the instant [_enterPositioning] counts down to.
  ///
  /// Null once nothing is left to walk to. A plan whose steps all
  /// auto-advance never asks the operator to move and returns null
  /// throughout.
  ({int atMs, int startsAtMs, String label})? get nextMove {
    final plan = _plan, starts = _stepStartMs;
    if (plan == null || starts == null) return null;
    // The step index advances BEFORE the gap opens, so in a gap the step it
    // names is the one about to run — and that step IS the walk's
    // destination when it opens a new position. Searching past it named the
    // position after the one the operator was walking to, and counted down
    // to that one's deadline.
    var from = _stepIndex + 1;
    if (_phase == FieldPhase.positioning) {
      if (_stepIndex >= plan.steps.length) return null;
      // Between repeats at one position there is no walk. Showing MOVE (and
      // with it the reset card) while the position still has runs left
      // asks the operator to wreck the runs that remain.
      if (plan.steps[_stepIndex].autoAdvance) return null;
      from = _stepIndex;
    }
    for (var i = from; i < plan.steps.length; i++) {
      if (plan.steps[i].autoAdvance) continue;
      return (
        // When the operator has to be standing there — the radio resets
        // then — and when the run itself opens. The second is the number
        // worth showing: nothing waits for the operator, so the schedule
        // is the only fact, and a countdown to it cannot be "missed".
        atMs: starts[i] - resetSlotMs(plan, plan.steps[i]),
        startsAtMs: starts[i],
        label: plan.steps[i].label,
      );
    }
    return null;
  }

  /// Whether this phone joins after the test start (roles 4+): the ones whose
  /// Bluetooth the operator must turn on mid-run.
  bool get joinsLater =>
      myJoinAtMs != null && _anchorMs != null && myJoinAtMs! > _anchorMs!;

  /// True from the test's start until this phone joins. The
  /// screen shows nothing but the countdown then: step progression is
  /// somebody else's run for a phone that has not joined the mesh yet, and
  /// what its operator needs is when to act.
  bool get waitingToJoin {
    if (!manualJoin || !_running || !joinsLater) return false;
    final j = myJoinAtMs;
    if (j == null || _plan == null) return false;
    return nowMs() < j;
  }

  /// True through this phone's join window: from the moment the quiet
  /// stretch before its join opens until it joins.
  ///
  /// The window is when its radio is coming up, and it is also the last
  /// stretch in which a phone whose SYSTEM Bluetooth is off can still be
  /// fixed in time — the app scripts its own transport but cannot turn the
  /// adapter on. The screen's loudest state belongs here rather than before
  /// it: a countdown to the window is information, the window itself is the
  /// only moment acting on it helps, and a join missed here costs that
  /// clique size its whole cell (measured 2026-08-25: one phone's adapter
  /// off, noticed 89 s late, and both of its N=6 runs measured a five-phone
  /// clique wearing a six-phone label).
  bool get joinWindowOpen {
    final at = joinWindowOpensAtMs, j = myJoinAtMs;
    if (at == null || j == null) return false;
    final t = nowMs();
    return t >= at && t < j;
  }

  /// The window preceding this phone's join step — the previous step's
  /// derived drain plus the join gap every device waits at a clique
  /// growth. It spans exactly the time in which no dwell is measuring.
  int _joinWindowSec() {
    final plan = _plan;
    final steps = plan?.steps;
    if (plan == null || steps == null || steps.isEmpty) return 0;
    final k = steps.indexWhere((st) => st.bleOn == true);
    if (k <= 0) return 0;
    return plan.gapAfterSec(steps[k - 1]) +
        (growsClique(plan, k) ? plan.joinGapSec : 0);
  }

  /// When this phone's join window opens: the drain before its join step
  /// plus the join gap every device waits at a clique growth. Nothing is
  /// measuring between that instant and the join. Null for founders and
  /// outside a manual test.
  int? get joinWindowOpensAtMs {
    final j = myJoinAtMs;
    if (j == null || !joinsLater) return null;
    return j - _joinWindowSec() * 1000;
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
    // Wall-clock plans only: every phone runs the same absolute lattice.
    // There is no other scheduling mode — a plan without the lattice's
    // placement and alignment declaration has nothing to run on.
    if (!plan.manualJoin) {
      _abortReason = 'not a wall-clock plan: manualJoin with placement and '
          'alignment windows is required';
      _notify();
      return;
    }
    // Role-free diluting plan: derive THIS phone's schedule from its nickname
    // before anything is recorded. The nickname is the only place the join
    // order lives — there is no per-role preset to pick wrongly (the field
    // run lost its whole N=2 phase to exactly that mistake). A nickname that
    // is not a number cannot join anywhere, so refuse loudly instead of
    // running a phone that would silently sit out every phase.
    // The ring sweep's warm-up is an OPERATOR precondition, not a phase: under
    // the gate a non-neighbour can never handshake, so every pair must already
    // hold a session before the topology is constrained. Refuse loudly rather
    // than run: a phone short of sessions cannot create a packet for the peers
    // it is missing (the send path gates on hasSession, and a Noise session is
    // pairwise), so those ordered pairs would contribute nothing for hours and
    // the shortfall would only surface in the analysis afterwards.
    if (plan.minSessionsToLaunch > 0) {
      final held = sessionTableCount?.call() ?? 0;
      if (held < plan.minSessionsToLaunch) {
        _abortReason = 'only $held Noise sessions, need '
            '${plan.minSessionsToLaunch} — warm the mesh up (toggle Bluetooth '
            'on subsets until every phone shows a full session table) and '
            'relaunch';
        _notify();
        return;
      }
    }
    // Freeze the ring HERE — before any step runs, so a session lost mid-run
    // cannot reshape the topology under the gate.
    _ringRoster = [for (final r in plan.roster) r.pubkeyHex.toLowerCase()];
    if (plan.ringRosterFromSessions) {
      final me = myPubkeyHex?.toLowerCase();
      if (me == null) {
        _abortReason = 'this plan builds its ring from the session table, but '
            'this device does not know its own pubkey';
        _notify();
        return;
      }
      // The size the plan was built for is DECLARED, never inferred from
      // another field. Without it there is nothing to compare the derived ring
      // against, and refusing is the only honest response — a guard that
      // silently does not run is worse than no guard, because the launch it
      // waves through looks checked.
      final want = plan.ringSize;
      if (want == null) {
        _abortReason = 'this plan builds its ring from the session table but '
            'declares no ringSize, so nothing can tell the derived ring from '
            'the wrong one';
        _notify();
        return;
      }
      // A ring needs four to be a ring. At three every pair sits at ring
      // distance 1, so r=1 is already the complete graph and no message can
      // require conveyance — the run would produce nothing, which is exactly
      // what happened on 2026-09-01 when a phone was missing. This is a claim
      // about the PLAN's shape, so it is checked against the declared size;
      // a room that turns up three phones short of a four-plan is caught by
      // the size comparison below, with a message that says so.
      if (want < 4) {
        _abortReason = 'this plan declares a ring of $want — a ring needs at '
            'least 4, or every pair is adjacent and there is nothing to convey';
        _notify();
        return;
      }
      _ringRoster = ringOrder([me, ...?sessionPeerHexes?.call()]);
      // THE ONLY THING A PHONE CAN DECIDE ALONE IS THE COUNT, and this claims
      // no more than that. It catches a table that is short (a half-warmed
      // fleet, missing a node) and one that is long (a stray phone warmed by
      // accident, which turns an N=4 run into N=5 while the radii and per-pair
      // send counts were both chosen for four).
      //
      // It cannot see MEMBERSHIP: this device knows its own session table and
      // nothing about anyone else's, so two phones can hold four-entry tables
      // naming different sets — {self,B,C,D} against {self,A,C,E} — pass this,
      // and enforce rings that disagree about every distance. No local check
      // can separate those, so that failure is made detectable rather than
      // prevented: the ring and its fingerprint are stamped on every marker,
      // for the operator to compare across the phones in their hands and for
      // the analysis to check afterwards. Nothing here catches it.
      //
      // The refusal is also per-device, with no channel to coordinate it — a
      // stray phone that handshakes with ONE fleet member leaves only that
      // member refusing while the rest launch a node short. Hence "relaunch
      // the fleet" rather than "relaunch this phone".
      if (_ringRoster.length != want) {
        _abortReason = 'this plan is built for $want phones but this device\'s '
            'session table describes ${_ringRoster.length} '
            '(${_ringRoster.map((h) => h.length <= 8 ? h : h.substring(0, 8)).join(", ")}) — '
            'a ring the fleet does not agree on is worse than no run. Warm up '
            'or power down until every phone shows ${want - 1} sessions, then '
            'relaunch the WHOLE fleet: the phones that did launch are running '
            'a ring with a hole in it';
        _notify();
        return;
      }
    }
    _ringFp = _ringRoster.isEmpty ? '' : _ringFingerprintOf(_ringRoster);
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
    // AFTER every guard that can still refuse the plan: a phone that bails
    // out here never reaches a terminal path, so setting the rate earlier
    // left it raised for the life of the process.
    //
    // Test-scoped and set ONCE: a per-step rate would make the sighting
    // count depend on which step you are in.
    onSetTraceEveryAdvertisement?.call(plan.traceEveryAdvertisement);
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
    final dtnCap = plan.dtnMaxBytes;
    if (dtnCap != null) onSetDtnMaxBytes?.call(dtnCap);
    // Off unless the plan asks: a state-of-charge flush writes to disk inside
    // a measurement window, which only a discharge run should pay for.
    recorder.flushEverySocDrop = plan.flushEverySocDrop ?? 0;
    await recorder.startExperiment(plan.expId);
    // Acknowledgement suppression is a whole-run property: it changes what
    // the receiver does, and flipping it per step would leave half a step's
    // messages waiting for an acknowledgement that the next step suppresses.
    //
    // Going QUIET is not. It is scoped to the dwell — see [_beginDwellQuiet].
    onSetSuppressAcks?.call(plan.suppressAcks);
    // Whole-run, unlike the silencing itself: the sweep must not evict on a
    // silence the run is causing on purpose, and its window spans dwells.
    if (plan.quietLink) onSetStaleSweepSuspended?.call(true);
    if (plan.manualJoin) {
      // Anchor on the wall clock, not the tap: every phone rounds up to the
      // same alignment boundary, so the start skew collapses to clock-sync
      // error instead of the spread of the taps. The boundary granularity
      // must exceed that spread.
      final alignMs = plan.alignSec * 1000;
      final resetMs = resetSlotMs(plan, plan.steps.first);
      final minStart = nowMs() + plan.placementSec * 1000;
      final anchor = ((minStart + alignMs - 1) ~/ alignMs) * alignMs;
      _anchorMs = anchor;
      // Every phone computes the same anchor, so it also gives every phone the
      // same run id — ids stay comparable across the fleet, as they must be.
      _runId = anchor;
      _stepStartMs = stepStarts(plan, anchor);
      // The target in the trace is the alignment proof: after the test, one
      // query shows whether all phones computed the same instant.
      await recorder.logMarker('placement', extra: {
        'targetMs': anchor,
        ..._ringMarkerFields(),
        if (joinOrder != null) 'order': joinOrder,
        if (myNickname != null && myNickname!.isNotEmpty) 'nick': myNickname,
      });
      _startRadioObserver();
      unawaited(refreshSystemBt?.call().then((_) => _notify()) ??
          Future<void>.value());
      // Scripted radios take their step-0 state for the whole placement
      // window: a phone whose first joined step is later must not spend
      // placement paired with the early clique — desk sessions formed here
      // would make it a send target for the opening cell's phones.
      if (plan.scriptedRadio && onSetBle != null) {
        final s0 = currentStep?.bleOn;
        if (s0 != null) unawaited(onSetBle!.call(s0));
      }
      _resetDownSeen = false;
      _resetCycleDone = false;
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
  /// initial state is stamped too, so every manual test opens with explicit
  /// radio ground truth instead of an implied one.
  ///
  /// Recovery is event-driven end to end: the down-edge itself triggers a
  /// single bounce when the step wants the radio up (re-armed by the next
  /// up-edge), the transport restarts itself on adapter-on, and the
  /// coordinator honours a scripted bring-up at the settings event that
  /// allows it. While the schedule
  /// wants it OFF, never bounce — a down radio is the plan, and fighting the
  /// operator's toggle would be a bug wearing a recovery mechanism's clothes.
  void _startRadioObserver() {
    _btSub?.cancel();
    final usable = bleUsable;
    if (usable == null) return;

    Future<void> stamp(bool up) async {
      if (up == _radioUp) return;
      _radioUp = up;
      if (up) _btOnSeen = true;
      if (wantsStackReset &&
          !_resetting &&
          (_phase == FieldPhase.placement ||
              _phase == FieldPhase.positioning)) {
        if (!up) {
          _resetDownSeen = true;
        } else if (_resetDownSeen) {
          _resetCycleDone = true;
        }
      }
      await recorder.logMarker(up ? 'bt-on' : 'bt-off', extra: {
        if (joinOrder != null) 'order': joinOrder,
      });
      _notify();
    }

    // Initial state, stamped from a direct read at observer start.
    _radioUp = !usable();
    unawaited(stamp(!_radioUp));

    // Transitions, stamped as they happen — and the DOWN edge doubles as
    // the recovery trigger: a service that dies while its step wants the
    // radio up gets ONE bounce per edge, at the event itself. Everything
    // else is owned by events below this layer — the transport restarts
    // itself on adapter-on, and the coordinator honours a scripted
    // bring-up the moment the settings toggle allows it. No poll anywhere.
    _btSub = bleUsableChanges?.listen((up) {
      unawaited(stamp(up));
      if (up) {
        _bounced = false;
        return;
      }
      // Never before the step's own instant: under the lattice the step
      // index advances at dwell end, a whole drain before the step opens,
      // and a joiner's radio must not rise inside the previous run's
      // drain. inPosition owns the scheduled raise.
      final beforeStepStart = _stepStartMs != null &&
          _stepIndex < _stepStartMs!.length &&
          nowMs() < _stepStartMs![_stepIndex];
      if (currentStep?.bleOn == true &&
          !beforeStepStart &&
          onSetBle != null &&
          !_bounced) {
        _bounced = true;
        unawaited(() async {
          await onSetBle!.call(false);
          await onSetBle!.call(true);
        }());
      }
    });
  }

  /// Enter the positioning phase for the current step. When the step
  /// auto-advances (same distance as the previous — nothing to walk to), a
  /// short settle-gap countdown fires [inPosition] automatically; a manual
  /// tap still skips the remaining gap. Otherwise the runner waits for the
  /// tap that marks "I reached the new position".
  void _enterPositioning() {
    unawaited(refreshSystemBt?.call().then((_) => _notify()) ??
        Future<void>.value());
    _resetDownSeen = false;
    _resetCycleDone = false;
    _phase = FieldPhase.positioning;
    // The gap counts down to the instant the next step's resets open, which
    // is its absolute start less the reset reservation. This gap is also the
    // join window: the phone whose first joined step is next spends
    // exactly this long on its join screen.
    _countdownToMs(
        _stepStartMs![_stepIndex] -
            resetSlotMs(_plan!, _plan!.steps[_stepIndex]),
        () => inPosition());
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
    if ((step.resetLinks ?? _plan!.resetLinks) && onResetLinks != null) {
      _resetting = true;
      _notify();
      // BLE bounce; wait for the transport back up. The session purge rides
      // INSIDE the dark window: pairing is eager, so a handshake completes on
      // its own the moment the radio returns, and purging after that hands the
      // step a session it was supposed to start without.
      // The dark window ends at an ABSOLUTE instant, not a duration after
      // this phone happened to finish tearing its transport down. The reset
      // slot opens at the same wall-clock instant on every device, so
      // anchoring the window's end to it keeps the fleet in one lattice:
      // whatever the buffer clear and the teardown cost on this handset is
      // absorbed by the padding rather than pushed onto the step that
      // follows. Null when the step has no scheduled start (a manual run),
      // and the callee then falls back to a relative window.
      final darkUntilMs = _darkUntilMsFor(step);
      await onResetLinks!.call(_plan!.linkResetDarkSec,
          untilMs: darkUntilMs, whileDark: () async {
        if (wantSessionReset) {
          onResetSessions!.call();
          sessionsResetWhileDark = true;
        }
        // The quietest instant a bouncing step has: buffer emptied, links
        // down, sessions gone, so nothing can transmit or receive while the
        // disk is busy.
        await recorder.flush();
      });
      _resetting = false;
      _notify();
      if (sessionsResetWhileDark) {
        await recorder.logMarker('sessions-reset');
      }
      await recorder.logMarker('links-reset');
    }
    // AFTER any bounce, for the same reason the dial cap is: a bounce builds a
    // fresh BleTransportService, and the gate has to be armed on the service
    // this step will actually dial with. (The radius itself lives in Redux and
    // survives the rebuild; this call is what applies the PRUNE.)
    //
    // Radius before sever, deliberately: the prune runs while the gate is
    // armed, so severing second cannot leave a window in which surviving links
    // re-dial under the outgoing radius.
    if (onSetRingGate != null) {
      await onSetRingGate!.call(_ringRoster, step.ringRadius);
      if (step.ringRadius != null) {
        await recorder.logMarker('ring-gate', extra: {'r': step.ringRadius});
      }
    }
    if ((step.severLinks ?? _plan!.severLinks) && onSeverLinks != null) {
      await onSeverLinks!.call();
      await recorder.logMarker('links-severed');
    }
    // AFTER the bounce, which builds a fresh transport: the cap and the step
    // context have to land on the service the step will actually dial with.
    // Null restores the production cap, so a step without a cap is not
    // running under the previous step's.
    onSetDialParallelism?.call(
        maxParallel: step.maxParallelDials, popN: step.cliqueN);
    // Set on EVERY step, not only on settles, so a step never inherits the
    // previous one's interval — the step after a settle is exactly the one
    // that has to hand it back.
    //
    // A plan may hold it high for the whole run instead. That is an ARM, not
    // a phase: the throughput experiment measures the interval's effect by
    // running one launch with it and one without, and a per-step flip would
    // blur the two together.
    onSetConnectionPriority?.call(
        _plan?.connectionPriorityHigh ?? step.settle);
    // Null restores the production spacing, so a step never inherits the
    // previous one's — the pacing-off arm and its control sit next to each
    // other in the same run.
    onSetFragmentDelay?.call(step.fragmentDelayMs);
    onResetEstablishmentCount?.call();
    // Only when the bounce did not already carry the purge — a plan that does
    // not reset links has no dark window to put it in.
    if (wantSessionReset && !sessionsResetWhileDark) {
      onResetSessions!.call();
      await recorder.logMarker('sessions-reset');
    }
    // THE per-step write, and the only one. It sits after the resets and
    // before the dwell opens, which is the quietest instant a step has: the
    // custody buffer was emptied at the top of this method, so nothing is
    // waiting to be conveyed, and the previous run's drain has closed.
    //
    // Not at dwell end: that instant BEGINS the drain, so the I/O landed on
    // the heaviest delivery traffic of the step — the traffic the drain
    // exists to measure. A bouncing step has already written inside its dark
    // window above and finds an empty buffer here.
    await recorder.flush();
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
    // THE MARKER OPENS THE WINDOW BEFORE THE RADIO COMES UP, and the order
    // here is the whole point. A joining phone's transport is built, starts
    // advertising, is discovered and dials — all of it in the slot reserved
    // ahead of the step. Stamping the marker after that put every one of
    // those dials OUTSIDE the segment analysis reads, so a cell that spent
    // its join forming links reports zero dial attempts and the links look
    // like they had always been there. The segment has to contain the
    // establishment it is an establishment measurement of.
    //
    // The marker carries this phone's CONFIGURED intent, not just the step
    // name: which join slot it was assigned and whether it believed it was
    // in the mesh for this step. Analysis can then tell a misconfigured
    // phone from one that was configured right and failed to join — from the
    // marker alone, without inferring it from when links first appear.
    await recorder.logMarker(step.label, extra: {
      if (joinOrder != null) 'order': joinOrder,
      if (step.bleOn != null) 'joined': step.bleOn,
      // The ring this phone is actually enforcing. Every phone must have
      // derived the SAME list or the gate is incoherent, and when the list
      // comes from each device's own session table that is a claim to be
      // CHECKED rather than assumed — the launch guard can only count, so this
      // is the only place a membership disagreement ever surfaces. Cheap
      // enough to carry per marker (a handful of short strings).
      ..._ringMarkerFields(),
      if (sessionPeerCount != null) 'sessions': sessionPeerCount!(),
      if (sessionTableCount != null)
        'sessionTable': sessionTableCount!(),
      if (_runId != null) 'run': _runId,
      // Dial-grid cell, on the marker that OPENS the window, so the analyzer
      // reads M / N / rep off the segment instead of re-parsing the label.
      if (step.ringRadius != null) 'r': step.ringRadius,
      if (step.maxParallelDials != null) 'maxParallel': step.maxParallelDials,
      if (step.maxParallelDials != null && step.cliqueN != null)
        'popN': step.cliqueN,
      if (step.maxParallelDials != null) 'rep': _repOf(step.label),
    });
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
    // The radio and the resets ran in the slot reserved ahead of the step,
    // inside the open window. Hold here until the step's own instant so the
    // DWELL opens at full length and every phone opens it together; a phone
    // whose resets overran is already past it and falls through, sending
    // late rather than silently shortening the run. The marker is already
    // stamped, so what the phones agree on here is when they start SENDING,
    // which is what the load arm is defined by.
    if (manualJoin && _stepStartMs != null) {
      final wait = _stepStartMs![_stepIndex] - nowMs();
      if (wait > 0) {
        await Future<void>.delayed(Duration(milliseconds: wait));
        if (!_running || currentStep != step) return;
      }
    }
    _ackSub ??= ackEvents?.listen(onAck);
    // Silence the radio for the MEASUREMENT, never before it.
    //
    // ANNOUNCE is what holds a leg up between steps: it is the inbound
    // traffic the liveness veto reads, and its timer carries the stale sweep
    // that would otherwise evict the peer. Silencing it from launch spends
    // the whole placement and alignment lattice with nothing keeping the link
    // alive — a run that did exactly that opened its first step already down
    // a leg and had none by the fourth minute.
    if (_plan?.quietLink ?? false) await onSetQuietLink?.call(true);
    _phase = FieldPhase.dwelling;
    _dwellEndsAtMs = _stepStartMs![_stepIndex] + step.dwellSec * 1000;
    _armRadioSuspectCheck(step);
    _scheduleSends(step);
    _countdownToMs(_dwellEndsAtMs!, _endDwell);
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
      // A step that grows the clique opens late by the join gap: the
      // previous N has drained, and every device holds here while the
      // joining phone's transport is built, advertises, is discovered and
      // handshakes — none of which should be charged to its first dwell.
      if (growsClique(plan, i)) t += plan.joinGapSec * 1000;
      starts.add(t);
      // The slot added here precedes the NEXT step's start; the final
      // iteration charges by the last step because the trailing resets
      // re-run exactly that step's resets.
      final next = i + 1 < plan.steps.length ? plan.steps[i + 1] : st;
      t += resetSlotMs(plan, next) +
          (st.dwellSec + plan.gapAfterSec(st)) * 1000;
    }
    return starts;
  }

  /// Whether step [i] grows the clique: it names a cliqueN different from
  /// its predecessor's. This is the one predicate the join gap keys on —
  /// the lattice reservation and the join window must read the same answer,
  /// or the screen promises time the schedule never holds.
  static bool growsClique(FieldPlan plan, int i) =>
      i > 0 &&
      plan.steps[i].cliqueN != null &&
      plan.steps[i].cliqueN != plan.steps[i - 1].cliqueN;

  /// The reservation ahead of one step: the full budget where the step bounces
  /// links or severs them, and zero where it does neither. The buffer clear and
  /// the session purge are store writes with nothing to wait for; charging them
  /// a slot would spend the budget before every run of a plan that bounces once.
  ///
  /// A sever earns the slot because it is a round trip to the plugin for every
  /// live path. It is NOT sized to let the links re-form: on the ring sweep the
  /// stage deliberately starts into zero links — the send ticker gates on a
  /// session, sessions survive the sever, so sends fire before any link is back
  /// and fall to the DTN buffer to go out on the sync exchange. That is the
  /// mechanism under test, and padding the slot until the mesh was back would
  /// measure around it.
  static int resetSlotMs(FieldPlan plan, FieldStep step) =>
      ((step.resetLinks ?? plan.resetLinks) ||
              (step.severLinks ?? plan.severLinks)
          ? plan.resetBudgetSec
          : 0) *
      1000;

  /// The wall-clock instant this step's dark window is scheduled to end.
  ///
  /// The slot opens at `stepStart - resetSlot` on every device, so the
  /// window's end is that instant plus the plan's dark seconds — identical
  /// across the fleet and independent of how long any one phone took to
  /// tear its transport down. Null where the step has no scheduled start
  /// or the plan sets no dark length; the bounce is then relative, which is
  /// right for a manual run that no other device is keeping time with.
  int? _darkUntilMsFor(FieldStep step) {
    final dark = _plan?.linkResetDarkSec;
    final starts = _stepStartMs;
    if (dark == null || _plan == null || starts == null) return null;
    if (_stepIndex < 0 || _stepIndex >= starts.length) return null;
    return starts[_stepIndex] - resetSlotMs(_plan!, step) + dark * 1000;
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


  /// Send targets for the current instant, narrowed to [FieldStep.sendTo].
  /// The three sources are described on [_allSendTargets].
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

  /// Every peer this device addresses, in priority order of three sources:
  ///
  /// - **The derived ring**, whenever the plan builds one from the session
  ///   table. Targets are every ring member but this device, labeled by 8-hex
  ///   prefix. It outranks the compiled roster deliberately — see below.
  /// - **The compiled roster**: this device must be a member (else it is
  ///   receive-only) and targets are every other row, with the roster's own
  ///   labels naming the id set.
  /// - **Neither**: every peer currently holding a session, labeled by 8-hex
  ///   prefix — the two-device case, with no pubkey to enter by hand.
  List<(String, Uint8List)> _allSendTargets() {
    final me = myPubkeyHex?.toLowerCase();
    final plan = _plan!;
    // A derived ring is the target list too, not just the topology.
    //
    // Leaving targets on the compiled roster while the gate ran on the derived
    // ring would only half-fix the failure this exists for: on 2026-09-01 the
    // roster named an absent phone and omitted a present one, and the present
    // one falls through `mine == null` below to receive-only — it would take a
    // ring position, relay for everyone else, and send nothing at all, all
    // run, without a word. Meanwhile the others would address a third of their
    // traffic to a phone that is not there. Six of twelve ordered pairs would
    // produce no records and nothing would say why.
    if (plan.ringRosterFromSessions && _ringRoster.isNotEmpty) {
      if (me == null) return const [];
      return [
        for (final hex in _ringRoster)
          if (hex != me)
            if (_hexToBytes(hex) case final pk?) (hex.substring(0, 8), pk),
      ];
    }
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
  /// [sessionUp] predicate: poll until some target has a session, then run
  /// rounds at the FULL dwell's pace until the dwell ends — data never races
  /// a re-forming link, a late first session costs rounds rather than
  /// compressing them, and an out-of-range step sends nothing. Without the
  /// predicate: fixed offsets from dwell start. Targets resolve at fire
  /// time; message ids are v4, matching production.
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
    final doSend = send;
    if (doSend == null) return;
    if (step.saturate) {
      _watchConvergence();
      _scheduleSaturating(step); // saturating mode ignores sendCount
      return;
    }
    if (step.sendCount <= 0) return;
    _watchConvergence();
    final ready0 = sessionUp;
    if (ready0 == null) {
      _runSendTicker(step);
      return;
    }
    _whenReady(ready0, sessionEvents, () {
      unawaited(recorder.logMarker('session-up'));
      _runSendTicker(step);
      _notify();
    });
  }

  /// ONE periodic timer paces the whole dwell: it fires up to
  /// [FieldStep.sendCount] times, and every fire sends one message to each
  /// target holding a session AT THAT INSTANT — so a session that lands
  /// mid-dwell joins the remaining rounds by construction, and an overload
  /// run costs one timer, not five hundred.
  ///
  /// The interval comes from the FULL dwell, never from what remains of it.
  /// Dividing the remainder by [FieldStep.sendCount] packed every round a
  /// late first session had missed into the tail — the schedule silently
  /// CAUGHT UP at a compressed rate, so exactly the trials whose links
  /// formed slowest were also the ones offered the hottest load, and the
  /// step's msg/s stopped being one number. Pacing from the full dwell
  /// keeps the rate constant for every device in the step; a late start
  /// costs the rounds the dwell's end cuts off (the phase leaving
  /// `dwelling` stops the ticker), which is the semantics every experiment
  /// doc claims.
  void _runSendTicker(FieldStep step) {
    // Sends are paced across the WHOLE dwell.
    //
    // There used to be two seconds shaved off the end, so a step's last
    // acknowledgement would still land inside its own dwell. It bought
    // nothing: every step is followed by a drain, the analysis windows the
    // SEND and counts the receive wherever it lands, and the only thing the
    // shave reliably produced was an off cadence — 1480 ms per pair where the
    // parameters plainly say 1500.
    final windowMs = step.dwellSec * 1000;
    if (windowMs <= 0) return;
    if (step.perPairPacing) {
      _runPerPairTickers(step, windowMs);
      return;
    }
    var fired = 0;
    void round() {
      fired++;
      _fireSendRound(step, fired - 1);
    }

    round(); // the first round opens the window; the ticker paces the rest
    if (fired >= step.sendCount) return;
    final intervalMs = windowMs ~/ step.sendCount;
    _sendTicker = Timer.periodic(
        Duration(milliseconds: intervalMs < 1 ? 1 : intervalMs), (t) {
      if (!_running || _phase != FieldPhase.dwelling ||
          fired >= step.sendCount) {
        t.cancel();
        return;
      }
      round();
      if (fired >= step.sendCount) t.cancel();
    });
  }

  /// Saturating throughput mode: once a session exists, push for the rest of
  /// the dwell on [FieldStep.sendLanes] concurrent lanes, each looping "fire
  /// one, await it, fire the next".
  ///
  /// Nothing is ACK-gated. An acknowledgement only counts ([onAck]); it never
  /// clocks a send, because clocking on acknowledgements caps the rate at
  /// lanes/RTT and measures the window rather than the link. Offered load is
  /// therefore set purely by the lane count and by how fast the send path
  /// drains, so `sent` against `acked` is offered load against carried load.
  void _scheduleSaturating(FieldStep step) {
    _outstanding.clear();
    _satSeq = 0;
    _ackedCount = 0;
    void begin() {
      unawaited(recorder.logMarker('saturate-start'));
      // The window the analyzer measures the rate over. The step marker is
      // the wrong start: it includes the wait for a session, which is dead
      // time that would be charged to the link as a lower rate.
      unawaited(recorder.log({
        'type': 'flow',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'start',
        'flow': 'saturate',
        'payloadBytes': step.sendBytes,
        'sendLanes': step.sendLanes,
      }));
      final lanes = step.sendLanes < 1 ? 1 : step.sendLanes;
      for (var i = 0; i < lanes; i++) {
        unawaited(_pushLane(step));
      }
      _notify();
    }

    final ready = sessionUp;
    if (ready == null) {
      begin();
      return;
    }
    _whenReady(ready, sessionEvents, () {
      unawaited(recorder.logMarker('session-up'));
      begin();
    });
  }

  /// One push lane: keep sending until the dwell ends, awaiting each send so
  /// the lane runs at exactly the rate the send path drains it.
  /// How long a lane waits before trying again once the link is gone.
  ///
  /// Yielding to the event loop keeps the loop INTERRUPTIBLE; it does not
  /// bound its RATE, and with no leg to carry anything the two are not the
  /// same problem. Each turn still mints a message id, allocates a payload —
  /// up to 55 kB for the largest step — fills it byte by byte, fails the
  /// send, and appends a drop record to a recorder that buffers in memory
  /// for the whole run. Thousands of times a second, that pegs the isolate
  /// and grows the heap without bound: measured as a sender whose frame
  /// intervals decayed 60 s, 90 s, 205 s, 600 s, 940 s and then stopped,
  /// with the run's own timers still firing. The UI was dead, so the step
  /// looked frozen at "00:01 left" while the loop underneath spun on.
  ///
  /// A link that is up makes this dead code: [_fireSaturating] then awaits
  /// real I/O and returns on the radio's schedule, which is the clock the
  /// measurement wants.
  static const Duration _noLinkBackoff = Duration(milliseconds: 100);

  Future<void> _pushLane(FieldStep step) async {
    while (_running && _phase == FieldPhase.dwelling && currentStep == step) {
      await _fireSaturating(step);
      // Yield to the EVENT LOOP, not just the microtask queue. A send that
      // never touches real I/O resolves as a microtask, and microtasks run
      // ahead of timers — an unbroken chain of them would starve the dwell
      // countdown and the UI, hanging the app for the rest of the step. A
      // zero-duration delay is a timer, so the loop can always be
      // interrupted. It costs one event-loop turn per message, far above
      // anything BLE carries, so it does not cap the measurement.
      //
      // With no leg ready the yield is not enough on its own — see
      // [_noLinkBackoff].
      final legs = legsReady?.call();
      await Future<void>.delayed(
          legs == 0 ? _noLinkBackoff : Duration.zero);
    }
  }

  /// Fire one message per target and await it. The await IS the clock.
  Future<void> _fireSaturating(FieldStep step) async {
    final doSend = send;
    if (doSend == null) return;
    if (!_running || _phase != FieldPhase.dwelling) return;
    final hasSession = sessionUp;
    final seq = _satSeq++;
    for (final (_, pubkey) in _sendTargets()) {
      if (hasSession != null && !hasSession(pubkey)) {
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
      _outstanding.add(messageId);
      _sentCount++;
      await doSend(pubkey, payload, messageId: messageId);
    }
  }

  /// End-to-end acknowledgement feed from the coordinator.
  ///
  /// An acknowledgement only COUNTS here. It never triggers a send — see
  /// [_scheduleSaturating].
  void onAck(String messageId) {
    if (!_outstanding.remove(messageId)) return;
    _ackedCount++;
    _notify();
  }

  /// One paced round: one message to EVERY target that can receive it. The
  /// step's send count is therefore a rate PER DESTINATION: at 1/s with
  /// seven peers a device puts seven messages a second on the air, which is
  /// the load model these experiments mean by "rate".
  ///
  /// This is the ROUND-paced path. [FieldStep.perPairPacing] takes a different
  /// one entirely — see [_runPerPairTickers].
  void _fireSendRound(FieldStep step, int seq) {
    // The gate is the SESSION, not a converged pair. A session exists as soon
    // as the Noise handshake completes, which is well before both GATT legs
    // are up, and a message can be sealed and sent the moment it does — so
    // waiting for convergence would hold traffic back for no reason and
    // charge the delay to the delivery numbers.
    final hasSession = sessionUp;
    for (final (_, pubkey) in _sendTargets()) {
      // Only at a target that can actually receive. The send path refuses a
      // peer with no session and records the refusal, which is correct for
      // it and wrong to provoke: a message aimed at a pair that has not
      // finished handshaking measures the runner's own timing, and lands in
      // the results as a delivery failure indistinguishable from one the
      // transport caused. Skipped, never sent — so an unhandshaked pair
      // cannot lower a delivery ratio, it can only shorten a send count.
      if (hasSession != null && !hasSession(pubkey)) {
        _skippedSends++;
        continue;
      }
      _sendOne(step, pubkey, seq);
    }
    _notify();
  }

  /// Seal and air ONE synthetic message at [pubkey]. The only place a testbed
  /// message is built, so both pacing models put identical bytes on the air.
  void _sendOne(FieldStep step, Uint8List pubkey, int seq) {
    final messageId = _uuid.v4();
    final payload = Uint8List(step.sendBytes);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = (seq + i) & 0xff;
    }
    // Reserved first byte: testbed traffic must never look like a real block
    // class in the wire-byte breakdown.
    if (payload.isNotEmpty) payload[0] = testbedPayloadMarker;
    _sentCount++;
    unawaited(send!(pubkey, payload, messageId: messageId));
  }

  /// ONE TIMER PER SESSION. Each peer this device can currently seal to gets
  /// its own ticker, firing [FieldStep.sendCount] times across the dwell, so
  /// the step's count is again a rate PER DESTINATION.
  ///
  /// The load a device offers therefore follows the sessions it actually
  /// holds, not the roster it was handed. Under the round-paced model a
  /// sessionless peer still consumed its slot in every round and was counted
  /// in `skippedSends`; here it simply has no timer, so the pairs that do
  /// exist keep their exact cadence instead of pacing around a gap.
  ///
  /// **The phases are staggered on purpose.** N timers of equal period started
  /// together fire together, which would put one message per session on the
  /// queue in the same instant — the burst that the ring cannot afford, where
  /// a node may hold two links carrying transit for everyone. Offsetting the
  /// i-th timer by `i/N` of a period keeps each pair's own cadence exactly
  /// [FieldStep.sendCount] over the dwell while the device's aggregate comes
  /// out evenly spread.
  ///
  /// The session set is sampled once, when the dwell opens. A pair that
  /// handshakes later in the window is not picked up — deliberately, because a
  /// timer added mid-dwell could not deliver its full count and would report a
  /// short pair as a lossy one.
  void _runPerPairTickers(FieldStep step, int windowMs) {
    final hasSession = sessionUp;
    final targets = _sendTargets();
    final live = [
      for (final t in targets)
        if (hasSession == null || hasSession(t.$2)) t.$2,
    ];
    // The launch guard demands a full session table and nothing evicts a live
    // session, so this should be every roster peer for the whole run. If it is
    // not, say so: a pair with no timer offers no load at all, and unlike the
    // round-paced model — where a sessionless peer at least incremented
    // skippedSends every round — nothing else would record that the trial ran
    // a pair short. A quietly reduced denominator is the kind of thing that
    // reads as a mesh result afterwards.
    if (live.length < targets.length) {
      final missing = [
        for (final t in targets)
          if (!live.contains(t.$2)) _hex(t.$2).substring(0, 8),
      ];
      unawaited(recorder.log({
        'type': 'runner',
        't': nowMs(),
        'event': 'pairTimersShort',
        'step': step.label,
        'armed': live.length,
        'expected': targets.length,
        'missing': missing,
      }));
    }
    if (live.isEmpty || step.sendCount <= 0) return;
    final periodMs = (windowMs ~/ step.sendCount).clamp(1, windowMs);
    final startMs = nowMs();
    for (final pubkey in live) {
      var fired = 0;
      void one() {
        fired++;
        _sendOne(step, pubkey, fired - 1);
        _notify();
      }

      bool done() =>
          !_running || _phase != FieldPhase.dwelling || fired >= step.sendCount;

      // One send per SLOT, at a uniformly random offset INSIDE the slot,
      // rather than on a strict period.
      //
      // The rate is identical either way — exactly [FieldStep.sendCount] sends
      // across the dwell, one per slot. What the jitter removes is aliasing.
      // Multi-hop latency here is quantised in ANNOUNCE rounds, because a
      // carried packet advances at most one hop per sync round, and the ring
      // sweep deliberately paces at one message per pair per round. A strictly
      // periodic timer at that same interval samples the quantised process at
      // one fixed phase for the entire trial, so a pair's whole latency
      // distribution is displaced by wherever its timer happened to land
      // relative to the announce cycle — up to a full round. The medians would
      // then be a property of timer phase, not of the topology, which is the
      // one thing this experiment exists to measure.
      //
      // Drawing each offset fresh spreads the phases across the cycle, so the
      // per-hop quantisation shows up as STEPS in the pooled distribution
      // instead of a per-pair bias. It also subsumes the fixed stagger that
      // used to sit here: independent draws collide only by chance, where
      // equal-period timers started together collide by construction.
      void scheduleNext() {
        if (done()) return;
        final slotStart = startMs + fired * periodMs;
        final target = slotStart + _sendJitter.nextInt(periodMs);
        final delay = target - nowMs();
        _sendTimers.add(Timer(
          Duration(milliseconds: delay > 0 ? delay : 0),
          () {
            if (done()) return;
            one();
            scheduleNext();
          },
        ));
      }

      scheduleNext();
    }
  }


  /// One deadline per dwell, not a poll: [_radioSuspectGraceSec] into the
  /// window, a step that wants the radio up and still holds no session is
  /// flagged. The service reporting usable is NOT a precondition — a radio
  /// that never comes up at all (system Bluetooth off) is the more common
  /// field failure than one that is up and deaf, and the earlier version of
  /// this check missed it entirely by requiring usable==true to even look.
  /// Surfaced on screen and as a once-per-run marker, never an abort: one
  /// phone's trouble must not end a seven-phone run. The first session
  /// event clears the banner; the check re-arms with every dwell.
  void _armRadioSuspectCheck(FieldStep step) {
    _radioSuspectTimer?.cancel();
    _suspectClear?.cancel();
    _suspectClear = null;
    _radioSuspect = false;
    _radioSuspectReason = null;
    if (step.bleOn != true) return;
    // The grace never exceeds the dwell it guards: a 20 s deadline inside a
    // 10 s dwell fires into the drain and the phase guard swallows it — the
    // smoke preset then never warns at all, in the very run meant to catch
    // a staging mistake before the field.
    final graceSec = step.dwellSec - 2 < _radioSuspectGraceSec
        ? (step.dwellSec - 2).clamp(3, _radioSuspectGraceSec)
        : _radioSuspectGraceSec;
    _radioSuspectTimer = Timer(Duration(seconds: graceSec), () {
      _radioSuspectTimer = null;
      if (!_running || _phase != FieldPhase.dwelling) return;
      final up = bleUsable?.call() ?? false;
      if (!up || (sessionPeerCount?.call() ?? 1) == 0) {
        _radioSuspect = true;
        _radioSuspectReason = up ? 'sessionless' : 'adapterOff';
        if (!_radioSuspectStamped) {
          _radioSuspectStamped = true;
          unawaited(recorder
              .logMarker('radio-suspect', extra: {'reason': _radioSuspectReason!}));
        }
        _notify();
        _suspectClear = sessionEvents?.listen((_) {
          _radioSuspect = false;
          _radioSuspectReason = null;
          _suspectClear?.cancel();
          _suspectClear = null;
          _notify();
        });
      }
    });
  }

  /// Run [then] the moment [ready] holds for any send target.
  ///
  /// Waits on [events] when one is supplied and polls only without it. Every
  /// gate the runner has is a predicate plus the stream that announces its
  /// edge, so nothing on the step's critical path is discovered a tick late.
  void _whenReady(bool Function(Uint8List peer) ready,
      Stream<Uint8List>? events, void Function() then) {
    bool anyReady() => _sendTargets().any((target) => ready(target.$2));
    if (anyReady()) {
      then();
      return;
    }
    if (events == null) {
      final poll = Timer.periodic(const Duration(milliseconds: 500), (t) {
        if (!_running || _phase != FieldPhase.dwelling) {
          t.cancel();
          return;
        }
        if (!anyReady()) return;
        t.cancel();
        then();
      });
      _sendTimers.add(poll);
      return;
    }
    late final StreamSubscription<Uint8List> sub;
    sub = events.listen((_) {
      if (!_running || _phase != FieldPhase.dwelling) {
        unawaited(sub.cancel());
        return;
      }
      if (!anyReady()) return;
      unawaited(sub.cancel());
      then();
    });
    _sessionWaits.add(sub);
  }

  /// Mark the moment a target's pair converges to both GATT legs.
  ///
  /// Convergence no longer gates anything — sends go out on the session — but
  /// it is still the fact the establishment ladder calls "established", so it
  /// has to reach the trace on its own. The watcher stops at the first
  /// converged target: one marker per step is what the analysis reads.
  void _watchConvergence() {
    final converged = linkSettled;
    if (converged == null) return;
    _whenReady(converged, linkSettledEvents, () {
      unawaited(recorder.logMarker('link-settled'));
    });
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
    _sendTicker?.cancel();
    _sendTicker = null;
    for (final t in _sendTimers) {
      t.cancel();
    }
    _sendTimers.clear();
    for (final sub in _sessionWaits) {
      unawaited(sub.cancel());
    }
    _sessionWaits.clear();
  }

  Future<void> _endDwell() async {
    _cancelSends();
    // The drain gets the radio back: a leg lost during the dwell can re-form
    // before the next one, instead of the run degrading step by step.
    if (_plan?.quietLink ?? false) await onSetQuietLink?.call(false);
    final saturating = currentStep;
    if (saturating != null && saturating.saturate) {
      // Closes the window the analyzer measures the rate over. `sent` is
      // offered load and `acked` is carried load; their gap is the overrun.
      await recorder.log({
        'type': 'flow',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'stop',
        'flow': 'saturate',
        'payloadBytes': saturating.sendBytes,
        'sendLanes': saturating.sendLanes,
        'sent': _satSeq,
        'acked': _ackedCount,
        'ackedBytes': _ackedCount * saturating.sendBytes,
      });
      _outstanding.clear();
    }
    // The run's own end, stamped before anything is torn down. A step's
    // segment runs to the NEXT step marker and so carries the reset that
    // follows, which makes the span the wrong place to read the dwell from;
    // this is the right one, and it does not depend on a plan resetting
    // anything. It also carries the run's own send ledger: fires and
    // holds-for-want-of-a-session, so a window that fired little traffic is
    // distinguishable from one whose traffic failed — for every run, the
    // run's last included.
    await recorder.logMarker('run-end', extra: {
      'sent': _sentCount - _sentAtSegStart,
      if (_skippedSends > 0) 'skippedSends': _skippedSends,
      // Links held as the window CLOSES, which is the count the traffic
      // actually met. It cannot ride the step marker: that is stamped before
      // `_runResets` bounces the transport, so on a step that resets links it
      // would report the count carried out of the PREVIOUS run. One sample
      // per run also says nothing about how a count moved inside a long
      // dwell -- adequate for a 60 s window, and the reason a ten-minute hold
      // is read from link records rather than from this field.
      if (linkPeerCount != null) 'links': linkPeerCount!(),
    });
    _sentAtSegStart = _sentCount;
    _skippedSends = 0;
    final step = currentStep;
    if (step != null && step.maxParallelDials != null) {
      await _logDialCell(step);
    }
    onWindowElapsed?.call();
    final plan = _plan!;
    if (_stepIndex + 1 < plan.steps.length) {
      _stepIndex++;
      _enterPositioning();
      return;
    }
    // Last step done. Its drain comes FIRST, custody intact — the last
    // run's tail lives under the same rules as every other run's:
    // arrivals and ACKs keep landing and the sync exchange can still
    // redeliver, for exactly one derived drain. Then the trailing reset
    // cuts the tail the way the next run's resets cut every other one,
    // `end` closes the segment, and recording stops. The drain length is
    // never a parameter here either: the settle window WAS the last drain
    // wearing its own knob, and its two hand-picked values were exactly
    // what the derivation yields.
    _phase = FieldPhase.settling;
    _startCountdown(plan.gapAfterSec(plan.steps.last), () async {
      await _runResets(plan.steps.last);
      await recorder.logMarker('end');
      await _finish();
    });
    _notify();
  }

  /// The battery reached the floor where Android's saver engages. This is a
  /// SUCCESSFUL end — the run collected what it came for — so it settles and
  /// uploads like a normal finish rather than aborting.
  Future<void> _finishAtFloor(int level) async {
    if (!_running) return;
    _batteryFloorLevel = level;
    _cancelSends();
    _tick?.cancel();
    _tick = null;
    _absFire?.cancel();
    _absFire = null;
    _radioSuspectTimer?.cancel();
    _radioSuspectTimer = null;
    _suspectClear?.cancel();
    _suspectClear = null;
    _btSub?.cancel();
    _btSub = null;
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
    // Test-scoped, like the dial cap: every terminal path (finish, abort,
    // force-finish) runs through here, so the trace rate never outlives the
    // test that asked for it.
    onSetTraceEveryAdvertisement?.call(false);
    onSetConnectionPriority?.call(false);
    // The ring gate too. Left armed at the last step's radius it would refuse
    // the non-neighbour handshakes the next warm-up needs, and the next launch
    // would fail its session-count check. Disarming prunes nothing — it only
    // grants permission — so the standing links are untouched.
    onSetRingGate?.call(const [], null);
  }

  /// Undo everything a run silenced. Called from EVERY exit — the natural
  /// end, an early finish and an abort alike.
  ///
  /// A phone left quiet cannot find anyone again and cannot be recovered
  /// except by restarting the app, which is not something an operator away
  /// from the bench can be asked to do. There is no exit worth leaving it in
  /// that state for.
  Future<void> _restoreAfterQuietRun() async {
    if (_plan?.quietLink ?? false) {
      await onSetQuietLink?.call(false);
      onSetStaleSweepSuspended?.call(false);
    }
    if (_plan?.suppressAcks ?? false) onSetSuppressAcks?.call(false);
  }

  Future<void> _finish() async {
    recorder.onBatteryFloor = null;
    await _restoreAfterQuietRun();
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
    await _restoreAfterQuietRun();
    _cancelSends();
    _tick?.cancel();
    _tick = null;
    _absFire?.cancel();
    _absFire = null;
    _radioSuspectTimer?.cancel();
    _radioSuspectTimer = null;
    _suspectClear?.cancel();
    _suspectClear = null;
    _btSub?.cancel();
    _btSub = null;
    recorder.onBatteryFloor = null;
    recorder.onUploadProgress = null;
    // Say so in the trace. Without it an early finish is indistinguishable
    // from a run whose process died: both end with no `end` marker, and the
    // analyzer cannot tell a deliberate stop from lost data.
    try {
      await recorder.logMarker('finished-early', extra: {
        'atStep': _stepIndex,
        'ofSteps': _plan?.steps.length,
        'phase': _phase.name,
      });
    } catch (_) {/* recording already stopped */}
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

  /// Abandon the run: marker the abort, stop recording. Files stay.
  Future<void> abort() async {
    if (!_running) return;
    await _restoreAfterQuietRun();
    _cancelSends();
    _tick?.cancel();
    _tick = null;
    _absFire?.cancel();
    _absFire = null;
    _radioSuspectTimer?.cancel();
    _radioSuspectTimer = null;
    _suspectClear?.cancel();
    _suspectClear = null;
    _btSub?.cancel();
    _btSub = null;
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
    _ackSub?.cancel();
    _ackSub = null;
    _cancelSends();
    _tick?.cancel();
    _tick = null;
    _absFire?.cancel();
    _absFire = null;
    _radioSuspectTimer?.cancel();
    _radioSuspectTimer = null;
    _suspectClear?.cancel();
    _suspectClear = null;
    _btSub?.cancel();
    _btSub = null;
    _restoreDialCap();
    super.dispose();
  }
}

/// 8 hex characters over the whole ring, for comparing two phones' rings at a
/// glance.
///
/// FNV-1a written out rather than a hash from a package: every phone has to
/// compute the same token from the same ring, and the value lands in traces
/// that outlive this code, so it cannot be a function whose output is free to
/// change between versions. Masked to 32 bits at every step so the arithmetic
/// is exact on any Dart runtime. Collisions are irrelevant here — the token
/// compares a handful of phones standing on one desk, and the full ring rides
/// beside it on the same marker.
String _ringFingerprintOf(List<String> ring) {
  var h = 0x811c9dc5;
  for (final c in ring.join(',').codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
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
