import 'dart:convert';
import 'dart:typed_data';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:grassroots_networking/src/models/secure_frame.dart';
import 'package:sodium_libs/sodium_libs.dart';

/// Handles Grassroots protocol logic: packet encoding/decoding,
/// ANNOUNCE parsing, MESSAGE handling, etc.
///
/// Pure functions - no state, no I/O, fully testable.
/// Extracted from transport layer to achieve separation of concerns.
class ProtocolHandler {
  final GrassrootsIdentity identity;

  final Sodium _sodium;

  /// ANNOUNCE flags-byte bit 0: the peer volunteers to introduce strangers
  /// redeeming a friend's invite (see [createAnnouncePayload]).
  static const int _flagWillingToFacilitate = 0x01;

  ProtocolHandler({
    required this.identity,
    required Sodium sodium,
  }) : _sodium = sodium;

  // ===== Encoding =====

  /// Create ANNOUNCE payload.
  ///
  /// ANNOUNCE is the one packet type whose sender is *meant* to be visible: it
  /// is a neighbor-local (non-relayed) presence broadcast, and the packet header
  /// no longer carries a sender or signature. So the announce authenticates
  /// itself — the payload ends with an Ed25519 signature over everything before
  /// it, verifiable against the embedded pubkey ([decodeAnnounce] enforces it).
  ///
  /// Format:
  /// [pubkey(32) + flags(1) + nickLen(1) + nick
  ///  + candidateCount(2) + repeated(candidateLen(2) + candidate)
  ///  + signature(64)]
  ///
  /// [willingToFacilitate] sets bit 0 of the flags byte: the peer volunteers
  /// to introduce strangers redeeming a friend's invite. It rides inside the
  /// signed body, so a peer's advertised willingness cannot be forged.
  Uint8List createAnnouncePayload({
    String? address,
    String? linkLocalAddress,
    Iterable<String> addressCandidates = const [],
    bool willingToFacilitate = false,
  }) {
    final nicknameBytes = _encodeNickname(identity.nickname);
    final candidates = <String>{
      if (address != null && address.isNotEmpty) address,
      if (linkLocalAddress != null && linkLocalAddress.isNotEmpty)
        linkLocalAddress,
      ...addressCandidates.where((candidate) => candidate.isNotEmpty),
    };
    final buffer = BytesBuilder();

    // Pubkey (32 bytes)
    buffer.add(identity.publicKey);

    // Flags (1 byte): bit 0 = willing to facilitate invites.
    buffer.addByte(willingToFacilitate ? _flagWillingToFacilitate : 0);

    // Nickname length (1 byte) + nickname
    buffer.addByte(nicknameBytes.length);
    buffer.add(nicknameBytes);

    // Candidate address set.
    final candidateCountBytes = ByteData(2);
    candidateCountBytes.setUint16(0, candidates.length, Endian.big);
    buffer.add(candidateCountBytes.buffer.asUint8List());
    for (final candidate in candidates) {
      final candidateBytes = Uint8List.fromList(candidate.codeUnits);
      final candidateLenBytes = ByteData(2);
      candidateLenBytes.setUint16(0, candidateBytes.length, Endian.big);
      buffer.add(candidateLenBytes.buffer.asUint8List());
      buffer.add(candidateBytes);
    }

    // Self-sign: append an Ed25519 signature over the announce body so the
    // pubkey↔nickname↔address binding is verifiable hop-locally.
    final body = buffer.toBytes();
    return Uint8List.fromList([...body, ..._signAnnounceBody(body)]);
  }

  /// Create MESSAGE packet.
  ///
  /// [packetId] is used as the wire-level identifier the recipient echoes
  /// back in its ACK. Pass the same id you stored in `MessageSendingAction`
  /// so `MessageDeliveredAction` (dispatched on ACK receipt) can match the
  /// outgoing message in the Redux store and flip ✓ → ✓✓.
  /// Build a single (non-fragmented) secure MESSAGE packet: the payload is
  /// wrapped in a [SecureFrame] and carried inside a [PacketType.secure]
  /// envelope. Larger payloads are fragmented by the caller (via
  /// `FragmentHandler.framesFor`) into several secure frames instead.
  ///
  /// The outer packetId is set equal to [messageId] so a single-packet message
  /// keeps one stable dedup id; the recipient recovers [messageId] from the
  /// decrypted frame and echoes it in its ACK.
  GrassrootsPacket createMessagePacket({
    required Uint8List payload,
    required String messageId,
    Uint8List? recipientPubkey,
  }) {
    final frame = SecureFrame(
      contentType: ContentType.message,
      messageId: messageId,
      chunk: payload,
    );
    return GrassrootsPacket(
      type: PacketType.secure,
      recipientPubkey: recipientPubkey,
      payload: frame.encode(),
      packetId: messageId,
    );
  }

