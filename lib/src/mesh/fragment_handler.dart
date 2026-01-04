import 'dart:async';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import '../models/packet.dart';

/// Result of fragmenting a large message
class FragmentedMessage {
  final String messageId;
  final List<BitchatPacket> fragments;
  
  FragmentedMessage({
    required this.messageId,
    required this.fragments,
  });
}

/// State of a message being reassembled
class _ReassemblyState {
  final String messageId;
  final int totalFragments;
  final int totalSize;
  final Map<int, Uint8List> receivedChunks = {};
  final DateTime startedAt = DateTime.now();
  final Uint8List senderPubkey;
  
  _ReassemblyState({
    required this.messageId,
    required this.totalFragments,
    required this.totalSize,
    required this.senderPubkey,
  });
  
  bool get isComplete => receivedChunks.length == totalFragments;
  
  void addChunk(int index, Uint8List data) {
    receivedChunks[index] = data;
  }
  
  Uint8List? reassemble() {
    if (!isComplete) return null;
    
    // Concatenate chunks in order
    final result = BytesBuilder();
    for (var i = 0; i < totalFragments; i++) {
      final chunk = receivedChunks[i];
      if (chunk == null) return null;
      result.add(chunk);
    }
    return result.toBytes();
  }
}

/// Handles fragmentation and reassembly of messages larger than BLE MTU.
/// 
/// Bitchat fragments messages > 500 bytes:
/// - fragmentStart: contains metadata + first chunk
/// - fragmentContinue: intermediate chunks
/// - fragmentEnd: final chunk, triggers reassembly
/// 
/// Inter-fragment delay: 20ms (to avoid overwhelming BLE buffer)
class FragmentHandler {
  static const _uuid = Uuid();
  
  /// Maximum payload size per fragment (matches Bitchat)
  static const int maxFragmentPayload = 450; // Leave room for fragment metadata
  
  /// Threshold for fragmenting (matches Bitchat)
  static const int fragmentThreshold = 500;
  
  /// Inter-fragment delay
  static const Duration fragmentDelay = Duration(milliseconds: 20);
  
  /// Timeout for incomplete reassembly
  static const Duration reassemblyTimeout = Duration(seconds: 30);
  
  /// Messages currently being reassembled, keyed by messageId
  final Map<String, _ReassemblyState> _reassemblyBuffer = {};
  
  /// Timer for cleaning up stale reassembly attempts
  Timer? _cleanupTimer;
  
  FragmentHandler() {
    _startCleanupTimer();
  }
  
  /// Check if a payload needs fragmentation
  bool needsFragmentation(Uint8List payload) => payload.length > fragmentThreshold;
  
  /// Fragment a large payload into multiple packets.
  /// 
  /// Returns a [FragmentedMessage] containing all the packets to send.
  /// Caller should send them with [fragmentDelay] between each.
  FragmentedMessage fragment({
    required Uint8List payload,
    required Uint8List senderPubkey,
    Uint8List? recipientPubkey,
    int ttl = BitchatPacket.defaultTtl,
  }) {
    if (!needsFragmentation(payload)) {
      throw ArgumentError('Payload does not need fragmentation');
    }
    
    final messageId = _uuid.v4();
    final fragments = <BitchatPacket>[];
    
    // Calculate number of fragments needed
    final totalFragments = (payload.length / maxFragmentPayload).ceil();
    
    for (var i = 0; i < totalFragments; i++) {
      final start = i * maxFragmentPayload;
      final end = (start + maxFragmentPayload).clamp(0, payload.length);
      final chunk = payload.sublist(start, end);
      
      final PacketType type;
      final Uint8List fragmentPayload;
      
      if (i == 0) {
        // First fragment: include metadata
        type = PacketType.fragmentStart;
        fragmentPayload = _encodeFragmentStart(
          messageId: messageId,
          totalFragments: totalFragments,
          totalSize: payload.length,
          chunk: chunk,
        );
      } else if (i == totalFragments - 1) {
        // Last fragment
        type = PacketType.fragmentEnd;
        fragmentPayload = _encodeFragmentEnd(
          messageId: messageId,
          fragmentIndex: i,
          chunk: chunk,
        );
      } else {
        // Middle fragments
        type = PacketType.fragmentContinue;
        fragmentPayload = _encodeFragmentContinue(
          messageId: messageId,
          fragmentIndex: i,
          chunk: chunk,
        );
      }
      
      fragments.add(BitchatPacket(
        type: type,
        ttl: ttl,
        senderPubkey: senderPubkey,
        recipientPubkey: recipientPubkey,
        payload: fragmentPayload,
        signature: Uint8List(64), // Placeholder - will be signed by caller
      ));
    }
    
    return FragmentedMessage(messageId: messageId, fragments: fragments);
  }
  
