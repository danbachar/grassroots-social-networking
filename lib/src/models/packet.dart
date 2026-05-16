import 'dart:typed_data';
import 'package:uuid/uuid.dart';

/// Packet types matching Grassroots protocol
enum PacketType {
  /// Peer identity announcement (sent periodically)
  announce(0x01),

  /// Application message (GSG blocks go here)
  message(0x02),

  /// Start of fragmented message
  fragmentStart(0x03),

  /// Continuation fragment
  fragmentContinue(0x04),

  /// Final fragment
  fragmentEnd(0x05),

  /// Delivery acknowledgment (for UDP transport)
  ack(0x06),

  /// Negative acknowledgment / request for data
  nack(0x07),

  /// Read receipt (recipient has read the message)
  readReceipt(0x08),

  /// Signaling (address registration, query, hole-punch coordination)
  signaling(0x09),

  /// Noise XX handshake message.
  noiseHandshake(0x0A),

  /// Session-encrypted application message.
  secureMessage(0x0B),

  /// Session-encrypted start of fragmented message.
  secureFragmentStart(0x0C),

  /// Session-encrypted continuation fragment.
  secureFragmentContinue(0x0D),

  /// Session-encrypted final fragment.
  secureFragmentEnd(0x0E),

  /// Session-encrypted delivery acknowledgment.
  secureAck(0x0F),

  /// Session-encrypted negative acknowledgment.
  secureNack(0x10),

  /// Session-encrypted read receipt.
  secureReadReceipt(0x11),

  /// Session-encrypted signaling packet.
  secureSignaling(0x12);

  final int value;
  const PacketType(this.value);

  static PacketType fromValue(int value) {
    return PacketType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => throw ArgumentError('Unknown packet type: $value'),
    );
  }
}

extension PacketTypeSessionSecurity on PacketType {
  /// Whether this packet type should be payload-encrypted once a Noise session
  /// exists. ANNOUNCE and Noise handshake packets intentionally stay clear so
  /// peers can identify each other and bootstrap the session.
  bool get usesSessionSecurity {
    switch (this) {
      case PacketType.message:
      case PacketType.fragmentStart:
      case PacketType.fragmentContinue:
      case PacketType.fragmentEnd:
      case PacketType.ack:
      case PacketType.nack:
      case PacketType.readReceipt:
      case PacketType.signaling:
        return true;
      case PacketType.announce:
      case PacketType.noiseHandshake:
      case PacketType.secureMessage:
      case PacketType.secureFragmentStart:
      case PacketType.secureFragmentContinue:
      case PacketType.secureFragmentEnd:
      case PacketType.secureAck:
      case PacketType.secureNack:
      case PacketType.secureReadReceipt:
      case PacketType.secureSignaling:
        return false;
    }
  }

  bool get isSessionEncrypted {
    switch (this) {
      case PacketType.secureMessage:
      case PacketType.secureFragmentStart:
      case PacketType.secureFragmentContinue:
      case PacketType.secureFragmentEnd:
      case PacketType.secureAck:
      case PacketType.secureNack:
      case PacketType.secureReadReceipt:
      case PacketType.secureSignaling:
        return true;
      case PacketType.announce:
      case PacketType.message:
      case PacketType.fragmentStart:
      case PacketType.fragmentContinue:
      case PacketType.fragmentEnd:
      case PacketType.ack:
      case PacketType.nack:
      case PacketType.readReceipt:
      case PacketType.signaling:
      case PacketType.noiseHandshake:
        return false;
    }
  }

  PacketType get secureVariant {
    switch (this) {
      case PacketType.message:
        return PacketType.secureMessage;
      case PacketType.fragmentStart:
        return PacketType.secureFragmentStart;
      case PacketType.fragmentContinue:
        return PacketType.secureFragmentContinue;
      case PacketType.fragmentEnd:
        return PacketType.secureFragmentEnd;
      case PacketType.ack:
        return PacketType.secureAck;
      case PacketType.nack:
        return PacketType.secureNack;
      case PacketType.readReceipt:
        return PacketType.secureReadReceipt;
      case PacketType.signaling:
        return PacketType.secureSignaling;
      case PacketType.announce:
      case PacketType.noiseHandshake:
      case PacketType.secureMessage:
      case PacketType.secureFragmentStart:
      case PacketType.secureFragmentContinue:
      case PacketType.secureFragmentEnd:
      case PacketType.secureAck:
      case PacketType.secureNack:
      case PacketType.secureReadReceipt:
      case PacketType.secureSignaling:
        throw StateError('Packet type $this has no secure variant');
    }
  }

