import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/secure_frame.dart';
import 'package:grassroots_networking/src/protocol/protocol_handler.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';

import 'helpers/sodium_test_bootstrap.dart';

Uint8List _key(int base) =>
    Uint8List.fromList(List.generate(32, (i) => (base + i) & 0xff));

void main() {
  late Sodium sodium;
  late ProtocolHandler handler;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sodium = await initTestSodium();
    final identity = await GrassrootsIdentity.create(
        keyPair: await Ed25519().newKeyPair(), nickname: 'Gossiper');
    handler = ProtocolHandler(identity: identity, sodium: sodium);
  });

  group('armed-time neighbour gossip codec', () {
    test('round-trips a sequence number and a neighbour list', () {
      final packet = handler.createTestbedNeighboursPacket(
        seq: 70000, // wider than a byte, so the 4-byte field is exercised
        neighbours: [_key(1), _key(100)],
        recipientPubkey: _key(200),
      );
      final frame = SecureFrame.decode(packet.payload);
      expect(frame.contentType, ContentType.testbedNeighbours);

      final (seq, peers) =
          ProtocolHandler.decodeTestbedNeighbours(frame.chunk);
      expect(seq, 70000);
      expect(peers, [_key(1), _key(100)]);
    });

    test('an empty list is valid — a phone that can see nobody', () {
      final packet = handler.createTestbedNeighboursPacket(
          seq: 1, neighbours: const [], recipientPubkey: _key(200));
      final (seq, peers) = ProtocolHandler.decodeTestbedNeighbours(
          SecureFrame.decode(packet.payload).chunk);
      expect(seq, 1);
      expect(peers, isEmpty);
    });

    test('a truncated payload throws rather than yielding a partial key', () {
      // A malformed frame must never decode into a plausible-looking pubkey:
      // that would put a phantom node in the mesh view.
      expect(
          () => ProtocolHandler.decodeTestbedNeighbours(
              Uint8List.fromList([0, 0, 0, 1, 9, 9, 9])),
          throwsFormatException);
      expect(
          () => ProtocolHandler.decodeTestbedNeighbours(
              Uint8List.fromList([0, 0])),
          throwsFormatException);
    });

    test('a wrong-length pubkey is refused at encode time', () {
      expect(
          () => handler.createTestbedNeighboursPacket(
              seq: 1,
              neighbours: [Uint8List(31)],
              recipientPubkey: _key(200)),
          throwsArgumentError);
    });
  });
}
