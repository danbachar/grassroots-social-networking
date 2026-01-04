import 'dart:typed_data';
import 'package:uuid/uuid.dart';

/// Packet types matching Bitchat protocol
enum PacketType {
  /// Peer identity announcement (sent on connection)
  announce(0x01),
  
  /// Application message (GSG blocks go here)
  message(0x02),
  
  /// Start of fragmented message
  fragmentStart(0x03),
  
  /// Continuation fragment
  fragmentContinue(0x04),
  
  /// Final fragment
  fragmentEnd(0x05),
  
  /// Delivery acknowledgment
  ack(0x06),
  
  /// Negative acknowledgment / request for data
  nack(0x07);
  
  final int value;
  const PacketType(this.value);
  
  static PacketType fromValue(int value) {
    return PacketType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => throw ArgumentError('Unknown packet type: $value'),
    );
  }
}

/// A Bitchat packet ready for BLE transmission.
/// 
/// Binary format (Bitchat-compatible):
/// ```
/// [0]      : Packet type (1 byte)
/// [1]      : TTL (1 byte)
/// [2-5]    : Timestamp (4 bytes, seconds since epoch, big-endian)
/// [6-37]   : Sender public key (32 bytes)
/// [38-69]  : Recipient public key (32 bytes, zeros for broadcast)
/// [70-71]  : Payload length (2 bytes, big-endian)
/// [72-87]  : Packet ID (16 bytes, UUID)
/// [88-151] : Signature (64 bytes, Ed25519)
/// [152-N]  : Payload (variable length)
/// ```
/// 
/// Total header size: 152 bytes
/// Max payload for single packet: ~350 bytes (with 500 byte MTU target)
class BitchatPacket {
  static const int headerSize = 152;
  static const int maxPayloadSize = 348; // 500 - 152
  static const int defaultTtl = 7;
  
  static const _uuid = Uuid();
  
  /// Unique packet identifier for deduplication
  final String packetId;
  
  /// Packet type
  final PacketType type;
  
  /// Time-to-live: decremented at each hop, dropped when 0
  int ttl;
  
  /// Creation timestamp (Unix seconds)
  final int timestamp;
  
  /// Sender's Ed25519 public key
  final Uint8List senderPubkey;
  
  /// Recipient's public key (null/zeros for broadcast)
  final Uint8List? recipientPubkey;
  
  /// Payload data (type-specific)
  final Uint8List payload;
  
  /// Ed25519 signature over packet contents
  Uint8List signature;
  
  BitchatPacket({
    String? packetId,
    required this.type,
    this.ttl = defaultTtl,
    int? timestamp,
    required this.senderPubkey,
    this.recipientPubkey,
    required this.payload,
    required this.signature,
  })  : packetId = packetId ?? _uuid.v4(),
        timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 {
    if (senderPubkey.length != 32) {
      throw ArgumentError('Sender public key must be 32 bytes');
    }
    if (recipientPubkey != null && recipientPubkey!.length != 32) {
      throw ArgumentError('Recipient public key must be 32 bytes');
    }
    if (signature.length != 64) {
      throw ArgumentError('Signature must be 64 bytes');
    }
  }
  
  /// Whether this is a broadcast packet (no specific recipient)
  bool get isBroadcast => recipientPubkey == null || 
      recipientPubkey!.every((b) => b == 0);
  
  /// Create a copy with decremented TTL for relaying
  BitchatPacket decrementTtl() {
    if (ttl <= 0) {
      throw StateError('Cannot decrement TTL below 0');
    }
    return BitchatPacket(
      packetId: packetId,
      type: type,
      ttl: ttl - 1,
      timestamp: timestamp,
      senderPubkey: senderPubkey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: signature,
    );
  }
  
