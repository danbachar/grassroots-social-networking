import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/protocol/protocol_handler.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../helpers/sodium_test_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Sodium sodium;
  setUpAll(() async {
    sodium = await initTestSodium();
  });

  group('ProtocolHandler', () {
    late ProtocolHandler handler;
    late GrassrootsIdentity testIdentity;

    setUp(() async {
      // Create a test identity for testing
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      testIdentity = await GrassrootsIdentity.create(
        keyPair: keyPair,
        nickname: 'TestUser',
      );
      handler = ProtocolHandler(identity: testIdentity, sodium: sodium);
    });

    group('createAnnouncePayload', () {
      test('encodes public key, version, and nickname correctly', () {
        final payload = handler.createAnnouncePayload();

        // Verify payload structure
        expect(payload.length,
            greaterThanOrEqualTo(32 + 2 + 1 + 'TestUser'.length + 2));

        // Public key (first 32 bytes)
        final pubkeyFromPayload = payload.sublist(0, 32);
        expect(pubkeyFromPayload, equals(testIdentity.publicKey));

        // Protocol version (next 2 bytes)
        final versionData =
            ByteData.view(payload.buffer, payload.offsetInBytes + 32, 2);
        final version = versionData.getUint16(0, Endian.big);
        expect(version, equals(1)); // Protocol version 1

        // Nickname length and nickname
        final nickLen = payload[34];
        expect(nickLen, equals('TestUser'.length));
        final nickname =
            String.fromCharCodes(payload.sublist(35, 35 + nickLen));
        expect(nickname, equals('TestUser'));
      });

      test('creates payload without candidates when not provided', () {
        final payload = handler.createAnnouncePayload();

        // Candidate count should be 0 after the nickname.
        const offset = 32 + 2 + 1 + 'TestUser'.length;
        final candidateCountData =
            ByteData.view(payload.buffer, payload.offsetInBytes + offset, 2);
        final candidateCount = candidateCountData.getUint16(0, Endian.big);
        expect(candidateCount, equals(0));
      });

      test('includes UDP address as a candidate when provided', () {
        const testAddress = '[::1]:4001';
        final payload = handler.createAnnouncePayload(address: testAddress);
        final decoded = handler.decodeAnnounce(payload);

        expect(decoded.udpAddress, equals(testAddress));
        expect(decoded.addressCandidates, equals({testAddress}));
      });

      test('handles empty nickname', () async {
        final algorithm = Ed25519();
        final keyPair = await algorithm.newKeyPair();
        final emptyNickIdentity = await GrassrootsIdentity.create(
          keyPair: keyPair,
          nickname: '',
        );
        final emptyHandler =
            ProtocolHandler(identity: emptyNickIdentity, sodium: sodium);

        final payload = emptyHandler.createAnnouncePayload();

        // Should have valid structure with 0-length nickname.
        // pubkey + version + nickLen(0) + candidateCount(0) + signature(64)
        expect(payload.length, equals(32 + 2 + 1 + 2 + 64));
        expect(payload[34], equals(0)); // nickname length = 0
      });

      test('includes UDP address candidates when provided', () {
        final payload = handler.createAnnouncePayload(
          address: '[2606:4700::1]:5000',
          addressCandidates: const {
            '[2606:4700::1]:5000',
            '198.51.100.7:5001',
          },
        );
        final decoded = handler.decodeAnnounce(payload);

        expect(
          decoded.addressCandidates,
          containsAll(const {
            '[2606:4700::1]:5000',
            '198.51.100.7:5001',
          }),
        );
      });

      test('round-trips a non-ASCII / emoji nickname as UTF-8', () async {
        final keyPair = await Ed25519().newKeyPair();
        const fancyNick = 'Zoë 🌱🚀 名字';
        final fancyIdentity = await GrassrootsIdentity.create(
          keyPair: keyPair,
          nickname: fancyNick,
        );
        final fancyHandler =
            ProtocolHandler(identity: fancyIdentity, sodium: sodium);

        final payload = fancyHandler.createAnnouncePayload();
        final decoded = fancyHandler.decodeAnnounce(payload);

        expect(decoded.nickname, equals(fancyNick));
        // The 1-byte length prefix counts UTF-8 bytes, not characters.
        expect(payload[34], equals(utf8.encode(fancyNick).length));
      });
    });

    group('decodeAnnounce', () {
      test('decodes announce payload created by createAnnouncePayload', () {
        final payload = handler.createAnnouncePayload();
        final decoded = handler.decodeAnnounce(payload);

        expect(decoded.publicKey, equals(testIdentity.publicKey));
        expect(decoded.nickname, equals('TestUser'));
        expect(decoded.protocolVersion, equals(1));
        expect(decoded.udpAddress, isNull);
        expect(decoded.addressCandidates, isEmpty);
      });

      test('decodes announce with UDP address', () {
        const testAddress = '[2001:db8::64]:5000';
        final payload = handler.createAnnouncePayload(address: testAddress);
        final decoded = handler.decodeAnnounce(payload);

        expect(decoded.publicKey, equals(testIdentity.publicKey));
        expect(decoded.nickname, equals('TestUser'));
        expect(decoded.protocolVersion, equals(1));
        expect(decoded.udpAddress, equals(testAddress));
        expect(decoded.addressCandidates, contains(testAddress));
      });

      test('throws on an unsigned / hand-built payload', () {
        // A hand-assembled announce body with no trailing Ed25519 signature is
        // not self-authenticating and must be rejected.
        final nicknameBytes = utf8.encode('MalformedPeer');
        final buffer = ByteData(32 + 2 + 1 + nicknameBytes.length);
        var offset = 0;

        buffer.buffer
            .asUint8List()
            .setRange(offset, offset + 32, testIdentity.publicKey);
        offset += 32;

        buffer.setUint16(offset, 1, Endian.big);
        offset += 2;

        buffer.setUint8(offset++, nicknameBytes.length);
        buffer.buffer
            .asUint8List()
            .setRange(offset, offset + nicknameBytes.length, nicknameBytes);

        final payload = buffer.buffer.asUint8List();
        expect(
          () => handler.decodeAnnounce(payload),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws on a too-short payload', () {
        expect(
          () => handler.decodeAnnounce(Uint8List(10)),
          throwsA(isA<FormatException>()),
        );
      });

      test('handles empty nickname in payload', () async {
        // A validly self-signed ANNOUNCE with a 0-length nickname must decode.
        final keyPair = await Ed25519().newKeyPair();
        final emptyNickIdentity = await GrassrootsIdentity.create(
          keyPair: keyPair,
          nickname: '',
        );
        final emptyHandler =
            ProtocolHandler(identity: emptyNickIdentity, sodium: sodium);

        final payload = emptyHandler.createAnnouncePayload();
        final decoded = emptyHandler.decodeAnnounce(payload);

        expect(decoded.nickname, equals(''));
        expect(decoded.udpAddress, isNull);
        expect(decoded.addressCandidates, isEmpty);
      });
    });

    group('createMessagePacket', () {
      test('creates packet with correct type (no cleartext sender)', () {
        final testPayload = utf8.encode('Hello, World!');
        final packet = handler.createMessagePacket(payload: testPayload);

        expect(packet.type, equals(PacketType.message));
        expect(packet.payload, equals(testPayload));
        expect(packet.recipientPubkey, isNull); // Broadcast
      });

      test('carries a packetId for ACK matching', () {
        final packet = handler.createMessagePacket(
          payload: utf8.encode('Hello'),
          packetId: 'fixed-id-123',
        );
        expect(packet.packetId, equals('fixed-id-123'));
      });

      test('creates packet with specific recipient', () {
        final testPayload = utf8.encode('Private message');
        final recipientPubkey =
            Uint8List.fromList(List.generate(32, (i) => 100 + i));
        final packet = handler.createMessagePacket(
          payload: testPayload,
          recipientPubkey: recipientPubkey,
        );

        expect(packet.type, equals(PacketType.message));
        expect(packet.payload, equals(testPayload));
        expect(packet.recipientPubkey, equals(recipientPubkey));
        expect(packet.isBroadcast, isFalse);
      });

      test('creates packet with empty payload', () {
        final packet = handler.createMessagePacket(payload: Uint8List(0));

        expect(packet.payload.length, equals(0));
        expect(packet.type, equals(PacketType.message));
      });

      test('creates packet with large payload', () {
        final largePayload = Uint8List(1000);
        for (var i = 0; i < 1000; i++) {
          largePayload[i] = i % 256;
        }

        final packet = handler.createMessagePacket(payload: largePayload);

        expect(packet.payload.length, equals(1000));
        expect(packet.payload, equals(largePayload));
      });
    });

    group('createReadReceiptPacket', () {
      test('creates read receipt with message ID', () {
        const messageId = 'test-message-id-12345';
        final recipientPubkey =
            Uint8List.fromList(List.generate(32, (i) => 50 + i));
        final packet = handler.createReadReceiptPacket(
          messageId: messageId,
          recipientPubkey: recipientPubkey,
        );

        expect(packet.type, equals(PacketType.readReceipt));
        expect(packet.recipientPubkey, equals(recipientPubkey));
        expect(utf8.decode(packet.payload), equals(messageId));
      });

      test('handles UUID message IDs', () {
        const messageId = '550e8400-e29b-41d4-a716-446655440000';
        final recipientPubkey = Uint8List.fromList(List.generate(32, (i) => i));
        final packet = handler.createReadReceiptPacket(
          messageId: messageId,
          recipientPubkey: recipientPubkey,
        );

        final decodedId = utf8.decode(packet.payload);
        expect(decodedId, equals(messageId));
      });
    });

    group('decodeReadReceipt', () {
      test('decodes read receipt payload', () {
        const messageId = 'msg-abc-123';
        final payload = utf8.encode(messageId);
        final decoded = handler.decodeReadReceipt(payload);

        expect(decoded, equals(messageId));
      });

      test('handles empty message ID', () {
        final payload = utf8.encode('');
        final decoded = handler.decodeReadReceipt(payload);

        expect(decoded, equals(''));
      });
    });

    group('createAckPacket', () {
      test('creates ACK with message ID', () {
        const messageId = 'ack-msg-1';
        final recipientPubkey =
            Uint8List.fromList(List.generate(32, (i) => 50 + i));
        final packet = handler.createAckPacket(
          messageId: messageId,
          recipientPubkey: recipientPubkey,
        );

        expect(packet.type, equals(PacketType.ack));
        expect(packet.recipientPubkey, equals(recipientPubkey));
        expect(utf8.decode(packet.payload), equals(messageId));
      });

      test('creates broadcast ACK when no recipient', () {
        final packet = handler.createAckPacket(messageId: 'ack-bcast');

        expect(packet.type, equals(PacketType.ack));
        expect(packet.isBroadcast, isTrue);
      });
    });

    // The wire envelope is now sender-anonymous: there is no per-packet
    // sender field and no whole-packet Ed25519 signature (signPacket /
    // verifyPacket are gone). The only self-authenticating packet is ANNOUNCE,
    // whose payload ends with an Ed25519 signature over its body. These tests
    // cover that self-sign round-trip — the new analog of the old whole-packet
    // sign/verify suite.
    group('ANNOUNCE self-sign round-trip', () {
      test('self-signed announce verifies and decodes', () {
        final payload = handler.createAnnouncePayload();
        final decoded = handler.decodeAnnounce(payload);

        expect(decoded.publicKey, equals(testIdentity.publicKey));
        expect(decoded.nickname, equals('TestUser'));
      });

      test('tampered body byte fails verification (FormatException)', () {
        final payload = handler.createAnnouncePayload();

        // Flip a byte inside the signed body (the nickname-length byte).
        payload[34] = payload[34] ^ 0xFF;

        expect(
          () => handler.decodeAnnounce(payload),
          throwsA(isA<FormatException>()),
        );
      });

      test('tampered signature byte fails verification (FormatException)', () {
        final payload = handler.createAnnouncePayload();

        // Flip a byte inside the trailing 64-byte signature.
        final last = payload.length - 1;
        payload[last] = payload[last] ^ 0xFF;

        expect(
          () => handler.decodeAnnounce(payload),
          throwsA(isA<FormatException>()),
        );
      });

      test('announce signed by a different identity fails verification',
          () async {
        // Build an announce whose embedded pubkey is testIdentity's, but whose
        // signature is produced by a different key — the binding must break.
        final otherKeyPair = await Ed25519().newKeyPair();
        final otherIdentity = await GrassrootsIdentity.create(
          keyPair: otherKeyPair,
          nickname: 'Other',
        );
        final otherHandler =
            ProtocolHandler(identity: otherIdentity, sodium: sodium);

        final genuine = handler.createAnnouncePayload();
        final forged = otherHandler.createAnnouncePayload();

        // Splice testIdentity's body (pubkey + nick) onto otherIdentity's
        // signature. The body claims testIdentity; the sig is over a different
        // body, so verification fails.
        final genuineBody = genuine.sublist(0, genuine.length - 64);
        final forgedSig = forged.sublist(forged.length - 64);
        final spliced =
            Uint8List.fromList([...genuineBody, ...forgedSig]);

        expect(
          () => handler.decodeAnnounce(spliced),
          throwsA(isA<FormatException>()),
        );
      });

      test('self-sign survives serialization round-trip', () {
        final payload = handler.createAnnouncePayload(
          address: '[2001:db8::1]:7000',
        );
        final packet = GrassrootsPacket(
          type: PacketType.announce,
          payload: payload,
        );

        final restored = GrassrootsPacket.deserialize(packet.serialize());
        final decoded = handler.decodeAnnounce(restored.payload);

        expect(decoded.publicKey, equals(testIdentity.publicKey));
        expect(decoded.nickname, equals('TestUser'));
        expect(decoded.udpAddress, equals('[2001:db8::1]:7000'));
      });
    });

    group('round-trip encoding/decoding', () {
      test('announce payload round-trip', () {
        final originalPayload = handler.createAnnouncePayload(
          address: '[2001:db8::a]:8000',
        );
        final decoded = handler.decodeAnnounce(originalPayload);

        // Re-encode with decoded data
        final reEncodedIdentity = GrassrootsIdentity.fromMap({
          'publicKey': decoded.publicKey,
          'privateKey': testIdentity.privateKey,
          'nickname': decoded.nickname,
        });
        final reEncodedHandler =
            ProtocolHandler(identity: reEncodedIdentity, sodium: sodium);
        final reEncodedPayload = reEncodedHandler.createAnnouncePayload(
          address: decoded.udpAddress,
        );

        expect(reEncodedPayload, equals(originalPayload));
      });
    });
  });
}
