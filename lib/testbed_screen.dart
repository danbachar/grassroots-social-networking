import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:redux/redux.dart';
import 'package:share_plus/share_plus.dart';

import 'field_runner_screen.dart';
import 'src/store/app_state.dart';
import 'src/store/settings_actions.dart';
import 'src/testbed/field_plan_presets.dart';
import 'src/testbed/field_runner.dart';
import 'src/testbed/testbed_config.dart';
import 'src/trace/experiment_recorder.dart';
import 'src/trace/trace_config.dart';

/// DEBUG/TESTBED ONLY screen for the evaluation in
/// `docs/testbed_experiments.md`: experiment recording, the scripted field
/// runner, and the bulk-flow config it triggers. Inert in production.
class TestbedScreen extends StatefulWidget {
  final Store<AppState> store;

  /// This device's hex public key (for building/verifying the roster). Null if
  /// the network isn't up yet.
  final String? myPubkeyHex;

  /// Trace logger for the experiment recording sink. Null hides the
  /// experiment section (network not up yet).
  final ExperimentRecorder? experimentRecorder;

  final VoidCallback? onStartBulk;
  final VoidCallback? onStopBulk;

  /// Field-runner hooks: per-step message sends and the per-step Noise
  /// session reset (the establishment-ladder measurement).
  final Future<String?> Function(Uint8List recipient, Uint8List payload,
      {String? messageId})? sendMessage;
  final VoidCallback? onResetSessions;
  final VoidCallback? onResetLinks;

  const TestbedScreen({
    super.key,
    required this.store,
    this.myPubkeyHex,
    this.experimentRecorder,
    this.onStartBulk,
    this.onStopBulk,
    this.sendMessage,
    this.onResetSessions,
    this.onResetLinks,
  });

  @override
  State<TestbedScreen> createState() => _TestbedScreenState();
}

class _TestbedScreenState extends State<TestbedScreen> {
  late final TextEditingController _bulkController;
  late final TextEditingController _expIdController;
  late final TextEditingController _markerController;
  late final TextEditingController _planController;
  String? _planError;
  Timer? _statusTimer;
  String? _bulkError;
  int _expFileBytes = 0;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    final settings = widget.store.state.settings;
    _bulkController = TextEditingController(
      text: settings.bulkFlowConfig == null
          ? ''
          : const JsonEncoder.withIndent('  ')
              .convert(settings.bulkFlowConfig!.toJson()),
    );
    _expIdController = TextEditingController(
        text: widget.experimentRecorder?.experimentId ?? '');
    _markerController = TextEditingController();
    _planController = TextEditingController();
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
    _bulkController.dispose();
    _expIdController.dispose();
    _markerController.dispose();
    _planController.dispose();
    super.dispose();
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

