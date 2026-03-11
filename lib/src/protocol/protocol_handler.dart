import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:bitchat_transport/src/models/identity.dart';
import 'package:bitchat_transport/src/models/packet.dart';

/// Handles Bitchat protocol logic: packet encoding/decoding,
/// ANNOUNCE parsing, MESSAGE handling, etc.
///
/// Pure functions - no state, no I/O, fully testable.
/// Extracted from transport layer to achieve separation of concerns.
class ProtocolHandler {
  final BitchatIdentity identity;
  static const int protocolVersion = 1;

  const ProtocolHandler({required this.identity});

  // ===== Encoding =====

  /// Create ANNOUNCE payload
  ///
  /// Format: [pubkey(32) + version(2) + nickLen(1) + nick + addrCount(1) + (addrLen(2) + addr) * addrCount]
  ///
  /// Addresses are ordered by priority (IPv6, relay, STUN).
  Uint8List createAnnouncePayload({List<String> addresses = const []}) {
    final nicknameBytes = Uint8List.fromList(identity.nickname.codeUnits);
    final buffer = BytesBuilder();

    // Pubkey (32 bytes)
    buffer.add(identity.publicKey);

    // Protocol version (2 bytes)
    final versionBytes = ByteData(2);
    versionBytes.setUint16(0, protocolVersion, Endian.big);
    buffer.add(versionBytes.buffer.asUint8List());

    // Nickname length (1 byte) + nickname
    buffer.addByte(nicknameBytes.length);
    buffer.add(nicknameBytes);

    // Address count (1 byte) + repeated (addrLen(2) + addr)
    buffer.addByte(addresses.length);
    for (final addr in addresses) {
      final addrBytes = Uint8List.fromList(addr.codeUnits);
      final addrLenBytes = ByteData(2);
      addrLenBytes.setUint16(0, addrBytes.length, Endian.big);
      buffer.add(addrLenBytes.buffer.asUint8List());
      buffer.add(addrBytes);
    }

    return buffer.toBytes();
  }

  /// Create MESSAGE packet
  BitchatPacket createMessagePacket({
    required Uint8List payload,
    Uint8List? recipientPubkey,
  }) {
    return BitchatPacket(
      type: PacketType.message,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64), // Caller must sign before sending
    );
  }

  /// Create READ_RECEIPT packet
  BitchatPacket createReadReceiptPacket({
    required String messageId,
    required Uint8List recipientPubkey,
  }) {
    final payload = utf8.encode(messageId);
    return BitchatPacket(
      type: PacketType.readReceipt,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64), // Caller must sign before sending
    );
  }

  // ===== Decoding =====

  /// Decode ANNOUNCE payload
  ///
  /// Format: [pubkey(32) + version(2) + nickLen(1) + nick + addrCount(1) + (addrLen(2) + addr) * addrCount]
  AnnounceData decodeAnnounce(Uint8List data) {
    var offset = 0;

    // Pubkey (32 bytes)
    final pubkey = data.sublist(offset, offset + 32);
    offset += 32;

    // Version (2 bytes)
    final version = ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
        .getUint16(0, Endian.big);
    offset += 2;

    // Nickname length (1 byte) + nickname
    final nicknameLength = data[offset];
    offset += 1;
    final nickname = String.fromCharCodes(data.sublist(offset, offset + nicknameLength));
    offset += nicknameLength;

    // Address count (1 byte) + repeated (addrLen(2) + addr)
    final addresses = <String>[];
    if (offset < data.length) {
      final addrCount = data[offset];
      offset += 1;
      for (var i = 0; i < addrCount && offset + 2 <= data.length; i++) {
        final addrLength = ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
            .getUint16(0, Endian.big);
        offset += 2;
        if (addrLength > 0 && offset + addrLength <= data.length) {
          addresses.add(String.fromCharCodes(data.sublist(offset, offset + addrLength)));
          offset += addrLength;
        }
      }
    }

    return AnnounceData(
      publicKey: Uint8List.fromList(pubkey),
      nickname: nickname,
      protocolVersion: version,
      libp2pAddresses: addresses,
    );
  }

  /// Decode READ_RECEIPT payload
  String decodeReadReceipt(Uint8List payload) {
    return utf8.decode(payload);
  }

  /// Create ACK packet (for delivery confirmation)
  BitchatPacket createAckPacket({
    required String messageId,
    Uint8List? recipientPubkey,
  }) {
    final payload = utf8.encode(messageId);
    return BitchatPacket(
      type: PacketType.ack,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64), // Caller must sign before sending
    );
  }

  // ===== Signing & Verification =====

  /// Sign a packet with the identity's Ed25519 private key.
  ///
  /// Mutates [packet.signature] in place.
  Future<void> signPacket(BitchatPacket packet) async {
    final algorithm = Ed25519();
    final signableBytes = packet.getSignableBytes();
    final signature = await algorithm.sign(signableBytes, keyPair: identity.keyPair);
    packet.signature = Uint8List.fromList(signature.bytes);
  }

  /// Verify a packet's Ed25519 signature against the sender's public key.
  ///
  /// Returns true if the signature is valid.
  Future<bool> verifyPacket(BitchatPacket packet) async {
    try {
      final algorithm = Ed25519();
      final signableBytes = packet.getSignableBytes();
      final publicKey = SimplePublicKey(
        packet.senderPubkey,
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        packet.signature,
        publicKey: publicKey,
      );
      return await algorithm.verify(signableBytes, signature: signature);
    } catch (e) {
      return false;
    }
  }
}

/// Decoded ANNOUNCE data
class AnnounceData {
  final Uint8List publicKey;
  final String nickname;
  final int protocolVersion;
  final List<String> libp2pAddresses;

  const AnnounceData({
    required this.publicKey,
    required this.nickname,
    required this.protocolVersion,
    this.libp2pAddresses = const [],
  });

  @override
  String toString() => 'AnnounceData($nickname, v$protocolVersion${libp2pAddresses.isNotEmpty ? ", addrs: $libp2pAddresses" : ""})';
}
