import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../trace/experiment_recorder.dart';
import 'testbed_config.dart';

/// Live status of one bulk flow, surfaced for the testbed UI.
@immutable
class BulkFlowStatus {
  final String flowLabel; // "A>B"
  final int sent;
  final int acked;
  final int ackedBytes;

  const BulkFlowStatus({
    required this.flowLabel,
    required this.sent,
    required this.acked,
    required this.ackedBytes,
  });
}

class _FlowRun {
  final BulkFlow flow;
  final Uint8List dstPubkey;
  int seq = 0;
  int sent = 0;
  int acked = 0;
  int ackedBytes = 0;

  /// Outstanding deterministic messageIds — an ACK for one of these refills
  /// the window. Abandoned (never re-sent) once the run window closes.
  final Set<String> outstanding = {};

  _FlowRun(this.flow, this.dstPubkey);

  String get label => '${flow.srcLabel}>${flow.dstLabel}';
}

/// DEBUG/TESTBED ONLY. Sustained-throughput driver for the data-plane
/// evaluation: per flow where this device is the source, keeps
/// `config.inFlight` messages of `config.payloadBytes` outstanding, sending
/// the next only when one is ACKed end-to-end — a message-level ARQ window
/// that saturates the link through the normal custody path. Messages are
/// NEVER re-sent by the driver: a lost message simply leaves the window
/// (custody/sync may still deliver it; the trace shows it as a late or
/// missing ACK). Goodput is computed offline from the `message` trace
/// records; the driver only marks the flow boundaries.
class BulkFlowDriver {
  final Future<String?> Function(Uint8List recipient, Uint8List payload,
      {String? messageId}) send;
  final void Function(String) log;
  final ExperimentRecorder? trace;
  static const _uuid = Uuid();

  final Map<String, _FlowRun> _byMessageId = {};
  List<_FlowRun> _runs = const [];
  BulkFlowConfig? _config;
  Timer? _endTimer;
  bool _running = false;

  BulkFlowDriver({required this.send, required this.log, this.trace});

  bool get isRunning => _running;

  List<BulkFlowStatus> get status => _runs
      .map((r) => BulkFlowStatus(
            flowLabel: r.label,
            sent: r.sent,
            acked: r.acked,
            ackedBytes: r.ackedBytes,
          ))
      .toList(growable: false);

  /// The deterministic messageId of `seq` on `src>dst` — same namespace trick
  /// as the workload driver, so offline analysis reproduces the id set.
  static String messageIdFor(String srcLabel, String dstLabel, int seq) =>
      _uuid.v5(workloadUuidNamespace, 'bulk|$srcLabel|$dstLabel|$seq');

  /// Begin executing the flows where [myPubkeyHex] is the source. No-op when
  /// already running or no flow selects this device.
  void start({required BulkFlowConfig config, required String myPubkeyHex}) {
    if (_running) return;
    final me = config.roster
        .where((r) => r.pubkeyHex.toLowerCase() == myPubkeyHex.toLowerCase())
        .firstOrNull;
    if (me == null) {
      log('[bulk] this device is not in the roster');
      return;
    }
    final byLabel = {for (final r in config.roster) r.label: r};
    final runs = <_FlowRun>[];
    for (final flow in config.flows) {
      if (flow.srcLabel != me.label) continue;
      final dst = byLabel[flow.dstLabel];
      if (dst == null) {
        log('[bulk] flow ${flow.srcLabel}>${flow.dstLabel}: unknown dst label');
        continue;
      }
      final dstPubkey = _hexToBytes(dst.pubkeyHex);
      if (dstPubkey == null || dstPubkey.length < 32) {
        log('[bulk] flow ${flow.srcLabel}>${flow.dstLabel}: bad dst pubkey');
        continue;
      }
      runs.add(_FlowRun(flow, dstPubkey));
    }
    if (runs.isEmpty) {
      log('[bulk] no flows have this device as source');
      return;
    }

    _config = config;
    _runs = runs;
    _byMessageId.clear();
    _running = true;
    _endTimer = Timer(Duration(milliseconds: config.durationMs), stop);
    log('[bulk] started: ${runs.length} flow(s), '
        '${config.payloadBytes}B x inFlight ${config.inFlight}, '
        '${config.durationMs}ms window');
    for (final run in runs) {
      _traceFlow('start', run);
      for (var i = 0; i < config.inFlight; i++) {
        _fireNext(run);
      }
    }
  }

  /// End the send window. Outstanding messages are abandoned, never re-sent.
  void stop() {
    if (!_running) return;
    _running = false;
    _endTimer?.cancel();
    _endTimer = null;
    for (final run in _runs) {
      _traceFlow('stop', run);
      log('[bulk] flow ${run.label}: sent ${run.sent}, acked ${run.acked} '
          '(${run.ackedBytes}B), ${run.outstanding.length} unacked');
    }
    _byMessageId.clear();
  }

  /// Feed of end-to-end ACKs from the coordinator. Refills the sending
  /// window of the flow the message belonged to.
  void onAck(String messageId) {
    final run = _byMessageId.remove(messageId);
    if (run == null) return;
    if (!run.outstanding.remove(messageId)) return;
    run.acked++;
    run.ackedBytes += _config?.payloadBytes ?? 0;
    if (_running) _fireNext(run);
  }

  void _fireNext(_FlowRun run) {
    final config = _config;
    if (config == null || !_running) return;
    final seq = run.seq++;
    final messageId =
        messageIdFor(run.flow.srcLabel, run.flow.dstLabel, seq);
    final payload = Uint8List(config.payloadBytes);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = (seq + i) & 0xff;
    }
    run.outstanding.add(messageId);
    _byMessageId[messageId] = run;
    run.sent++;
    unawaited(send(run.dstPubkey, payload, messageId: messageId));
  }

  void _traceFlow(String event, _FlowRun run) {
    final config = _config;
    if (!(trace?.active ?? false) || config == null) return;
    unawaited(trace!.log({
      'type': 'flow',
      't': DateTime.now().millisecondsSinceEpoch,
      'event': event,
      'flow': run.label,
      'payloadBytes': config.payloadBytes,
      'inFlight': config.inFlight,
      if (event == 'stop') 'sent': run.sent,
      if (event == 'stop') 'acked': run.acked,
      if (event == 'stop') 'ackedBytes': run.ackedBytes,
    }));
  }
}

Uint8List? _hexToBytes(String hex) {
  final clean = hex.trim().toLowerCase();
  if (clean.isEmpty || clean.length.isOdd) return null;
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final b = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}