  /// Process an incoming fragment packet.
  /// 
  /// Returns the reassembled payload if this was the final fragment
  /// and all fragments have been received. Otherwise returns null.
  Uint8List? processFragment(BitchatPacket packet) {
    switch (packet.type) {
      case PacketType.fragmentStart:
        return _processFragmentStart(packet);
      case PacketType.fragmentContinue:
        return _processFragmentContinue(packet);
      case PacketType.fragmentEnd:
        return _processFragmentEnd(packet);
      default:
        throw ArgumentError('Not a fragment packet: ${packet.type}');
    }
  }
  
  Uint8List? _processFragmentStart(BitchatPacket packet) {
    final (messageId, totalFragments, totalSize, chunk) = 
        _decodeFragmentStart(packet.payload);
    
    // Create reassembly state
    _reassemblyBuffer[messageId] = _ReassemblyState(
      messageId: messageId,
      totalFragments: totalFragments,
      totalSize: totalSize,
      senderPubkey: packet.senderPubkey,
    )..addChunk(0, chunk);
    
    // Check if single-fragment message
    if (totalFragments == 1) {
      final state = _reassemblyBuffer.remove(messageId)!;
      return state.reassemble();
    }
    
    return null;
  }
  
  Uint8List? _processFragmentContinue(BitchatPacket packet) {
    final (messageId, fragmentIndex, chunk) = 
        _decodeFragmentContinue(packet.payload);
    
    final state = _reassemblyBuffer[messageId];
    if (state == null) {
      // Missing start fragment, can't reassemble
      return null;
    }
    
    state.addChunk(fragmentIndex, chunk);
    return null;
  }
  
  Uint8List? _processFragmentEnd(BitchatPacket packet) {
    final (messageId, fragmentIndex, chunk) = 
        _decodeFragmentEnd(packet.payload);
    
    final state = _reassemblyBuffer[messageId];
    if (state == null) {
      // Missing start fragment, can't reassemble
      return null;
    }
    
    state.addChunk(fragmentIndex, chunk);
    
    // Attempt reassembly
    final result = state.reassemble();
    if (result != null) {
      _reassemblyBuffer.remove(messageId);
    }
    
    return result;
  }
  
  // ===== Encoding helpers =====
  
  Uint8List _encodeFragmentStart({
    required String messageId,
    required int totalFragments,
    required int totalSize,
    required Uint8List chunk,
  }) {
    // Format: [messageId:36][totalFragments:2][totalSize:4][chunk:...]
    final buffer = BytesBuilder();
    buffer.add(Uint8List.fromList(messageId.codeUnits));
    
    final header = ByteData(6);
    header.setUint16(0, totalFragments, Endian.big);
    header.setUint32(2, totalSize, Endian.big);
    buffer.add(header.buffer.asUint8List());
    
    buffer.add(chunk);
    return buffer.toBytes();
  }
  
  Uint8List _encodeFragmentContinue({
    required String messageId,
    required int fragmentIndex,
    required Uint8List chunk,
  }) {
    // Format: [messageId:36][fragmentIndex:2][chunk:...]
    final buffer = BytesBuilder();
    buffer.add(Uint8List.fromList(messageId.codeUnits));
    
    final header = ByteData(2);
    header.setUint16(0, fragmentIndex, Endian.big);
    buffer.add(header.buffer.asUint8List());
    
    buffer.add(chunk);
    return buffer.toBytes();
  }
  
  Uint8List _encodeFragmentEnd({
    required String messageId,
    required int fragmentIndex,
    required Uint8List chunk,
  }) {
    // Same format as continue
    return _encodeFragmentContinue(
      messageId: messageId,
      fragmentIndex: fragmentIndex,
      chunk: chunk,
    );
  }
  
  // ===== Decoding helpers =====
  
  (String, int, int, Uint8List) _decodeFragmentStart(Uint8List data) {
    final messageId = String.fromCharCodes(data.sublist(0, 36));
    final header = ByteData.view(data.buffer, data.offsetInBytes + 36, 6);
    final totalFragments = header.getUint16(0, Endian.big);
    final totalSize = header.getUint32(2, Endian.big);
    final chunk = data.sublist(42);
    return (messageId, totalFragments, totalSize, chunk);
  }
  
  (String, int, Uint8List) _decodeFragmentContinue(Uint8List data) {
    final messageId = String.fromCharCodes(data.sublist(0, 36));
    final header = ByteData.view(data.buffer, data.offsetInBytes + 36, 2);
    final fragmentIndex = header.getUint16(0, Endian.big);
    final chunk = data.sublist(38);
    return (messageId, fragmentIndex, chunk);
  }
  
  (String, int, Uint8List) _decodeFragmentEnd(Uint8List data) {
    return _decodeFragmentContinue(data);
  }
  
  // ===== Cleanup =====
  
  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _cleanupStaleReassemblies();
    });
  }
  
  void _cleanupStaleReassemblies() {
    final now = DateTime.now();
    _reassemblyBuffer.removeWhere((id, state) {
      return now.difference(state.startedAt) > reassemblyTimeout;
    });
  }
  
  /// Clean up resources
  void dispose() {
    _cleanupTimer?.cancel();
    _reassemblyBuffer.clear();
  }
}
