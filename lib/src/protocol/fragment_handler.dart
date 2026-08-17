import 'dart:async';
import 'dart:typed_data';

import '../models/packet.dart';
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
  ///   60 (packet header) + 25 (Noise version+nonce+tag) + 21 (frame header)
  ///   = 106 bytes.
  /// So chunk ≤ 244 − 106 = 138; we use 130, holding 8 bytes back. The
  /// overhead is DERIVED from [GrassrootsPacket.headerSize], so restoring the
  /// 6-byte creation stamp (54 → 60) moved the budget 136 → 130 by itself and
  /// kept the margin intact.
  ///
  /// That 8 is a CHOSEN margin, not a measured one. What it buys is the one
  /// number here that is not a constant: 247 is the MTU the transport
  /// *requests*, not necessarily the one a given pair negotiates. A chunk cut
  /// to exactly 144 truncates silently against any peer that settles below
  /// 247, and 8 bytes covers down to a 239-byte MTU. Whether such a peer
  /// exists on real hardware is measurable and, until the ATT-ceiling probe
  /// runs (`Raw link: ATT ceiling probe` — see [FieldPlanPresets.rawLink]),
  /// unmeasured. Reclaiming it is worth ~6% more payload per fragment.
  static const int _bleFloorMtu = 247;
  static const int _packetFixedOverhead =
      GrassrootsPacket.headerSize + 25 + 21; // = 106
  static const int maxFragmentPayload =
      _bleFloorMtu - 3 - _packetFixedOverhead - 8; // = 130

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

  /// Fired when a partial reassembly is abandoned: the 4-minute timeout swept
  /// it ('timeout') or reassembly failed despite a complete count — an
  /// out-of-range fragIndex was counted ('broken'). Both are whole-message
  /// losses that were previously invisible; the coordinator wires this to a
  /// `drop` trace record.
  void Function(String reason, String messageId, int have, int total)?
      onAbandon;

  /// In-progress reassembly count — `buf` trace record occupancy.
  int get reassemblyCount => _reassemblyBuffer.length;

  /// Bytes currently held across all partial reassemblies.
  int get reassemblyBytes => _reassemblyBuffer.values
      .fold(0, (sum, s) => sum + s.bufferedBytes);

  FragmentHandler() {
    _startCleanupTimer();
  }

  /// Whether a payload must be fragmented to fit one sealed packet.
  bool needsFragmentation(Uint8List payload) =>
      payload.length > fragmentThreshold;

  /// Build the [SecureFrame]s carrying [payload] under [messageId].
  ///
  /// A payload at or below the chunk budget yields a single frame
  /// (`fragCount == 1`); larger payloads are chunked at the budget. The caller
  /// seals each frame into its own [PacketType.secure] packet and floods them
  /// [fragmentDelay] apart.
  ///
  /// [chunkBudget] overrides the chunk size AND the single-vs-multi threshold.
  /// Null (the default) is the sealed end-to-end path, sized to the floor MTU
  /// ([maxFragmentPayload]). A caller passes an explicit budget to size
  /// fragments to a specific target's DISCOVERED per-leg MTU — the cleartext,
  /// neighbour-local path (ANNOUNCE / Noise handshake), where the frame is
  /// written as `frame.encode()` in the packet payload instead of being sealed.
  /// Reassembly is identical either way: [accept] keys on the 16-byte
  /// [SecureFrame.messageId], which is globally unique, so no per-peer keying
  /// is needed.
  List<SecureFrame> framesFor({
    required Uint8List payload,
    required String messageId,
    ContentType contentType = ContentType.message,
    int? chunkBudget,
  }) {
    final budget = chunkBudget ?? maxFragmentPayload;

    if (payload.length <= budget) {
      return [
        SecureFrame(
          contentType: contentType,
          messageId: messageId,
          chunk: payload,
        ),
      ];
    }

    final total = (payload.length / budget).ceil();
    final frames = <SecureFrame>[];
    for (var i = 0; i < total; i++) {
      final start = i * budget;
      final end = (start + budget).clamp(0, payload.length);
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
    final whole = state.reassemble();
    if (whole == null) {
      // Count-complete but unassemblable: an out-of-range fragIndex was
      // counted toward isComplete. The state is already removed, so the
      // message is gone for good — say so.
      onAbandon?.call(
          'broken', frame.messageId, state.chunkCount, state.totalFragments);
    }
    return whole;
  }

  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final now = DateTime.now();
      _reassemblyBuffer.removeWhere((messageId, state) {
        if (now.difference(state.startedAt) <= reassemblyTimeout) return false;
        onAbandon?.call(
            'timeout', messageId, state.chunkCount, state.totalFragments);
        return true;
      });
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

  int get chunkCount => _chunks.length;

  int get bufferedBytes =>
      _chunks.values.fold(0, (sum, c) => sum + c.length);

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
