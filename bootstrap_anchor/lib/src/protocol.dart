import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

import 'identity.dart';
import 'packet.dart';

/// Protocol handler for the bootstrap anchor.
///
/// Handles packet signing, verification, and ANNOUNCE encoding/decoding.
/// Wire-compatible with the Flutter client's ProtocolHandler.
class Protocol {
  final AnchorIdentity identity;
  static const int protocolVersion = 1;

  const Protocol({required this.identity});

  // ===== Signing & Verification =====

  /// Sign a packet with our Ed25519 private key.
  Future<void> signPacket(BitchatPacket packet) async {
    final algorithm = Ed25519();
    final signableBytes = packet.getSignableBytes();
    final signature =
        await algorithm.sign(signableBytes, keyPair: identity.keyPair);
    packet.signature = Uint8List.fromList(signature.bytes);
  }

  /// Verify a packet's Ed25519 signature against the sender's public key.
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

  // ===== ANNOUNCE =====

  /// Create ANNOUNCE payload.
  ///
  /// Format: pubkey(32) + version(2) + nickLen(1) + nick
  /// + candidateCount(2) + repeated(candidateLen(2) + candidate)
  Uint8List createAnnouncePayload({
    String? address,
    String? linkLocalAddress,
    Iterable<String> addressCandidates = const [],
  }) {
    final nicknameBytes = Uint8List.fromList(identity.nickname.codeUnits);
    final candidates = <String>{
      if (address != null && address.isNotEmpty) address,
      if (linkLocalAddress != null && linkLocalAddress.isNotEmpty)
        linkLocalAddress,
      ...addressCandidates.where((candidate) => candidate.isNotEmpty),
    };
    final buffer = BytesBuilder();

    // Pubkey (32 bytes)
    buffer.add(identity.publicKey);

    // Protocol version (2 bytes, big-endian)
    final versionBytes = ByteData(2);
    versionBytes.setUint16(0, protocolVersion, Endian.big);
    buffer.add(versionBytes.buffer.asUint8List());

    // Nickname length (1 byte) + nickname
    buffer.addByte(nicknameBytes.length);
    buffer.add(nicknameBytes);

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

    return buffer.toBytes();
  }

  /// Decode ANNOUNCE payload.
  AnnounceData decodeAnnounce(Uint8List data) {
    var offset = 0;

    final pubkey = data.sublist(offset, offset + 32);
    offset += 32;

    final version = ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
        .getUint16(0, Endian.big);
    offset += 2;

    final nicknameLength = data[offset];
    offset += 1;
    final nickname =
        String.fromCharCodes(data.sublist(offset, offset + nicknameLength));
    offset += nicknameLength;

    if (offset + 2 > data.length) {
      throw const FormatException('ANNOUNCE payload missing candidates');
    }

    final addressCandidates = <String>{};
    final candidateCount =
        ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
            .getUint16(0, Endian.big);
    offset += 2;
    for (var i = 0; i < candidateCount; i++) {
      if (offset + 2 > data.length) {
        throw const FormatException('ANNOUNCE candidate length missing');
      }
      final candidateLength =
          ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
              .getUint16(0, Endian.big);
      offset += 2;
      if (offset + candidateLength > data.length) {
        throw const FormatException('ANNOUNCE candidate truncated');
      }
      if (candidateLength > 0) {
        addressCandidates.add(String.fromCharCodes(
          data.sublist(offset, offset + candidateLength),
        ));
      }
      offset += candidateLength;
    }

    final address = _firstNonLinkLocalCandidate(addressCandidates);
    final linkLocalAddress = _firstLinkLocalCandidate(addressCandidates);

    return AnnounceData(
      publicKey: Uint8List.fromList(pubkey),
      nickname: nickname,
      protocolVersion: version,
      udpAddress: address,
      linkLocalAddress: linkLocalAddress,
      addressCandidates: addressCandidates,
    );
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

  /// Create an ANNOUNCE packet (broadcast).
  BitchatPacket createAnnouncePacket({String? address}) {
    final payload = createAnnouncePayload(address: address);
    return BitchatPacket(
      type: PacketType.announce,
      senderPubkey: identity.publicKey,
      recipientPubkey: null, // broadcast
      payload: payload,
      signature: Uint8List(64), // must sign before sending
    );
  }

  /// Create ACK packet.
  BitchatPacket createAckPacket({
    required String messageId,
    Uint8List? recipientPubkey,
  }) {
    final payload = Uint8List.fromList(messageId.codeUnits);
    return BitchatPacket(
      type: PacketType.ack,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64),
    );
  }

  /// Create a signaling packet targeting a specific peer.
  BitchatPacket createSignalingPacket({
    required Uint8List recipientPubkey,
    required Uint8List signalingPayload,
  }) {
    return BitchatPacket(
      type: PacketType.signaling,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: signalingPayload,
      signature: Uint8List(64),
    );
  }
}

/// Decoded ANNOUNCE data.
class AnnounceData {
  final Uint8List publicKey;
  final String nickname;
  final int protocolVersion;
  final String? udpAddress;
  final String? linkLocalAddress;
  final Set<String> addressCandidates;

  const AnnounceData({
    required this.publicKey,
    required this.nickname,
    required this.protocolVersion,
    this.udpAddress,
    this.linkLocalAddress,
    this.addressCandidates = const {},
  });

  String get pubkeyHex =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() => 'AnnounceData($nickname, v$protocolVersion'
      '${udpAddress != null ? ", addr: $udpAddress" : ""}'
      '${linkLocalAddress != null ? ", ll: $linkLocalAddress" : ""}'
      '${addressCandidates.isNotEmpty ? ", candidates: $addressCandidates" : ""})';
}
