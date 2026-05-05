import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:grassroots_networking/src/models/identity.dart';

void main() {
  group('GrassrootsIdentity', () {
    late GrassrootsIdentity identity;

    setUp(() async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      identity = await GrassrootsIdentity.create(
        keyPair: keyPair,
        nickname: 'Alice',
      );
    });

    group('create()', () {
      test('sets publicKey to 32 bytes', () {
        expect(identity.publicKey.length, equals(32));
      });

      test('sets privateKey to 64 bytes (seed + pubkey)', () {
        expect(identity.privateKey.length, equals(64));
      });

      test('privateKey contains seed followed by publicKey', () {
        // Last 32 bytes of privateKey should equal publicKey
        final pubkeyFromPrivate = identity.privateKey.sublist(32, 64);
        expect(pubkeyFromPrivate, equals(identity.publicKey));
      });

      test('stores nickname', () {
        expect(identity.nickname, equals('Alice'));
      });

      test('stores keyPair', () {
        expect(identity.keyPair, isNotNull);
      });

      test('works with different nicknames', () async {
        final algorithm = Ed25519();
        final keyPair = await algorithm.newKeyPair();
        final id = await GrassrootsIdentity.create(
          keyPair: keyPair,
          nickname: 'Bob',
        );
        expect(id.nickname, equals('Bob'));
      });
    });

    group('bleServiceUuid', () {
      test('returns correctly formatted UUID string (8-4-4-4-12)', () {
        final uuid = identity.bleServiceUuid;
        final parts = uuid.split('-');
        expect(parts.length, equals(5));
        expect(parts[0].length, equals(8));
        expect(parts[1].length, equals(4));
        expect(parts[2].length, equals(4));
        expect(parts[3].length, equals(4));
        expect(parts[4].length, equals(12));
      });

      test('UUID is lowercase hex', () {
        final uuid = identity.bleServiceUuid;
        final hexOnly = uuid.replaceAll('-', '');
        expect(hexOnly, matches(RegExp(r'^[0-9a-f]{32}$')));
      });

      test('UUID starts with Grassroots prefix and ends with last 8 bytes of pubkey', () {
        final uuid = identity.bleServiceUuid;
        final hexOnly = uuid.replaceAll('-', '');

        // First 16 hex chars = Grassroots prefix
        expect(hexOnly.substring(0, 16),
            equals(GrassrootsIdentity.grassrootsUuidPrefix));

        // Last 16 hex chars = last 8 bytes of pubkey
        final last8 = identity.publicKey.sublist(24, 32);
        final expectedSuffix =
            last8.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        expect(hexOnly.substring(16), equals(expectedSuffix));
      });

      test('deriveServiceUuid static method matches bleServiceUuid getter', () {
        expect(GrassrootsIdentity.deriveServiceUuid(identity.publicKey),
            equals(identity.bleServiceUuid));
      });

      test('grassrootsUuidPrefix is 8 bytes (16 hex chars)', () {
        expect(GrassrootsIdentity.grassrootsUuidPrefix.length, equals(16));
        expect(GrassrootsIdentity.grassrootsUuidPrefix,
            matches(RegExp(r'^[0-9a-f]{16}$')));
      });

      test('different identities produce different UUIDs', () async {
        final algorithm = Ed25519();
        final keyPair2 = await algorithm.newKeyPair();
        final identity2 = await GrassrootsIdentity.create(
          keyPair: keyPair2,
          nickname: 'Bob',
        );
        expect(identity.bleServiceUuid, isNot(equals(identity2.bleServiceUuid)));
      });
    });

    group('shortFingerprint', () {
      test('returns first 8 bytes of pubkey in hex with colons, uppercase', () {
        final fingerprint = identity.shortFingerprint;
        final parts = fingerprint.split(':');
        expect(parts.length, equals(8));
        for (final part in parts) {
          expect(part.length, equals(2));
          expect(part, matches(RegExp(r'^[0-9A-F]{2}$')));
        }
      });

      test('matches first 8 bytes of publicKey', () {
        final fingerprint = identity.shortFingerprint;
        final expectedHex = identity.publicKey
            .sublist(0, 8)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(':')
            .toUpperCase();
        expect(fingerprint, equals(expectedHex));
      });
    });

    group('toJson() / fromMap() round-trip', () {
      test('serializes and deserializes preserving publicKey', () {
        final json = identity.toJson();
        final restored = GrassrootsIdentity.fromMap(json);
        expect(restored.publicKey, equals(identity.publicKey));
      });

      test('serializes and deserializes preserving privateKey', () {
        final json = identity.toJson();
        final restored = GrassrootsIdentity.fromMap(json);
        expect(restored.privateKey, equals(identity.privateKey));
      });

      test('serializes and deserializes preserving nickname', () {
        final json = identity.toJson();
        final restored = GrassrootsIdentity.fromMap(json);
        expect(restored.nickname, equals(identity.nickname));
      });

      test('fromMap restores a working GrassrootsIdentity with valid keyPair', () async {
        final json = identity.toJson();
        final restored = GrassrootsIdentity.fromMap(json);

        // keyPair should be usable - extract public key and compare
        final restoredPk = await restored.keyPair.extractPublicKey();
        expect(
          Uint8List.fromList(restoredPk.bytes),
          equals(identity.publicKey),
        );
      });

      test('restored identity has valid bleServiceUuid', () {
        final json = identity.toJson();
        final restored = GrassrootsIdentity.fromMap(json);
        expect(restored.bleServiceUuid, equals(identity.bleServiceUuid));
      });

      test('restored identity has valid shortFingerprint', () {
        final json = identity.toJson();
        final restored = GrassrootsIdentity.fromMap(json);
        expect(restored.shortFingerprint, equals(identity.shortFingerprint));
      });
    });

    group('toString()', () {
      test('returns GrassrootsIdentity(nickname)', () {
        expect(identity.toString(), equals('GrassrootsIdentity(Alice)'));
      });

      test('reflects the current nickname', () async {
        final algorithm = Ed25519();
        final keyPair = await algorithm.newKeyPair();
        final id = await GrassrootsIdentity.create(
          keyPair: keyPair,
          nickname: 'Charlie',
        );
        expect(id.toString(), equals('GrassrootsIdentity(Charlie)'));
      });
    });
  });
}
