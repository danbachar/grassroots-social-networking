import 'dart:async';
import 'dart:typed_data';

/// Transport-level fragmenter for splitting/reassembling raw bytes.
///
/// Each transport configures its own max payload size:
/// - BLE: 512 bytes (characteristic write limit)
/// - libp2p: 65536 bytes
///
/// Fragment wire format (5-byte header):
/// ```
/// [0xFF] [msgId: 2B big-endian] [index: 1B] [total: 1B] [chunk data]
/// ```
///
/// The 0xFF marker byte distinguishes fragments from BitchatPackets
/// (whose first byte is the PacketType, values 0x01-0x08).
class Fragmenter {
  /// Marker byte for transport-level fragments.
  static const int fragmentMarker = 0xFF;

  /// Fragment header size: marker(1) + msgId(2) + index(1) + total(1) = 5.
  static const int headerSize = 5;

  /// Inter-fragment delay to avoid overwhelming transport buffers.
  static const Duration fragmentDelay = Duration(milliseconds: 20);

  /// Timeout for incomplete reassembly.
  static const Duration reassemblyTimeout = Duration(seconds: 30);

  /// Default maximum bytes per transport write (e.g. 512 for BLE).
  /// Can be overridden per-call in [split] via the [maxSize] parameter.
  final int maxPayloadSize;

  /// Maximum chunk data per fragment (using default maxPayloadSize).
  int get maxChunkSize => maxPayloadSize - headerSize;

  /// Incrementing message ID counter (wraps at 65536).
  int _nextMessageId = 0;

  /// Reassembly buffer keyed by (peerId, messageId).
  final Map<(String, int), _ReassemblyState> _reassemblyBuffer = {};

  /// Cleanup timer for stale reassemblies.
  Timer? _cleanupTimer;

  Fragmenter({required this.maxPayloadSize}) {
    if (maxPayloadSize <= headerSize) {
      throw ArgumentError('maxPayloadSize must be > $headerSize');
    }
    _cleanupTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _cleanupStale(),
    );
  }

  /// Split data into transport-sized chunks.
  ///
  /// Returns `[data]` unchanged if it fits in a single write.
  /// Otherwise returns a list of fragment chunks, each ≤ [maxSize]
  /// (or [maxPayloadSize] if [maxSize] is not provided).
  ///
  /// Use [maxSize] to override the default for a specific peer, e.g.
  /// based on the negotiated BLE MTU (`mtu - 3`).
  List<Uint8List> split(Uint8List data, {int? maxSize}) {
    final effectiveMaxPayload = maxSize ?? maxPayloadSize;
    final effectiveMaxChunk = effectiveMaxPayload - headerSize;

    if (effectiveMaxChunk <= 0) {
      throw ArgumentError('maxSize must be > $headerSize');
    }

    if (data.length <= effectiveMaxPayload) return [data];

    final messageId = _nextMessageId;
    _nextMessageId = (_nextMessageId + 1) & 0xFFFF;

    final chunks = <Uint8List>[];
    final totalFragments = (data.length / effectiveMaxChunk).ceil();
    if (totalFragments > 255) {
      throw ArgumentError(
        'Data too large: $totalFragments fragments needed (max 255)',
      );
    }

    for (var i = 0; i < totalFragments; i++) {
      final start = i * effectiveMaxChunk;
      final end = (start + effectiveMaxChunk).clamp(0, data.length);
      final chunkData = data.sublist(start, end);

      final chunk = Uint8List(headerSize + chunkData.length);
      chunk[0] = fragmentMarker;
      chunk[1] = (messageId >> 8) & 0xFF;
      chunk[2] = messageId & 0xFF;
      chunk[3] = i;
      chunk[4] = totalFragments;
      chunk.setRange(headerSize, chunk.length, chunkData);

      chunks.add(chunk);
    }

    return chunks;
  }

  /// Receive a fragment chunk from a peer.
  ///
  /// Returns the reassembled complete data when all fragments have arrived.
  /// Returns null while waiting for more fragments.
  Uint8List? receive(String peerId, Uint8List chunk) {
    if (chunk.length < headerSize || chunk[0] != fragmentMarker) return null;

    final messageId = (chunk[1] << 8) | chunk[2];
    final fragmentIndex = chunk[3];
    final totalFragments = chunk[4];

    // Reject invalid fragment headers
    if (totalFragments == 0 || fragmentIndex >= totalFragments) return null;

    final chunkData = chunk.sublist(headerSize);

    final key = (peerId, messageId);
    final state = _reassemblyBuffer.putIfAbsent(
      key,
      () => _ReassemblyState(totalFragments: totalFragments),
    );

    state.addChunk(fragmentIndex, chunkData);

    if (state.isComplete) {
      _reassemblyBuffer.remove(key);
      return state.reassemble();
    }

    return null;
  }

  void _cleanupStale() {
    final now = DateTime.now();
    _reassemblyBuffer.removeWhere(
      (_, state) => now.difference(state.createdAt) > reassemblyTimeout,
    );
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _reassemblyBuffer.clear();
  }
}

class _ReassemblyState {
  final int totalFragments;
  final Map<int, Uint8List> chunks = {};
  final DateTime createdAt = DateTime.now();

  _ReassemblyState({required this.totalFragments});

  bool get isComplete => chunks.length == totalFragments;

  void addChunk(int index, Uint8List data) {
    chunks[index] = data;
  }

  Uint8List? reassemble() {
    if (!isComplete) return null;
    final builder = BytesBuilder();
    for (var i = 0; i < totalFragments; i++) {
      final chunk = chunks[i];
      if (chunk == null) return null;
      builder.add(chunk);
    }
    return builder.toBytes();
  }
}
