import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:bitchat_transport/src/models/identity.dart';
import 'package:bitchat_transport/src/models/packet.dart';
import 'package:bitchat_transport/src/models/peer.dart';
import 'package:bitchat_transport/src/protocol/protocol_handler.dart';
import 'package:bitchat_transport/src/protocol/fragment_handler.dart';
import 'package:bitchat_transport/src/routing/message_router.dart';
import 'package:bitchat_transport/src/store/store.dart';

void main() {
  late BitchatIdentity aliceIdentity;
  late BitchatIdentity bobIdentity;
  late ProtocolHandler aliceProtocol;
  late ProtocolHandler bobProtocol;
  late MessageRouter aliceRouter;
  late MessageRouter bobRouter;
  late Store<AppState> aliceStore;
  late Store<AppState> bobStore;

  setUp(() async {
    final algorithm = Ed25519();

    final aliceKeyPair = await algorithm.newKeyPair();
    aliceIdentity = await BitchatIdentity.create(
      keyPair: aliceKeyPair,
      nickname: 'Alice',
    );

    final bobKeyPair = await algorithm.newKeyPair();
    bobIdentity = await BitchatIdentity.create(
      keyPair: bobKeyPair,
      nickname: 'Bob',
    );

    aliceStore = Store<AppState>(appReducer, initialState: const AppState());
    bobStore = Store<AppState>(appReducer, initialState: const AppState());

    aliceProtocol = ProtocolHandler(identity: aliceIdentity);
    bobProtocol = ProtocolHandler(identity: bobIdentity);

    aliceRouter = MessageRouter(
      identity: aliceIdentity,
      store: aliceStore,
      protocolHandler: aliceProtocol,
      fragmentHandler: FragmentHandler(),
    );

    bobRouter = MessageRouter(
      identity: bobIdentity,
      store: bobStore,
      protocolHandler: bobProtocol,
      fragmentHandler: FragmentHandler(),
    );
  });

  tearDown(() {
    aliceRouter.dispose();
    bobRouter.dispose();
  });

  group('BLE ANNOUNCE roundtrip', () {
    test('Alice creates ANNOUNCE, Bob receives and decodes it', () async {
      // Alice creates an ANNOUNCE payload
      final announcePayload = aliceProtocol.createAnnouncePayload();

      // Alice wraps it in a BitchatPacket (as BLE transport does)
      final packet = BitchatPacket(
        type: PacketType.announce,
        senderPubkey: aliceIdentity.publicKey,
        payload: announcePayload,
        signature: Uint8List(64),
      );

      // Sign with Alice's key
      await aliceProtocol.signPacket(packet);

      // Bob's router processes the BLE packet
      AnnounceData? receivedAnnounce;
      PeerTransport? receivedTransport;
      bobRouter.onPeerAnnounced = (data, transport, {bool isNew = false}) {
        receivedAnnounce = data;
        receivedTransport = transport;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        rssi: -50,
      );

      // Verify Bob decoded Alice's announce correctly
      expect(receivedAnnounce, isNotNull);
      expect(receivedAnnounce!.publicKey, equals(aliceIdentity.publicKey));
      expect(receivedAnnounce!.nickname, equals('Alice'));
      expect(receivedAnnounce!.protocolVersion, equals(1));
      expect(receivedTransport, equals(PeerTransport.bleDirect));

      // Verify Bob's Redux store was updated
      final peerState = bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peerState, isNotNull);
      expect(peerState!.nickname, equals('Alice'));
      expect(peerState.transport, equals(PeerTransport.bleDirect));
      expect(peerState.rssi, equals(-50));
    });

    test('ANNOUNCE with libp2p address roundtrips correctly', () async {
      const address = '/ip4/192.168.1.1/tcp/4001/p2p/QmHash123';
      final announcePayload = aliceProtocol.createAnnouncePayload(address: address);

      final packet = BitchatPacket(
        type: PacketType.announce,
        senderPubkey: aliceIdentity.publicKey,
        payload: announcePayload,
        signature: Uint8List(64),
      );

      await aliceProtocol.signPacket(packet);

      AnnounceData? receivedAnnounce;
      bobRouter.onPeerAnnounced = (data, transport, {bool isNew = false}) {
        receivedAnnounce = data;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        rssi: -60,
      );

      expect(receivedAnnounce, isNotNull);
      expect(receivedAnnounce!.libp2pAddress, equals(address));

      // Verify libp2p address stored in Redux
      final peerState = bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peerState!.libp2pAddress, equals(address));
    });
  });

  group('BLE MESSAGE roundtrip', () {
    test('Alice sends MESSAGE to Bob, Bob receives it', () async {
      final messagePayload = Uint8List.fromList([10, 20, 30, 40, 50]);

      // Alice creates a message packet targeted at Bob
      final packet = aliceProtocol.createMessagePacket(
        payload: messagePayload,
        recipientPubkey: bobIdentity.publicKey,
      );

      // Sign with Alice's key
      await aliceProtocol.signPacket(packet);

      // Bob's router processes it
      String? receivedId;
      Uint8List? receivedPayload;
      Uint8List? receivedSender;
      bobRouter.onMessageReceived = (id, sender, payload) {
        receivedId = id;
        receivedSender = sender;
        receivedPayload = payload;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        rssi: -70,
      );

      expect(receivedId, isNotNull);
      expect(receivedPayload, equals(messagePayload));
      expect(receivedSender, equals(aliceIdentity.publicKey));
    });

    test('message for someone else is dropped', () async {
      final otherPub = Uint8List.fromList(List.generate(32, (i) => 100 + i));
      final messagePayload = Uint8List.fromList([1, 2, 3]);

      // Alice sends to someone other than Bob
      final packet = aliceProtocol.createMessagePacket(
        payload: messagePayload,
        recipientPubkey: otherPub,
      );

      await aliceProtocol.signPacket(packet);

      bool messageReceived = false;
      bobRouter.onMessageReceived = (_, __, ___) {
        messageReceived = true;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        rssi: -70,
      );

      expect(messageReceived, isFalse);
    });

    test('broadcast message is received by Bob', () async {
      final messagePayload = Uint8List.fromList([5, 6, 7, 8]);

      // Alice sends broadcast (no recipient)
      final packet = aliceProtocol.createMessagePacket(
        payload: messagePayload,
      );

      await aliceProtocol.signPacket(packet);

      Uint8List? receivedPayload;
      bobRouter.onMessageReceived = (_, __, payload) {
        receivedPayload = payload;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        rssi: -70,
      );

      expect(receivedPayload, equals(messagePayload));
    });
  });

  group('BLE READ_RECEIPT roundtrip', () {
    test('Alice sends read receipt, Bob receives message ID', () async {
      const messageId = 'msg-12345678';

      final packet = aliceProtocol.createReadReceiptPacket(
        messageId: messageId,
        recipientPubkey: bobIdentity.publicKey,
      );

      await aliceProtocol.signPacket(packet);

      String? receivedMessageId;
      bobRouter.onReadReceiptReceived = (id) {
        receivedMessageId = id;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.bleDirect,
        rssi: -70,
      );

      expect(receivedMessageId, equals(messageId));
    });
  });

  group('LibP2P ANNOUNCE roundtrip', () {
    test('Alice creates libp2p ANNOUNCE, Bob receives and decodes it', () async {
      final announcePayload = aliceProtocol.createAnnouncePayload();

      final packet = BitchatPacket(
        type: PacketType.announce,
        senderPubkey: aliceIdentity.publicKey,
        payload: announcePayload,
        signature: Uint8List(64),
      );

      await aliceProtocol.signPacket(packet);

      // Bob's router processes it
      AnnounceData? receivedAnnounce;
      PeerTransport? receivedTransport;
      bobRouter.onPeerAnnounced = (data, transport, {bool isNew = false}) {
        receivedAnnounce = data;
        receivedTransport = transport;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.libp2p,
        libp2pPeerId: 'peer-alice-id',
      );

      expect(receivedAnnounce, isNotNull);
      expect(receivedAnnounce!.publicKey, equals(aliceIdentity.publicKey));
      expect(receivedAnnounce!.nickname, equals('Alice'));
      expect(receivedAnnounce!.protocolVersion, equals(1));
      expect(receivedTransport, equals(PeerTransport.libp2p));

      // Verify Bob's Redux store was updated
      final peerState = bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peerState, isNotNull);
      expect(peerState!.nickname, equals('Alice'));
      expect(peerState.transport, equals(PeerTransport.libp2p));
    });

    test('libp2p ANNOUNCE with address roundtrips correctly', () async {
      const address = '/ip6/::1/udp/4001/udx';
      final announcePayload = aliceProtocol.createAnnouncePayload(address: address);

      final packet = BitchatPacket(
        type: PacketType.announce,
        senderPubkey: aliceIdentity.publicKey,
        payload: announcePayload,
        signature: Uint8List(64),
      );

      await aliceProtocol.signPacket(packet);

      AnnounceData? receivedAnnounce;
      bobRouter.onPeerAnnounced = (data, transport, {bool isNew = false}) {
        receivedAnnounce = data;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.libp2p,
        libp2pPeerId: 'peer-alice-id',
      );

      expect(receivedAnnounce!.libp2pAddress, equals(address));
    });
  });

  group('LibP2P MESSAGE roundtrip', () {
    test('Alice sends libp2p message, Bob receives it', () async {
      final messagePayload = Uint8List.fromList([99, 88, 77]);

      final packet = aliceProtocol.createMessagePacket(
        payload: messagePayload,
        recipientPubkey: bobIdentity.publicKey,
      );

      await aliceProtocol.signPacket(packet);

      String? receivedId;
      Uint8List? receivedPayload;
      Uint8List? receivedSender;
      bobRouter.onMessageReceived = (id, sender, payload) {
        receivedId = id;
        receivedSender = sender;
        receivedPayload = payload;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.libp2p,
        libp2pPeerId: 'peer-alice-id',
      );

      expect(receivedId, isNotNull);
      expect(receivedPayload, equals(messagePayload));
      expect(receivedSender, equals(aliceIdentity.publicKey));
    });
  });

  group('LibP2P ACK roundtrip', () {
    test('Alice sends ACK, Bob receives message ID', () async {
      const messageId = 'ack12345';

      final packet = aliceProtocol.createAckPacket(
        messageId: messageId,
        recipientPubkey: bobIdentity.publicKey,
      );

      await aliceProtocol.signPacket(packet);

      String? receivedMessageId;
      bobRouter.onAckReceived = (id) {
        receivedMessageId = id;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.libp2p,
        libp2pPeerId: 'peer-alice-id',
      );

      expect(receivedMessageId, equals(messageId));
    });
  });

  group('LibP2P READ_RECEIPT roundtrip', () {
    test('Alice sends read receipt via libp2p, Bob receives it', () async {
      const messageId = 'rcpt1234';

      final packet = aliceProtocol.createReadReceiptPacket(
        messageId: messageId,
        recipientPubkey: bobIdentity.publicKey,
      );

      await aliceProtocol.signPacket(packet);

      String? receivedMessageId;
      bobRouter.onReadReceiptReceived = (id) {
        receivedMessageId = id;
      };

      await bobRouter.processPacket(
        packet,
        transport: PeerTransport.libp2p,
        libp2pPeerId: 'peer-alice-id',
      );

      expect(receivedMessageId, equals(messageId));
    });
  });

  group('BLE dedup across multiple packets', () {
    test('same packet sent twice is only processed once', () async {
      final messagePayload = Uint8List.fromList([1, 2, 3]);
      final packet = aliceProtocol.createMessagePacket(
        payload: messagePayload,
        recipientPubkey: bobIdentity.publicKey,
      );

      await aliceProtocol.signPacket(packet);

      int receiveCount = 0;
      bobRouter.onMessageReceived = (_, __, ___) {
        receiveCount++;
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

      expect(receiveCount, equals(1));
    });

    test('ANNOUNCE is always processed even if seen before', () async {
      final announcePayload = aliceProtocol.createAnnouncePayload();
      final packet = BitchatPacket(
        type: PacketType.announce,
        senderPubkey: aliceIdentity.publicKey,
        payload: announcePayload,
        signature: Uint8List(64),
      );

      await aliceProtocol.signPacket(packet);

      int announceCount = 0;
      bobRouter.onPeerAnnounced = (_, __, {bool isNew = false}) {
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
    test('peer announced via BLE then libp2p updates transport info', () async {
      // First: Alice announces via BLE
      final bleAnnouncePayload = aliceProtocol.createAnnouncePayload();
      final blePacket = BitchatPacket(
        type: PacketType.announce,
        senderPubkey: aliceIdentity.publicKey,
        payload: bleAnnouncePayload,
        signature: Uint8List(64),
      );
      await aliceProtocol.signPacket(blePacket);

      await bobRouter.processPacket(
        blePacket,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        rssi: -40,
      );

      var peer = bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peer, isNotNull);
      expect(peer!.transport, equals(PeerTransport.bleDirect));
      expect(peer.bleDeviceId, equals('device-alice'));

      // Then: Alice announces via libp2p with address
      const libp2pAddr = '/ip4/10.0.0.1/tcp/4001/p2p/QmAlice';
      final libp2pAnnouncePayload = aliceProtocol.createAnnouncePayload(address: libp2pAddr);
      final libp2pPacket = BitchatPacket(
        type: PacketType.announce,
        senderPubkey: aliceIdentity.publicKey,
        payload: libp2pAnnouncePayload,
        signature: Uint8List(64),
      );
      await aliceProtocol.signPacket(libp2pPacket);

      await bobRouter.processPacket(
        libp2pPacket,
        transport: PeerTransport.libp2p,
        libp2pPeerId: 'peer-alice-libp2p',
      );

      // Peer should now have libp2p address too
      peer = bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(peer, isNotNull);
      expect(peer!.libp2pAddress, equals(libp2pAddr));
    });
  });

  group('bidirectional communication', () {
    test('Alice and Bob exchange announces and messages', () async {
      // Alice announces to Bob
      final aliceAnnouncePayload = aliceProtocol.createAnnouncePayload();
      final aliceAnnouncePacket = BitchatPacket(
        type: PacketType.announce,
        senderPubkey: aliceIdentity.publicKey,
        payload: aliceAnnouncePayload,
        signature: Uint8List(64),
      );
      await aliceProtocol.signPacket(aliceAnnouncePacket);

      await bobRouter.processPacket(
        aliceAnnouncePacket,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-alice',
        rssi: -45,
      );

      // Bob announces to Alice
      final bobAnnouncePayload = bobProtocol.createAnnouncePayload();
      final bobAnnouncePacket = BitchatPacket(
        type: PacketType.announce,
        senderPubkey: bobIdentity.publicKey,
        payload: bobAnnouncePayload,
        signature: Uint8List(64),
      );
      await bobProtocol.signPacket(bobAnnouncePacket);

      await aliceRouter.processPacket(
        bobAnnouncePacket,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'device-bob',
        rssi: -55,
      );

      // Both stores should know about each other
      final bobInAliceStore = aliceStore.state.peers.getPeerByPubkey(bobIdentity.publicKey);
      final aliceInBobStore = bobStore.state.peers.getPeerByPubkey(aliceIdentity.publicKey);
      expect(bobInAliceStore, isNotNull);
      expect(aliceInBobStore, isNotNull);
      expect(bobInAliceStore!.nickname, equals('Bob'));
      expect(aliceInBobStore!.nickname, equals('Alice'));

      // Alice sends message to Bob
      final helloPayload = Uint8List.fromList('hello bob'.codeUnits);
      final aliceMsg = aliceProtocol.createMessagePacket(
        payload: helloPayload,
        recipientPubkey: bobIdentity.publicKey,
      );
      await aliceProtocol.signPacket(aliceMsg);

      Uint8List? bobReceived;
      bobRouter.onMessageReceived = (_, __, payload) {
        bobReceived = payload;
      };
      await bobRouter.processPacket(
        aliceMsg,
        transport: PeerTransport.bleDirect,
        rssi: -50,
      );
      expect(bobReceived, equals(helloPayload));

      // Bob sends message to Alice
      final replyPayload = Uint8List.fromList('hi alice'.codeUnits);
      final bobMsg = bobProtocol.createMessagePacket(
        payload: replyPayload,
        recipientPubkey: aliceIdentity.publicKey,
      );
      await bobProtocol.signPacket(bobMsg);

      Uint8List? aliceReceived;
      aliceRouter.onMessageReceived = (_, __, payload) {
        aliceReceived = payload;
      };
      await aliceRouter.processPacket(
        bobMsg,
        transport: PeerTransport.bleDirect,
        rssi: -50,
      );
      expect(aliceReceived, equals(replyPayload));
    });
  });
}
