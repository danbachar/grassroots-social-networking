import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
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

  /// This device's ANNOUNCE nickname. When it is a plain integer it IS
  /// the join order — the number is set once, on the phone, and shown on
  /// its own screen, so deriving the order from it removes the per-run
  /// retyping that put two devices on one node number.
  final String? myNickname;

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
  final Future<void> Function(int? darkSec, {void Function()? whileDark})?
      onResetLinks;
  final VoidCallback? onResetDtnBuffer;

  /// Runs the on-device crypto bench (failed-AEAD and handshake cost).
  final Future<Map<String, dynamic>> Function()? onCryptoBench;

  /// Monotonic BLE tx+rx bytes — the field runner's dead-radio watchdog.
  final int Function()? bleWireBytes;

  /// Whether the BLE transport is up — the watchdog's primary signal, valid
  /// even when the radio is deliberately alone.
  final bool Function()? bleUsable;
  final bool Function()? bleUndiscoverable;

  /// BLE-usability transitions, delivered at the state change itself — the
  /// runner's bt-on/bt-off stamps come from this, never from a poll.
  final Stream<bool>? bleUsableChanges;
  final Future<int?> Function(Uint8List peer,
      {required String leg, required int seq, int sizeDelta})? sendRaw;
  final Future<void> Function(bool on)? onSetBle;
  final bool Function(Uint8List peer)? linkSettled;

  /// Whether a Noise session exists with this peer — what a send is gated on.
  final bool Function(Uint8List peer)? sessionUp;
  final Stream<Uint8List>? sessionEvents;
  final Stream<Uint8List>? linkSettledEvents;

  /// Dial-grid hooks (see FieldRunner.onSetDialParallelism).
  final void Function({int? maxParallel, int? popN})? onSetDialParallelism;
  final int Function()? establishmentCount;
  final VoidCallback? onResetEstablishmentCount;

  /// Registers a listener for end-to-end ACKs (saturating throughput mode).
  final void Function(void Function(String messageId)? listener)?
      registerAckListener;

  /// DEBUG/TESTBED. Peers this phone holds a session with.
  final int Function()? sessionPeerCount;

  /// Sessions in the Noise table (see FieldRunner.sessionTableCount).
  final int Function()? sessionTableCount;

  const TestbedScreen({
    super.key,
    required this.store,
    this.myPubkeyHex,
    this.myNickname,
    this.experimentRecorder,
    this.onStartBulk,
    this.onStopBulk,
    this.sendMessage,
    this.onResetSessions,
    this.onResetLinks,
    this.onResetDtnBuffer,
    this.onCryptoBench,
    this.bleWireBytes,
    this.bleUsable,
    this.bleUndiscoverable,
    this.bleUsableChanges,
    this.sendRaw,
    this.onSetBle,
    this.linkSettled,
    this.sessionUp,
    this.sessionEvents,
    this.linkSettledEvents,
    this.onSetDialParallelism,
    this.establishmentCount,
    this.onResetEstablishmentCount,
    this.registerAckListener,
    this.sessionPeerCount,
    this.sessionTableCount,
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

  /// Set only when a sweep reported every chunk accepted. Cleared whenever
  /// the on-disk file set changes (a new run recorded, or files cleared), so
  /// green can never refer to a file that has since grown.
  bool _uploadComplete = false;

  /// Set when an attempt finished with at least one chunk unaccepted. Drives
  /// the red X. Without it a phone that failed to deliver its recording looks
  /// exactly like one that was never asked, since a snackbar is gone by the
  /// time you reach the next phone.
  bool _uploadFailed = false;

  /// Auto-upload trigger. Runs are recorded with Wi-Fi off (it starves BLE
  /// scanning), so the end-of-run upload always fails and the data sat on the
  /// device until someone pressed the button on every phone. Re-attaching to a
  /// network is the moment that can succeed.
  StreamSubscription<List<ConnectivityResult>>? _connSub;

  /// The pushed runner route, so the upload can close it. The full-screen
  /// runner covers the button that reports upload state, so leaving it up
  /// hides the very thing the operator needs to see.
  Route<void>? _runnerRoute;
  bool _benchRunning = false;
  String? _benchResult;

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
    _connSub = Connectivity().onConnectivityChanged.listen(_onConnectivity);
  }

  /// A network appeared: upload without being asked.
  ///
  /// Gated on there being something to send and nothing in flight. Wi-Fi and
  /// ethernet only — mobile data is deliberately excluded, since a multi-hour
  /// recording is tens of MB and nothing about this is urgent enough to spend
  /// a data plan on.
  void _onConnectivity(List<ConnectivityResult> results) {
    final onNetwork = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    if (!onNetwork) return;
    if (!TraceConfig.isConfigured) return;
    // NEVER during a run. Uploading closes the runner, and closing the runner
    // route disposes it, so a phone that regains a network mid-run would kill
    // its own experiment.
    //
    // Recording active is the authoritative test — it is true for the whole
    // run and independent of which screen is showing.
    final recorder = widget.experimentRecorder;
    if (recorder != null && recorder.active) return;
    if (_runnerRoute?.isActive ?? false) return;
    if (_uploading || _uploadComplete) return;
    // Ask the disk rather than the cached count. Not because the cache is
    // wrong — the status poll keeps it current — but because this fires on a
    // network change, which can land inside the first poll interval after the
    // screen mounts, when the count is still its initial zero. Reading disk
    // makes the trigger independent of the poll's timing.
    //
    // No need to re-test the in-flight flag afterwards: _uploadExperimentFiles
    // opens with its own `if (_uploading) return`, so a tap that starts an
    // upload during this await is refused there.
    unawaited(() async {
      final trace = widget.experimentRecorder;
      if (trace == null) return;
      final bytes = await trace.experimentFileSize();
      if (!mounted || bytes <= 0) return;
      await _uploadExperimentFiles();
    }());
  }

  /// Close the runner if it is up, so the upload's own state is visible.
  void _closeRunner() {
    final route = _runnerRoute;
    if (route == null || !route.isActive) return;
    _runnerRoute = null;
    route.navigator?.removeRoute(route);
  }

  void _refreshStatus() {
    final trace = widget.experimentRecorder;
    // Poll the on-disk size whether or not a recording is RUNNING. Gating this
    // on `trace.active` meant the size stopped being maintained the moment a
    // run ended — which is precisely when the files matter, and it left the
    // auto-upload trigger reading a stale or zero byte count and skipping the
    // upload it exists to perform.
    if (trace != null) {
      unawaited(trace.experimentFileSize().then((bytes) {
        if (!mounted) return;
        setState(() {
          // Any change in what is on disk invalidates a previous "all chunks
          // landed": uploadId embeds the file length, so a grown file uploads
          // under new ids and the old green would be a lie.
          if (bytes != _expFileBytes) {
            _uploadComplete = false;
            _uploadFailed = false;
          }
          _expFileBytes = bytes;
        });
      }));
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    unawaited(_connSub?.cancel());
    _bulkController.dispose();
    _expIdController.dispose();
    _markerController.dispose();
    _planController.dispose();
    _sweepStepController.dispose();
    _sweepReceiverController.dispose();
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
    // The upload's state lives on this screen's button, so the full-screen
    // runner comes down as the attempt starts rather than after it ends.
    _closeRunner();
    setState(() {
      _uploading = true;
      _uploadComplete = false; // a fresh attempt is not yet proven complete
      _uploadFailed = false;
    });
    UploadOutcome outcome;
    try {
      outcome = await recorder.uploadExperimentFiles(
        url: TraceConfig.serverUrl,
        token: TraceConfig.serverToken,
        deviceId: widget.myPubkeyHex ?? 'unknown',
      );
    } catch (_) {
      outcome = const UploadOutcome(message: 'Upload failed', complete: false);
    }
    if (!mounted) return;
    setState(() {
      _uploading = false;
      _uploadComplete = outcome.complete;
      _uploadFailed = !outcome.complete;
    });
    _snack(outcome.message);
  }

  /// Parse the pasted plan, or show why it cannot be used.
  FieldPlan? _parsePlan() {
    final recorder = widget.experimentRecorder;
    if (recorder == null) return null;
    if (recorder.active) {
      _snack('An experiment is already recording — stop it first');
      return null;
    }
    try {
      final json = jsonDecode(_planController.text) as Map<String, dynamic>;
      final plan = FieldPlan.fromJson(json);
      if (plan.steps.isEmpty) throw const FormatException('no steps');
      setState(() => _planError = null);
      return plan;
    } catch (e) {
      setState(() => _planError = e.toString());
      return null;
    }
  }

  FieldRunner _makeRunner(ExperimentRecorder recorder) {
    return FieldRunner(
      recorder: recorder,
      // The formation assertion: each step marker stamps the session-peer
      // count, so "was the topology up when this rep opened" is a field on
      // the marker. The hook existed but was never handed to the runner —
      // the home preflight's markers all read sessions:null.
      sessionPeerCount: widget.sessionPeerCount,
      sessionTableCount: widget.sessionTableCount,
      onStartBulk: widget.onStartBulk,
      onStopBulk: widget.onStopBulk,
      myPubkeyHex: widget.myPubkeyHex,
      myNickname: widget.myNickname,
      send: widget.sendMessage,
      onResetSessions: widget.onResetSessions,
      onResetLinks: widget.onResetLinks,
      onResetDtnBuffer: widget.onResetDtnBuffer,
      sendRaw: widget.sendRaw,
      onSetBle: widget.onSetBle,
      bleWireBytes: widget.bleWireBytes,
      bleUsable: widget.bleUsable,
      bleUndiscoverable: widget.bleUndiscoverable,
      bleUsableChanges: widget.bleUsableChanges,
      linkSettled: widget.linkSettled,
      sessionUp: widget.sessionUp,
      sessionEvents: widget.sessionEvents,
      linkSettledEvents: widget.linkSettledEvents,
      onSetDialParallelism: widget.onSetDialParallelism,
      establishmentCount: widget.establishmentCount,
      onResetEstablishmentCount: widget.onResetEstablishmentCount,
      // Rosterless plans target every peer a message can be addressed to —
      // those with a live session — not every peer the store has identified.
      // The two are different sets: a verified ANNOUNCE makes a peer known
      // while its handshake is still ahead, and addressing it then produces a
      // refusal that the run would otherwise record as a delivery failure.
      knownPeers: () => widget.store.state.peers.sessionPeers
          .map((p) => p.publicKey)
          .where((pk) => pk.length == 32)
          .toList(),
      onWindowElapsed: () => HapticFeedback.heavyImpact(),
      // A token-less build must SAY so at the end of a run. Wiring this to
      // null instead let a finished plan report nothing at all, which is how
      // a multi-hour recording silently fails to reach the server — the data
      // is still on the device, but nothing on screen says to go get it.
      upload: TraceConfig.isConfigured
          ? () async {
              // Starting the end-of-run upload closes the runner and shows the
              // spinner, so the operator watches the attempt, not a finished
              // run screen that says nothing about whether the data left.
              if (mounted) {
                _closeRunner();
                setState(() {
                  _uploading = true;
                  _uploadFailed = false;
                  _uploadComplete = false;
                });
              }
              final outcome = await recorder.uploadExperimentFiles(
                url: TraceConfig.serverUrl,
                token: TraceConfig.serverToken,
                deviceId: widget.myPubkeyHex ?? 'unknown',
              );
              // The end-of-run auto-upload drives the same indicator as the
              // manual button, so a finished run shows green without needing
              // a press to find out — and red when a chunk did not land.
              if (mounted) {
                setState(() {
                  _uploading = false;
                  _uploadComplete = outcome.complete;
                  _uploadFailed = !outcome.complete;
                });
              }
              return outcome.message;
            }
          : () async => 'NOT UPLOADED — this build has no TRACE_TOKEN. The '
              'recording is safe on this device: rebuild with '
              '--dart-define=TRACE_TOKEN=..., install with -r (app data is '
              'kept), then press Upload files.',
    );
  }

  /// Open the runner screen for [plan], wiring the listeners it needs and
  /// tearing them down when the screen closes.
  void _openRunner(FieldPlan plan) {
    final recorder = widget.experimentRecorder;
    if (recorder == null) return;
    final runner = _makeRunner(recorder);
    // Saturating steps refill their window on each end-to-end ACK.
    widget.registerAckListener?.call(runner.onAck);
    final route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => FieldRunnerScreen(
        runner: runner,
        plan: plan,
      ),
    );
    _runnerRoute = route;
    Navigator.of(context)
        .push(route)
        .then((_) {
      _runnerRoute = null;
      widget.registerAckListener?.call(null);
      runner.dispose();
    });
  }

  void _launchPlan() {
    final plan = _parsePlan();
    if (plan != null) _openRunner(plan);
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
    if (mounted) setState(() => _uploadComplete = false);
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
          const SizedBox(height: 24),
          ..._benchSection(),
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
        // Green means every chunk of every file was accepted. Without it the
        // only way to know an upload finished was to press it again, which is
        // safe only while the file is unchanged: uploadId embeds the file
        // LENGTH, so a press after the file has grown derives new ids the
        // server cannot recognise as already-stored.
        OutlinedButton.icon(
          onPressed: _uploading ? null : () async => _uploadExperimentFiles(),
          // Three terminal appearances, because three outcomes matter to an
          // operator standing at the bench: in flight, everything landed, or
          // something did not. Green and red both persist — a snackbar is
          // gone by the time you have walked to the next phone.
          style: _uploadComplete
              ? OutlinedButton.styleFrom(
                  foregroundColor: Colors.green.shade700,
                  side: BorderSide(color: Colors.green.shade700, width: 2),
                )
              : _uploadFailed
                  ? OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      side: BorderSide(color: Colors.red.shade700, width: 2),
                    )
                  : null,
          icon: _uploading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(_uploadComplete
                  ? Icons.cloud_done
                  : _uploadFailed
                      ? Icons.close
                      : Icons.cloud_upload_outlined),
          label: Text(_uploading
              ? 'Uploading…'
              : _uploadComplete
                  ? 'Uploaded ✓'
                  : _uploadFailed
                      ? 'Upload failed — retry'
                      : 'Upload files'),
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
              setState(() => _selectedPreset = name);
              if (name == FieldPlanPresets.lineSweepPresetName) {
                _applySweep();
              } else {
                _setPlan(FieldPlanPresets.presets[name]!);
              }
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
      if (_selectedPreset == FieldPlanPresets.lineSweepPresetName) ...[
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: _sweepPicker(
              label: 'Start (m)',
              value: _sweepStartDistance,
              options: [1, for (var d = 5; d <= 200; d += 5) d],
              onPick: _setSweepStart,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _sweepPicker(
              label: 'Reach (m)',
              value: _sweepMaxDistance,
              options: [1, for (var d = 5; d <= 200; d += 5) d],
              onPick: _setSweepMax,
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _sweepStepController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                labelText: 'Step (m)',
              ),
              onChanged: (text) {
                // Any spacing the ground calls for. A half-typed or cleared
                // field keeps the last usable step rather than rebuilding the
                // plan around a number that is not there yet.
                final m = int.tryParse(text.trim());
                if (m == null || m < 1) return;
                setState(() => _sweepStepMetres = m);
                _applySweep();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _sweepPicker(
              label: 'Repeats',
              value: _sweepTrials,
              options: [for (var t = 1; t <= 10; t++) t],
              suffix: '',
              onPick: (t) {
                setState(() => _sweepTrials = t);
                _applySweep();
              },
            ),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _sweepReceiverController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            labelText: 'One-way receiver pubkey prefix (blank = both send)',
            helperText: 'July design: paste the STATIC phone\'s pubkey '
                'prefix; every other phone sends 100/trial toward it',
          ),
          onChanged: (_) => _applySweep(),
        ),
        const SizedBox(height: 6),
        Text(
          '$_sweepPositions positions '
          '($_sweepStartDistance–$_sweepMaxDistance m every '
          '$_sweepStepMetres m) x $_sweepTrials — '
          '${_sweepDuration()}, walking included',
          style: const TextStyle(fontSize: 13, color: Colors.grey),
        ),
      ],
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
          label: const Text('Launch here'),
        ),
      ]),
    ];
  }

  /// Reach and repeats for the line sweep, and the entry they belong to.
  ///
  /// Held on the screen rather than in the plan JSON: changing either has to
  /// rebuild the plan, and the JSON is the output of that choice, not its
  /// home.
  late final TextEditingController _sweepStepController =
      TextEditingController(text: '$_sweepStepMetres');

  int _sweepStartDistance = 10;
  int _sweepMaxDistance = 120;
  int _sweepStepMetres = 10;
  int _sweepTrials = 10;
  String? _selectedPreset;

  late final TextEditingController _sweepReceiverController =
      TextEditingController();

  FieldPlan get _sweepPlan => FieldPlanPresets.lineSweepUpTo(
        startDistance: _sweepStartDistance,
        maxDistance: _sweepMaxDistance,
        stepMetres: _sweepStepMetres,
        trials: _sweepTrials,
        receiverPrefix: _sweepReceiverController.text,
      );

  void _applySweep() => _setPlan(_sweepPlan);

  /// Keep the start at or below the reach as either is picked, so the pair
  /// on screen is always a sweep the operator could actually walk.
  void _setSweepStart(int m) {
    setState(() {
      _sweepStartDistance = m;
      if (_sweepMaxDistance < m) _sweepMaxDistance = m;
    });
    _applySweep();
  }

  void _setSweepMax(int m) {
    setState(() {
      _sweepMaxDistance = m;
      if (_sweepStartDistance > m) _sweepStartDistance = m;
    });
    _applySweep();
  }

  /// The positions the current pickers produce — the number the operator is
  /// really choosing, since reach alone does not give it.
  int get _sweepPositions =>
      _sweepPlan.steps.where((s) => !s.autoAdvance).length;

  /// How long the chosen sweep runs, walking included.
  ///
  /// Read off the plan's own wall-clock schedule rather than multiplied out
  /// by hand: each new position is rounded up to an alignment boundary, so
  /// the arithmetic is not steps x dwell.
  Widget _sweepPicker({
    required String label,
    required int value,
    required List<int> options,
    required void Function(int) onPick,
    String suffix = ' m',
  }) =>
      DropdownButtonFormField<int>(
        isExpanded: true,
        initialValue: options.contains(value) ? value : options.first,
        decoration: InputDecoration(
          border: const OutlineInputBorder(),
          isDense: true,
          labelText: label,
        ),
        items: [
          for (final o in options)
            DropdownMenuItem(value: o, child: Text('$o$suffix')),
        ],
        onChanged: (v) {
          if (v != null) onPick(v);
        },
      );

  String _sweepDuration() {
    final plan = _sweepPlan;
    final starts = FieldRunner.stepStarts(plan, 0);
    final ms = starts.last +
        (plan.steps.last.dwellSec + plan.settleSec) * 1000 +
        plan.placementSec * 1000;
    final m = ms ~/ 60000;
    return m >= 60 ? '${m ~/ 60} h ${m % 60} min' : '$m min';
  }

  void _setPlan(FieldPlan plan) {
    _planController.text =
        const JsonEncoder.withIndent('  ').convert(plan.toJson());
    setState(() => _planError = null);
  }

  Future<void> _openPlanWizard() async {
    final result = await showDialog<_WizardResult>(
      context: context,
      builder: (_) => _PlanWizardDialog(myNickname: widget.myNickname),
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

  Future<void> _runCryptoBench() async {
    final bench = widget.onCryptoBench;
    if (bench == null || _benchRunning) return;
    setState(() {
      _benchRunning = true;
      _benchResult = null;
    });
    try {
      final r = await bench();
      final rows = (r['decrypt'] as List).cast<Map<String, dynamic>>();
      final hs = (r['handshake'] as Map)['tHandshakeUs'] as double;
      final buf = StringBuffer()
        ..writeln('sessions  failed-AEAD   miss     hit')
        ..writeln('-' * 40);
      for (final row in rows) {
        buf.writeln('${row['sessions'].toString().padLeft(8)}  '
            '${(row['tFailUs'] as double).toStringAsFixed(1).padLeft(8)}us  '
            '${(row['missUs'] as double).toStringAsFixed(0).padLeft(6)}us  '
            '${(row['hitUs'] as double).toStringAsFixed(1).padLeft(6)}us');
      }
      buf
        ..writeln('-' * 40)
        ..writeln('Noise XX handshake (CPU only): '
            '${(hs / 1000).toStringAsFixed(2)} ms')
        ..writeln('1 handshake = ${(hs / (rows.last['tFailUs'] as double)).round()} '
            'failed AEAD opens');
      if (!mounted) return;
      setState(() => _benchResult = buf.toString());
      unawaited(widget.experimentRecorder?.log({
        'type': 'bench',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'crypto',
        'decrypt': rows,
        'tHandshakeUs': hs,
      }) ?? Future<void>.value());
    } catch (e) {
      if (mounted) setState(() => _benchResult = 'Bench failed: $e');
    } finally {
      if (mounted) setState(() => _benchRunning = false);
    }
  }

  List<Widget> _benchSection() {
    return [
      _sectionHeader('Crypto bench', 'Sizes the session cap'),
      const Text(
        'Times one failed AEAD open and one Noise XX handshake on THIS '
        'device. A packet not addressed to us costs sessions x failed-AEAD, '
        'so that number is the price of holding one more session — and the '
        'price of dropping the recipient field from the envelope, which '
        'would send every transit packet through the same walk. Run it on '
        'the slowest phone in the fleet; a development machine understates '
        'it by roughly 10x. Takes a few seconds and pins the CPU.',
        style: TextStyle(fontSize: 13, color: Colors.grey),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed:
            widget.onCryptoBench == null || _benchRunning ? null : _runCryptoBench,
        icon: _benchRunning
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.speed_rounded),
        label: Text(_benchRunning ? 'Running…' : 'Run crypto bench'),
      ),
      if (_benchResult != null) ...[
        const SizedBox(height: 10),
        SelectableText(
          _benchResult!,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ],
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
  const _PlanWizardDialog({this.myNickname});

  /// This device's ANNOUNCE nickname, used to seed the join order.
  final String? myNickname;

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
  late final TextEditingController _dwellSec =
      TextEditingController(text: '180');
  late final TextEditingController _repeat = TextEditingController(text: '1');
  // Payload ARM: one saturating step per size. [defaultSendBytes] is exactly
  // one sealed packet at the BLE floor MTU, 264 B two and 1200 B nine — so the
  // per-message cost of fragmentation comes out as a measured curve.
  late final TextEditingController _payloadBytes =
      TextEditingController(text: '$defaultSendBytes, 264, 1200');
  late final TextEditingController _sendLanes =
      TextEditingController(text: '1');
  late final TextEditingController _laneCounts =
      TextEditingController(text: '1, 4, 16, 64');
  late final TextEditingController _rawLegs =
      TextEditingController(text: 'notify, write, stripe');
  /// Power baseline: which of the two complementary schedules this phone
  /// runs. Both use the SAME labels; role decides who is up during solo and
  /// who sends during light/heavy.
  int _powerRole = 1;
  // Mesh scaling: total devices taking part, and this phone's join order.
  /// Store-carry-forward: which phone the senders address while it is dark.
  final TextEditingController _travellerPrefix = TextEditingController();
  final TextEditingController _maxDevices =
      TextEditingController(text: '8');
  /// Join order, seeded from the nickname: on this fleet the nickname IS the
  /// node number, so the operator no longer retypes it per run. Falls back to
  /// 1 for a non-numeric nickname, and stays editable either way.
  late final TextEditingController _meshRole =
      TextEditingController(text: _nicknameOrder()?.toString() ?? '1');
  bool _meshSaturate = true;

  /// The nickname read as a join order, or null when it is not a plain
  /// positive integer. Deliberately strict: a nickname like "pixel-2" must
  /// NOT silently become node 2.
  int? _nicknameOrder() {
    final n = int.tryParse(widget.myNickname?.trim() ?? '');
    return (n != null && n > 0) ? n : null;
  }

  /// Manual Bluetooth join (operator toggles settings-BT; wall-clock
  /// anchored start). Default ON — it is the current field procedure, and
  /// forgetting it on one of eight phones would silently give that phone a
  /// different timeline.
  /// Every experiment runs the manual logic: the operator owns system
  /// Bluetooth and every phone starts on the same wall-clock instant. The
  /// switch that could turn this off offered the retired app-controlled,
  /// tap-anchored mode, which no plan has used since the Arm flow was
  /// deleted — a run started that way is not comparable with any recorded
  /// result, so the option is gone rather than merely defaulted off.
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
      _dwellSec,
      _repeat,
      _payloadBytes,
      _sendLanes,
      _laneCounts,
      _rawLegs,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  int _int(TextEditingController c, int fallback) =>
      int.tryParse(c.text.trim()) ?? fallback;

  /// True once the experimenter has typed in the id field. Changing the
  /// experiment kind then leaves their id ALONE — silently overwriting it is
  /// how a run ends up filed under the wrong name, which only surfaces hours
  /// later when the analysis cannot find it.
  bool _idEdited = false;

  void _suggestId(FieldPlanKind kind) {
    if (_idEdited) return;
    _expId.text = switch (kind) {
      FieldPlanKind.meshScale => 'mesh-scale-1',
      // The spacing belongs in the id: the sweep is run per distance.
      FieldPlanKind.joinTime => 'join-time-30m',
      FieldPlanKind.storeCarryForward => 'scf-desk-1',
      FieldPlanKind.homeSoak => 'home-soak-1',
      FieldPlanKind.throughput => 'throughput-1',
      FieldPlanKind.throughputCeiling => 'throughput-ceiling-1',
      FieldPlanKind.rawLink => 'raw-link-1',
      FieldPlanKind.powerBaseline => 'pw-base-1',
    };
  }

  @override
  Widget build(BuildContext context) {
    // Landscape is the working orientation in the field (a phone on a tripod
    // does not rotate), and there the viewport is short: a fixed-width box
    // with no height bound let the content exceed what AlertDialog will give
    // it, so the scroll view was handed a box it could not scroll inside and
    // the lower fields became unreachable. Bound BOTH axes against the actual
    // viewport, minus the insets the keyboard takes when a field is focused.
    final media = MediaQuery.of(context);
    final maxH = media.size.height - media.viewInsets.bottom - 140;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      title: const Text('Build a field plan'),
      content: SizedBox(
        width: media.size.width < 460 ? media.size.width * 0.86 : 400,
        height: maxH.clamp(200.0, 560.0),
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
                onChanged: (_) => _idEdited = true,
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
                    _suggestTiming(k);
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
      case FieldPlanKind.throughput:
        return [
          _num(_dwellSec, 'Saturate for (s)'),
          const SizedBox(height: 12),
          _num(_payloadBytes, 'Message sizes (bytes, comma-separated)'),
          const SizedBox(height: 12),
          _num(_sendLanes, 'Concurrent send lanes'),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Fires as many messages as the link carries: pushes '
              'as fast as the send path drains, never waiting for an '
              'ACK. Each size is its own step — $defaultSendBytes B is one '
              'sealed packet, larger sizes fragment. A NON-zero window is '
              'ACK-clocked and caps the rate at window/RTT.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ];
      case FieldPlanKind.throughputCeiling:
        return [
          _num(_dwellSec, 'Saturate for (s)'),
          const SizedBox(height: 12),
          _num(_payloadBytes, 'Message size (bytes) — first value is used'),
          const SizedBox(height: 12),
          _num(_laneCounts, 'Lane counts to sweep (comma-separated)'),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Each lane pushes independently, none ACK-gated, so offered '
              'load rises with the lane count. The ceiling is where delivery '
              'drops below 100% and goodput stops climbing.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ];
      case FieldPlanKind.rawLink:
        return [
          _num(_dwellSec, 'Blast for (s)'),
          const SizedBox(height: 12),
          _num(_rawLegs, 'Legs to test (notify, write, stripe)'),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'MTU-sized raw blobs, no seal/ACK/buffering — the naked GATT '
              'pipe. notify = this device\'s peripheral leg, write = its '
              'central leg, stripe = alternate blobs across both.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ];
      case FieldPlanKind.meshScale:
        return [
          _num(_maxDevices, 'Total devices taking part'),
          const SizedBox(height: 12),
          _num(_meshRole, "This phone's join order (1 = present from the start)"),
          const SizedBox(height: 12),
          _num(_dwellSec, 'Step length (s)'),
          const SizedBox(height: 12),
          _num(_repeat, 'Repeats per device count'),
          const SizedBox(height: 12),
          _num(_sendLanes, 'Concurrent send lanes'),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(_meshSaturate
                ? 'Saturate (every device pushes as fast as it can)'
                : 'Fixed rate — sends per step below'),
            value: _meshSaturate,
            onChanged: (v) => setState(() => _meshSaturate = v),
          ),
          if (!_meshSaturate) ...[
            const SizedBox(height: 12),
            _num(_sends, 'Send rounds per step (each round hits every peer)'),
          ],
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Run on EVERY phone with the same total and a different join '
              'order. Devices 1-3 are present from the start; device k joins '
              'at step n=k by turning its radio on — so all phones run the '
              'same timeline and must be STARTED together.\n\n'
              'If the phones end up far apart, set a walk-out window: tap '
              'them all at one spot, then carry them into position while it '
              'runs. Measurement starts only after it elapses, and that step '
              'is excluded from the analysis.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ];
      case FieldPlanKind.storeCarryForward:
        return [
          _num(_meshRole, "This phone's role (1 = the TRAVELLER that goes dark)"),
          const SizedBox(height: 12),
          _num(_travellerPrefix,
              "Traveller's pubkey prefix — optional, blank = message everyone"),
          const SizedBox(height: 12),
          _num(_dwellSec, 'Dark window and return window each (s)'),
          const SizedBox(height: 12),
          _num(_sends, 'Medium-arm messages over the dark window'),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Set the role and leave the rest: the role is seeded from this '
              'phone\'s nickname, and a blank prefix means everyone messages '
              'everyone with one member away — the field-day shape. '
              'Desk test — distance is not the variable, offered load is. '
              'Three arms run back to back: low, medium, then HIGH, which is '
              'the heaviest arm (saturate, one lane, one sealed packet). '
              'Phone 1 drops its radio for the dark window while everyone '
              'else messages it; on return nobody sends, so every delivery in '
              'that window came out of a buffer. Start all phones together.',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ];
      case FieldPlanKind.joinTime:
        return [
          _num(_meshRole, "This phone's join order (the block-k phone is the frontier)"),
          const SizedBox(height: 12),
          _num(_maxDevices, 'Total devices taking part'),
          const SizedBox(height: 12),
          _num(_dwellSec, 'Join window per rep (s)'),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Establishment only — the standing mesh stays QUIET so link '
              'formation is not measured through traffic churn; mesh '
              'performance is the separate Mesh scaling run. The block-k '
              'phone toggles Bluetooth at the prompts ("Repeat" times per '
              'block), then anneals and the next phone takes over. Put the '
              'SPACING in the experiment id (join-time-30m).',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        ];
      case FieldPlanKind.powerBaseline:
        return [
          _num(_dwellSec, 'Segment length (s)'),
          const SizedBox(height: 12),
          _num(_repeat, 'Ladder repeats'),
          const SizedBox(height: 12),
          _num(_sends, 'Light-segment sends (per dwell)'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('This phone is P1 (up in solo, sends in '
                'light/heavy)${_powerRole == 1 ? '' : ' — currently P2'}'),
            value: _powerRole == 1,
            onChanged: (v) => setState(() => _powerRole = v ? 1 : 2),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Run UNPLUGGED at minimum brightness on both phones, one P1 '
              'and one P2, launched within a few seconds of each other. The '
              'runner toggles BLE itself — one tap, then hands-free.',
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

  /// Load the kind's canonical dwell/repeat when the experiment changes —
  /// a shared text field keeping the PREVIOUS kind's numbers is how a line
  /// sweep ends up with a 180s dwell nobody chose.
  void _suggestTiming(FieldPlanKind kind) {
    final (dwell, repeat, sends) = switch (kind) {
      // 10 reps per device count: the power ladder showed between-rep spread
      // is where the uncertainty lives, so one pass per size is not enough.
      FieldPlanKind.meshScale => (120, 10, 60),
      // dwell = the frontier's join window per rep; repeat = cold joins per N.
      FieldPlanKind.joinTime => (60, 5, 0),
      // dwell = the dark AND the return window; sends = the MEDIUM arm's
      // count (low is a trickle, high saturates and ignores it).
      FieldPlanKind.storeCarryForward => (120, 1, 60),
      FieldPlanKind.homeSoak => (60, 1, 40),
      FieldPlanKind.throughput => (60, 1, 0),
      FieldPlanKind.throughputCeiling => (60, 1, 0),
      FieldPlanKind.rawLink => (30, 10, 0),
      FieldPlanKind.powerBaseline => (600, 2, 600),
    };
    _dwellSec.text = '$dwell';
    _repeat.text = '$repeat';
    if (sends > 0) _sends.text = '$sends';
  }

  bool get _defSessions => FieldPlanWizard.resetDefaults(_kind).$1;
  bool get _defLinks => FieldPlanWizard.resetDefaults(_kind).$2;

  FieldPlan _build() {
    final plan = _buildKind();
    // The manual running logic is how ALL experiments run — operator toggles
    // system Bluetooth, wall-clock anchored start, no GPS. Kinds that build
    // it in (mesh scale, join time) pass through untouched; everything else
    // is wrapped here.
    if (!plan.manualJoin) {
      return FieldPlanPresets.manualized(plan);
    }
    return plan;
  }

  FieldPlan _buildKind() => FieldPlanWizard.build(
        kind: _kind,
        expId: _expId.text,
        dwellMin: _int(_dwellMin, 40),
        sends: _int(_sends, 40),
        dwellSec: _int(_dwellSec, 180),
        repeat: _int(_repeat, 1),
        resetSessions: _resetSessions,
        resetLinks: _resetLinks,
        payloadSizes: FieldPlanWizard.parseInts(
            _payloadBytes.text, const [defaultSendBytes]),
        sendLanes: _int(_sendLanes, 1),
        laneCounts:
            FieldPlanWizard.parseInts(_laneCounts.text, const [1, 4, 16, 64]),
        powerRole: _powerRole,
        maxDevices: int.tryParse(_maxDevices.text.trim()) ?? 8,
        meshRole: int.tryParse(_meshRole.text.trim()) ?? 1,
        travellerPrefix: _travellerPrefix.text.trim(),
        saturate: _meshSaturate,
        manualJoin: true,
        rawLegs: [
          for (final leg in _rawLegs.text.split(','))
            if (const {'notify', 'write', 'stripe'}.contains(leg.trim()))
              leg.trim(),
        ],
      );
}
