import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/testbed/field_runner.dart';
import 'src/testbed/testbed_config.dart';

/// DEBUG/TESTBED ONLY. Full-screen field-experiment runner: giant text and a
/// single dominant button, readable at arm's length in sunlight. The
/// [FieldRunner] state machine does the sequencing; this screen renders its
/// phase and forwards taps.
class FieldRunnerScreen extends StatefulWidget {
  final FieldRunner runner;
  final FieldPlan plan;

  const FieldRunnerScreen({
    super.key,
    required this.runner,
    required this.plan,
  });

  @override
  State<FieldRunnerScreen> createState() => _FieldRunnerScreenState();
}

class _FieldRunnerScreenState extends State<FieldRunnerScreen> {
  @override
  void initState() {
    super.initState();
    widget.runner.addListener(_onRunner);
    if (!widget.runner.isRunning) {
      widget.runner.start(widget.plan);
    }
  }

  @override
  void dispose() {
    widget.runner.removeListener(_onRunner);
    super.dispose();
  }

  void _onRunner() {
    if (mounted) setState(() {});
  }

  String _mmss(int sec) =>
      '${(sec ~/ 60).toString().padLeft(2, '0')}:'
      '${(sec % 60).toString().padLeft(2, '0')}';

  /// Hours only once there are hours: a whole run is four digits of minutes
  /// in mm:ss, which is read as a clock time and misread as minutes.
  String _span(int sec) {
    if (sec < 0) sec = 0;
    if (sec < 3600) return _mmss(sec);
    return '${sec ~/ 3600}:'
        '${((sec % 3600) ~/ 60).toString().padLeft(2, '0')}:'
        '${(sec % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _confirmAbort() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abort the run?'),
        content: const Text('An "aborted" marker is stamped and the recording '
            'stops. Files stay on the device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep running')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Abort')),
        ],
      ),
    );
    if (confirmed == true) await widget.runner.abort();
  }

  @override
  Widget build(BuildContext context) {
    final runner = widget.runner;
    final plan = widget.plan;
    final step = runner.currentStep;
    final total = plan.steps.length;

    return PopScope(
      canPop: !runner.isRunning,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text('${plan.expId} — step '
              '${(runner.stepIndex + 1).clamp(1, total)}/$total'
              '${runner.joinOrder == null ? '' : ' · #${runner.joinOrder}'}'),
          actions: [
            if (runner.isRunning)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () async => _confirmAbort(),
              ),
          ],
        ),
        // Landscape is the field orientation — a phone on a tripod does not
        // rotate — and there the viewport is short enough that the countdown
        // and the abort screen overflow. Scroll when the content is taller
        // than the viewport, centre it when it is not, so nothing is ever
        // unreachable and the common case still looks deliberate.
        body: SafeArea(
          child: Column(children: [
            // A phone nobody can find still scans, still dials, still counts
            // down — nothing in the normal display contradicts it. This is the
            // only thing between that and an hour of empty trace, so it sits
            // above every phase rather than inside one.
            if (widget.runner.bleUndiscoverable?.call() ?? false)
              Container(
                width: double.infinity,
                color: Colors.red.shade900,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: const Row(children: [
                  Icon(Icons.wifi_tethering_off, color: Colors.white, size: 30),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'NOT ADVERTISING — no peer can find this phone.\n'
                      'Check aeroplane mode and Bluetooth.',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800),
                    ),
                  ),
                ]),
              ),
            Expanded(
              child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
                child: switch (runner.phase) {
                  _ when runner.finishing => _finishing(runner),
                  _ when runner.resetting => _resetting(step),
                  FieldPhase.placement => _placement(runner),
                  _ when runner.waitingToJoin => _waitingToJoin(runner),
                  FieldPhase.positioning => runner.manualJoin
                      ? _manualGap(step!, runner)
                      : _positioning(step!, runner),
                  // A dwell the operator has to act in is an instruction;
                  // one they do not is just time left on the run.
                  // Measuring and walking are different instructions — one
                  // means stand still, the other means go — so they cannot
                  // share a headline. The dwell names itself; the walk window
                  // (positioning) carries the big MOVE countdown.
                  FieldPhase.dwelling => runner.radioAction != null
                      ? _radioPrompt(runner.radioAction!, runner.remainingSec)
                      : _measuring(step!, runner),
                  FieldPhase.settling => _countdown(
                      'SETTLING',
                      runner.remainingSec,
                      'letting late ACKs land',
                      Colors.blue,
                      // Escape hatch: the settle window is the last thing
                      // between a finished run and its files, and a phone
                      // that looks stuck here holds up everyone else.
                      onSkip: () async => widget.runner.forceFinish(),
                      skipLabel: 'Finish now'),
                  FieldPhase.finished => _finished(runner),
                },
              ),
            ),
          ),
            ),
          ]),
        ),
      ),
    );
  }

  /// The shared anchor, rendered in UTC.
  ///
  /// This string is the fleet's alignment CHECK — every phone must show the
  /// same one — and the anchor itself is an epoch instant, identical on every
  /// phone regardless of timezone. Rendering it in LOCAL time made the check
  /// test the timezone instead: a phone whose zone is two hours out would
  /// display a start time two hours off while computing exactly the same
  /// anchor, which reads as a broken clock. In
  /// UTC, phones that agree show identical text and phones that disagree
  /// really do disagree.
  /// A wall-clock time for the operator, in the phone's own timezone.
  ///
  /// The schedule is computed in UTC so every phone lands on one instant, but
  /// nobody standing at the bench is holding a UTC clock — the time shown here
  /// is the one they can compare against a watch.
  static String _hhmmss(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  /// "BLUETOOTH ON in 12:30 (at 14:52:30)" for a phone that joins later.
  String _joinEta(FieldRunner runner) {
    final at = runner.myJoinAtMs;
    if (at == null || !runner.joinsLater) return '';
    final rem = at - DateTime.now().millisecondsSinceEpoch;
    return 'BLUETOOTH ON in ${_mmss(rem <= 0 ? 0 : rem ~/ 1000)}'
        ' (at ${_hhmmss(at)})';
  }

  /// Manual-join placement: the phones are being carried to their marks and
  /// every screen shows the SAME target instant — which is also the check:
  /// a phone whose clock is wrong shows a different time, before the run
  /// instead of in the data afterwards.
  Widget _placement(FieldRunner runner) {
    final target = runner.startTargetMs;
    final later = runner.joinsLater;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('PLACE THE PHONES',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 24)),
        const SizedBox(height: 10),
        if (target != null)
          FittedBox(
            child: Text('starts at ${_hhmmss(target)}',
                style: const TextStyle(
                    color: Colors.tealAccent,
                    fontSize: 54,
                    fontWeight: FontWeight.w800)),
          ),
        const SizedBox(height: 6),
        const Text(
            'every phone must show this exact time — one that differs has a '
            'wrong clock',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 14)),
        const SizedBox(height: 18),
        Text(_mmss(runner.remainingSec),
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 88,
                fontWeight: FontWeight.w800)),
        if (runner.joinOrder != null) ...[
          const SizedBox(height: 14),
          _orderBadge(runner.joinOrder!),
        ],
        const SizedBox(height: 14),
        if (runner.radioAction != null)
          Text(
              runner.radioAction == 'on'
                  ? 'TURN BLUETOOTH ON — it must be up before the start'
                  : 'TURN BLUETOOTH OFF — it must be down before the start',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 20,
                  fontWeight: FontWeight.w800))
        else
          Text(
              later
                  ? 'keep Bluetooth OFF — this phone joins at '
                      '${runner.myJoinAtMs == null ? "its step" : _hhmmss(runner.myJoinAtMs!)}'
                  : 'Bluetooth stays ON on this phone',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: later ? Colors.orangeAccent : Colors.white54,
                  fontSize: 18,
                  fontWeight: FontWeight.w600)),
      ],
    );
  }

  /// A phone that has not joined the mesh yet. On a scripted-radio plan the
  /// runner works the transport itself, so there is nothing to ask for and
  /// the screen counts down to the end of the run like any other idle phone.
  /// Where the operator owns the radio, their join IS an instruction, so it
  /// wears the same ENABLE BT face as every other radio window.
  Widget _waitingToJoin(FieldRunner runner) {
    final joinAt = runner.myJoinAtMs;
    final windowAt = joinAt == null
        ? null
        : joinAt - widget.plan.autoAdvanceGapSec * 1000;
    if (widget.plan.scriptedRadio) {
      return _untilEnd(runner,
          note: windowAt == null
              ? null
              : 'joins itself at ${_hhmmss(windowAt)}');
    }
    final remaining = windowAt == null
        ? 0
        : ((windowAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    return _radioPrompt('on', remaining < 0 ? 0 : remaining,
        order: runner.joinOrder);
  }

  /// The dwell, named: the phones are measuring and must not move.
  ///
  /// The next position rides along as a footnote so the operator knows where
  /// they are headed, but the instruction to GO is the walk window's alone —
  /// a headline that says MOVE while the trial is still running reads as an
  /// instruction to move.
  Widget _measuring(FieldStep step, FieldRunner runner) {
    final move = runner.nextMove;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.wifi_tethering, color: Colors.tealAccent, size: 64),
        const SizedBox(height: 14),
        const Text('MEASURING — HOLD POSITION',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white54,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
        FittedBox(
          child: Text(step.label,
              style: const TextStyle(
                  color: Colors.tealAccent,
                  fontSize: 96,
                  fontWeight: FontWeight.w800)),
        ),
        Text('${_mmss(runner.remainingSec)} left in this trial',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 22)),
        if (move != null) ...[
          const SizedBox(height: 18),
          Text('then walk to ${move.label} — be there ${_hhmmss(move.atMs)}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 20)),
        ],
        if (step.bulk)
          const Text('bulk flows running',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 16)),
      ],
    );
  }

  /// The operator's next walk, counted down.
  ///
  /// On a plan that asks nobody to move, time-to-end is the only number worth
  /// this size. On a sweep it is the wrong one: the run ends in an hour and
  /// the next position is due in two minutes, and missing that instant
  /// measures a distance the trace will still label as the one intended.
  Widget _untilMove(FieldRunner runner, ({int atMs, String label}) move) {
    final remaining =
        ((move.atMs - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    final late = remaining <= 0;
    final urgent = remaining <= 30;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(late ? Icons.directions_run : Icons.directions_walk,
            color: late ? Colors.redAccent : Colors.orangeAccent, size: 64),
        const SizedBox(height: 14),
        FittedBox(
          child: Text(late ? 'BE AT ${move.label} NOW' : 'MOVE TO ${move.label} IN',
              style: TextStyle(
                  color: late ? Colors.redAccent : Colors.orangeAccent,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.1)),
        ),
        if (!late)
          FittedBox(
            child: Text(_span(remaining),
                style: TextStyle(
                    color: urgent ? Colors.redAccent : Colors.tealAccent,
                    fontSize: 96,
                    fontWeight: FontWeight.w800)),
          ),
        Text('at ${_hhmmss(move.atMs)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 22)),
        const SizedBox(height: 18),
        Text(
            runner.planEndMs == null
                ? ''
                : 'run ends ${_hhmmss(runner.planEndMs!)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 18)),
        if (runner.joinOrder != null) ...[
          const SizedBox(height: 14),
          _orderBadge(runner.joinOrder!),
        ],
      ],
    );
  }

  /// The one screen for a phone with nothing to do: how long until the whole
  /// run is over. A step boundary nobody has to act on is not worth a number
  /// this size, and an unattended run is read from across a room.
  Widget _untilEnd(FieldRunner runner, {String? note}) {
    final endAt = runner.planEndMs;
    final remaining = endAt == null
        ? runner.remainingSec
        : ((endAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.hourglass_bottom, color: Colors.white24, size: 64),
        const SizedBox(height: 14),
        const Text('EXPERIMENT ENDS IN',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white54,
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
        FittedBox(
          child: Text(_span(remaining),
              style: const TextStyle(
                  color: Colors.tealAccent,
                  fontSize: 96,
                  fontWeight: FontWeight.w800)),
        ),
        if (endAt != null)
          Text('at ${_hhmmss(endAt)}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 22)),
        if (runner.joinOrder != null) ...[
          const SizedBox(height: 18),
          _orderBadge(runner.joinOrder!),
        ],
        const SizedBox(height: 16),
        Text(
            [
              if (note != null) note,
              '${runner.currentStep?.label ?? ''} '
                  '(step ${runner.stepIndex + 1}/${widget.plan.steps.length})',
            ].join('\n'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white30, fontSize: 14)),
      ],
    );
  }

  /// The between-step gap in manual mode — no taps exist. Where the operator
  /// owns the radio and the NEXT step is this phone's first joined one, this
  /// gap IS their window to turn Bluetooth on, and the screen is nothing but
  /// that instruction; `radioAction` is what decides that, and it stays null
  /// on a scripted-radio plan.
  Widget _manualGap(FieldStep step, FieldRunner runner) {
    final action = runner.radioAction;
    if (action != null) return _radioPrompt(action, runner.remainingSec);
    final move = runner.nextMove;
    if (move != null && runner.radioSeenUp) return _untilMove(runner, move);
    return _untilEnd(runner,
        note: !runner.radioSeenUp && runner.joinsLater
            ? _joinEta(runner)
            : 'next — ${step.label}');
  }

  /// Full-screen radio instruction: the operator's window to toggle system
  /// Bluetooth, counted down. One widget for both directions and for both a
  /// mid-run window and a join, so the ask is phrased the same everywhere.
  Widget _radioPrompt(String action, int remainingSec, {int? order}) {
    final on = action == 'on';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(on ? Icons.bluetooth : Icons.bluetooth_disabled,
            color: Colors.orangeAccent, size: 88),
        const SizedBox(height: 16),
        FittedBox(
          child: Text(on ? 'ENABLE BT IN' : 'DISABLE BT IN',
              style: const TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 44,
                  fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 10),
        FittedBox(
          child: Text(_span(remainingSec),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 88,
                  fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 10),
        const Text('in the phone\'s Settings — the step starts either way',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 16)),
        if (order != null) ...[
          const SizedBox(height: 18),
          _orderBadge(order),
        ],
      ],
    );
  }

  /// This phone's assigned join order, sized to be read at arm's length while
  /// the phone is being placed.
  Widget _orderBadge(int order) => Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.tealAccent, width: 3),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text('THIS PHONE IS #$order',
              style: const TextStyle(
                  color: Colors.tealAccent,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5)),
        ),
      );

  /// The settle window has closed and the run is wrapping up. Shown
  /// separately because the phase is still `settling` until the upload
  /// returns — so the countdown reads 00:00 for however long a large trace
  /// takes to chunk to the server, which is indistinguishable from wedged.
  Widget _finishing(FieldRunner runner) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
              height: 74,
              child: Center(
                  child: SizedBox(
                      width: 54,
                      height: 54,
                      child: CircularProgressIndicator(
                          strokeWidth: 5,
                          color: Colors.tealAccent,
                          // Determinate once the upload reports bytes read;
                          // indeterminate while the buffer is still being
                          // written, where there is nothing honest to show.
                          value: runner.uploadFraction)))),
          const SizedBox(height: 22),
          const Text('WRAPPING UP',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.tealAccent,
                  fontSize: 38,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text(runner.finishingWhat,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 20)),
          if (runner.uploadFraction != null) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: runner.uploadFraction,
                minHeight: 10,
                backgroundColor: Colors.white12,
                color: Colors.tealAccent,
              ),
            ),
            const SizedBox(height: 8),
            Text('${runner.uploadChunks} chunk(s) sent',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white38, fontSize: 15)),
          ],
          const SizedBox(height: 10),
          const Text(
              'The recording is already on disk. A large trace uploads in '
              'chunks and can take minutes.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 15)),
          const SizedBox(height: 30),
          SizedBox(
            height: 72,
            child: OutlinedButton(
              onPressed: () async => widget.runner.forceFinish(),
              child: const Text('Finish now (upload later)',
                  style: TextStyle(fontSize: 21)),
            ),
          ),
        ],
      );

  Widget _aborted(String reason) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.error, color: Colors.redAccent, size: 96),
          const SizedBox(height: 24),
          const Text('RUN ABORTED',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.redAccent,
                  fontSize: 40,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          Text(reason,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 20)),
          const SizedBox(height: 16),
          const Text('The recorded data is NOT usable. Fix the radio and '
              'start over.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 18)),
          const SizedBox(height: 48),
          SizedBox(
            height: 72,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done', style: TextStyle(fontSize: 24)),
            ),
          ),
        ],
      );

  Widget _resetting(FieldStep? step) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.bluetooth_disabled,
              color: Colors.white54, size: 72),
          const SizedBox(height: 24),
          const Text('RESETTING BLE',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text('going dark so the peer drops us, then reconnecting…'
              '${step != null ? '\nnext: ${step.label}' : ''}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 16)),
        ],
      );

  Widget _positioning(FieldStep step, FieldRunner runner) {
    final auto = step.autoAdvance;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(auto ? 'AUTO-ADVANCING' : 'WALK TO',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 24)),
        const SizedBox(height: 8),
        FittedBox(
          child: Text(step.label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 72,
                  fontWeight: FontWeight.w800)),
        ),
        if (auto) ...[
          const SizedBox(height: 8),
          Text('starts in ${runner.remainingSec}s',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 22)),
        ],
        const SizedBox(height: 48),
        SizedBox(
          height: 140,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green,
              textStyle:
                  const TextStyle(fontSize: 40, fontWeight: FontWeight.w800),
            ),
            onPressed: () async {
              await HapticFeedback.heavyImpact();
              await runner.inPosition();
            },
            child: Text(auto ? 'START NOW' : 'IN POSITION'),
          ),
        ),
        const SizedBox(height: 16),
        Text('dwell ${_mmss(step.dwellSec)}'
            '${step.bulk ? ' + bulk flows' : ''}'
            '${step.sendCount > 0 ? ' + ${step.sendCount} sends' : ''}'
            '${runner.sentCount > 0 ? ' — ${runner.sentCount} sent' : ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 18)),
      ],
    );
  }

  Widget _countdown(String title, int sec, String subtitle, Color color,
      {Future<void> Function()? onSkip, String skipLabel = 'Skip'}) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FittedBox(
          child: Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: color, fontSize: 48, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 24),
        Text(_mmss(sec),
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 120,
                fontWeight: FontWeight.w800,
                fontFeatures: [FontFeature.tabularFigures()])),
        const SizedBox(height: 16),
        Text(subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 18)),
        if (onSkip != null) ...[
          const SizedBox(height: 26),
          SizedBox(
            height: 64,
            child: OutlinedButton(
              onPressed: () async => onSkip(),
              child: Text(skipLabel, style: const TextStyle(fontSize: 20)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _finished(FieldRunner runner) {
    // An abort that renders like a normal finish is how bad data gets
    // analysed as if it were good — show the reason instead of a green tick.
    final aborted = runner.abortReason;
    if (aborted != null) return _aborted(aborted);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 96),
        const SizedBox(height: 24),
        const Text('RUN COMPLETE',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white,
                fontSize: 40,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 16),
        Text(runner.uploadResult ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 20)),
        const SizedBox(height: 48),
        SizedBox(
          height: 72,
          child: OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done', style: TextStyle(fontSize: 24)),
          ),
        ),
      ],
    );
  }
}
