import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:grassroots_networking/src/models/peer.dart';
import 'package:grassroots_networking/src/session/noise_session_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<GrassrootsIdentity> identity(String nickname) async {
    return GrassrootsIdentity.create(
      keyPair: await Ed25519().newKeyPair(),
      nickname: nickname,
    );
  }

  GrassrootsPacket handshakePacket({
    required GrassrootsIdentity sender,
    required GrassrootsIdentity recipient,
    required Uint8List payload,
  }) {
    return GrassrootsPacket(
      type: PacketType.noiseHandshake,
      ttl: 0,
      senderPubkey: sender.publicKey,
      recipientPubkey: recipient.publicKey,
      payload: payload,
      signature: Uint8List(64),
    );
  }

  test('establishes independent BLE and UDP sessions for the same peer',
      () async {
    final alice = await identity('Alice');
    final bob = await identity('Bob');
    final aliceSessions = NoiseSessionManager(identity: alice);
    final bobSessions = NoiseSessionManager(identity: bob);

    Future<void> completeHandshake(PeerTransport transport) async {
      final msg1 = await aliceSessions.startHandshake(
        transport,
        bob.publicKey,
      );
      expect(msg1, isNotNull);

      final msg2 = await bobSessions.handleHandshakePacket(
        handshakePacket(sender: alice, recipient: bob, payload: msg1!),
        transport: transport,
      );
      expect(msg2.responsePayload, isNotNull);

      final msg3 = await aliceSessions.handleHandshakePacket(
        handshakePacket(
          sender: bob,
          recipient: alice,
          payload: msg2.responsePayload!,
        ),
        transport: transport,
      );
      expect(msg3.sessionEstablished, isTrue);
      expect(msg3.responsePayload, isNotNull);

      final finished = await bobSessions.handleHandshakePacket(
        handshakePacket(
          sender: alice,
          recipient: bob,
          payload: msg3.responsePayload!,
        ),
        transport: transport,
      );
      expect(finished.sessionEstablished, isTrue);
      expect(aliceSessions.hasSession(transport, bob.publicKey), isTrue);
      expect(bobSessions.hasSession(transport, alice.publicKey), isTrue);
    }

    await completeHandshake(PeerTransport.bleDirect);
    await completeHandshake(PeerTransport.udp);

    final clear = GrassrootsPacket(
      type: PacketType.message,
      senderPubkey: alice.publicKey,
      recipientPubkey: bob.publicKey,
      payload: Uint8List.fromList([1, 2, 3, 4]),
      signature: Uint8List(64),
    );

    final bleEncrypted = await aliceSessions.encryptPacket(
      clear,
      transport: PeerTransport.bleDirect,
      remotePubkey: bob.publicKey,
    );
    final udpEncrypted = await aliceSessions.encryptPacket(
      clear,
      transport: PeerTransport.udp,
      remotePubkey: bob.publicKey,
    );

    expect(bleEncrypted.type, PacketType.secureMessage);
    expect(udpEncrypted.type, PacketType.secureMessage);
    expect(bleEncrypted.payload, isNot(equals(clear.payload)));
    expect(udpEncrypted.payload, isNot(equals(bleEncrypted.payload)));

    final bleDecrypted = await bobSessions.decryptPacket(
      bleEncrypted,
      transport: PeerTransport.bleDirect,
    );
    final udpDecrypted = await bobSessions.decryptPacket(
      udpEncrypted,
      transport: PeerTransport.udp,
    );

    expect(bleDecrypted.type, PacketType.message);
    expect(udpDecrypted.type, PacketType.message);
    expect(bleDecrypted.payload, clear.payload);
    expect(udpDecrypted.payload, clear.payload);
  });
}