  /// Create a READ_RECEIPT secure packet. The read messageId travels as the
  /// frame chunk (and as the frame's messageId).
  GrassrootsPacket createReadReceiptPacket({
    required String messageId,
    required Uint8List recipientPubkey,
  }) {
    final frame = SecureFrame(
      contentType: ContentType.readReceipt,
      messageId: messageId,
      chunk: utf8.encode(messageId),
    );
    return GrassrootsPacket(
      type: PacketType.secure,
      recipientPubkey: recipientPubkey,
      payload: frame.encode(),
    );
  }

  // ===== Decoding =====

  /// Decode ANNOUNCE payload
  ///
  /// Format:
  /// [pubkey(32) + flags(1) + nickLen(1) + nick
  ///  + candidateCount(2) + repeated(candidateLen(2) + candidate)]
  AnnounceData decodeAnnounce(Uint8List data) {
    if (data.length < 32 + 64) {
      throw const FormatException('ANNOUNCE payload too short');
    }

    // Split off and verify the trailing Ed25519 signature over the body. A
    // forged or tampered ANNOUNCE fails here and is dropped by the caller.
    final body = Uint8List.sublistView(data, 0, data.length - 64);
    final signature = Uint8List.sublistView(data, data.length - 64);
    final pubkey = Uint8List.fromList(body.sublist(0, 32));
    if (!_verifyAnnounceBody(body, signature, pubkey)) {
      throw const FormatException('ANNOUNCE signature invalid');
    }

    var offset = 32; // pubkey extracted above

    // Flags (1 byte).
    final flags = body[offset];
    final willingToFacilitate = (flags & _flagWillingToFacilitate) != 0;
    offset += 1;

    // Nickname length (1 byte) + nickname
    final nicknameLength = body[offset];
    offset += 1;
    final nickname = utf8.decode(
      body.sublist(offset, offset + nicknameLength),
      allowMalformed: true,
    );
    offset += nicknameLength;

    if (offset + 2 > body.length) {
      throw const FormatException('ANNOUNCE payload missing candidates');
    }

    final addressCandidates = <String>{};
    final candidateCount =
        ByteData.view(body.buffer, body.offsetInBytes + offset, 2)
            .getUint16(0, Endian.big);
    offset += 2;
    for (var i = 0; i < candidateCount; i++) {
      if (offset + 2 > body.length) {
        throw const FormatException('ANNOUNCE candidate length missing');
      }
      final candidateLength =
          ByteData.view(body.buffer, body.offsetInBytes + offset, 2)
              .getUint16(0, Endian.big);
      offset += 2;
      if (offset + candidateLength > body.length) {
        throw const FormatException('ANNOUNCE candidate truncated');
      }
      if (candidateLength > 0) {
        addressCandidates.add(
          String.fromCharCodes(
            body.sublist(offset, offset + candidateLength),
          ),
        );
      }
      offset += candidateLength;
    }

    final address = _firstNonLinkLocalCandidate(addressCandidates);
    final linkLocalAddress = _firstLinkLocalCandidate(addressCandidates);

    return AnnounceData(
      publicKey: Uint8List.fromList(pubkey),
      nickname: nickname,
      willingToFacilitate: willingToFacilitate,
      udpAddress: address,
      linkLocalAddress: linkLocalAddress,
      addressCandidates: addressCandidates,
    );
  }

  /// Decode READ_RECEIPT payload
  String decodeReadReceipt(Uint8List payload) {
    return utf8.decode(payload);
  }