  void _launchPlan() {
    final recorder = widget.experimentRecorder;
    if (recorder == null) return;
    if (recorder.active) {
      _snack('An experiment is already recording — stop it first');
      return;
    }
    FieldPlan plan;
    try {
      final json = jsonDecode(_planController.text) as Map<String, dynamic>;
      plan = FieldPlan.fromJson(json);
      if (plan.steps.isEmpty) throw const FormatException('no steps');
    } catch (e) {
      setState(() => _planError = e.toString());
      return;
    }
    setState(() => _planError = null);
    final runner = FieldRunner(
      recorder: recorder,
      onStartBulk: widget.onStartBulk,
      onStopBulk: widget.onStopBulk,
      myPubkeyHex: widget.myPubkeyHex,
      send: widget.sendMessage,
      onResetSessions: widget.onResetSessions,
      onResetLinks: widget.onResetLinks,
      // Rosterless plans (the two-device default) target every peer the
      // store currently knows.
      knownPeers: () => widget.store.state.peers.peersList
          .map((p) => p.publicKey)
          .where((pk) => pk.length == 32)
          .toList(),
      onWindowElapsed: () => HapticFeedback.heavyImpact(),
      upload: TraceConfig.isConfigured
          ? () => recorder.uploadExperimentFiles(
                url: TraceConfig.serverUrl,
                token: TraceConfig.serverToken,
                deviceId: widget.myPubkeyHex ?? 'unknown',
              )
          : null,
    );
    Navigator.of(context)
        .push(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => FieldRunnerScreen(runner: runner, plan: plan),
        ))
        .then((_) => runner.dispose());
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
    return Scaffold(
      appBar: AppBar(title: const Text('Testbed (debug)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.experimentRecorder != null) ...[
            ..._experimentSection(widget.experimentRecorder!),
            const Divider(height: 40),
            ..._autoRunnerSection(),
            const Divider(height: 40),
          ],
          const Divider(height: 40),
          ..._bulkSection(),
          if (widget.myPubkeyHex != null) ...[
            const SizedBox(height: 16),
            // Roster building: every config in this screen keys on full
            // pubkeys — tap to copy this device's.
            _copyableKey('This device', widget.myPubkeyHex!),
          ],
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

  List<Widget> _autoRunnerSection() {
    return [
      _sectionHeader('Auto runner', 'Scripted field experiment'),
      const Text(
        'Load the shared plan JSON (identical on every device), tap Launch, '
        'and follow the full-screen prompts: it starts recording, stamps each '
        'step marker on your IN POSITION tap, holds the dwell (running bulk '
        'flows on bulk steps), then marks end, settles, stops, and uploads.',
        style: TextStyle(fontSize: 13, color: Colors.grey),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            initialValue: null,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              labelText: 'Preset',
            ),
            hint: const Text('Pick a preset…'),
            items: [
              for (final name in FieldPlanPresets.presets.keys)
                DropdownMenuItem(value: name, child: Text(name)),
            ],
            onChanged: (name) {
              if (name == null) return;
              _setPlan(FieldPlanPresets.presets[name]!);
            },
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _openPlanWizard,
          icon: const Icon(Icons.auto_fix_high),
          label: const Text('Wizard'),
        ),
      ]),
      const SizedBox(height: 8),
      TextField(
        controller: _planController,
        maxLines: 10,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: 'FieldPlan JSON — pick a preset, run the Wizard, or paste',
        ),
      ),
      if (_planError != null) ...[
        const SizedBox(height: 6),
        Text('Parse error: $_planError',
            style: const TextStyle(color: Colors.red, fontSize: 12)),
      ],
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: _launchPlan,
          icon: const Icon(Icons.play_circle_fill),
          label: const Text('Launch'),
        ),
      ]),
    ];
  }

  void _setPlan(FieldPlan plan) {
    _planController.text =
        const JsonEncoder.withIndent('  ').convert(plan.toJson());
    setState(() => _planError = null);
  }

  Future<void> _openPlanWizard() async {
    final result = await showDialog<_WizardResult>(
      context: context,
      builder: (_) => const _PlanWizardDialog(),
    );
    if (result == null) return;
    if (result.plan != null) {
      // Moving device: fill the plan, ready to Launch.
      _setPlan(result.plan!);
    } else if (result.staticExpId != null) {
      // Static device: no plan. Point the experiment id at Record; the mover's
      // markers segment this device's trace offline.
      _expIdController.text = result.staticExpId!;
      setState(() {});
      _snack('Static device: scroll up to Experiment recording and press '
          'Record (id filled in). Stop + Upload when the sweep ends.');
    }
  }

  List<Widget> _bulkSection() {
    return [
      _sectionHeader('Bulk flows', 'Sustained throughput (dilating clique)'),
      const Text(
        'Paste the shared bulk-flow JSON (identical on every device) and '
        'Load it. The auto runner starts/stops these flows on steps marked '
        'bulk: true; each device runs only the flows where it is the source.',
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

/// Wizard outcome: a plan to run (this device moves) OR just the shared
/// experiment id for a record-only static device.
class _WizardResult {
  final FieldPlan? plan;
  final String? staticExpId;
  const _WizardResult.plan(this.plan) : staticExpId = null;
  const _WizardResult.static(this.staticExpId) : plan = null;
}

/// DEBUG/TESTBED ONLY. A few-question wizard that builds a [FieldPlan] (or a
/// static record-only request) and pops it back to the caller. Pure plan
/// construction lives in [FieldPlanWizard]; this is only the form.
class _PlanWizardDialog extends StatefulWidget {
  const _PlanWizardDialog();

  @override
  State<_PlanWizardDialog> createState() => _PlanWizardDialogState();
}

class _PlanWizardDialogState extends State<_PlanWizardDialog> {
  FieldPlanKind _kind = FieldPlanKind.homeSoak;
  late final TextEditingController _expId =
      TextEditingController(text: 'home-soak-1');
  late final TextEditingController _dwellMin =
      TextEditingController(text: '40');
  late final TextEditingController _sends = TextEditingController(text: '40');
  late final TextEditingController _distances =
      TextEditingController(text: '1, 5, 10, 20, 40, 80, 120');
  late final TextEditingController _sendsPerStep =
      TextEditingController(text: '5');
  late final TextEditingController _dwellSec =
      TextEditingController(text: '180');
  late final TextEditingController _sides =
      TextEditingController(text: '10, 20, 40');
  late final TextEditingController _repeat = TextEditingController(text: '1');
  bool _retreat = true;
  /// Whether THIS device walks the sweep (mover) or stays put (static,
  /// record-only). Drives the whole form.
  bool _moves = true;
  // null = use the kind's default; set once the user toggles a switch.
  bool? _resetSessions;
  bool? _resetLinks;

  @override
  void dispose() {
    for (final c in [
      _expId,
      _dwellMin,
      _sends,
      _distances,
      _sendsPerStep,
      _dwellSec,
      _sides,
      _repeat,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int _int(TextEditingController c, int fallback) =>
      int.tryParse(c.text.trim()) ?? fallback;

  void _suggestId(FieldPlanKind kind) {
    _expId.text = switch (kind) {
      FieldPlanKind.homeSoak => 'home-soak-1',
      FieldPlanKind.lineSweep => 'cp-line-1',
      FieldPlanKind.dataPlane => 'dp-tri-baseline',
    };
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Build a field plan'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _resetSwitch(
                'This device moves during the test',
                _moves,
                (v) => setState(() => _moves = v),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _expId,
                decoration: const InputDecoration(
                    labelText: 'Experiment id (same on both devices)',
                    isDense: true),
              ),
              if (!_moves)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Static device: it just records + ACKs. Generate fills '
                    'the id into Experiment recording — press Record there, '
                    'then Stop + Upload when the moving device finishes. The '
                    'moving device\'s markers define the distance segments.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              if (_moves) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<FieldPlanKind>(
                  initialValue: _kind,
                  decoration: const InputDecoration(
                      labelText: 'Experiment', isDense: true),
                  items: [
                    for (final k in FieldPlanKind.values)
                      DropdownMenuItem(value: k, child: Text(k.label)),
                  ],
                  onChanged: (k) => setState(() {
                    _kind = k!;
                    _suggestId(k);
                    // Reset toggles fall back to the new kind's defaults.
                    _resetSessions = null;
                    _resetLinks = null;
                  }),
                ),
                const SizedBox(height: 12),
                ..._fieldsForKind(),
                const Divider(height: 24),
                _num(_repeat, 'Repeat each step (trials)'),
                _resetSwitch(
                  'Reset sessions each step',
                  _resetSessions ?? _defSessions,
                  (v) => setState(() => _resetSessions = v),
                ),
                _resetSwitch(
                  'Reset BLE links each step',
                  _resetLinks ?? _defLinks,
                  (v) => setState(() => _resetLinks = v),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Tap IN POSITION at each new distance; repeat trials at '
                    'the same distance auto-advance.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(
              context,
              _moves
                  ? _WizardResult.plan(_build())
                  : _WizardResult.static(
                      _expId.text.trim().isEmpty ? 'exp' : _expId.text.trim())),
          child: Text(_moves ? 'Generate' : 'Use static'),
        ),
      ],
    );
  }

  List<Widget> _fieldsForKind() {
    switch (_kind) {
      case FieldPlanKind.homeSoak:
        return [
          _num(_dwellMin, 'Dwell (minutes)'),
          const SizedBox(height: 12),
          _num(_sends, 'Messages over the dwell'),
        ];
      case FieldPlanKind.lineSweep:
        return [
          _num(_distances, 'Distances (m, comma-separated)'),
          const SizedBox(height: 12),
          _num(_dwellSec, 'Dwell per step (s)'),
          const SizedBox(height: 12),
          _num(_sendsPerStep, 'Messages per step'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Retreat sweep (hysteresis)'),
            value: _retreat,
            onChanged: (v) => setState(() => _retreat = v),
          ),
        ];
      case FieldPlanKind.dataPlane:
        return [
          _num(_sides, 'Side lengths (m, comma-separated)'),
          const SizedBox(height: 12),
          _num(_dwellSec, 'Dwell per step (s)'),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('Load a Bulk flows config too — these steps run it.',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ];
    }
  }

  Widget _num(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: TextInputType.text,
        decoration: InputDecoration(labelText: label, isDense: true),
      );

  Widget _resetSwitch(String title, bool value, ValueChanged<bool> onChanged) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(title),
        value: value,
        onChanged: onChanged,
      );

  bool get _defSessions => FieldPlanWizard.resetDefaults(_kind).$1;
  bool get _defLinks => FieldPlanWizard.resetDefaults(_kind).$2;

  FieldPlan _build() => FieldPlanWizard.build(
        kind: _kind,
        expId: _expId.text,
        dwellMin: _int(_dwellMin, 40),
        sends: _int(_sends, 40),
        distances: FieldPlanWizard.parseInts(
            _distances.text, const [1, 5, 10, 20, 40, 80, 120]),
        retreat: _retreat,
        sendsPerStep: _int(_sendsPerStep, 5),
        dwellSec: _int(_dwellSec, 180),
        sideLengths:
            FieldPlanWizard.parseInts(_sides.text, const [10, 20, 40]),
        repeat: _int(_repeat, 1),
        resetSessions: _resetSessions,
        resetLinks: _resetLinks,
      );
}