  PacketType get clearVariant {
    switch (this) {
      case PacketType.secureMessage:
        return PacketType.message;
      case PacketType.secureFragmentStart:
        return PacketType.fragmentStart;
      case PacketType.secureFragmentContinue:
        return PacketType.fragmentContinue;
      case PacketType.secureFragmentEnd:
        return PacketType.fragmentEnd;
      case PacketType.secureAck:
        return PacketType.ack;
      case PacketType.secureNack:
        return PacketType.nack;
      case PacketType.secureReadReceipt:
        return PacketType.readReceipt;
      case PacketType.secureSignaling:
        return PacketType.signaling;
      case PacketType.announce:
      case PacketType.message:
      case PacketType.fragmentStart:
      case PacketType.fragmentContinue:
      case PacketType.fragmentEnd:
      case PacketType.ack:
      case PacketType.nack:
      case PacketType.readReceipt:
      case PacketType.signaling:
      case PacketType.noiseHandshake:
        throw StateError('Packet type $this is not session encrypted');
    }
  }
}

/// A Grassroots packet ready for BLE transmission.
///
/// Binary format (Grassroots-compatible):
/// ```
/// [0]       : Packet type (1 byte)
/// [1]       : TTL (1 byte)
/// [2-5]     : Timestamp (4 bytes, seconds since epoch, big-endian)
/// [6-37]    : Sender public key (32 bytes)
/// [38-69]   : Recipient public key (32 bytes, zeros for broadcast)
/// [70-73]   : Payload length (4 bytes, big-endian)
/// [74-89]   : Packet ID (16 bytes, UUID)
/// [90-153]  : Signature (64 bytes, Ed25519)
/// [154-N]   : Payload (variable length)
/// ```
///
/// Total header size: 154 bytes. The 4-byte payload length is the on-wire
/// framer: stream transports (UDP/UDX) accumulate bytes until
/// `headerSize + payloadLength` are available before treating a buffer as
/// one packet.
class GrassrootsPacket {
  static const int headerSize = 154;
  static const int payloadLengthOffset = 70; // byte index of length field
  static const int signatureOffset = 90; // byte index of signature start
  static const int signatureLength = 64;

  /// Soft target for fragmented payloads — chosen to keep a single
  /// encrypted+signed packet under ~500 byte MTU on BLE.
  static const int maxPayloadSize = 346; // 500 - 154
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

  GrassrootsPacket({
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
  bool get isBroadcast =>
      recipientPubkey == null || recipientPubkey!.every((b) => b == 0);

  /// Create a copy with decremented TTL for relaying
  GrassrootsPacket decrementTtl() {
    if (ttl <= 0) {
      throw StateError('Cannot decrement TTL below 0');
    }
    return GrassrootsPacket(
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

  GrassrootsPacket copyWith({
    String? packetId,
    PacketType? type,
    int? ttl,
    int? timestamp,
    Uint8List? senderPubkey,
    Uint8List? recipientPubkey,
    Uint8List? payload,
    Uint8List? signature,
  }) {
    return GrassrootsPacket(
      packetId: packetId ?? this.packetId,
      type: type ?? this.type,
      ttl: ttl ?? this.ttl,
      timestamp: timestamp ?? this.timestamp,
      senderPubkey: senderPubkey ?? this.senderPubkey,
      recipientPubkey: recipientPubkey ?? this.recipientPubkey,
      payload: payload ?? this.payload,
      signature: signature ?? this.signature,
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

    // Payload length (4 bytes, big-endian)
    buffer.setUint32(offset, payload.length, Endian.big);
    offset += 4;

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
  static GrassrootsPacket deserialize(Uint8List data) {
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
    final payloadLength = buffer.getUint32(offset, Endian.big);
    offset += 4;

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
      throw FormatException(
          'Incomplete payload: expected $payloadLength bytes');
    }
    final payload =
        Uint8List.fromList(data.sublist(offset, offset + payloadLength));

    // debugPrint("Serialized packet of type $type with payload length $payloadLength");
    return GrassrootsPacket(
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
    // Zero out the signature portion.
    final signable = Uint8List.fromList(serialized);
    signable.fillRange(signatureOffset, signatureOffset + signatureLength, 0);
    return signable;
  }

  /// Peek the payload length from a serialized buffer without parsing the
  /// rest of the header. Used by stream-transport receive paths (UDP) to
  /// know when enough bytes have been accumulated to slice out one packet.
  /// Returns null when the buffer is shorter than the header.
  static int? peekPayloadLength(Uint8List data, [int offset = 0]) {
    if (data.length - offset < headerSize) return null;
    final view = ByteData.view(data.buffer, data.offsetInBytes + offset,
        data.length - offset);
    return view.getUint32(payloadLengthOffset, Endian.big);
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
  String toString() =>
      'GrassrootsPacket($type, ttl=$ttl, payload=${payload.length}b)';
}
