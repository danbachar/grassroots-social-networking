import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:grassroots_networking/src/models/secure_frame.dart';
import 'package:grassroots_networking/src/session/noise_session_manager.dart';
import 'package:grassroots_networking/src/testbed/testbed_config.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:uuid/uuid.dart';

import '../helpers/sodium_test_bootstrap.dart';

/// BENCHMARK, not a test — named `_bench.dart` so `flutter test` skips it.
/// Run explicitly:
///
///     flutter test test/bench/trial_decrypt_bench.dart
///
/// Question it answers: what would it cost to drop the cleartext recipient id
/// from the envelope? Today a node compares 32 bytes to know whether a packet
/// is its own, and only the addressee runs the AEAD. With a blind envelope
/// EVERY node must trial-decrypt EVERY packet against EVERY session until one
/// opens (or all fail, for transit traffic) — a wrong session is only refuted
/// at the Poly1305 tag, after a full pass over the payload.
///
/// Measured here on the real primitives (no mocks): the marginal cost of one
/// failed attempt, and the totals for the two shapes that matter — a packet
/// addressed to us (one success, on average half the sessions tried first)
/// versus transit traffic (all sessions fail, the relay's per-packet tax that
/// today is exactly zero).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SodiumSumo sodium;
  setUpAll(() async {
    sodium = await initTestSodium();
  });

  Future<GrassrootsIdentity> identity(String nickname) async =>
      GrassrootsIdentity.create(
          keyPair: await Ed25519().newKeyPair(), nickname: nickname);

  GrassrootsPacket handshakePacket(Uint8List payload) => GrassrootsPacket(
      type: PacketType.noiseHandshake, ttl: 0, payload: payload);

  Future<void> completeHandshake({
    required NoiseSessionManager initiator,
    required Uint8List initPub,
    required NoiseSessionManager responder,
    required Uint8List respPub,
  }) async {
    final m1 = await initiator.startHandshake(respPub);
    final r1 = await responder.handleHandshakePacket(handshakePacket(m1!),
        remotePubkey: initPub);
    final r2 = await initiator.handleHandshakePacket(
        handshakePacket(r1.responsePayload!),
        remotePubkey: respPub);
    await responder.handleHandshakePacket(
        handshakePacket(r2.responsePayload!),
        remotePubkey: initPub);
  }

  /// One sealed packet, freshly nonced. Reused packets would hit the replay
  /// check and measure a cheap throw instead of the crypto.
  Future<GrassrootsPacket> seal(
      NoiseSessionManager from, Uint8List toPub, int bytes) async {
    final frame = SecureFrame(
      contentType: ContentType.message,
      messageId: const Uuid().v4(),
      chunk: Uint8List(bytes),
    );
    return from.encryptPacket(
      GrassrootsPacket(
          type: PacketType.secure, recipientPubkey: toPub,
          payload: frame.encode()),
      remotePubkey: toPub,
    );
  }

  test('trial-decrypt cost vs session count', () async {
    const sessionCount = 20;
    const iterations = 200;
    const payload = defaultSendBytes; // 132 B = exactly one sealed packet

    final me = await identity('Receiver');
    final mine = NoiseSessionManager(identity: me, sodium: sodium);

    // N peers, handshaked in order — _entries is insertion-ordered, so peer 0
    // is the first session tried and peer N-1 the last.
    final peers = <NoiseSessionManager>[];
    final peerPubs = <Uint8List>[];
    for (var i = 0; i < sessionCount; i++) {
      final id = await identity('Peer$i');
      final mgr = NoiseSessionManager(identity: id, sodium: sodium);
      await completeHandshake(
          initiator: mgr, initPub: id.publicKey,
          responder: mine, respPub: me.publicKey);
      peers.add(mgr);
      peerPubs.add(id.publicKey);
    }

    // A stranger we hold no session with: its packets are transit traffic —
    // every session fails, which is the relay case.
    final strangerId = await identity('Stranger');
    final stranger = NoiseSessionManager(identity: strangerId, sodium: sodium);
    final other = await identity('StrangerPeer');
    final otherMgr = NoiseSessionManager(identity: other, sodium: sodium);
    await completeHandshake(
        initiator: stranger, initPub: strangerId.publicKey,
        responder: otherMgr, respPub: other.publicKey);

    Future<List<GrassrootsPacket>> batch(
            NoiseSessionManager from, Uint8List toPub) async =>
        [for (var i = 0; i < iterations; i++) await seal(from, toPub, payload)];

    final firstBatch = await batch(peers.first, me.publicKey);
    final lastBatch = await batch(peers.last, me.publicKey);
    final transitBatch = await batch(stranger, other.publicKey);

    Future<double> timeUs(List<GrassrootsPacket> packets) async {
      final sw = Stopwatch()..start();
      for (final p in packets) {
        await mine.trialDecrypt(p);
      }
      sw.stop();
      return sw.elapsedMicroseconds / packets.length;
    }

    // Warm up the JIT. Uses transit traffic on purpose: a successful decrypt
    // remembers its nonce, and a later packet carrying an already-seen nonce
    // is refuted by the replay check BEFORE any crypto — measuring a cheap
    // throw instead of a real attempt. Sessions that have decrypted nothing
    // have empty replay windows, so their failures are full AEAD passes.
    await timeUs(await batch(stranger, other.publicKey));

    // Transit FIRST, while every session's replay window is still empty.
    final transit = await timeUs(transitBatch); // N attempts, none open it
    final best = await timeUs(firstBatch); // 1 attempt (session 0 opens it)
    final worst = await timeUs(lastBatch); // N attempts (last session opens it)

    // From transit: N full failures, no success, no replay short-circuits.
    final perAttempt = transit / sessionCount;

    // ignore: avoid_print
    print('''

=== trial-decrypt cost ($sessionCount sessions, $payload B payload, n=$iterations) ===
  addressed to us, best case  (1 attempt)   : ${best.toStringAsFixed(1)} us
  addressed to us, worst case ($sessionCount attempts) : ${worst.toStringAsFixed(1)} us
  transit traffic  (all $sessionCount fail)          : ${transit.toStringAsFixed(1)} us
  marginal cost of ONE failed attempt        : ${perAttempt.toStringAsFixed(1)} us
  (worst case includes a replay-window short-circuit on session 0 — the
   per-session replay set accidentally pre-filters some attempts for free)

  Today a relay pays ~0 us per transit packet (32-byte compare, no crypto).
  At the measured mesh capacity (~40 packets/s):
    transit tax at $sessionCount sessions : ${(transit * 40 / 10000).toStringAsFixed(2)} % of one core
    transit tax at 5 sessions  : ${((best + perAttempt * 4) * 40 / 10000).toStringAsFixed(2)} % of one core
''');

    expect(perAttempt, greaterThan(0));
  });
}
