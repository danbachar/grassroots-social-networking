import 'dart:typed_data';

/// Per-packet-type byte/packet counters for one transport's wire traffic.
///
/// Classifies every serialized packet by its outer type byte (byte 0 of the
/// Grassroots envelope) and accumulates tx/rx totals. [drainRecord] emits the
/// deltas since the previous drain as a `wire` trace record, so the trace
/// stream carries a periodic control-plane/data-plane byte breakdown:
/// ANNOUNCE + handshake + sync traffic is the control-plane cost of
/// establishing a link and keeping it alive; `secure` is the data plane.
///
/// Counting happens at the transport send/receive choke points, so a
/// broadcast that goes out over N links counts N times — these are bytes on
/// the air, not bytes composed.
class WireLedger {
  static const _typeNames = {
    0x01: 'announce',
    0x02: 'handshake',
    0x03: 'secure',
    0x04: 'syncOffer',
    0x05: 'syncRequest',
  };

  static String typeNameFor(int typeByte) =>
      _typeNames[typeByte] ?? 'other';

  final Map<String, int> _txBytes = {};
  final Map<String, int> _txPackets = {};
  final Map<String, int> _rxBytes = {};
  final Map<String, int> _rxPackets = {};
  bool _dirty = false;

  void onTx(Uint8List data) => _count(_txBytes, _txPackets, data);

  void onRx(Uint8List data) => _count(_rxBytes, _rxPackets, data);

  void _count(Map<String, int> bytes, Map<String, int> packets,
      Uint8List data) {
    if (data.isEmpty) return;
    final name = typeNameFor(data[0]);
    bytes[name] = (bytes[name] ?? 0) + data.length;
    packets[name] = (packets[name] ?? 0) + 1;
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