  /// Serialize to binary format for BLE transmission
  Uint8List serialize() {
    final buffer = ByteData(headerSize + payload.length);
    var offset = 0;
    
    // Type (1 byte)
    buffer.setUint8(offset++, type.value);
    
    // TTL (1 byte)
    buffer.setUint8(offset++, ttl);
    
    // Timestamp (4 bytes, big-endian)
    buffer.setUint32(offset, timestamp, Endian.big);
    offset += 4;
    
    // Sender pubkey (32 bytes)
    final bytes = buffer.buffer.asUint8List();
    bytes.setRange(offset, offset + 32, senderPubkey);
    offset += 32;
    
    // Recipient pubkey (32 bytes, zeros if broadcast)
    if (recipientPubkey != null) {
      bytes.setRange(offset, offset + 32, recipientPubkey!);
    } else {
      bytes.fillRange(offset, offset + 32, 0);
    }
    offset += 32;
    
    // Payload length (2 bytes, big-endian)
    buffer.setUint16(offset, payload.length, Endian.big);
    offset += 2;
    
    // Packet ID (16 bytes - UUID as bytes)
    final idBytes = _uuidToBytes(packetId);
    bytes.setRange(offset, offset + 16, idBytes);
    offset += 16;
    
    // Signature (64 bytes)
    bytes.setRange(offset, offset + 64, signature);
    offset += 64;
    
    // Payload
    bytes.setRange(offset, offset + payload.length, payload);
    
    return bytes;
  }
  
  /// Deserialize from binary format
  static BitchatPacket deserialize(Uint8List data) {
    if (data.length < headerSize) {
      throw FormatException('Packet too small: ${data.length} < $headerSize');
    }
    
    final buffer = ByteData.view(data.buffer, data.offsetInBytes, data.length);
    var offset = 0;
    
    // Type
    final type = PacketType.fromValue(buffer.getUint8(offset++));
    
    // TTL
    final ttl = buffer.getUint8(offset++);
    
    // Timestamp
    final timestamp = buffer.getUint32(offset, Endian.big);
    offset += 4;
    
    // Sender pubkey
    final senderPubkey = Uint8List.fromList(data.sublist(offset, offset + 32));
    offset += 32;
    
    // Recipient pubkey
    final recipientBytes = data.sublist(offset, offset + 32);
    final recipientPubkey = recipientBytes.every((b) => b == 0) 
        ? null 
        : Uint8List.fromList(recipientBytes);
    offset += 32;
    
    // Payload length
    final payloadLength = buffer.getUint16(offset, Endian.big);
    offset += 2;
    
    // Packet ID
    final idBytes = data.sublist(offset, offset + 16);
    final packetId = _bytesToUuid(idBytes);
    offset += 16;
    
    // Signature
    final sigBytes = data.sublist(offset, offset + 64);
    final signature = Uint8List.fromList(sigBytes);
    offset += 64;
    
    // Payload
    if (data.length < offset + payloadLength) {
      throw FormatException('Incomplete payload: expected $payloadLength bytes');
    }
    final payload = Uint8List.fromList(data.sublist(offset, offset + payloadLength));
    
    return BitchatPacket(
      packetId: packetId,
      type: type,
      ttl: ttl,
      timestamp: timestamp,
      senderPubkey: senderPubkey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: signature,
    );
  }
  
  /// Get bytes that should be signed (everything except signature)
  Uint8List getSignableBytes() {
    final serialized = serialize();
    // Zero out the signature portion (bytes 88-151)
    final signable = Uint8List.fromList(serialized);
    signable.fillRange(88, 152, 0);
    return signable;
  }
  
  /// Convert UUID string to 16 bytes
  static Uint8List _uuidToBytes(String uuid) {
    final hex = uuid.replaceAll('-', '');
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
  
  /// Convert 16 bytes to UUID string
  static String _bytesToUuid(Uint8List bytes) {
    if (bytes.length != 16) throw ArgumentError('UUID must be 16 bytes');
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-'
           '${hex.substring(8, 12)}-'
           '${hex.substring(12, 16)}-'
           '${hex.substring(16, 20)}-'
           '${hex.substring(20, 32)}';
  }
  
  @override
  String toString() => 'BitchatPacket($type, ttl=$ttl, payload=${payload.length}b)';
}
