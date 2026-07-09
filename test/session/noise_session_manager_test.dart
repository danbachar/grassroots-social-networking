import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:grassroots_networking/src/models/secure_frame.dart';
import 'package:grassroots_networking/src/session/noise_session_manager.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:uuid/uuid.dart';

import '../helpers/sodium_test_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds an UNSEALED [PacketType.secure] content packet whose payload is a
  /// [SecureFrame] carrying [content]. This is what an application hands the
  /// session manager to seal (was: a clear `PacketType.message` packet).
  GrassrootsPacket securePacket({
    required Uint8List recipient,
    required Uint8List content,
    int ttl = 0,
    ContentType contentType = ContentType.message,
  }) {
    final frame = SecureFrame(
      contentType: contentType,
      messageId: const Uuid().v4(),
      chunk: content,
    );
    return GrassrootsPacket(
      type: PacketType.secure,
      ttl: ttl,
      recipientPubkey: recipient,
      payload: frame.encode(),
    );
  }

  late SodiumSumo sodium;
  setUpAll(() async {
    sodium = await initTestSodium();
  });

  Future<GrassrootsIdentity> identity(String nickname) async {
    return GrassrootsIdentity.create(
      keyPair: await Ed25519().newKeyPair(),
      nickname: nickname,
    );
  }

  GrassrootsPacket handshakePacket(Uint8List payload) {
    return GrassrootsPacket(
      type: PacketType.noiseHandshake,
      ttl: 0,
      payload: payload,
    );
  }

  /// Drives a full XX handshake between [initiator] (with identity [initPub])
  /// and [responder] (with identity [respPub]). The wire envelope is
  /// sender-anonymous, so each side is told the peer's pubkey out of band via
  /// the `remotePubkey:` argument (resolved by the coordinator from the peer's
  /// verified ANNOUNCE) — never read off the packet.
  Future<void> completeHandshake({
    required NoiseSessionManager initiator,
    required Uint8List initPub,
    required NoiseSessionManager responder,
    required Uint8List respPub,
  }) async {
    final m1 = await initiator.startHandshake(respPub);
    expect(m1, isNotNull);

    final r1 = await responder.handleHandshakePacket(
      handshakePacket(m1!),
      remotePubkey: initPub,
    );
    expect(r1.responsePayload, isNotNull);

    final r2 = await initiator.handleHandshakePacket(
      handshakePacket(r1.responsePayload!),
      remotePubkey: respPub,
    );
    expect(r2.sessionEstablished, isTrue);
    expect(r2.responsePayload, isNotNull);

    final finished = await responder.handleHandshakePacket(
      handshakePacket(r2.responsePayload!),
      remotePubkey: initPub,
    );
    expect(finished.sessionEstablished, isTrue);
  }

  test('establishes an end-to-end session and round-trips an encrypted packet',
      () async {
    final alice = await identity('Alice');
    final bob = await identity('Bob');
    final aliceSessions = NoiseSessionManager(identity: alice, sodium: sodium);
    final bobSessions = NoiseSessionManager(identity: bob, sodium: sodium);

    await completeHandshake(
      initiator: aliceSessions,
      initPub: alice.publicKey,
      responder: bobSessions,
      respPub: bob.publicKey,
    );

    // Sessions are keyed by peer identity, not by transport path.
    expect(aliceSessions.hasSession(bob.publicKey), isTrue);
    expect(bobSessions.hasSession(alice.publicKey), isTrue);

    final clear = securePacket(
      recipient: bob.publicKey,
      content: Uint8List.fromList([1, 2, 3, 4]),
    );

    final sealed = await aliceSessions.encryptPacket(
      clear,
      remotePubkey: bob.publicKey,
    );
    // The wire type stays `secure`; only the payload becomes ciphertext.
    expect(sealed.type, PacketType.secure);
    expect(sealed.payload, isNot(equals(clear.payload)));

    // Bob has no sender field on the wire — he demultiplexes by trial-decrypt.
    final decrypted = await bobSessions.trialDecrypt(sealed);
    expect(decrypted, isNotNull);
    final (clearPacket, senderPubkey) = decrypted!;
    // The cleartext packet is still typed `secure`; the inner content type and
    // body live in its decoded SecureFrame.
    expect(clearPacket.type, PacketType.secure);
    expect(clearPacket.payload, clear.payload);
    final frame = SecureFrame.decode(clearPacket.payload);
    expect(frame.contentType, ContentType.message);
    expect(frame.chunk, Uint8List.fromList([1, 2, 3, 4]));
    // The recovered sender is Alice, recovered from the session, not the header.
    expect(senderPubkey, equals(alice.publicKey));
  });

  test('a relay-mutated TTL still trial-decrypts (AAD excludes TTL)', () async {
    final alice = await identity('Alice');
    final bob = await identity('Bob');
    final aliceSessions = NoiseSessionManager(identity: alice, sodium: sodium);
    final bobSessions = NoiseSessionManager(identity: bob, sodium: sodium);

    await completeHandshake(
      initiator: aliceSessions,
      initPub: alice.publicKey,
      responder: bobSessions,
      respPub: bob.publicKey,
    );

    final clear = securePacket(
      recipient: bob.publicKey,
      content: Uint8List.fromList([9, 8, 7, 6, 5]),
      ttl: 7,
    );
    final sealed = await aliceSessions.encryptPacket(
      clear,
      remotePubkey: bob.publicKey,
    );

    // A relay hop decrements the TTL on the envelope. Because the application
    // AEAD AAD excludes TTL, the recipient must still open the packet.
    final relayed = sealed.decrementTtl();
    expect(relayed.ttl, sealed.ttl - 1);

    final decrypted = await bobSessions.trialDecrypt(relayed);
    expect(decrypted, isNotNull);
    expect(decrypted!.$1.payload, clear.payload);
    final frame = SecureFrame.decode(decrypted.$1.payload);
    expect(frame.contentType, ContentType.message);
    expect(frame.chunk, Uint8List.fromList([9, 8, 7, 6, 5]));
    expect(decrypted.$2, equals(alice.publicKey));
  });

  test('a replayed sealed packet is rejected on the second trial-decrypt',
      () async {
    final alice = await identity('Alice');
    final bob = await identity('Bob');
    final aliceSessions = NoiseSessionManager(identity: alice, sodium: sodium);
    final bobSessions = NoiseSessionManager(identity: bob, sodium: sodium);

    await completeHandshake(
      initiator: aliceSessions,
      initPub: alice.publicKey,
      responder: bobSessions,
      respPub: bob.publicKey,
    );

    final sealed = await aliceSessions.encryptPacket(
      securePacket(
        recipient: bob.publicKey,
        content: Uint8List.fromList([42]),
      ),
      remotePubkey: bob.publicKey,
    );

    final first = await bobSessions.trialDecrypt(sealed);
    expect(first, isNotNull);

    // Same nonce replayed — the session's replay window rejects it, and with no
    // other open session the trial-decrypt yields null.
    final second = await bobSessions.trialDecrypt(sealed);
    expect(second, isNull);
  });

  test('reset() drops the session so further sealed packets cannot be opened',
      () async {
    final alice = await identity('Alice');
    final bob = await identity('Bob');
    final aliceSessions = NoiseSessionManager(identity: alice, sodium: sodium);
    final bobSessions = NoiseSessionManager(identity: bob, sodium: sodium);

    await completeHandshake(
      initiator: aliceSessions,
      initPub: alice.publicKey,
      responder: bobSessions,
      respPub: bob.publicKey,
    );
    expect(bobSessions.hasSession(alice.publicKey), isTrue);

    final sealed = await aliceSessions.encryptPacket(
      securePacket(
        recipient: bob.publicKey,
        content: Uint8List.fromList([1, 1, 2, 3, 5]),
      ),
      remotePubkey: bob.publicKey,
    );

    bobSessions.reset(alice.publicKey);
    expect(bobSessions.hasSession(alice.publicKey), isFalse);

    // With no session left, Bob can no longer open the packet.
    final decrypted = await bobSessions.trialDecrypt(sealed);
    expect(decrypted, isNull);
  });

  test(
      'aborts the handshake when the delivered static key does not match the '
      'claimed identity (impersonation)', () async {
    final alice = await identity('Alice');
    final bob = await identity('Bob');
    final mallory = await identity('Mallory');

    final bobSessions = NoiseSessionManager(identity: bob, sodium: sodium);
    final mallorySessions =
        NoiseSessionManager(identity: mallory, sodium: sodium);

    // Mallory drives an initiator handshake toward Bob, but the coordinator on
    // Bob's side resolves the peer identity as Alice (e.g. from a forged
    // ANNOUNCE) — an identity whose Noise static Mallory cannot produce.
    final msg1 = await mallorySessions.startHandshake(bob.publicKey);
    expect(msg1, isNotNull);

    final msg2 = await bobSessions.handleHandshakePacket(
      handshakePacket(msg1!),
      remotePubkey: alice.publicKey,
    );
    expect(msg2.responsePayload, isNotNull);

    // Mallory completes her side (she keys the session under Bob, whose static
    // is genuine), producing a msg3 that carries *Mallory's* static.
    final msg3 = await mallorySessions.handleHandshakePacket(
      handshakePacket(msg2.responsePayload!),
      remotePubkey: bob.publicKey,
    );
    expect(msg3.responsePayload, isNotNull);

    // Bob receives msg3, still resolved as coming from Alice. The delivered
    // static is Mallory's and does not match the X25519 form of Alice's
    // identity, so Bob aborts and establishes no session.
    final finished = await bobSessions.handleHandshakePacket(
      handshakePacket(msg3.responsePayload!),
      remotePubkey: alice.publicKey,
    );

    expect(finished.sessionEstablished, isFalse);
    expect(bobSessions.hasSession(alice.publicKey), isFalse);
  });
}
