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

  /// DEBUG/TESTBED. Signals every peer to start; returns how many were
  /// reached. Present only when the runner was armed for a remote start.
  final Future<int> Function(String expId)? onBroadcastStart;

  /// Peers this phone holds a Noise SESSION with — one hop, not the mesh.
  ///
  /// Sessions, not live links: the start signal travels on sessions, and a
  /// session is keyed by peer identity so it survives the link churn a
  /// joining phone causes. Counting live links instead made this collapse to
  /// 1-2 mid-join while the flood was entirely healthy.
  ///
  /// It does not have to reach the roster size before pressing — phones
  /// further out are reached by relay. It has to be non-zero and settled.
  final int Function()? neighbourCount;

  /// Phones in the connected component containing this one, learned from the
  /// armed-time neighbour gossip. This is the number that answers "will the
  /// start signal reach everyone", which a one-hop count cannot.
  final int Function()? meshComponentSize;

  /// Gossip this phone's neighbours to its peers. Driven on a timer while
  /// armed, and never while a run is under way.
  final Future<int> Function()? onGossipNeighbours;

  /// Drop the gossiped view when the run begins.
  final VoidCallback? onClearMeshView;

  const FieldRunnerScreen({
    super.key,
    required this.runner,
    required this.plan,
    this.onBroadcastStart,
    this.neighbourCount,
    this.meshComponentSize,
    this.onGossipNeighbours,
    this.onClearMeshView,
  });

  @override
  State<FieldRunnerScreen> createState() => _FieldRunnerScreenState();
}

class _FieldRunnerScreenState extends State<FieldRunnerScreen> {
  Timer? _armedTick;
  int _tickCount = 0;

