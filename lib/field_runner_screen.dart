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

  const FieldRunnerScreen({super.key, required this.runner, required this.plan});

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
              '${(runner.stepIndex + 1).clamp(1, total)}/$total'),
          actions: [
            if (runner.isRunning)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () async => _confirmAbort(),
              ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: switch (runner.phase) {
              _ when runner.resetting => _resetting(step),
              FieldPhase.positioning => _positioning(step!, runner),
              FieldPhase.dwelling => _countdown(
                  'HOLD — ${step!.label}',
                  runner.remainingSec,
                  step.bulk ? 'bulk flows running' : 'recording',
                  Colors.orangeAccent),
              FieldPhase.settling => _countdown('SETTLING',
                  runner.remainingSec, 'letting late ACKs land', Colors.blue),
              FieldPhase.finished => _finished(runner),
            },
          ),
        ),
      ),
    );
  }

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

  Widget _countdown(String title, int sec, String subtitle, Color color) {
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
      ],
    );
  }

  Widget _finished(FieldRunner runner) {
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
