import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:grassroots_networking/src/grassroots_network.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:grassroots_networking/src/models/peer.dart';
import 'package:grassroots_networking/src/models/secure_frame.dart';
import 'package:grassroots_networking/src/protocol/fragment_handler.dart';
import 'package:grassroots_networking/src/store/store.dart';

import 'helpers/sodium_test_bootstrap.dart';

/// EVERY fragment of a message goes out, not just the first.
///
/// A message larger than one sealed packet is split into N packets that the
/// send path hands out one at a time. All N must reach the outbound path: the
/// recipient reassembles only when it holds the whole set, so a message
/// missing one fragment is never delivered, never ACKed, and never confirmed —
/// while a single-packet message to the same peer succeeds, which is what
/// makes the failure look like "long messages don't work".
///
/// This is only observable when the recipient is on a LIVE LINK. Without one
/// every fragment goes to the DTN buffer regardless, so the bug hides: it is
/// the direct-write answer that used to stop the loop. Hence the seams —
/// [GrassrootsNetwork.messageRouter] to supply that answer without a radio,
/// and [GrassrootsNetwork.noiseSessions] to complete a real handshake first,
/// since no packet may exist before a session with its target does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<GrassrootsNetwork> buildNetwork(String nickname) async {
    final sodium = await initTestSodium();
    final identity = await GrassrootsIdentity.create(
      keyPair: await Ed25519().newKeyPair(),
      nickname: nickname,
    );
    return GrassrootsNetwork(
      identity: identity,
      store: Store<AppState>(appReducer, initialState: const AppState()),
      sodium: sodium,
    );
  }

  /// Complete a real Noise XX handshake between [a] and [b] by shuttling the
  /// three handshake payloads, exactly as the two coordinators' ANNOUNCE paths
  /// would. Nothing here is faked: both sides end holding a genuine session.
  Future<void> handshake(GrassrootsNetwork a, GrassrootsNetwork b) async {
    GrassrootsPacket wrap(Uint8List payload) => GrassrootsPacket(
          type: PacketType.noiseHandshake,
          ttl: 1,
          payload: payload,
        );

    final msg1 = await a.noiseSessions.startHandshake(b.identity.publicKey);
    final msg2 = (await b.noiseSessions
            .handleHandshakePacket(wrap(msg1!), remotePubkey: a.identity.publicKey))
        .responsePayload;
    final msg3 = (await a.noiseSessions
            .handleHandshakePacket(wrap(msg2!), remotePubkey: b.identity.publicKey))
        .responsePayload;
    final done = await b.noiseSessions
        .handleHandshakePacket(wrap(msg3!), remotePubkey: a.identity.publicKey);

    expect(done.sessionEstablished, isTrue,
        reason: 'the harness must produce a real session, not a stubbed one');
    expect(a.noiseSessions.hasSession(b.identity.publicKey), isTrue);
  }

  /// Everything the send path handed to the outbound router, in order.
  List<GrassrootsPacket> captureDirectSends(
    GrassrootsNetwork from, {
    required PeerTransport answer,
  }) {
    final written = <GrassrootsPacket>[];
    from.messageRouter.directSend = (recipientPubkey, sealed) async {
      written.add(sealed);
      return answer;
    };
    return written;
  }

  /// The payload [to] reassembles from [packets], or null if the set is
  /// incomplete. Mirrors the real receive path: trial-decrypt, decode the
  /// frame, reassemble by messageId.
  Future<Uint8List?> reassemble(
    GrassrootsNetwork to,
    List<GrassrootsPacket> packets,
  ) async {
    final handler = FragmentHandler();
    addTearDown(handler.dispose);
    Uint8List? whole;
    for (final packet in packets) {
      final opened = await to.noiseSessions.trialDecrypt(packet);
      expect(opened, isNotNull,
          reason: 'the recipient must be able to open every fragment');
      whole ??= handler.accept(SecureFrame.decode(opened!.$1.payload));
    }
    return whole;
  }

  test('a fragmented message hands every fragment to the outbound path',
      () async {
    final alice = await buildNetwork('alice');
    final bob = await buildNetwork('bob');
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await handshake(alice, bob);

    // A long JSON body — the shape that first surfaced this. Well over the
    // single-packet budget, so the send path must fragment it.
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'note': List.generate(40, (i) => 'entry $i padded out to force splitting'),
    })));
    expect(payload.length, greaterThan(FragmentHandler.fragmentThreshold));
    final expectedFragments =
        (payload.length / FragmentHandler.maxFragmentPayload).ceil();
    expect(expectedFragments, greaterThan(1));

    final written =
        captureDirectSends(alice, answer: PeerTransport.bleDirect);
    await alice.send(bob.identity.publicKey, payload);

    expect(written.length, expectedFragments,
        reason: 'a live link on the first fragment must not stop the rest — '
            'that is the whole bug');
    expect(written.map((p) => p.packetId).toSet().length, expectedFragments,
        reason: 'each fragment is its own packet with its own id');

    // The real proof: the recipient can rebuild the message from exactly what
    // went out. A count alone would pass on N copies of fragment 0.
    expect(await reassemble(bob, written), payload);
  });

  test('every fragment is buffered too, so a silent drop is still recoverable',
      () async {
    final alice = await buildNetwork('alice');
    final bob = await buildNetwork('bob');
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await handshake(alice, bob);

    final payload = Uint8List(FragmentHandler.maxFragmentPayload * 4);
    captureDirectSends(alice, answer: PeerTransport.bleDirect);
    await alice.send(bob.identity.publicKey, payload);

    // A write landing proves the bytes crossed the air, not that the peer's
    // app layer processed them, so every fragment is held for the sync
    // exchange until the end-to-end ACK.
    expect(alice.bufferSnapshot()['dtnPackets'], 4);
    expect(alice.bufferSnapshot()['ackIndex'], 1,
        reason: 'one message, however many packets it took');
  });

  test('with no live link every fragment still reaches the buffer', () async {
    final alice = await buildNetwork('alice');
    final bob = await buildNetwork('bob');
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await handshake(alice, bob);

    final payload = Uint8List(FragmentHandler.maxFragmentPayload * 3);
    // No transport carries it: this is the store-carry-forward path.
    final written = <GrassrootsPacket>[];
    alice.messageRouter.directSend = (recipientPubkey, sealed) async {
      written.add(sealed);
      return null;
    };
    await alice.send(bob.identity.publicKey, payload);

    expect(written.length, 3);
    expect(alice.bufferSnapshot()['dtnPackets'], 3);
  });

  test('a message that fits one packet is not fragmented', () async {
    final alice = await buildNetwork('alice');
    final bob = await buildNetwork('bob');
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);
    await handshake(alice, bob);

    final payload = Uint8List.fromList(utf8.encode('hi'));
    final written =
        captureDirectSends(alice, answer: PeerTransport.bleDirect);
    await alice.send(bob.identity.publicKey, payload);

    expect(written.length, 1);
    expect(await reassemble(bob, written), payload);
  });
}
