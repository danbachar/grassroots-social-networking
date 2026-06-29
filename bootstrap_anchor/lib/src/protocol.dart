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

  // ===== ANNOUNCE signing & verification =====
  //
  // The wire envelope is sender-anonymous and unsigned. Only ANNOUNCE — a
  // presence broadcast whose sender is the point — self-authenticates: its
  // payload ends with an Ed25519 signature over the body, verified against the
  // embedded pubkey. Everything else is authenticated end-to-end by Noise.

  Future<Uint8List> _signAnnounceBody(Uint8List body) async {
    final algorithm = Ed25519();
    final signature = await algorithm.sign(body, keyPair: identity.keyPair);
    return Uint8List.fromList(signature.bytes);
  }

  Future<bool> _verifyAnnounceBody(
    Uint8List body,
    Uint8List signature,
    Uint8List pubkey,
  ) async {
    try {
      final algorithm = Ed25519();
      final publicKey = SimplePublicKey(pubkey, type: KeyPairType.ed25519);
      return await algorithm.verify(
        body,
        signature: Signature(signature, publicKey: publicKey),
      );
    } catch (e) {
      return false;
    }
  }

  // ===== ANNOUNCE =====

  /// Create ANNOUNCE payload.
  ///
  /// Format: pubkey(32) + version(2) + nickLen(1) + nick
  /// + candidateCount(2) + repeated(candidateLen(2) + candidate)
  Future<Uint8List> createAnnouncePayload({
    String? address,
    String? linkLocalAddress,
    Iterable<String> addressCandidates = const [],
  }) async {
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

    // Self-sign: append an Ed25519 signature over the body.
    final body = buffer.toBytes();
    return Uint8List.fromList([...body, ...await _signAnnounceBody(body)]);
  }

  /// Decode and verify an ANNOUNCE payload. Throws on a bad/forged signature.
  Future<AnnounceData> decodeAnnounce(Uint8List data) async {
    if (data.length < 32 + 64) {
      throw const FormatException('ANNOUNCE payload too short');
    }
    final body = Uint8List.sublistView(data, 0, data.length - 64);
    final signature = Uint8List.sublistView(data, data.length - 64);
    final pubkey = Uint8List.fromList(body.sublist(0, 32));
    if (!await _verifyAnnounceBody(body, signature, pubkey)) {
      throw const FormatException('ANNOUNCE signature invalid');
    }

    var offset = 32; // pubkey extracted above

    final version = ByteData.view(body.buffer, body.offsetInBytes + offset, 2)
        .getUint16(0, Endian.big);
    offset += 2;

    final nicknameLength = body[offset];
    offset += 1;
    final nickname =
        String.fromCharCodes(body.sublist(offset, offset + nicknameLength));
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
        addressCandidates.add(String.fromCharCodes(
          body.sublist(offset, offset + candidateLength),
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

  /// Create an ANNOUNCE packet (broadcast). The payload self-signs.
  Future<GrassrootsPacket> createAnnouncePacket({String? address}) async {
    final payload = await createAnnouncePayload(address: address);
    return GrassrootsPacket(
      type: PacketType.announce,
      ttl: 1, // neighbor-local; payload is self-signed
      recipientPubkey: null, // broadcast
      payload: payload,
    );
  }

  /// Create ACK packet.
  GrassrootsPacket createAckPacket({
    required String messageId,
    Uint8List? recipientPubkey,
  }) {
    final payload = Uint8List.fromList(messageId.codeUnits);
    return GrassrootsPacket(
      type: PacketType.ack,
      recipientPubkey: recipientPubkey,
      payload: payload,
    );
  }

  /// Create a signaling packet targeting a specific peer.
  GrassrootsPacket createSignalingPacket({
    required Uint8List recipientPubkey,
    required Uint8List signalingPayload,
  }) {
    return GrassrootsPacket(
      type: PacketType.signaling,
      recipientPubkey: recipientPubkey,
      payload: signalingPayload,
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
