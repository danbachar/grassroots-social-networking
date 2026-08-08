import 'dart:typed_data';

import '../models/packet.dart';

/// Per-packet-type byte/packet counters for one transport's wire traffic.
///
/// Classifies every serialized packet by its outer type byte (byte 0 of the
/// Grassroots envelope) and accumulates tx/rx totals. [drainRecord] emits the
/// deltas since the previous drain as a `wire` trace record, so the trace
/// stream carries a periodic control-plane/data-plane byte breakdown:
/// ANNOUNCE + handshake is the visible control-plane cost of establishing a
/// link and keeping it alive; `secure` is everything sealed — application
/// data AND the sync-on-connect control frames, which are indistinguishable
/// on the air by design.
///
/// Counting happens at the transport send/receive choke points, so a
/// broadcast that goes out over N links counts N times — these are bytes on
/// the air, not bytes composed.
class WireLedger {
  static const _typeNames = {
    0x01: 'announce',
    0x02: 'handshake',
    0x03: 'secure',
    0x7F: 'raw',
  };

  static String typeNameFor(int typeByte) =>
      _typeNames[typeByte] ?? 'other';

  final Map<String, int> _txBytes = {};
  final Map<String, int> _txPackets = {};
  final Map<String, int> _rxBytes = {};
  final Map<String, int> _rxPackets = {};
  bool _dirty = false;

  /// Every byte this ledger has seen, tx and rx together, NOT reset by
  /// [drainRecord]. The field runner samples it to prove a `bleOn: true`
  /// segment actually got the radio on the air: a segment that moves zero
  /// bytes is a dead radio, and without this check the runner would dwell
  /// out the full step and advance, which is how a 2-hour power ladder was
  /// recorded against a radio that never came back up.
  int _totalBytes = 0;

  /// Monotonic tx+rx byte total since this ledger was created. A BLE bounce
  /// disposes the transport and its ledger, so a fresh service starts at
  /// zero — which is exactly the baseline a per-segment check wants.
  int get totalBytes => _totalBytes;

  /// Resolves the inner content type of one of OUR sealed packets by its
  /// packetId (bytes 38..54 of the envelope). Only the sender knows this —
  /// the ledger sits below decryption — so tx `secure` bytes are split
  /// exactly (`secure:data`, `secure:ack`, `secure:sync`, …) while rx
  /// `secure` stays aggregate, which is precisely what a peer on the air
  /// can tell apart.
  String Function(String packetId)? secureContentFor;

  void onTx(Uint8List data) => _count(_txBytes, _txPackets, data, tx: true);

  void onRx(Uint8List data) => _count(_rxBytes, _rxPackets, data);

  static String? _packetIdOf(Uint8List data) {
    if (data.length < 54) return null;
    try {
      return GrassrootsPacket.bytesToUuid(data.sublist(38, 54));
    } catch (_) {
      return null;
    }
  }

  void _count(Map<String, int> bytes, Map<String, int> packets, Uint8List data,
      {bool tx = false}) {
    if (data.isEmpty) return;
    var name = typeNameFor(data[0]);
    if (tx && name == 'secure' && secureContentFor != null) {
      final id = _packetIdOf(data);
      if (id != null) {
        final content = secureContentFor!(id);
        if (content.isNotEmpty) name = 'secure:$content';
      }
    }
    bytes[name] = (bytes[name] ?? 0) + data.length;
    packets[name] = (packets[name] ?? 0) + 1;
    _totalBytes += data.length;
    _dirty = true;
  }

  /// The deltas since the last drain as a trace record, or null when no
  /// traffic moved. Resets the counters.
  Map<String, dynamic>? drainRecord({required String transport}) {
    if (!_dirty) return null;
    final record = {
      'type': 'wire',
      't': DateTime.now().millisecondsSinceEpoch,
      'transport': transport,
      if (_txBytes.isNotEmpty) 'txBytes': Map<String, int>.from(_txBytes),
      if (_txPackets.isNotEmpty) 'txPackets': Map<String, int>.from(_txPackets),
      if (_rxBytes.isNotEmpty) 'rxBytes': Map<String, int>.from(_rxBytes),
      if (_rxPackets.isNotEmpty) 'rxPackets': Map<String, int>.from(_rxPackets),
    };
    _txBytes.clear();
    _txPackets.clear();
    _rxBytes.clear();
    _rxPackets.clear();
    _dirty = false;
    return record;
  }
}
