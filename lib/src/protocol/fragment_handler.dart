import 'dart:async';
import 'dart:typed_data';

import '../models/secure_frame.dart';

/// Splits large payloads into [SecureFrame]s and reassembles them.
///
/// Fragmentation lives *inside* the sealed envelope: each fragment is an
/// ordinary [PacketType.secure] packet whose plaintext is a [SecureFrame] with
/// `fragCount > 1`. Relays never see fragment boundaries; only the recipient,
/// after decrypting, reassembles by [SecureFrame.messageId].
class FragmentHandler {
  /// Maximum chunk size per fragment.
  ///
  /// Each fragment is sent as ONE BLE GATT write — the plugin does not
  /// split/reassemble, so a sealed packet larger than `ATT_MTU - 3` is
  /// silently truncated on the wire and the receiver can't parse it. A flooded
  /// packet reaches peers with different MTUs, so we size for the floor MTU we
  /// request ([_bleFloorMtu] = 247 → 244 usable). Fixed overhead per packet:
  ///   58 (packet header) + 25 (Noise version+nonce+tag) + 21 (frame header)
  ///   = 104 bytes.
  /// So chunk ≤ 244 − 104 = 140; we use 132 for margin (236-byte packet).
  static const int _bleFloorMtu = 247;
  static const int _packetFixedOverhead = 58 + 25 + 21; // = 104
  static const int maxFragmentPayload =
      _bleFloorMtu - 3 - _packetFixedOverhead - 8; // = 132

  /// Payloads larger than this are fragmented; at or below fit one sealed
  /// packet within the BLE floor MTU. Same budget as [maxFragmentPayload] (a
  /// single frame carries no more than a fragment does).
  static const int fragmentThreshold = maxFragmentPayload;

  /// Inter-fragment send delay (avoids overwhelming the BLE buffer).
  static const Duration fragmentDelay = Duration(milliseconds: 20);

  /// Timeout for an incomplete reassembly. Must outlast the slowest transfer
  /// we allow: a capped file at ~132 B/fragment × 20 ms/fragment. Sized for
  /// the ~1 MB attachment cap (~8k fragments ≈ 160 s) plus slack.
  static const Duration reassemblyTimeout = Duration(minutes: 4);

  final Map<String, _ReassemblyState> _reassemblyBuffer = {};
  Timer? _cleanupTimer;

  FragmentHandler() {
    _startCleanupTimer();
  }

  /// Whether a payload must be fragmented to fit one sealed packet.
  bool needsFragmentation(Uint8List payload) =>
      payload.length > fragmentThreshold;

  /// Build the [SecureFrame]s carrying [payload] under [messageId].
  ///
  /// A payload at or below [fragmentThreshold] yields a single frame
  /// (`fragCount == 1`); larger payloads are chunked at [maxFragmentPayload].
  /// The caller seals each frame into its own [PacketType.secure] packet and
  /// floods them [fragmentDelay] apart.
  List<SecureFrame> framesFor({
    required Uint8List payload,
    required String messageId,
    ContentType contentType = ContentType.message,
  }) {
    if (!needsFragmentation(payload)) {
      return [
        SecureFrame(
          contentType: contentType,
          messageId: messageId,
          chunk: payload,
        ),
      ];
    }

    final total = (payload.length / maxFragmentPayload).ceil();
    final frames = <SecureFrame>[];
    for (var i = 0; i < total; i++) {
      final start = i * maxFragmentPayload;
      final end = (start + maxFragmentPayload).clamp(0, payload.length);
      frames.add(SecureFrame(
        contentType: contentType,
        messageId: messageId,
        fragIndex: i,
        fragCount: total,
        chunk: Uint8List.fromList(payload.sublist(start, end)),
      ));
    }
    return frames;
  }

  /// Accept a decrypted [frame]. Returns the complete payload when the logical
  /// message is whole (immediately for a single-fragment frame), else null
  /// while more fragments are outstanding.
  Uint8List? accept(SecureFrame frame) {
    if (!frame.isFragmented) return frame.chunk;

    final state = _reassemblyBuffer.putIfAbsent(
      frame.messageId,
      () => _ReassemblyState(totalFragments: frame.fragCount),
    );
    state.addChunk(frame.fragIndex, frame.chunk);
    if (!state.isComplete) return null;

    _reassemblyBuffer.remove(frame.messageId);
    return state.reassemble();
  }

  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final now = DateTime.now();
      _reassemblyBuffer.removeWhere(
        (_, state) => now.difference(state.startedAt) > reassemblyTimeout,
      );
    });
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _reassemblyBuffer.clear();
  }
}

class _ReassemblyState {
  final int totalFragments;
  final Map<int, Uint8List> _chunks = {};
  final DateTime startedAt = DateTime.now();

  _ReassemblyState({required this.totalFragments});

  void addChunk(int index, Uint8List data) => _chunks[index] = data;

  bool get isComplete => _chunks.length == totalFragments;

  Uint8List? reassemble() {
    final result = BytesBuilder();
    for (var i = 0; i < totalFragments; i++) {
      final chunk = _chunks[i];
      if (chunk == null) return null;
      result.add(chunk);
    }
    return result.toBytes();
  }
}
