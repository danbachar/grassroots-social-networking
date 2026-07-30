import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:redux/redux.dart';
import 'package:share_plus/share_plus.dart';

import 'src/store/app_state.dart';
import 'src/store/settings_actions.dart';
import 'src/testbed/bulk_flow_driver.dart';
import 'src/testbed/testbed_config.dart';
import 'src/testbed/workload_driver.dart';
import 'src/trace/experiment_recorder.dart';
import 'src/trace/trace_config.dart';

/// Live status of the workload driver, surfaced for the testbed UI.
class WorkloadStatus {
  final bool running;
  final int scheduled;
  final int sent;
  const WorkloadStatus(
      {required this.running, required this.scheduled, required this.sent});
}

/// Live status of the bulk-flow driver, surfaced for the testbed UI.
class BulkStatus {
  final bool running;
  final List<BulkFlowStatus> flows;
  const BulkStatus({required this.running, required this.flows});
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

  /// Trace logger for the experiment recording sink. Null hides the
  /// experiment section (network not up yet).
  final ExperimentRecorder? experimentRecorder;

  final VoidCallback? onStartBulk;
  final VoidCallback? onStopBulk;
  final BulkStatus Function()? bulkStatus;

  const TestbedScreen({
    super.key,
    required this.store,
    this.myPubkeyHex,
    this.onStartWorkload,
    this.onStopWorkload,
    this.workloadStatus,
    this.experimentRecorder,
    this.onStartBulk,
    this.onStopBulk,
    this.bulkStatus,
  });

  @override
  State<TestbedScreen> createState() => _TestbedScreenState();
}