  @override
  void initState() {
    super.initState();
    widget.runner.addListener(_onRunner);
    // Nothing notifies while merely armed, but the peer count is changing as
    // the mesh converges — and that is exactly what you are waiting on.
    _armedTick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || widget.runner.armedPlan == null) return;
      // Gossip every other tick: often enough that the count settles while
      // you walk back from placing the last phone, rare enough to be
      // invisible next to ANNOUNCE traffic.
      if ((_tickCount++).isEven) unawaited(widget.onGossipNeighbours?.call());
      setState(() {});
    });
    // An ARMED runner is deliberately not started: it is waiting for a
    // peer's signal (or for this phone to be the one that sends it).
    if (!widget.runner.isRunning && widget.runner.armedPlan == null) {
      widget.runner.start(widget.plan);
    }
  }

  @override
  void dispose() {
    _armedTick?.cancel();
    widget.runner.removeListener(_onRunner);
    super.dispose();
  }

  void _onRunner() {
    if (mounted) setState(() {});
  }

  String _mmss(int sec) =>
      '${(sec ~/ 60).toString().padLeft(2, '0')}:'
      '${(sec % 60).toString().padLeft(2, '0')}';

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
              '${plan.deviceOrder == null ? '' : ' · #${plan.deviceOrder}'}'),
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
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
                child: switch (runner.phase) {
                  _ when runner.armedPlan != null => _armed(runner),
                  _ when runner.finishing => _finishing(runner),
                  _ when runner.resetting => _resetting(step),
                  FieldPhase.placement => _placement(runner),
                  _ when runner.waitingToJoin => _waitingToJoin(runner),
                  FieldPhase.positioning => runner.manualJoin
                      ? _manualGap(step!, runner)
                      : _positioning(step!, runner),
                  FieldPhase.dwelling => _countdown(
                      'HOLD — ${step!.label}',
                      runner.remainingSec,
                      [
                        step.bulk ? 'bulk flows running' : 'recording',
                        if (runner.radioAction != null)
                          'TURN BLUETOOTH '
                              '${runner.radioAction == 'on' ? 'ON' : 'OFF'} — '
                              'the window has already started',
                        if (runner.locationStatus.isNotEmpty)
                          runner.locationStatus,
                      ].join('\n'),
                      Colors.orangeAccent),
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
      ),
    );
  }

  /// Waiting for a peer's start signal. Every phone sits here; ONE is
  /// tapped and signals the rest, so devices spread over hundreds of metres
  /// begin together instead of however far apart their taps landed.
  Widget _armed(FieldRunner runner) {
    final broadcast = widget.onBroadcastStart;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.podcasts_rounded, color: Colors.tealAccent, size: 88),
        const SizedBox(height: 20),
        const Text('ARMED',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.tealAccent,
                fontSize: 44,
                fontWeight: FontWeight.w800)),
        // The join order decides when this phone enters the mesh, and a phone
        // handed to the wrong spot silently costs a whole mesh size: the
        // 7-device smoke run's n=3 steps had two devices because one slot was
        // never filled. This is the screen you are looking at while placing
        // the phones, so the order is stated here, big, not left to the
        // preset name in a list somewhere behind you.
        if (runner.armedPlan!.deviceOrder != null) ...[
          const SizedBox(height: 16),
          _orderBadge(runner.armedPlan!.deviceOrder!),
        ],
        const SizedBox(height: 12),
        Text('waiting for the start signal\n"${runner.armedPlan!.expId}"',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 19),
            ),
        const SizedBox(height: 10),
        const Text(
            'Place every phone first, then press START ALL on exactly one.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 15)),
        if (widget.neighbourCount != null) ...[
          const SizedBox(height: 14),
          Builder(builder: (_) {
            final n = widget.neighbourCount!();
            // One hop. Phones further out are reached by relay, so this does
            // not need to equal the roster — it needs to be non-zero and to
            // have stopped climbing.
            // The mesh figure is the one that answers "will the signal
            // reach everyone" — the neighbour count is only this phone's
            // one-hop view and is shown as supporting detail.
            final mesh = widget.meshComponentSize?.call();
            return Column(children: [
              if (mesh != null)
                Text('$mesh phone(s) in the mesh',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: mesh <= 1
                            ? Colors.orangeAccent
                            : Colors.tealAccent,
                        fontSize: 30,
                        fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                  n == 0
                      ? 'no sessions yet — wait for the mesh to form'
                      : '$n session peer(s) of this phone',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: n == 0 ? Colors.orangeAccent : Colors.white54,
                      fontSize: 15)),
              const SizedBox(height: 4),
              const Text('press START ALL once this stops climbing',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white30, fontSize: 13)),
            ]);
          }),
        ],
        const SizedBox(height: 34),
        if (broadcast != null)
          SizedBox(
            height: 88,
            child: FilledButton(
              onPressed: () async {
                final expId = runner.armedPlan!.expId;
                final n = await broadcast(expId);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(n == 0
                        ? 'No peer reached — is anyone else armed and in range?'
                        : 'Signalled $n peer(s)')));
                // This phone starts too: it is part of the mesh, not a
                // remote control.
                widget.onClearMeshView?.call();
                await runner.remoteStart(expId);
              },
              child: const Text('START ALL',
                  style: TextStyle(
                      fontSize: 30, fontWeight: FontWeight.w800)),
            ),
          ),
        const SizedBox(height: 14),
        SizedBox(
          height: 60,
          child: OutlinedButton(
            onPressed: () {
              runner.disarm();
              Navigator.of(context).pop();
            },
            child: const Text('Cancel', style: TextStyle(fontSize: 20)),
          ),
        ),
      ],
    );
  }

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
        if (widget.plan.deviceOrder != null) ...[
          const SizedBox(height: 14),
          _orderBadge(widget.plan.deviceOrder!),
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

  /// A phone that has not joined the mesh yet: the run's step progression is
  /// irrelevant to its operator — the one thing that matters is when to turn
  /// Bluetooth on, so that is the whole screen.
  Widget _waitingToJoin(FieldRunner runner) {
    final joinAt = runner.myJoinAtMs;
    final windowAt = joinAt == null
        ? null
        : joinAt - widget.plan.autoAdvanceGapSec * 1000;
    final remaining = windowAt == null
        ? 0
        : ((windowAt - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.bluetooth_disabled,
            color: Colors.white54, size: 72),
        const SizedBox(height: 14),
        const Text('KEEP BLUETOOTH OFF',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white70,
                fontSize: 30,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 22),
        const Text('you turn it ON in',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 20)),
        Text(_mmss(remaining < 0 ? 0 : remaining),
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.tealAccent,
                fontSize: 96,
                fontWeight: FontWeight.w800)),
        if (windowAt != null)
          Text('at ${_hhmmss(windowAt)}',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 22)),
        if (widget.plan.deviceOrder != null) ...[
          const SizedBox(height: 18),
          _orderBadge(widget.plan.deviceOrder!),
        ],
        const SizedBox(height: 16),
        Text(
            'run in progress — '
            '${runner.currentStep?.label ?? ''} '
            '(step ${runner.stepIndex + 1}/${widget.plan.steps.length})',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white30, fontSize: 14)),
      ],
    );
  }

  /// The between-step gap in manual mode — no taps exist. When the NEXT step
  /// is this phone's first joined one, this gap IS the operator's window to
  /// turn Bluetooth on, and the screen is nothing but that instruction.
  Widget _manualGap(FieldStep step, FieldRunner runner) {
    final action = runner.radioAction;
    if (action != null) return _radioPrompt(action, runner.remainingSec);
    return _countdown(
      'NEXT — ${step.label}',
      runner.remainingSec,
      [
        'between steps',
        if (!runner.radioSeenUp && runner.joinsLater) _joinEta(runner),
      ].join('\n'),
      Colors.blueGrey,
    );
  }

  /// Full-screen radio instruction: the operator's window to toggle system
  /// Bluetooth, counted down. One widget for both directions so an off-step
  /// and a join-step can never phrase the ask differently.
  Widget _radioPrompt(String action, int remainingSec) {
    final on = action == 'on';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(on ? Icons.bluetooth : Icons.bluetooth_disabled,
            color: Colors.orangeAccent, size: 88),
        const SizedBox(height: 16),
        FittedBox(
          child: Text(on ? 'TURN ON BLUETOOTH NOW' : 'TURN OFF BLUETOOTH NOW',
              style: const TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 44,
                  fontWeight: FontWeight.w800)),
        ),
        const SizedBox(height: 10),
        Text(_mmss(remainingSec),
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 88,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        const Text('in the phone\'s Settings — the step starts either way',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 16)),
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
        // Say what the tap will do about position, because the answer differs
        // by step and is otherwise only discoverable from the data afterwards.
        if (runner.hasLocation) ...[
          const SizedBox(height: 10),
          Text(
              step.label == 'distribute'
                  ? 'no GPS fix yet — this tap starts the walk-out.\n'
                      'The fix is taken where you put the phone down.'
                  : runner.locationFixes == 0
                      ? 'a GPS fix is taken when this step begins'
                      : 'tapping re-fixes this phone\'s position',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 15)),
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
