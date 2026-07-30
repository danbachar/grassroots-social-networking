import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../trace/experiment_recorder.dart';
import 'testbed_config.dart';

/// The runner's user-visible phase.
enum FieldPhase {
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

  /// Message send hook (the coordinator's `send`). A send to a sessionless
  /// peer triggers the lazy handshake — which is exactly the point after a
  /// per-step session reset.
  final Future<String?> Function(Uint8List recipient, Uint8List payload,
      {String? messageId})? send;

  /// Drops all Noise sessions (per-step, when the plan asks) so each step
  /// measures the full establishment ladder.
  final VoidCallback? onResetSessions;

  /// Tears down every BLE link (per-step, when the plan asks) so each step
  /// also re-runs discovery + connect — a fully independent trial.
  final VoidCallback? onResetLinks;

  /// Currently identified peers (pubkeys), consulted when the plan has NO
  /// roster: every known peer becomes a send target and labels are the 8-hex
  /// pubkey prefixes — the two-device case needs no manual pubkey entry.
  /// Resolved lazily at each send so a peer discovered mid-run still counts.
  final List<Uint8List> Function()? knownPeers;

  static const _uuid = Uuid();

  /// Uploads the experiment files; returns a user-facing status line.
  /// Null when this build has no upload destination.
  final Future<String> Function()? upload;

  /// Fires when a dwell or settle window elapses — the screen uses it for
  /// haptics/sound so the experimenter feels the step end pocket-blind.
  final VoidCallback? onWindowElapsed;

  FieldRunner({
    required this.recorder,
    this.onStartBulk,
    this.onStopBulk,
    this.myPubkeyHex,
    this.send,
    this.onResetSessions,
    this.onResetLinks,
    this.knownPeers,
    this.upload,
    this.onWindowElapsed,
  });

  FieldPlan? _plan;
  FieldPhase _phase = FieldPhase.finished;
  int _stepIndex = 0;
  int _remainingSec = 0;
  bool _running = false;
  String? _uploadResult;
  Timer? _tick;
  final List<Timer> _sendTimers = [];
  int _sentCount = 0;

  /// Messages fired by the plan so far (all steps).
  int get sentCount => _sentCount;

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

  /// Begin the plan: starts the experiment recording and enters the first
  /// step's positioning phase. No-op while already running.
  Future<void> start(FieldPlan plan) async {
    if (_running || plan.steps.isEmpty) return;
    _plan = plan;
    _stepIndex = 0;
    _uploadResult = null;
    _running = true;
    await recorder.startExperiment(plan.expId);
    _enterPositioning();
  }

  /// Enter the positioning phase for the current step. When the step
  /// auto-advances (same distance as the previous — nothing to walk to), a
  /// short settle-gap countdown fires [inPosition] automatically; a manual
  /// tap still skips the remaining gap. Otherwise the runner waits for the
  /// tap that marks "I reached the new position".
  void _enterPositioning() {
    _phase = FieldPhase.positioning;
    if (currentStep?.autoAdvance ?? false) {
      _startCountdown(_plan!.autoAdvanceGapSec, inPosition);
    }
    notifyListeners();
  }

  /// The experimenter reached the current step's position: drop sessions
  /// (when the plan asks), stamp the ground-truth marker, hold the dwell,
  /// and run the step's sends spread through it.
  Future<void> inPosition() async {
    final step = currentStep;
    if (!_running || _phase != FieldPhase.positioning || step == null) return;
    _tick?.cancel(); // a manual tap pre-empts any auto-advance gap countdown
    _tick = null;
    if (_plan!.resetLinks && onResetLinks != null) {
      onResetLinks!.call();
      await recorder.logMarker('links-reset');
    }
    if (_plan!.resetSessions && onResetSessions != null) {
      onResetSessions!.call();
      await recorder.logMarker('sessions-reset');
    }
    await recorder.logMarker(step.label);
    if (step.bulk) onStartBulk?.call();
    _phase = FieldPhase.dwelling;
    _scheduleSends(step);
    _startCountdown(step.dwellSec, _endDwell);
    notifyListeners();
  }

  /// Send targets for the current instant. With a roster: this device must
  /// be a member (else receive-only) and targets are every other row, roster
  /// labels naming the id set. Without a roster: every currently identified
  /// peer, labeled by 8-hex pubkey prefix — the two-device case with no
  /// manual pubkey entry.
  List<(String, Uint8List)> _sendTargets() {
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

  /// Spread [FieldStep.sendCount] messages to every send target through the
  /// dwell. The first fires ~1s in — after a session reset it is the
  /// handshake trigger, so the establishment ladder starts immediately.
  /// Targets resolve at fire time (a peer identified mid-dwell still
  /// counts). Ids are the offline-reproducible UUIDv5 set
  /// `field|expId|src|dst|stepIndex|seq`.
  void _scheduleSends(FieldStep step) {
    final doSend = send;
    final plan = _plan!;
    if (step.sendCount <= 0 || doSend == null) return;

    final windowSec = step.dwellSec > 2 ? step.dwellSec - 2 : step.dwellSec;
    final stepIdx = _stepIndex;
    for (var seq = 0; seq < step.sendCount; seq++) {
      final offsetSec = 1 + (seq * windowSec) ~/ step.sendCount;
      final localSeq = seq;
      _sendTimers.add(Timer(Duration(seconds: offsetSec), () {
        for (final (dstLabel, pubkey) in _sendTargets()) {
          final messageId = _uuid.v5(workloadUuidNamespace,
              'field|${plan.expId}|$_srcLabel|$dstLabel|$stepIdx|$localSeq');
          final payload = Uint8List(step.sendBytes);
          for (var i = 0; i < payload.length; i++) {
            payload[i] = (localSeq + i) & 0xff;
          }
          _sentCount++;
          unawaited(doSend(pubkey, payload, messageId: messageId));
        }
        notifyListeners();
      }));
    }
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
    final step = currentStep;
    if (step != null && step.bulk) onStopBulk?.call();
    onWindowElapsed?.call();
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
    notifyListeners();
  }

  Future<void> _finish() async {
    await recorder.stopExperiment();
    onWindowElapsed?.call();
    final doUpload = upload;
    if (doUpload != null) {
      try {
        _uploadResult = await doUpload();
      } catch (_) {
        _uploadResult = 'Upload failed — files kept on device';
      }
    } else {
      _uploadResult = 'No upload configured — share files manually';
    }
    _phase = FieldPhase.finished;
    _running = false;
    notifyListeners();
  }

  /// Abandon the run: marker the abort, stop bulk + recording. Files stay.
  Future<void> abort() async {
    if (!_running) return;
    _cancelSends();
    _tick?.cancel();
    _tick = null;
    final step = currentStep;
    if (step != null && step.bulk && _phase == FieldPhase.dwelling) {
      onStopBulk?.call();
    }
    await recorder.logMarker('aborted');
    await recorder.stopExperiment();
    _phase = FieldPhase.finished;
    _running = false;
    notifyListeners();
  }

  void _startCountdown(int seconds, Future<void> Function() onDone) {
    _tick?.cancel();
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
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _cancelSends();
    _tick?.cancel();
    _tick = null;
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