  /// Create an ACK secure packet. The acked messageId travels as the frame
  /// chunk (and as the frame's messageId).
  GrassrootsPacket createAckPacket({
    required String messageId,
    Uint8List? recipientPubkey,
  }) {
    final frame = SecureFrame(
      contentType: ContentType.ack,
      messageId: messageId,
      chunk: utf8.encode(messageId),
    );
    return GrassrootsPacket(
      type: PacketType.secure,
      recipientPubkey: recipientPubkey,
      payload: frame.encode(),
    );
  }

  // ===== ANNOUNCE Signing & Verification =====
  //
  // Only ANNOUNCE is signed now. Every other packet type is either a Noise
  // handshake (authenticated by the handshake itself) or session-encrypted
  // (authenticated end-to-end by the AEAD tag). Relays never verify — they
  // forward sealed, sender-anonymous packets by recipient ID.

  /// Sign the ANNOUNCE body with the identity's Ed25519 private key.
  Uint8List _signAnnounceBody(Uint8List body) {
    // The identity's `privateKey` is the standard 64-byte Ed25519 secret key
    // (32-byte seed concatenated with the 32-byte public key).
    final secretKey = SecureKey.fromList(_sodium, identity.privateKey);
    try {
      return _sodium.crypto.sign.detached(
        message: body,
        secretKey: secretKey,
      );
    } finally {
      secretKey.dispose();
    }
  }

  /// Verify an ANNOUNCE body signature against the embedded pubkey.
  bool _verifyAnnounceBody(
    Uint8List body,
    Uint8List signature,
    Uint8List pubkey,
  ) {
    try {
      return _sodium.crypto.sign.verifyDetached(
        signature: signature,
        message: body,
        publicKey: pubkey,
      );
    } catch (_) {
      return false;
    }
  }

  /// Encode a nickname as UTF-8 for the ANNOUNCE payload, truncated to fit the
  /// 1-byte length prefix (max 255 bytes) on a code-point boundary so
  /// multi-byte characters (emoji, non-ASCII names) survive the round-trip.
  /// The matching decode is `utf8.decode(...)` in [decodeAnnounce].
  static Uint8List _encodeNickname(String nickname) {
    final encoded = utf8.encode(nickname);
    if (encoded.length <= 255) return Uint8List.fromList(encoded);
    final truncated = <int>[];
    for (final rune in nickname.runes) {
      final runeBytes = utf8.encode(String.fromCharCode(rune));
      if (truncated.length + runeBytes.length > 255) break;
      truncated.addAll(runeBytes);
    }
    return Uint8List.fromList(truncated);
  }

  String? _firstNonLinkLocalCandidate(Iterable<String> candidates) {
    for (final candidate in candidates) {
      if (!_isLinkLocalCandidate(candidate)) return candidate;
    }
    return null;
  }

  String? _firstLinkLocalCandidate(Iterable<String> candidates) {
    for (final candidate in candidates) {
      if (_isLinkLocalCandidate(candidate)) return candidate;
    }
    return null;
  }

  bool _isLinkLocalCandidate(String candidate) {
    final lower = candidate.toLowerCase();
    if (lower.startsWith('[')) {
      final end = lower.indexOf(']');
      final host = end == -1 ? lower.substring(1) : lower.substring(1, end);
      return host.startsWith('fe80:');
    }
    final colon = lower.lastIndexOf(':');
    final host = colon == -1 ? lower : lower.substring(0, colon);
    return host.startsWith('169.254.');
  }
}

/// Decoded ANNOUNCE data
class AnnounceData {
  final Uint8List publicKey;
  final String nickname;

  /// Whether the peer advertises willingness to introduce strangers redeeming
  /// a friend's invite (authenticated by the ANNOUNCE signature).
  final bool willingToFacilitate;

  final String? udpAddress;
  final String? linkLocalAddress;
  final Set<String> addressCandidates;

  const AnnounceData({
    required this.publicKey,
    required this.nickname,
    this.willingToFacilitate = false,
    this.udpAddress,
    this.linkLocalAddress,
    this.addressCandidates = const {},
  });

  @override
  String toString() => 'AnnounceData($nickname'
      '${udpAddress != null ? ", addr: $udpAddress" : ""}'
      '${linkLocalAddress != null ? ", ll: $linkLocalAddress" : ""}'
      '${addressCandidates.isNotEmpty ? ", candidates: $addressCandidates" : ""})';
}
