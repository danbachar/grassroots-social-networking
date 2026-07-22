import 'dart:typed_data';
import 'package:uuid/uuid.dart';

/// Packet types matching Grassroots protocol
enum PacketType {
  /// Neighbor-local, self-signed presence broadcast — the one clear packet whose
  /// sender is *meant* to be visible. Never relayed.
  announce(0x01),

  /// Noise XX handshake message (neighbor-local, not relayed).
  noiseHandshake(0x02),

  /// Session-sealed envelope. Everything that is not an ANNOUNCE or a handshake
  /// is one opaque `secure` packet: the content type and any fragmentation live
  /// INSIDE the encrypted payload (see [SecureFrame]), so a relay only ever sees
  /// an opaque, recipient-addressed blob — never the message class.
  secure(0x03),

  /// Sync-on-connect custody summary (neighbor-local, never relayed).
  /// Cleartext list of packetIds this node's DTN store is carrying; the
  /// receiving neighbor tests them against its seen-set and requests the ones
  /// it lacks. Reveals only packetIds — which the envelope already exposes to
  /// every flood recipient.
  syncOffer(0x04),

  /// Reply to [syncOffer] (neighbor-local, never relayed): the subset of
  /// offered packetIds the sender wants conveyed. The offerer answers by
  /// sending each stored sealed packet over the same link.
  syncRequest(0x05);

  final int value;
  const PacketType(this.value);

  static PacketType fromValue(int value) {
    return PacketType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => throw ArgumentError('Unknown packet type: $value'),
    );
  }
}

/// A Grassroots packet ready for mesh transmission.
///
/// **Sender-anonymous envelope.** The outer header carries only the *recipient*
/// ID — never the sender — so a relay can route by recipient without learning
/// who originated the packet, and there is no whole-packet Ed25519 signature on
/// the wire (relays cannot authenticate an anonymous sender; authentication is
/// end-to-end inside the Noise session). See CLAUDE.md → Mesh Envelope & Trust.
///
/// Binary format:
/// ```
/// [0]      : Packet type (1 byte)
/// [1]      : TTL (1 byte, decremented at each relay hop, dropped at 0)
/// [2-5]    : Timestamp (4 bytes, seconds since epoch, big-endian)
/// [6-37]   : Recipient public key (32 bytes, zeros for broadcast)
/// [38-53]  : Packet ID (16 bytes, UUID — dedup / loop prevention)
/// [54-57]  : Payload length (4 bytes, big-endian)
/// [58-N]   : Payload (variable length; Noise-sealed for session types)
/// ```
///
/// Total header size: 58 bytes. The 4-byte payload length is the on-wire
/// framer: stream transports (UDP/UDX) accumulate bytes until
/// `headerSize + payloadLength` are available before treating a buffer as
/// one packet.
class GrassrootsPacket {
  static const int headerSize = 58;
  static const int payloadLengthOffset = 54; // byte index of length field

  /// Soft target for fragmented payloads — chosen to keep a single
  /// encrypted packet under ~500 byte MTU on BLE.
  static const int maxPayloadSize = 442; // 500 - 58
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

  /// Recipient's public key (null/zeros for broadcast)
  final Uint8List? recipientPubkey;

  /// Payload data (type-specific). For session types this is the Noise-sealed
  /// ciphertext; the sender's identity lives inside it, not in the header.
  final Uint8List payload;

  GrassrootsPacket({
    String? packetId,
    required this.type,
    this.ttl = defaultTtl,
    int? timestamp,
    this.recipientPubkey,
    required this.payload,
  })  : packetId = packetId ?? _uuid.v4(),
        timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000 {
    if (recipientPubkey != null && recipientPubkey!.length != 32) {
      throw ArgumentError('Recipient public key must be 32 bytes');
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
      recipientPubkey: recipientPubkey,
      payload: payload,
    );
  }

  GrassrootsPacket copyWith({
    String? packetId,
    PacketType? type,
    int? ttl,
    int? timestamp,
    Uint8List? recipientPubkey,
    Uint8List? payload,
  }) {
    return GrassrootsPacket(
      packetId: packetId ?? this.packetId,
      type: type ?? this.type,
      ttl: ttl ?? this.ttl,
      timestamp: timestamp ?? this.timestamp,
      recipientPubkey: recipientPubkey ?? this.recipientPubkey,
      payload: payload ?? this.payload,
    );
  }

  /// Serialize to binary format for transmission
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

    final bytes = buffer.buffer.asUint8List();

    // Recipient pubkey (32 bytes, zeros if broadcast)
    if (recipientPubkey != null) {
      bytes.setRange(offset, offset + 32, recipientPubkey!);
    } else {
      bytes.fillRange(offset, offset + 32, 0);
    }
    offset += 32;

    // Packet ID (16 bytes - UUID as bytes)
    final idBytes = uuidToBytes(packetId);
    bytes.setRange(offset, offset + 16, idBytes);
    offset += 16;

    // Payload length (4 bytes, big-endian)
    buffer.setUint32(offset, payload.length, Endian.big);
    offset += 4;

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

    // Recipient pubkey
    final recipientBytes = data.sublist(offset, offset + 32);
    final recipientPubkey = recipientBytes.every((b) => b == 0)
        ? null
        : Uint8List.fromList(recipientBytes);
    offset += 32;

    // Packet ID
    final idBytes = data.sublist(offset, offset + 16);
    final packetId = bytesToUuid(idBytes);
    offset += 16;

    // Payload length
    final payloadLength = buffer.getUint32(offset, Endian.big);
    offset += 4;

    // Payload
    if (data.length < offset + payloadLength) {
      throw FormatException(
          'Incomplete payload: expected $payloadLength bytes');
    }
    final payload =
        Uint8List.fromList(data.sublist(offset, offset + payloadLength));

    return GrassrootsPacket(
      packetId: packetId,
      type: type,
      ttl: ttl,
      timestamp: timestamp,
      recipientPubkey: recipientPubkey,
      payload: payload,
    );
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
  static Uint8List uuidToBytes(String uuid) {
    final hex = uuid.replaceAll('-', '');
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  /// Convert 16 bytes to UUID string
  static String bytesToUuid(Uint8List bytes) {
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