class _TestbedScreenState extends State<TestbedScreen> {
  late final TextEditingController _allowController;
  late final TextEditingController _workloadController;
  late final TextEditingController _bulkController;
  late final TextEditingController _expIdController;
  late final TextEditingController _markerController;
  bool _allowEnabled = false;
  Timer? _statusTimer;
  String? _workloadError;
  String? _bulkError;
  int _computedSchedule = -1;
  int _expFileBytes = 0;
  bool _uploading = false;

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
    _bulkController = TextEditingController(
      text: settings.bulkFlowConfig == null
          ? ''
          : const JsonEncoder.withIndent('  ')
              .convert(settings.bulkFlowConfig!.toJson()),
    );
    _expIdController = TextEditingController(
        text: widget.experimentRecorder?.experimentId ?? '');
    _markerController = TextEditingController();
    _statusTimer = Timer.periodic(
        const Duration(milliseconds: 500), (_) => _refreshStatus());
  }

  void _refreshStatus() {
    final trace = widget.experimentRecorder;
    if (trace != null && trace.active) {
      unawaited(trace.experimentFileSize().then((bytes) {
        if (mounted) setState(() => _expFileBytes = bytes);
      }));
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _allowController.dispose();
    _workloadController.dispose();
    _bulkController.dispose();
    _expIdController.dispose();
    _markerController.dispose();
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

  void _loadBulk() {
    setState(() => _bulkError = null);
    try {
      final json = jsonDecode(_bulkController.text) as Map<String, dynamic>;
      final config = BulkFlowConfig.fromJson(json);
      widget.store.dispatch(SetBulkFlowConfigAction(config));
      final me = widget.myPubkeyHex?.toLowerCase();
      final myLabel = config.roster
          .where((r) => r.pubkeyHex.toLowerCase() == me)
          .map((r) => r.label)
          .firstOrNull;
      final mine = myLabel == null
          ? 0
          : config.flows.where((f) => f.srcLabel == myLabel).length;
      _snack('Bulk config loaded — $mine flow(s) have this device as source');
    } catch (e) {
      setState(() => _bulkError = e.toString());
    }
  }

  void _clearBulk() {
    widget.store.dispatch(SetBulkFlowConfigAction(null));
    setState(() => _bulkController.text = '');
    _snack('Bulk config cleared');
  }

  void _fillBulkExample() {
    final me = widget.myPubkeyHex ?? '<this-device-hex-pubkey>';
    final example = {
      'roster': [
        {'label': 'A', 'pubkeyHex': me},
        {'label': 'B', 'pubkeyHex': '<peer-B-hex-pubkey>'},
        {'label': 'C', 'pubkeyHex': '<peer-C-hex-pubkey>'},
      ],
      // Baseline: one pair. Contended all-to-all: list every ordered pair.
      'flows': [
        {'src': 'A', 'dst': 'B'},
      ],
      'payloadBytes': 16384,
      'durationMs': 120000,
      'inFlight': 2,
    };
    _bulkController.text = const JsonEncoder.withIndent('  ').convert(example);
    setState(() {});
  }

  Future<void> _toggleExperiment() async {
    final trace = widget.experimentRecorder;
    if (trace == null) return;
    if (trace.active) {
      await trace.stopExperiment();
      _snack('Experiment stopped');
    } else {
      final id = _expIdController.text.trim();
      if (id.isEmpty) {
        _snack('Enter an experiment id first');
        return;
      }
      await trace.startExperiment(id);
      _snack('Recording experiment "${trace.experimentId}"');
    }
    setState(() {});
  }

  Future<void> _logMarker() async {
    final trace = widget.experimentRecorder;
    final label = _markerController.text.trim();
    if (trace == null || label.isEmpty) return;
    await trace.logMarker(label);
    _snack('Marker: $label');
  }

  Future<void> _uploadExperimentFiles() async {
    final recorder = widget.experimentRecorder;
    if (recorder == null) return;
    if (!TraceConfig.isConfigured) {
      _snack('No upload token baked into this build '
          '(--dart-define=TRACE_TOKEN=...)');
      return;
    }
    if (_uploading) return;
    setState(() => _uploading = true);
    String message;
    try {
      message = await recorder.uploadExperimentFiles(
        url: TraceConfig.serverUrl,
        token: TraceConfig.serverToken,
        deviceId: widget.myPubkeyHex ?? 'unknown',
      );
    } catch (_) {
      message = 'Upload failed';
    }
    if (!mounted) return;
    setState(() => _uploading = false);
    _snack(message);
  }

  Future<void> _shareExperimentFiles() async {
    final trace = widget.experimentRecorder;
    if (trace == null) return;
    final paths = await trace.experimentFilePaths();
    if (paths.isEmpty) {
      _snack('No experiment files on this device');
      return;
    }
    await Share.shareXFiles(paths.map(XFile.new).toList(),
        subject: 'Grassroots experiment traces');
  }

  Future<void> _clearExperimentFiles() async {
    final trace = widget.experimentRecorder;
    if (trace == null) return;
    if (trace.active) {
      _snack('Stop the experiment before clearing');
      return;
    }
    final paths = await trace.experimentFilePaths();
    if (paths.isEmpty) {
      _snack('Nothing to clear');
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete experiment files?'),
        content: Text('${paths.length} recorded experiment file(s) will be '
            'permanently deleted from this device. Share them first.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await trace.clearExperimentFiles();
    _snack('Experiment files deleted');
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
          if (widget.experimentRecorder != null) ...[
            ..._experimentSection(widget.experimentRecorder!),
            const Divider(height: 40),
          ],
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
          const Divider(height: 40),
          ..._bulkSection(),
        ],
      ),
    );
  }

  List<Widget> _experimentSection(ExperimentRecorder trace) {
    final active = trace.active;
    return [
      _sectionHeader('Experiment recording',
          'Local ground-truth trace for the evaluation chapter'),
      const Text(
        'While recording, every trace record (RSSI samples, link stages, '
        'wire bytes, messages, markers) is appended to a local exp file — '
        'independent of the upload consent setting. Share it out when the '
        'run is done.',
        style: TextStyle(fontSize: 13, color: Colors.grey),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _expIdController,
            enabled: !active,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Experiment id',
              hintText: 'cp-line-1',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: () async => _toggleExperiment(),
          icon: Icon(active ? Icons.stop : Icons.fiber_manual_record),
          label: Text(active ? 'Stop' : 'Record'),
        ),
      ]),
      const SizedBox(height: 6),
      Text(
        active
            ? 'RECORDING "${trace.experimentId}" — '
                '${(_expFileBytes / 1024).toStringAsFixed(1)} KiB'
            : 'Not recording',
        style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? Colors.red : Colors.grey),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _markerController,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Ground-truth marker',
              hintText: 'd=80m approaching',
              isDense: true,
            ),
            onSubmitted: (_) => unawaited(_logMarker()),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: active ? () async => _logMarker() : null,
          child: const Text('Mark'),
        ),
      ]),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          onPressed: () async => _shareExperimentFiles(),
          icon: const Icon(Icons.ios_share),
          label: const Text('Share files'),
        ),
        OutlinedButton.icon(
          onPressed: _uploading ? null : () async => _uploadExperimentFiles(),
          icon: _uploading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_upload_outlined),
          label: Text(_uploading ? 'Uploading…' : 'Upload files'),
        ),
        OutlinedButton.icon(
          onPressed: () async => _clearExperimentFiles(),
          icon: const Icon(Icons.delete_outline),
          label: const Text('Clear files'),
        ),
      ]),
    ];
  }

  List<Widget> _bulkSection() {
    final status = widget.bulkStatus?.call();
    return [
      _sectionHeader('Bulk flows', 'Sustained throughput (dilating clique)'),
      const Text(
        'Paste the shared bulk-flow JSON (identical on every device). Each '
        'device runs only the flows where it is the source, keeping inFlight '
        'messages outstanding until the window ends. Never re-sends.',
        style: TextStyle(fontSize: 13, color: Colors.grey),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _bulkController,
        maxLines: 10,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: 'BulkFlowConfig JSON',
        ),
      ),
      if (_bulkError != null) ...[
        const SizedBox(height: 6),
        Text('Parse error: $_bulkError',
            style: const TextStyle(color: Colors.red, fontSize: 12)),
      ],
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
            onPressed: _fillBulkExample, child: const Text('Fill example')),
        FilledButton(onPressed: _loadBulk, child: const Text('Load config')),
        OutlinedButton(onPressed: _clearBulk, child: const Text('Clear')),
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
                    : 'Driver: ${status.running ? 'RUNNING' : 'stopped'}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (status != null)
                for (final f in status.flows)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '${f.flowLabel}: sent ${f.sent}, acked ${f.acked} '
                      '(${(f.ackedBytes / 1024).toStringAsFixed(1)} KiB)',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
              const SizedBox(height: 8),
              Row(children: [
                FilledButton.icon(
                  onPressed: widget.onStartBulk,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: widget.onStopBulk,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ]),
            ],
          ),
        ),
      ),
    ];
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
