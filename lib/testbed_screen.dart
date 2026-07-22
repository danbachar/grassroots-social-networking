import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:redux/redux.dart';

import 'src/store/app_state.dart';
import 'src/store/settings_actions.dart';
import 'src/testbed/testbed_config.dart';
import 'src/testbed/workload_driver.dart';

/// Live status of the workload driver, surfaced for the testbed UI.
class WorkloadStatus {
  final bool running;
  final int scheduled;
  final int sent;
  const WorkloadStatus(
      {required this.running, required this.scheduled, required this.sent});
}

/// DEBUG/TESTBED ONLY screen. Two harnesses for the evaluation in
/// `docs/testbed_case_studies.md`:
///   1. Neighbour allowlist — force an arbitrary BLE topology.
///   2. Workload driver — deterministic offered load.
///
/// Both are inert in production: the allowlist only bites when explicitly
/// enabled here, and the workload only runs while Start is held.
class TestbedScreen extends StatefulWidget {
  final Store<AppState> store;

  /// This device's hex public key (for building/verifying the roster). Null if
  /// the network isn't up yet.
  final String? myPubkeyHex;

  final Future<void> Function()? onStartWorkload;
  final VoidCallback? onStopWorkload;
  final WorkloadStatus Function()? workloadStatus;

  const TestbedScreen({
    super.key,
    required this.store,
    this.myPubkeyHex,
    this.onStartWorkload,
    this.onStopWorkload,
    this.workloadStatus,
  });

  @override
  State<TestbedScreen> createState() => _TestbedScreenState();
}

class _TestbedScreenState extends State<TestbedScreen> {
  late final TextEditingController _allowController;
  late final TextEditingController _workloadController;
  bool _allowEnabled = false;
  Timer? _statusTimer;
  String? _workloadError;
  int _computedSchedule = -1;

  @override
  void initState() {
    super.initState();
    final settings = widget.store.state.settings;
    final allow = settings.neighborAllowlist;
    _allowEnabled = allow?.enabled ?? false;
    _allowController =
        TextEditingController(text: (allow?.allow ?? const []).join('\n'));
    _workloadController = TextEditingController(
      text: settings.workloadConfig == null
          ? ''
          : const JsonEncoder.withIndent('  ')
              .convert(settings.workloadConfig!.toJson()),
    );
    _statusTimer = Timer.periodic(
        const Duration(milliseconds: 500), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _allowController.dispose();
    _workloadController.dispose();
    super.dispose();
  }

  void _applyAllowlist() {
    final lines = _allowController.text
        .split(RegExp(r'[\s,]+'))
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();
    widget.store.dispatch(SetNeighborAllowlistAction(
        NeighborAllowlist(enabled: _allowEnabled, allow: lines)));
    _snack('Allowlist applied: ${lines.length} neighbour(s), '
        'enabled=$_allowEnabled');
  }

  void _clearAllowlist() {
    widget.store.dispatch(SetNeighborAllowlistAction(null));
    setState(() {
      _allowEnabled = false;
      _allowController.text = '';
    });
    _snack('Allowlist cleared (production behaviour)');
  }

  void _loadWorkload() {
    setState(() {
      _workloadError = null;
      _computedSchedule = -1;
    });
    try {
      final json = jsonDecode(_workloadController.text) as Map<String, dynamic>;
      final config = WorkloadConfig.fromJson(json);
      widget.store.dispatch(SetWorkloadConfigAction(config));
      final me = widget.myPubkeyHex;
      final count = me == null
          ? -1
          : WorkloadDriver.computeSchedule(config: config, myPubkeyHex: me)
              .length;
      setState(() => _computedSchedule = count);
      _snack('Workload loaded${count >= 0 ? ' — $count sends scheduled for '
          'this device' : ''}');
    } catch (e) {
      setState(() => _workloadError = e.toString());
    }
  }

  void _clearWorkload() {
    widget.store.dispatch(SetWorkloadConfigAction(null));
    setState(() {
      _workloadController.text = '';
      _computedSchedule = -1;
    });
    _snack('Workload config cleared');
  }

  void _fillExample() {
    final me = widget.myPubkeyHex ?? '<this-device-hex-pubkey>';
    final example = {
      'seed': 42,
      'startAtEpochMs': DateTime.now()
              .add(const Duration(seconds: 30))
              .millisecondsSinceEpoch,
      'endAtEpochMs': DateTime.now()
              .add(const Duration(minutes: 30))
              .millisecondsSinceEpoch,
      'ratePerPairPerHour': 60,
      'roster': [
        {'label': 'A', 'pubkeyHex': me},
        {'label': 'B', 'pubkeyHex': '<peer-B-hex-pubkey>'},
        {'label': 'C', 'pubkeyHex': '<peer-C-hex-pubkey>'},
      ],
      'payloadMix': [
        {'bytes': 184, 'weight': 0.8},
        {'bytes': 1200, 'weight': 0.2},
      ],
    };
    _workloadController.text =
        const JsonEncoder.withIndent('  ').convert(example);
    setState(() {});
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.workloadStatus?.call();
    return Scaffold(
      appBar: AppBar(title: const Text('Testbed (debug)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader(
              'Neighbour allowlist', 'Software-defined BLE topology'),
          const Text(
            'When enabled, this device only forms BLE links with the listed '
            'neighbours (full hex public keys, one per line). Off = normal.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Allowlist enabled'),
            value: _allowEnabled,
            onChanged: (v) => setState(() => _allowEnabled = v),
          ),
          TextField(
            controller: _allowController,
            maxLines: 4,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'one hex pubkey per line',
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton(onPressed: _applyAllowlist, child: const Text('Apply')),
            const SizedBox(width: 8),
            OutlinedButton(
                onPressed: _clearAllowlist, child: const Text('Clear')),
          ]),
          if (widget.myPubkeyHex != null) ...[
            const SizedBox(height: 8),
            _copyableKey('This device', widget.myPubkeyHex!),
          ],
          const Divider(height: 40),
          _sectionHeader('Workload driver', 'Deterministic offered load'),
          const Text(
            'Paste the shared workload JSON (identical on every device). Load '
            'stores it; Start executes only this device\'s source rows, firing '
            'sends regardless of reachability.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _workloadController,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'WorkloadConfig JSON',
            ),
          ),
          if (_workloadError != null) ...[
            const SizedBox(height: 6),
            Text('Parse error: $_workloadError',
                style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
          if (_computedSchedule >= 0) ...[
            const SizedBox(height: 6),
            Text('$_computedSchedule sends scheduled for this device',
                style: const TextStyle(fontSize: 12, color: Colors.green)),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: _fillExample, child: const Text('Fill example')),
            FilledButton(
                onPressed: _loadWorkload, child: const Text('Load config')),
            OutlinedButton(
                onPressed: _clearWorkload, child: const Text('Clear')),
          ]),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    status == null
                        ? 'Driver: unavailable (network not up)'
                        : 'Driver: ${status.running ? 'RUNNING' : 'stopped'} — '
                            'sent ${status.sent} / ${status.scheduled}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    FilledButton.icon(
                      onPressed: widget.onStartWorkload == null
                          ? null
                          : () async => widget.onStartWorkload!.call(),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: widget.onStopWorkload,
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, String subtitle) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            Text(subtitle,
                style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ],
        ),
      );

  Widget _copyableKey(String label, String hex) => InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: hex));
          _snack('$label pubkey copied');
        },
        child: Row(children: [
          const Icon(Icons.copy, size: 14, color: Colors.grey),
          const SizedBox(width: 6),
          Expanded(
            child: Text('$label: $hex',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      );
}
