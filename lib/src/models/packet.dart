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
  /// an opaque, recipient-addressed blob — never the message class. Sync-on-
  /// connect control frames ride inside it too, so buffer contents are
  /// never on the air in the clear.
  secure(0x03);

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
/// [2-33]   : Recipient public key (32 bytes, zeros for broadcast)
/// [34-49]  : Packet ID (16 bytes, UUID — dedup / loop prevention)
/// [50-53]  : Payload length (4 bytes, big-endian)
/// [54-59]  : Creation time (6 bytes, big-endian ms since epoch —
///            originator-stamped; the GCS sync window is expressed in it)
/// [60-N]   : Payload (variable length; Noise-sealed for session types)
/// ```
///
/// Total header size: 60 bytes. The 4-byte payload length is the on-wire
/// framer: stream transports (UDP/UDX) accumulate bytes until
/// `headerSize + payloadLength` are available before treating a buffer as
/// one packet.
/// DEBUG/TESTBED ONLY outer type byte for raw-throughput blobs: not a
/// [PacketType], never deserialized. A raw blob is [rawPacketType, ...fill]
/// — the receiver counts its bytes in the wire ledger and drops it before
/// the parser. Measures the GATT pipe with zero protocol on top.
const int rawPacketType = 0x7F;

class GrassrootsPacket {
  static const int headerSize = 60;
  static const int packetIdOffset = 34; // byte index of the 16-byte packet id
  static const int payloadLengthOffset = 50; // byte index of length field

  /// Byte index of the 6-byte creation time. APPENDED after the length field
  /// rather than inserted, so every offset above keeps its value — the wire
  /// ledger reads the packetId at 34 and the UDP framer reads the length at
  /// 50 to know where a packet ends, and moving either would have broken
  /// framing for a field neither of them needs.
  static const int createdAtOffset = 54;

  /// Soft target for fragmented payloads — chosen to keep a single
  /// encrypted packet under ~500 byte MTU on BLE.
  static const int maxPayloadSize = 440; // 500 - 60
  static const int defaultTtl = 7;

  static const _uuid = Uuid();

  /// When the ORIGINATOR created this packet, in Unix MILLISECONDS.
  ///
  /// Carried on the wire because it is the only age every node can agree on.
  /// Each node's own `storedAt` is its receipt time, so a packet that keeps
  /// hopping restarts its clock at every hop and can outlive the buffer's age
  /// cap many times over; and a sync window scoped by receipt time means two
  /// nodes comparing "the same" window are comparing different numbers. This
  /// field fixes both — expiry becomes absolute, and a filter can name the
  /// window it covers.
  ///
  /// Milliseconds, in 6 bytes, not the 4-byte seconds it used to be. The sync
  /// sweep bounds a window by `[from, to]` where `to` is the creation stamp of
  /// the last packet that fit the filter, and the responder answers from that
  /// window — so every packet sharing the boundary stamp must either be inside
  /// the filter or outside the window. At second resolution and a measured
  /// 127 msg/s (scf-rearm-5) against a 106-element filter, a single second
  /// routinely holds more packets than the filter can carry: the boundary
  /// would cut mid-second, the responder would re-send what it could not know
  /// was advertised, and the cursor could never advance past that second at
  /// all. Milliseconds make ties rare and the boundary well defined. 4 bytes
  /// of ms only spans 49 days, hence 6.
  ///
  /// It was in the header until 9bff06d, which removed it as part of a
  /// slimming without giving a reason. Costs 6 bytes, taking the single-packet
  /// payload budget from 136 to 130.
  ///
  /// Privacy: this tells any relay the AGE of traffic it carries. The
  /// envelope is otherwise sender-anonymous, so it is a weak correlation aid
  /// — packets minted together look alike. Accepted deliberately: the sync
  /// window needs a shared, originator-stamped clock, and no coarser
  /// resolution gives one (see the tie/boundary reasoning above).
  final int createdAtMs;

  /// Unique packet identifier for deduplication
  final String packetId;

  /// Packet type
  final PacketType type;

  /// Time-to-live: decremented at each hop, dropped when 0
  int ttl;

  /// Recipient's public key (null/zeros for broadcast)
  final Uint8List? recipientPubkey;

  /// Payload data (type-specific). For session types this is the Noise-sealed
  /// ciphertext; the sender's identity lives inside it, not in the header.
  final Uint8List payload;

  GrassrootsPacket({
    String? packetId,
    required this.type,
    this.ttl = defaultTtl,
    this.recipientPubkey,
    required this.payload,
    int? createdAtMs,
  })  : packetId = packetId ?? _uuid.v4(),
        createdAtMs =
            createdAtMs ?? DateTime.now().millisecondsSinceEpoch {
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
      recipientPubkey: recipientPubkey,
      payload: payload,
      // The creation time is the ORIGINATOR's and never re-stamped: a hop is
      // not a new packet, and re-stamping would reset the age every relay —
      // exactly the bug this field exists to remove.
      createdAtMs: createdAtMs,
    );
  }

  GrassrootsPacket copyWith({
    String? packetId,
    PacketType? type,
    int? ttl,
    Uint8List? recipientPubkey,
    Uint8List? payload,
    int? createdAtMs,
  }) {
    return GrassrootsPacket(
      packetId: packetId ?? this.packetId,
      type: type ?? this.type,
      ttl: ttl ?? this.ttl,
      recipientPubkey: recipientPubkey ?? this.recipientPubkey,
      payload: payload ?? this.payload,
      createdAtMs: createdAtMs ?? this.createdAtMs,
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

    // Creation time (6 bytes, Unix milliseconds, big-endian). 48 bits spans
    // ~8900 years; 32 would span 49 days.
    buffer.setUint16(offset, (createdAtMs >> 32) & 0xFFFF, Endian.big);
    buffer.setUint32(offset + 2, createdAtMs & 0xFFFFFFFF, Endian.big);
    offset += 6;

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

    final createdAtMs = (buffer.getUint16(offset, Endian.big) << 32) |
        buffer.getUint32(offset + 2, Endian.big);
    offset += 6;

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
      recipientPubkey: recipientPubkey,
      payload: payload,
      createdAtMs: createdAtMs,
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
