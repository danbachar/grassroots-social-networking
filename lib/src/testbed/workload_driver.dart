import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'testbed_config.dart';

/// Fixed namespace for the workload's deterministic UUIDv5 message ids. Any
/// offline tool using this namespace + the same `"{src}|{dst}|{seq}"` name
/// reproduces the exact id set (the delivery-ratio denominator).
const String workloadUuidNamespace = 'b8f4a1e2-1c3d-4b5a-9e7f-677261737372';

/// A portable, offline-reproducible PRNG (mulberry32). Deliberately NOT
/// `dart:math` Random — every device and any offline analysis must compute the
/// identical stream from a seed, independent of SDK/platform.
class Mulberry32 {
  int _state;
  Mulberry32(int seed) : _state = seed & 0xFFFFFFFF;

  /// Next double in [0, 1).
  double nextDouble() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    var t = _state;
    t = (t ^ (t >> 15)) * (t | 1) & 0xFFFFFFFF;
    t ^= t + ((t ^ (t >> 7)) * (t | 61) & 0xFFFFFFFF) & 0xFFFFFFFF;
    return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0;
  }
}

/// FNV-1a 32-bit — a stable, documented string hash for per-pair PRNG seeding
/// (String.hashCode is not guaranteed reproducible offline).
int fnv1a32(String s) {
  var hash = 0x811c9dc5;
  for (final unit in s.codeUnits) {
    hash ^= unit & 0xff;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// One scheduled send: fire [payloadBytes] to [dstPubkey] at [scheduledMs]
/// under the deterministic [messageId].
@immutable
class WorkloadEvent {
  final int scheduledMs;
  final String dstLabel;
  final Uint8List dstPubkey;
  final int payloadBytes;
  final String messageId;
  final int seq;

  const WorkloadEvent({
    required this.scheduledMs,
    required this.dstLabel,
    required this.dstPubkey,
    required this.payloadBytes,
    required this.messageId,
    required this.seq,
  });
}

/// DEBUG/TESTBED ONLY. Fires a device's slice of a deterministic offered-load
/// schedule via [send], regardless of reachability (an unreachable recipient
/// is queued by the network — a valid "offered but undelivered" event).
class WorkloadDriver {
  final Future<String?> Function(Uint8List recipient, Uint8List payload,
      {String? messageId}) send;
  final void Function(String) log;
  static const _uuid = Uuid();

  Timer? _tick;
  List<WorkloadEvent> _pending = const [];
  int _cursor = 0;
  int _sent = 0;
  bool _running = false;

  WorkloadDriver({required this.send, required this.log});

  bool get isRunning => _running;
  int get scheduledCount => _pending.length;
  int get sentCount => _sent;

  /// Compute this device's source-side schedule (rows where [myPubkeyHex] is
  /// the source), sorted by time. Pure/deterministic — also used by tests and
  /// offline reproduction.
  static List<WorkloadEvent> computeSchedule({
    required WorkloadConfig config,
    required String myPubkeyHex,
  }) {
    final me = config.roster
        .where((r) => r.pubkeyHex.toLowerCase() == myPubkeyHex.toLowerCase())
        .firstOrNull;
    if (me == null) return const [];
    if (config.ratePerPairPerHour <= 0 ||
        config.endAtEpochMs <= config.startAtEpochMs) {
      return const [];
    }

    final ratePerSec = config.ratePerPairPerHour / 3600.0;
    final totalWeight =
        config.payloadMix.fold<double>(0, (a, p) => a + p.weight);
    final events = <WorkloadEvent>[];

    for (final dst in config.roster) {
      if (dst.label == me.label) continue; // no self-sends
      final rng = Mulberry32(
          fnv1a32('${config.seed}|${me.label}|${dst.label}'));
      final dstBytes = _hexToBytesOrEmpty(dst.pubkeyHex);
      var tMs = config.startAtEpochMs.toDouble();
      var seq = 0;
      while (true) {
        // Draw order is part of the contract: inter-arrival, then payload.
        var u = rng.nextDouble();
        if (u <= 0) u = 1e-12; // guard against ln(0)
        tMs += (-math.log(u) / ratePerSec) * 1000.0;
        if (tMs > config.endAtEpochMs) break;
        final payloadBytes = _weightedPick(config.payloadMix, totalWeight, rng);
        final id = _uuid.v5(
            workloadUuidNamespace, '${me.label}|${dst.label}|$seq');
        events.add(WorkloadEvent(
          scheduledMs: tMs.floor(),
          dstLabel: dst.label,
          dstPubkey: dstBytes,
          payloadBytes: payloadBytes,
          messageId: id,
          seq: seq,
        ));
        seq++;
      }
    }
    events.sort((a, b) => a.scheduledMs.compareTo(b.scheduledMs));
    return events;
  }

  /// Begin executing the schedule. No-op if already running or the device is
  /// not in the roster.
  void start({required WorkloadConfig config, required String myPubkeyHex}) {
    if (_running) return;
    _pending = computeSchedule(config: config, myPubkeyHex: myPubkeyHex);
    _cursor = 0;
    _sent = 0;
    if (_pending.isEmpty) {
      log('[workload] nothing to send (not in roster or empty schedule)');
      return;
    }
    _running = true;
    log('[workload] started: ${_pending.length} scheduled sends, '
        'window ends ${config.endAtEpochMs}');
    _tick = Timer.periodic(const Duration(milliseconds: 200), (_) => _fireDue());
    _fireDue();
  }

  void stop() {
    _tick?.cancel();
    _tick = null;
    if (_running) {
      log('[workload] stopped: sent $_sent of ${_pending.length}');
    }
    _running = false;
  }

  void _fireDue() {
    if (!_running) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    while (_cursor < _pending.length &&
        _pending[_cursor].scheduledMs <= nowMs) {
      final e = _pending[_cursor++];
      if (e.dstPubkey.length < 32) {
        log('[workload] skip seq ${e.seq}→${e.dstLabel}: bad roster pubkey');
        continue;
      }
      final payload = Uint8List(e.payloadBytes);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (e.seq + i) & 0xff;
      }
      unawaited(send(e.dstPubkey, payload, messageId: e.messageId));
      _sent++;
    }
    if (_cursor >= _pending.length) {
      log('[workload] complete: fired all $_sent scheduled sends');
      stop();
    }
  }

  static int _weightedPick(
      List<WorkloadPayload> mix, double totalWeight, Mulberry32 rng) {
    if (mix.isEmpty) return 0;
    if (totalWeight <= 0) return mix.first.bytes;
    var r = rng.nextDouble() * totalWeight;
    for (final p in mix) {
      r -= p.weight;
      if (r <= 0) return p.bytes;
    }
    return mix.last.bytes;
  }
}

Uint8List _hexToBytesOrEmpty(String hex) {
  final clean = hex.trim().toLowerCase();
  if (clean.isEmpty || clean.length.isOdd) return Uint8List(0);
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final b = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return Uint8List(0);
    out[i] = b;
  }
  return out;
}
