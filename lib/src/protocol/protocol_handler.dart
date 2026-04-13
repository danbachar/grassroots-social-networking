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
  /// Format: [pubkey(32) + version(2) + nickLen(1) + nick + addrLen(2) + addr? + llAddrLen(2) + llAddr?]
  ///
  /// The address field is included when the sender has a UDP address.
  /// Omitted (addrLen 0) only for BLE announcements to non-friends (privacy).
  /// The link-local address is optional and only included for BLE friends on
  /// the same LAN — used as a faster alternative to global IPv6.
  Uint8List createAnnouncePayload({String? address, String? linkLocalAddress}) {
    final nicknameBytes = Uint8List.fromList(identity.nickname.codeUnits);
    final addressBytes = address != null ? Uint8List.fromList(address.codeUnits) : Uint8List(0);
    final llAddrBytes = linkLocalAddress != null ? Uint8List.fromList(linkLocalAddress.codeUnits) : Uint8List(0);
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

    // Address length (2 bytes) + address
    final addrLenBytes = ByteData(2);
    addrLenBytes.setUint16(0, addressBytes.length, Endian.big);
    buffer.add(addrLenBytes.buffer.asUint8List());
    if (addressBytes.isNotEmpty) {
      buffer.add(addressBytes);
    }

    // Link-local address length (2 bytes) + link-local address
    final llAddrLenBytes = ByteData(2);
    llAddrLenBytes.setUint16(0, llAddrBytes.length, Endian.big);
    buffer.add(llAddrLenBytes.buffer.asUint8List());
    if (llAddrBytes.isNotEmpty) {
      buffer.add(llAddrBytes);
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
  /// Format: [pubkey(32) + version(2) + nickLen(1) + nick + addrLen(2) + addr? + llAddrLen(2) + llAddr?]
  /// Returns: AnnounceData with public key, nickname, version, optional address, and optional link-local
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

    // Address length (2 bytes) + address (optional - may not exist in old payloads)
    String? address;
    if (offset + 2 <= data.length) {
      final addrLength = ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
          .getUint16(0, Endian.big);
      offset += 2;
      if (addrLength > 0 && offset + addrLength <= data.length) {
        address = String.fromCharCodes(data.sublist(offset, offset + addrLength));
        offset += addrLength;
      }
    }

    // Link-local address length (2 bytes) + link-local address (optional)
    String? linkLocalAddress;
    if (offset + 2 <= data.length) {
      final llAddrLength = ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
          .getUint16(0, Endian.big);
      offset += 2;
      if (llAddrLength > 0 && offset + llAddrLength <= data.length) {
        linkLocalAddress = String.fromCharCodes(data.sublist(offset, offset + llAddrLength));
        offset += llAddrLength;
      }
    }

    return AnnounceData(
      publicKey: Uint8List.fromList(pubkey),
      nickname: nickname,
      protocolVersion: version,
      udpAddress: address,
      linkLocalAddress: linkLocalAddress,
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
  final String? udpAddress;
  final String? linkLocalAddress;

  const AnnounceData({
    required this.publicKey,
    required this.nickname,
    required this.protocolVersion,
    this.udpAddress,
    this.linkLocalAddress,
  });

  @override
  String toString() => 'AnnounceData($nickname, v$protocolVersion${udpAddress != null ? ", addr: $udpAddress" : ""}${linkLocalAddress != null ? ", ll: $linkLocalAddress" : ""})';
}
