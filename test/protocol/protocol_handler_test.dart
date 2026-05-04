import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:bitchat_transport/src/protocol/protocol_handler.dart';
import 'package:bitchat_transport/src/models/identity.dart';
import 'package:bitchat_transport/src/models/packet.dart';
import 'package:cryptography/cryptography.dart';

void main() {
  group('ProtocolHandler', () {
    late ProtocolHandler handler;
    late BitchatIdentity testIdentity;

    setUp(() async {
      // Create a test identity for testing
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      testIdentity = await BitchatIdentity.create(
        keyPair: keyPair,
        nickname: 'TestUser',
      );
      handler = ProtocolHandler(identity: testIdentity);
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
        final emptyNickIdentity = await BitchatIdentity.create(
          keyPair: keyPair,
          nickname: '',
        );
        final emptyHandler = ProtocolHandler(identity: emptyNickIdentity);

        final payload = emptyHandler.createAnnouncePayload();

        // Should have valid structure with 0-length nickname
        expect(
            payload.length,
            equals(32 +
                2 +
                1 +
                2)); // pubkey + version + nickLen(0) + candidateCount(0)
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

      test('throws when candidate set is missing', () {
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

      test('handles empty nickname in payload', () {
        final buffer = ByteData(32 + 2 + 1 + 2);
        var offset = 0;

        // Public key
        buffer.buffer
            .asUint8List()
            .setRange(offset, offset + 32, testIdentity.publicKey);
        offset += 32;

        // Version
        buffer.setUint16(offset, 1, Endian.big);
        offset += 2;

        // Nickname length = 0
        buffer.setUint8(offset++, 0);

        // Candidate count = 0
        buffer.setUint16(offset, 0, Endian.big);

        final payload = buffer.buffer.asUint8List();
        final decoded = handler.decodeAnnounce(payload);

        expect(decoded.nickname, equals(''));
        expect(decoded.udpAddress, isNull);
        expect(decoded.addressCandidates, isEmpty);
      });
    });

    group('createMessagePacket', () {
      test('creates packet with correct type and sender', () {
        final testPayload = utf8.encode('Hello, World!');
        final packet = handler.createMessagePacket(payload: testPayload);

        expect(packet.type, equals(PacketType.message));
        expect(packet.senderPubkey, equals(testIdentity.publicKey));
        expect(packet.payload, equals(testPayload));
        expect(packet.recipientPubkey, isNull); // Broadcast
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
        expect(packet.senderPubkey, equals(testIdentity.publicKey));
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
        expect(packet.senderPubkey, equals(testIdentity.publicKey));
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
        expect(packet.senderPubkey, equals(testIdentity.publicKey));
        expect(packet.recipientPubkey, equals(recipientPubkey));
        expect(utf8.decode(packet.payload), equals(messageId));
      });

      test('creates broadcast ACK when no recipient', () {
        final packet = handler.createAckPacket(messageId: 'ack-bcast');

        expect(packet.type, equals(PacketType.ack));
        expect(packet.isBroadcast, isTrue);
      });
    });

    group('signPacket and verifyPacket', () {
      test('signed packet verifies successfully', () async {
        final packet = handler.createMessagePacket(
          payload: utf8.encode('Hello'),
          recipientPubkey: Uint8List(32),
        );

        await handler.signPacket(packet);
        final isValid = await handler.verifyPacket(packet);

        expect(isValid, isTrue);
      });

      test('unsigned packet (all-zero signature) fails verification', () async {
        final packet = handler.createMessagePacket(
          payload: utf8.encode('Hello'),
        );
        // signature is Uint8List(64) — all zeros

        final isValid = await handler.verifyPacket(packet);

        expect(isValid, isFalse);
      });

      test('tampered payload fails verification', () async {
        final packet = handler.createMessagePacket(
          payload: utf8.encode('Original'),
          recipientPubkey: Uint8List(32),
        );

        await handler.signPacket(packet);

        // Tamper with payload after signing
        packet.payload[0] = packet.payload[0] ^ 0xFF;

        final isValid = await handler.verifyPacket(packet);
        expect(isValid, isFalse);
      });

      test('tampered signature fails verification', () async {
        final packet = handler.createMessagePacket(
          payload: utf8.encode('Data'),
          recipientPubkey: Uint8List(32),
        );

        await handler.signPacket(packet);

        // Tamper with signature
        packet.signature[0] = packet.signature[0] ^ 0xFF;

        final isValid = await handler.verifyPacket(packet);
        expect(isValid, isFalse);
      });

      test('packet signed by different identity fails verification', () async {
        // Create a different identity
        final otherKeyPair = await Ed25519().newKeyPair();
        final otherIdentity = await BitchatIdentity.create(
          keyPair: otherKeyPair,
          nickname: 'Other',
        );
        final otherHandler = ProtocolHandler(identity: otherIdentity);

        // Create packet claiming to be from testIdentity
        final packet = handler.createMessagePacket(
          payload: utf8.encode('Forged'),
        );

        // Sign with otherIdentity's key (but senderPubkey is testIdentity's)
        await otherHandler.signPacket(packet);

        // Verification should fail: signature doesn't match senderPubkey
        final isValid = await handler.verifyPacket(packet);
        expect(isValid, isFalse);
      });

      test('sign and verify works for all packet types', () async {
        final packets = [
          handler.createMessagePacket(payload: utf8.encode('msg')),
          handler.createReadReceiptPacket(
            messageId: 'rcpt-1',
            recipientPubkey: Uint8List(32),
          ),
          handler.createAckPacket(messageId: 'ack-1'),
          BitchatPacket(
            type: PacketType.announce,
            senderPubkey: testIdentity.publicKey,
            payload: handler.createAnnouncePayload(),
            signature: Uint8List(64),
          ),
        ];

        for (final packet in packets) {
          await handler.signPacket(packet);
          final isValid = await handler.verifyPacket(packet);
          expect(isValid, isTrue, reason: 'Failed for ${packet.type}');
        }
      });

      test('sign and verify survives serialization round-trip', () async {
        final packet = handler.createMessagePacket(
          payload: utf8.encode('Round trip test'),
          recipientPubkey: Uint8List.fromList(List.generate(32, (i) => i)),
        );

        await handler.signPacket(packet);

        // Serialize and deserialize
        final bytes = packet.serialize();
        final restored = BitchatPacket.deserialize(bytes);

        final isValid = await handler.verifyPacket(restored);
        expect(isValid, isTrue);
      });
    });

    group('round-trip encoding/decoding', () {
      test('announce payload round-trip', () {
        final originalPayload = handler.createAnnouncePayload(
          address: '[2001:db8::a]:8000',
        );
        final decoded = handler.decodeAnnounce(originalPayload);

        // Re-encode with decoded data
        final reEncodedIdentity = BitchatIdentity.fromMap({
          'publicKey': decoded.publicKey,
          'privateKey': testIdentity.privateKey,
          'nickname': decoded.nickname,
        });
        final reEncodedHandler = ProtocolHandler(identity: reEncodedIdentity);
        final reEncodedPayload = reEncodedHandler.createAnnouncePayload(
          address: decoded.udpAddress,
        );

        expect(reEncodedPayload, equals(originalPayload));
      });
    });
  });
}
