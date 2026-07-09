import 'dart:typed_data';

/// The logical kind of an end-to-end payload.
///
/// This is the *inner* content type: it travels INSIDE the sealed
/// [PacketType.secure] envelope, never in the wire header, so a relay cannot
/// tell a message from an ack from a signaling packet — it only ever sees an
/// opaque, recipient-addressed blob.
enum ContentType {
  /// Application message (a GSG block; may be fragmented).
  message(0x01),

  /// Delivery acknowledgment. Chunk is the UTF-8 messageId being acked.
  ack(0x02),

  /// Read receipt. Chunk is the UTF-8 messageId that was read.
  readReceipt(0x03),

  /// Hole-punch / address signaling. Chunk is a `SignalingCodec` payload.
  signaling(0x04);

  final int value;
  const ContentType(this.value);

  static ContentType fromValue(int value) {
    return ContentType.values.firstWhere(
      (t) => t.value == value,
      orElse: () =>
          throw FormatException('Unknown content type: $value'),
    );
  }
}

/// The plaintext framing sealed inside a [PacketType.secure] packet.
///
/// Layout (big-endian):
/// ```
/// [0]      contentType (1 byte)
/// [1-2]    fragIndex   (2 bytes) — 0-based
/// [3-4]    fragCount   (2 bytes) — total fragments; 1 = not fragmented
/// [5-20]   messageId   (16 bytes) — logical message id (binary UUID)
/// [21..]   chunk       — this fragment's bytes (the whole payload if fragCount==1)
/// ```
///
/// Fragmentation is expressed here, orthogonally to [contentType], rather than
/// as distinct wire packet types: a whole message is simply `fragCount == 1`.
/// The recipient reassembles by [messageId] after decrypting each fragment.
class SecureFrame {
  static const int headerSize = 21;

  final ContentType contentType;
  final int fragIndex;
  final int fragCount;

  /// Logical message id (canonical UUID string). For [ContentType.message] this
  /// is the app-level id the sender tracks and the recipient echoes in its ACK.
  /// For ack/readReceipt/signaling it is unused framing (the meaningful id, if
  /// any, is in [chunk]).
  final String messageId;

  final Uint8List chunk;

  SecureFrame({
    required this.contentType,
    required this.messageId,
    required this.chunk,
    this.fragIndex = 0,
    this.fragCount = 1,
  }) {
    if (fragCount < 1) {
      throw ArgumentError('fragCount must be >= 1');
    }
    if (fragIndex < 0 || fragIndex >= fragCount) {
      throw ArgumentError('fragIndex $fragIndex out of range [0,$fragCount)');
    }
  }

  bool get isFragmented => fragCount > 1;

  Uint8List encode() {
    final out = Uint8List(headerSize + chunk.length);
    final view = ByteData.view(out.buffer);
    view.setUint8(0, contentType.value);
    view.setUint16(1, fragIndex, Endian.big);
    view.setUint16(3, fragCount, Endian.big);
    out.setRange(5, 21, _uuidToBytes(messageId));
    out.setRange(21, 21 + chunk.length, chunk);
    return out;
  }

  static SecureFrame decode(Uint8List data) {
    if (data.length < headerSize) {
      throw FormatException(
          'Secure frame too small: ${data.length} < $headerSize');
    }
    final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
    final contentType = ContentType.fromValue(view.getUint8(0));
    final fragIndex = view.getUint16(1, Endian.big);
    final fragCount = view.getUint16(3, Endian.big);
    final messageId = _bytesToUuid(data.sublist(5, 21));
    final chunk = Uint8List.fromList(data.sublist(21));
    return SecureFrame(
      contentType: contentType,
      fragIndex: fragIndex,
      fragCount: fragCount,
      messageId: messageId,
      chunk: chunk,
    );
  }

  static Uint8List _uuidToBytes(String uuid) {
    final hex = uuid.replaceAll('-', '');
    if (hex.length != 32) {
      throw ArgumentError('messageId must be a UUID: $uuid');
    }
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  static String _bytesToUuid(Uint8List bytes) {
    if (bytes.length != 16) throw ArgumentError('UUID must be 16 bytes');
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
