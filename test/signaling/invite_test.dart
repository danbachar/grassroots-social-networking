import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Ed25519;
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/signaling/invite.dart';
import 'package:sodium_libs/sodium_libs.dart';

import '../helpers/sodium_test_bootstrap.dart';

Future<GrassrootsIdentity> _identity(String nick) async {
  final keyPair = await Ed25519().newKeyPair();
  return GrassrootsIdentity.create(keyPair: keyPair, nickname: nick);
}

void main() {
  late Sodium sodium;
  setUpAll(() async {
    sodium = await initTestSodium();
  });

  Invite build(
    GrassrootsIdentity inviter, {
    required List<InviteIntroducer> introducers,
    int? expiry,
    int maxUses = 1,
    Uint8List? nonce,
  }) {
    return InviteSigner(sodium).sign(
      inviter: inviter.publicKey,
      privateKey: inviter.privateKey,
      introducers: introducers,
      expiry: expiry ??
          DateTime.now()
                  .add(const Duration(hours: 1))
                  .millisecondsSinceEpoch ~/
              1000,
      nonce: nonce ?? Uint8List.fromList(List.generate(16, (i) => i)),
      maxUses: maxUses,
    );
  }

  test('signed invite round-trips through the link and verifies', () async {
    final inviter = await _identity('Inviter');
    final intro = await _identity('Introducer');
    final invite = build(
      inviter,
      introducers: [
        InviteIntroducer(
          pubkey: intro.publicKey,
          addresses: const ['[2606:4700::1]:4001', '198.51.100.7:4001'],
        ),
      ],
      maxUses: 3,
    );

    final decoded = Invite.parseLink(invite.toLink(), sodium);

    expect(decoded.inviter, equals(inviter.publicKey));
    expect(decoded.maxUses, equals(3));
    expect(decoded.nonce, equals(invite.nonce));
    expect(decoded.introducers, hasLength(1));
    expect(decoded.introducers.single.pubkey, equals(intro.publicKey));
    expect(
      decoded.introducers.single.addresses,
      equals(const ['[2606:4700::1]:4001', '198.51.100.7:4001']),
    );
  });

  test('a tampered invite body fails verification', () async {
    final inviter = await _identity('Inviter');
    final intro = await _identity('Introducer');
    final invite = build(
      inviter,
      introducers: [
        InviteIntroducer(pubkey: intro.publicKey, addresses: const ['x:1']),
      ],
    );

    // Flip a byte inside the signed body (the maxUses field).
    final blob = invite.encode();
    blob[1 + 32 + 8 + Invite.nonceLength] ^= 0xFF;

    expect(() => Invite.decode(blob, sodium),
        throwsA(isA<FormatException>()));
  });

  test('an invite whose signature is by a different key is rejected',
      () async {
    final inviter = await _identity('Inviter');
    final impostor = await _identity('Impostor');
    final intro = await _identity('Introducer');

    // A body that claims the inviter's pubkey, but signed with the impostor's
    // key — the signature won't verify against the embedded inviter pubkey.
    final body = Invite.canonicalBody(
      inviter: inviter.publicKey,
      introducers: [
        InviteIntroducer(pubkey: intro.publicKey, addresses: const ['x:1']),
      ],
      expiry:
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
              1000,
      nonce: Uint8List(16),
      maxUses: 1,
    );
    final secretKey = SecureKey.fromList(sodium, impostor.privateKey);
    final impostorSig = sodium.crypto.sign.detached(
      message: body,
      secretKey: secretKey,
    );
    secretKey.dispose();
    final forged = Uint8List.fromList([...body, ...impostorSig]);

    expect(() => Invite.decode(forged, sodium),
        throwsA(isA<FormatException>()));
  });

  test('expiry is reported against a clock', () async {
    final inviter = await _identity('Inviter');
    final intro = await _identity('Introducer');
    final past = DateTime.now()
            .subtract(const Duration(minutes: 1))
            .millisecondsSinceEpoch ~/
        1000;
    final invite = build(
      inviter,
      introducers: [
        InviteIntroducer(pubkey: intro.publicKey, addresses: const ['x:1']),
      ],
      expiry: past,
    );

    expect(invite.isExpiredAt(DateTime.now()), isTrue);
    expect(
      invite.isExpiredAt(
          DateTime.fromMillisecondsSinceEpoch((past - 60) * 1000)),
      isFalse,
    );
  });

  test('parseLink rejects non-invite URIs', () async {
    expect(() => Invite.parseLink('https://example.com', sodium),
        throwsA(isA<FormatException>()));
    expect(() => Invite.parseLink('grassroots://invite', sodium),
        throwsA(isA<FormatException>()));
    expect(() => Invite.parseLink('grassroots://invite?d=@@notbase64@@', sodium),
        throwsA(isA<FormatException>()));
  });
}
