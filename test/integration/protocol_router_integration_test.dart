import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:grassroots_networking/src/models/peer.dart';
import 'package:grassroots_networking/src/models/secure_frame.dart';
import 'package:grassroots_networking/src/protocol/protocol_handler.dart';
import 'package:grassroots_networking/src/protocol/fragment_handler.dart';
import 'package:grassroots_networking/src/routing/message_router.dart';
import 'package:grassroots_networking/src/session/noise_session_manager.dart';
import 'package:grassroots_networking/src/store/store.dart';

import '../helpers/sodium_test_bootstrap.dart';

/// Build an UNSEALED secure MESSAGE packet whose sealed frame carries
/// [messageId] as its logical id. The outer wire [packetId] is a *separate*
/// random id (as a real transport assigns it) — the router dedups the wire
/// packet on packetId and the logical message on the frame's messageId, so the
/// two must differ for delivery to fire.
GrassrootsPacket messagePacket({
  required Uint8List payload,
  required String messageId,
  required Uint8List recipientPubkey,
}) {
  final frame = SecureFrame(
    contentType: ContentType.message,
    messageId: messageId,
    chunk: payload,
  );
  return GrassrootsPacket(
    type: PacketType.secure,
    recipientPubkey: recipientPubkey,
    payload: frame.encode(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SodiumSumo sodium;
  setUpAll(() async {
    sodium = await initTestSodium();
  });

  late GrassrootsIdentity aliceIdentity;
  late GrassrootsIdentity bobIdentity;
  late ProtocolHandler aliceProtocol;
  late ProtocolHandler bobProtocol;
  late NoiseSessionManager aliceSessions;
  late NoiseSessionManager bobSessions;
  late MessageRouter aliceRouter;
  late MessageRouter bobRouter;
  late Store<AppState> aliceStore;
  late Store<AppState> bobStore;

  /// Build an ANNOUNCE packet whose payload is validly self-signed by [protocol]
  /// (the new wire format has no header sender/signature — the payload carries
  /// the Ed25519 signature, verified by [ProtocolHandler.decodeAnnounce]).
  GrassrootsPacket announcePacket(
    ProtocolHandler protocol, {
    String? address,
  }) {
    return GrassrootsPacket(
      type: PacketType.announce,
      payload: protocol.createAnnouncePayload(address: address),
    );
  }

  /// Drive a full Noise XX handshake so [initiator] (identity [initiatorPub])
  /// and [responder] (identity [responderPub]) both end up with a live session.
  Future<void> completeHandshake(
    NoiseSessionManager initiator,
    Uint8List initiatorPub,
    NoiseSessionManager responder,
    Uint8List responderPub,
  ) async {
    final m1 = await initiator.startHandshake(responderPub);
    expect(m1, isNotNull);

    final r1 = await responder.handleHandshakePacket(
      GrassrootsPacket(type: PacketType.noiseHandshake, payload: m1!),
      remotePubkey: initiatorPub,
    );
    expect(r1.responsePayload, isNotNull);

    final r2 = await initiator.handleHandshakePacket(
      GrassrootsPacket(
          type: PacketType.noiseHandshake, payload: r1.responsePayload!),
      remotePubkey: responderPub,
    );
    expect(r2.responsePayload, isNotNull);

    final r3 = await responder.handleHandshakePacket(
      GrassrootsPacket(
          type: PacketType.noiseHandshake, payload: r2.responsePayload!),
      remotePubkey: initiatorPub,
    );
    expect(r3.sessionEstablished, isTrue);

    expect(initiator.hasSession(responderPub), isTrue);
    expect(responder.hasSession(initiatorPub), isTrue);
  }

  setUp(() async {
    final algorithm = Ed25519();

    final aliceKeyPair = await algorithm.newKeyPair();
    aliceIdentity = await GrassrootsIdentity.create(
      keyPair: aliceKeyPair,
      nickname: 'Alice',
    );

    final bobKeyPair = await algorithm.newKeyPair();
    bobIdentity = await GrassrootsIdentity.create(
      keyPair: bobKeyPair,
      nickname: 'Bob',
    );

    aliceStore = Store<AppState>(appReducer, initialState: const AppState());
    bobStore = Store<AppState>(appReducer, initialState: const AppState());

    aliceProtocol = ProtocolHandler(identity: aliceIdentity, sodium: sodium);
    bobProtocol = ProtocolHandler(identity: bobIdentity, sodium: sodium);

    aliceSessions = NoiseSessionManager(identity: aliceIdentity, sodium: sodium);
    bobSessions = NoiseSessionManager(identity: bobIdentity, sodium: sodium);

    aliceRouter = MessageRouter(
      identity: aliceIdentity,
      store: aliceStore,
      protocolHandler: aliceProtocol,
      fragmentHandler: FragmentHandler(),
    );
    aliceRouter.trialDecrypt = aliceSessions.trialDecrypt;

    bobRouter = MessageRouter(
      identity: bobIdentity,
      store: bobStore,
      protocolHandler: bobProtocol,
      fragmentHandler: FragmentHandler(),
    );
    bobRouter.trialDecrypt = bobSessions.trialDecrypt;
  });

  tearDown(() {
    aliceRouter.dispose();
    bobRouter.dispose();
    aliceSessions.dispose();
    bobSessions.dispose();
  });

  group('BLE ANNOUNCE roundtrip', () {
    test('Alice creates ANNOUNCE, Bob receives and decodes it', () async {
      // Alice creates a self-signed ANNOUNCE packet (as the BLE transport does).
      final packet = announcePacket(aliceProtocol);

      // Bob's router processes the BLE packet.
      AnnounceData? receivedAnnounce;
      PeerTransport? receivedTransport;
      bobRouter.onPeerAnnounced =
          (data, transport, {bool isNew = false, String? udpPeerId}) {
        receivedAnnounce = data;
        receivedTransport = transport;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        rssi: -50,
      );

      // Verify Bob decoded Alice's announce correctly.
      expect(receivedAnnounce, isNotNull);
      expect(receivedAnnounce!.publicKey, equals(aliceIdentity.publicKey));
      expect(receivedAnnounce!.nickname, equals('Alice'));
      expect(receivedAnnounce!.protocolVersion, equals(1));
      expect(receivedTransport, equals(PeerTransport.bleDirect));

      // Verify Bob's Redux store was updated.
      final peerState =
          bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peerState, isNotNull);
      expect(peerState!.nickname, equals('Alice'));
      expect(peerState.transport, equals(PeerTransport.bleDirect));
      expect(peerState.rssi, equals(-50));
    });

    test('ANNOUNCE with UDP address roundtrips correctly', () async {
      const address = '[2001:db8::1]:4001';
      final packet = announcePacket(aliceProtocol, address: address);

      AnnounceData? receivedAnnounce;
      bobRouter.onPeerAnnounced =
          (data, transport, {bool isNew = false, String? udpPeerId}) {
        receivedAnnounce = data;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        rssi: -60,
      );

      expect(receivedAnnounce, isNotNull);
      expect(receivedAnnounce!.udpAddress, equals(address));

      // Verify UDP address stored in Redux.
      final peerState =
          bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peerState!.udpAddress, equals(address));
    });

    test('forged ANNOUNCE (tampered payload) is dropped', () async {
      // Take a valid signed ANNOUNCE, then flip a byte in the body so the
      // embedded Ed25519 signature no longer verifies. The router must drop it.
      final valid = aliceProtocol.createAnnouncePayload();
      final tampered = Uint8List.fromList(valid);
      // Mutate a nickname byte (well inside the signed body, before the sig).
      tampered[40] ^= 0xFF;
      final packet = GrassrootsPacket(
        type: PacketType.announce,
        payload: tampered,
      );

      var announceFired = false;
      bobRouter.onPeerAnnounced =
          (_, __, {bool isNew = false, String? udpPeerId}) {
        announceFired = true;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        rssi: -50,
      );

      expect(announceFired, isFalse);
      expect(
        bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey),
        isNull,
      );
    });
  });

  group('BLE MESSAGE roundtrip (end-to-end via Noise)', () {
    test('Alice sends MESSAGE to Bob, Bob receives it and an ACK is requested',
        () async {
      await completeHandshake(
        aliceSessions,
        aliceIdentity.publicKey,
        bobSessions,
        bobIdentity.publicKey,
      );

      final messagePayload = Uint8List.fromList([10, 20, 30, 40, 50]);
      const messageId = '00000000-0000-4000-8000-000000000001';

      // Alice creates a message packet targeted at Bob and seals it under the
      // Noise session (the wire packet is sender-anonymous + encrypted).
      final clear = messagePacket(
        payload: messagePayload,
        messageId: messageId,
        recipientPubkey: bobIdentity.publicKey,
      );
      final sealed = await aliceSessions.encryptPacket(
        clear,
        remotePubkey: bobIdentity.publicKey,
      );
      // Content type + fragmentation now live inside the sealed frame; the wire
      // type is the single opaque PacketType.secure.
      expect(sealed.type, equals(PacketType.secure));
      expect(sealed.payload, isNot(equals(messagePayload)));

      // Bob's router processes the sealed bytes: it trial-decrypts, delivers,
      // and asks for an ACK back to the recovered sender.
      String? receivedId;
      Uint8List? receivedPayload;
      Uint8List? receivedSender;
      bobRouter.onMessageReceived = (id, sender, payload, _) {
        receivedId = id;
        receivedSender = sender;
        receivedPayload = payload;
      };
      Uint8List? ackSender;
      String? ackMessageId;
      bobRouter.onAckRequested = (sender, messageId, _) {
        ackSender = sender;
        ackMessageId = messageId;
      };

      await bobRouter.processPacket(
        sealed,
        transport: PeerTransport.bleDirect,
        rssi: -70,
      );

      // The delivered id is the frame's logical messageId, recovered from the
      // decrypted frame (distinct from the sender-anonymous outer packetId).
      expect(receivedId, equals(messageId));
      expect(receivedPayload, equals(messagePayload));
      expect(receivedSender, equals(aliceIdentity.publicKey));

      // ACK requested back to the original sender, keyed on the message id.
      expect(ackSender, equals(aliceIdentity.publicKey));
      expect(ackMessageId, equals(messageId));
    });

    test('a relay that decrements TTL does not break end-to-end decryption',
        () async {
      // AAD excludes TTL, so a relay mutating it must not break the seal.
      await completeHandshake(
        aliceSessions,
        aliceIdentity.publicKey,
        bobSessions,
        bobIdentity.publicKey,
      );

      final messagePayload = Uint8List.fromList([7, 7, 7]);
      final clear = messagePacket(
        payload: messagePayload,
        messageId: '00000000-0000-4000-8000-000000000002',
        recipientPubkey: bobIdentity.publicKey,
      );
      final sealed = await aliceSessions.encryptPacket(
        clear,
        remotePubkey: bobIdentity.publicKey,
      );

      // Simulate a relay hop.
      final relayed = sealed.decrementTtl();
      expect(relayed.ttl, equals(sealed.ttl - 1));

      Uint8List? receivedPayload;
      bobRouter.onMessageReceived = (_, __, payload, ___) {
        receivedPayload = payload;
      };

      await bobRouter.processPacket(
        relayed,
        transport: PeerTransport.bleDirect,
        rssi: -70,
      );

      expect(receivedPayload, equals(messagePayload));
    });

    test('message for someone else is relayed, not delivered to Bob', () async {
      await completeHandshake(
        aliceSessions,
        aliceIdentity.publicKey,
        bobSessions,
        bobIdentity.publicKey,
      );

      final otherPub = Uint8List.fromList(List.generate(32, (i) => 100 + i));
      final messagePayload = Uint8List.fromList([1, 2, 3]);

      // Alice sends to someone other than Bob. Even though Bob holds a session
      // with Alice, the packet is not addressed to Bob, so Bob must NOT deliver
      // it — it gets relayed (managed flooding) instead.
      final clear = messagePacket(
        payload: messagePayload,
        messageId: '00000000-0000-4000-8000-000000000003',
        recipientPubkey: otherPub,
      );
      final sealed = await aliceSessions.encryptPacket(
        clear,
        remotePubkey: bobIdentity.publicKey,
      );

      var messageReceived = false;
      bobRouter.onMessageReceived = (_, __, ___, ____) {
        messageReceived = true;
      };
      GrassrootsPacket? relayed;
      bobRouter.onRelay = (packet, {String? excludeBlePeerId}) {
        relayed = packet;
      };

      await bobRouter.processPacket(
        sealed,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        rssi: -70,
      );

      expect(messageReceived, isFalse);
      // Relayed toward the (unreachable) recipient with a decremented TTL.
      expect(relayed, isNotNull);
      expect(relayed!.recipientPubkey, equals(otherPub));
      expect(relayed!.ttl, equals(sealed.ttl - 1));
    });
  });

  group('BLE READ_RECEIPT roundtrip (end-to-end via Noise)', () {
    test('Alice sends read receipt, Bob receives message ID', () async {
      await completeHandshake(
        aliceSessions,
        aliceIdentity.publicKey,
        bobSessions,
        bobIdentity.publicKey,
      );

      const messageId = '00000000-0000-4000-8000-0000000000aa';

      final clear = aliceProtocol.createReadReceiptPacket(
        messageId: messageId,
        recipientPubkey: bobIdentity.publicKey,
      );
      final sealed = await aliceSessions.encryptPacket(
        clear,
        remotePubkey: bobIdentity.publicKey,
      );
      // Read-receipt content type is now sealed inside the frame; the wire type
      // is the opaque PacketType.secure.
      expect(sealed.type, equals(PacketType.secure));

      String? receivedMessageId;
      bobRouter.onReadReceiptReceived = (id) {
        receivedMessageId = id;
      };

      await bobRouter.processPacket(
        sealed,
        transport: PeerTransport.bleDirect,
        rssi: -70,
      );

      expect(receivedMessageId, equals(messageId));
    });
  });

  group('UDP ANNOUNCE roundtrip', () {
    test('Alice creates UDP ANNOUNCE, Bob receives and decodes it', () async {
      final packet = announcePacket(aliceProtocol);

      // Bob's router processes it.
      AnnounceData? receivedAnnounce;
      PeerTransport? receivedTransport;
      bobRouter.onPeerAnnounced =
          (data, transport, {bool isNew = false, String? udpPeerId}) {
        receivedAnnounce = data;
        receivedTransport = transport;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.udp,
        udpPeerId: 'peer-alice-id',
      );

      expect(receivedAnnounce, isNotNull);
      expect(receivedAnnounce!.publicKey, equals(aliceIdentity.publicKey));
      expect(receivedAnnounce!.nickname, equals('Alice'));
      expect(receivedAnnounce!.protocolVersion, equals(1));
      expect(receivedTransport, equals(PeerTransport.udp));

      // Verify Bob's Redux store was updated.
      final peerState =
          bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peerState, isNotNull);
      expect(peerState!.nickname, equals('Alice'));
      expect(peerState.transport, equals(PeerTransport.udp));
    });

    test('UDP ANNOUNCE with address roundtrips correctly', () async {
      const address = '[2001:db8::2]:4001';
      final packet = announcePacket(aliceProtocol, address: address);

      AnnounceData? receivedAnnounce;
      bobRouter.onPeerAnnounced =
          (data, transport, {bool isNew = false, String? udpPeerId}) {
        receivedAnnounce = data;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.udp,
        udpPeerId: 'peer-alice-id',
      );

      expect(receivedAnnounce!.udpAddress, equals(address));
    });
  });

  group('UDP MESSAGE roundtrip (end-to-end via Noise)', () {
    test('Alice sends UDP message, Bob receives it', () async {
      await completeHandshake(
        aliceSessions,
        aliceIdentity.publicKey,
        bobSessions,
        bobIdentity.publicKey,
      );

      final messagePayload = Uint8List.fromList([99, 88, 77]);

      final clear = messagePacket(
        payload: messagePayload,
        messageId: '00000000-0000-4000-8000-000000000004',
        recipientPubkey: bobIdentity.publicKey,
      );
      final sealed = await aliceSessions.encryptPacket(
        clear,
        remotePubkey: bobIdentity.publicKey,
      );

      String? receivedId;
      Uint8List? receivedPayload;
      Uint8List? receivedSender;
      bobRouter.onMessageReceived = (id, sender, payload, _) {
        receivedId = id;
        receivedSender = sender;
        receivedPayload = payload;
      };

      await bobRouter.processPacket(
        sealed,
        transport: PeerTransport.udp,
        udpPeerId: 'peer-alice-id',
      );

      expect(receivedId, isNotNull);
      expect(receivedPayload, equals(messagePayload));
      expect(receivedSender, equals(aliceIdentity.publicKey));
    });
  });

  group('UDP ACK roundtrip (end-to-end via Noise)', () {
    test('Alice sends ACK, Bob receives message ID', () async {
      await completeHandshake(
        aliceSessions,
        aliceIdentity.publicKey,
        bobSessions,
        bobIdentity.publicKey,
      );

      const messageId = '00000000-0000-4000-8000-0000000000bb';

      final clear = aliceProtocol.createAckPacket(
        messageId: messageId,
        recipientPubkey: bobIdentity.publicKey,
      );
      final sealed = await aliceSessions.encryptPacket(
        clear,
        remotePubkey: bobIdentity.publicKey,
      );
      // ACK content type is sealed inside the frame; wire type is opaque secure.
      expect(sealed.type, equals(PacketType.secure));

      String? receivedMessageId;
      bobRouter.onAckReceived = (id) {
        receivedMessageId = id;
      };

      await bobRouter.processPacket(
        sealed,
        transport: PeerTransport.udp,
        udpPeerId: 'peer-alice-id',
      );

      expect(receivedMessageId, equals(messageId));
    });
  });

  group('UDP READ_RECEIPT roundtrip (end-to-end via Noise)', () {
    test('Alice sends read receipt via UDP, Bob receives it', () async {
      await completeHandshake(
        aliceSessions,
        aliceIdentity.publicKey,
        bobSessions,
        bobIdentity.publicKey,
      );

      const messageId = '00000000-0000-4000-8000-0000000000cc';

      final clear = aliceProtocol.createReadReceiptPacket(
        messageId: messageId,
        recipientPubkey: bobIdentity.publicKey,
      );
      final sealed = await aliceSessions.encryptPacket(
        clear,
        remotePubkey: bobIdentity.publicKey,
      );

      String? receivedMessageId;
      bobRouter.onReadReceiptReceived = (id) {
        receivedMessageId = id;
      };

      await bobRouter.processPacket(
        sealed,
        transport: PeerTransport.udp,
        udpPeerId: 'peer-alice-id',
      );

      expect(receivedMessageId, equals(messageId));
    });
  });

  group('BLE dedup across multiple packets', () {
    test('same message replayed is delivered once (nonce/replay rejected)',
        () async {
      await completeHandshake(
        aliceSessions,
        aliceIdentity.publicKey,
        bobSessions,
        bobIdentity.publicKey,
      );

      final messagePayload = Uint8List.fromList([1, 2, 3]);
      final clear = messagePacket(
        payload: messagePayload,
        messageId: '00000000-0000-4000-8000-000000000005',
        recipientPubkey: bobIdentity.publicKey,
      );
      final sealed = await aliceSessions.encryptPacket(
        clear,
        remotePubkey: bobIdentity.publicKey,
      );

      int receiveCount = 0;
      bobRouter.onMessageReceived = (_, __, ___, ____) {
        receiveCount++;
      };

      await bobRouter.processPacket(
        sealed,
        transport: PeerTransport.bleDirect,
        rssi: -50,
      );
      // Replay the exact same sealed packet. The BloomFilter dedups on packetId
      // (and the session's nonce replay-check would also reject it), so Bob
      // delivers it to the app only once.
      await bobRouter.processPacket(
        sealed,
        transport: PeerTransport.bleDirect,
        rssi: -50,
      );

      expect(receiveCount, equals(1));
    });

    test('ANNOUNCE is always processed even if seen before', () async {
      final packet = announcePacket(aliceProtocol);

      int announceCount = 0;
      bobRouter.onPeerAnnounced =
          (_, __, {bool isNew = false, String? udpPeerId}) {
        announceCount++;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        rssi: -50,
      );
      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        rssi: -50,
      );

      expect(announceCount, equals(2));
    });
  });

  group('cross-transport peer discovery', () {
    test('peer announced via BLE then UDP updates transport info', () async {
      // First: Alice announces via BLE.
      final blePacket = announcePacket(aliceProtocol);

      await bobRouter.processPacket(
        blePacket,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        bleRole: BleRole.central,
        rssi: -40,
      );

      var peer = bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peer, isNotNull);
      expect(peer!.transport, equals(PeerTransport.bleDirect));
      expect(peer.bleDeviceId, equals('device-alice'));

      // Then: Alice announces via UDP with address.
      const udpAddr = '[2001:db8::a]:4001';
      final udpPacket = announcePacket(aliceProtocol, address: udpAddr);

      await bobRouter.processPacket(
        udpPacket,
        transport: PeerTransport.udp,
        udpPeerId: 'peer-alice-udp',
      );

      // Peer should now have UDP address too.
      peer = bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peer, isNotNull);
      expect(peer!.udpAddress, equals(udpAddr));
    });
  });

  group('bidirectional communication', () {
    test('Alice and Bob exchange announces and messages', () async {
      // Each peer needs a Noise session with the other before they can exchange
      // sealed application messages.
      await completeHandshake(
        aliceSessions,
        aliceIdentity.publicKey,
        bobSessions,
        bobIdentity.publicKey,
      );

      // Alice announces to Bob.
      await bobRouter.processPacket(
        announcePacket(aliceProtocol),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        rssi: -45,
      );

      // Bob announces to Alice.
      await aliceRouter.processPacket(
        announcePacket(bobProtocol),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-bob',
        rssi: -55,
      );

      // Both stores should know about each other.
      final bobInAliceStore =
          aliceStore.state.peers.getPeerByPubkey(bobIdentity.publicKey);
      final aliceInBobStore =
          bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(bobInAliceStore, isNotNull);
      expect(aliceInBobStore, isNotNull);
      expect(bobInAliceStore!.nickname, equals('Bob'));
      expect(aliceInBobStore!.nickname, equals('Alice'));

      // Alice sends a sealed message to Bob.
      final helloPayload = Uint8List.fromList('hello bob'.codeUnits);
      final aliceMsg = await aliceSessions.encryptPacket(
        messagePacket(
          payload: helloPayload,
          messageId: '00000000-0000-4000-8000-000000000006',
          recipientPubkey: bobIdentity.publicKey,
        ),
        remotePubkey: bobIdentity.publicKey,
      );

      Uint8List? bobReceived;
      Uint8List? bobSawSender;
      bobRouter.onMessageReceived = (_, sender, payload, ___) {
        bobReceived = payload;
        bobSawSender = sender;
      };
      await bobRouter.processPacket(
        aliceMsg,
        transport: PeerTransport.bleDirect,
        rssi: -50,
      );
      expect(bobReceived, equals(helloPayload));
      expect(bobSawSender, equals(aliceIdentity.publicKey));

      // Bob sends a sealed reply to Alice.
      final replyPayload = Uint8List.fromList('hi alice'.codeUnits);
      final bobMsg = await bobSessions.encryptPacket(
        messagePacket(
          payload: replyPayload,
          messageId: '00000000-0000-4000-8000-000000000007',
          recipientPubkey: aliceIdentity.publicKey,
        ),
        remotePubkey: aliceIdentity.publicKey,
      );

      Uint8List? aliceReceived;
      Uint8List? aliceSawSender;
      aliceRouter.onMessageReceived = (_, sender, payload, ___) {
        aliceReceived = payload;
        aliceSawSender = sender;
      };
      await aliceRouter.processPacket(
        bobMsg,
        transport: PeerTransport.bleDirect,
        rssi: -50,
      );
      expect(aliceReceived, equals(replyPayload));
      expect(aliceSawSender, equals(bobIdentity.publicKey));
    });
  });
}
