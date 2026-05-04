import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:cryptography/cryptography.dart';
import 'package:bitchat_transport/src/routing/message_router.dart';
import 'package:bitchat_transport/src/protocol/protocol_handler.dart';
import 'package:bitchat_transport/src/protocol/fragment_handler.dart';
import 'package:bitchat_transport/src/models/identity.dart';
import 'package:bitchat_transport/src/models/packet.dart';
import 'package:bitchat_transport/src/models/peer.dart';
import 'package:bitchat_transport/src/store/store.dart';

/// Helper to create an ANNOUNCE payload:
/// [pubkey(32) + version(2) + nickLen(1) + nick + candidateCount(2) + candidates]
Uint8List buildAnnouncePayload({
  required Uint8List pubkey,
  String nickname = 'OtherPeer',
  String? address,
  Set<String> addressCandidates = const {},
}) {
  final nicknameBytes = Uint8List.fromList(nickname.codeUnits);
  final candidates = <String>{
    if (address != null && address.isNotEmpty) address,
    ...addressCandidates,
  };
  final buffer = BytesBuilder();

  buffer.add(pubkey);

  final versionBytes = ByteData(2);
  versionBytes.setUint16(0, 1, Endian.big);
  buffer.add(versionBytes.buffer.asUint8List());

  buffer.addByte(nicknameBytes.length);
  buffer.add(nicknameBytes);

  final candidateCountBytes = ByteData(2);
  candidateCountBytes.setUint16(0, candidates.length, Endian.big);
  buffer.add(candidateCountBytes.buffer.asUint8List());
  for (final candidate in candidates) {
    final candidateBytes = Uint8List.fromList(candidate.codeUnits);
    final lenBytes = ByteData(2);
    lenBytes.setUint16(0, candidateBytes.length, Endian.big);
    buffer.add(lenBytes.buffer.asUint8List());
    buffer.add(candidateBytes);
  }

  return buffer.toBytes();
}

void main() {
  group('MessageRouter', () {
    late MessageRouter router;
    late Store<AppState> store;
    late BitchatIdentity identity;
    late BitchatIdentity otherIdentity;
    late ProtocolHandler protocolHandler;
    late ProtocolHandler otherProtocolHandler;
    late FragmentHandler fragmentHandler;
    late Uint8List otherPubkey;

    setUp(() async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      identity = await BitchatIdentity.create(
        keyPair: keyPair,
        nickname: 'TestUser',
      );

      final otherKeyPair = await algorithm.newKeyPair();
      otherIdentity = await BitchatIdentity.create(
        keyPair: otherKeyPair,
        nickname: 'OtherPeer',
      );

      store = Store<AppState>(
        appReducer,
        initialState: const AppState(),
      );

      protocolHandler = ProtocolHandler(identity: identity);
      otherProtocolHandler = ProtocolHandler(identity: otherIdentity);
      fragmentHandler = FragmentHandler();

      router = MessageRouter(
        identity: identity,
        store: store,
        protocolHandler: protocolHandler,
        fragmentHandler: fragmentHandler,
      );

      otherPubkey = otherIdentity.publicKey;
    });

    tearDown(() {
      router.dispose();
    });

    /// Create a signed packet from the other peer's perspective.
    /// Must be awaited since signing is async.
    Future<BitchatPacket> signedPacket({
      required PacketType type,
      Uint8List? senderPubkey,
      Uint8List? recipientPubkey,
      Uint8List? payload,
      String? packetId,
      ProtocolHandler? signer,
    }) async {
      final p = BitchatPacket(
        packetId: packetId,
        type: type,
        senderPubkey: senderPubkey ?? otherPubkey,
        recipientPubkey: recipientPubkey,
        payload: payload ?? Uint8List(0),
        signature: Uint8List(64),
      );
      await (signer ?? otherProtocolHandler).signPacket(p);
      return p;
    }

    // =========================================================================
    // Signature Verification
    // =========================================================================

    group('signature verification', () {
      test('drops packet with zero signature (unsigned)', () async {
        bool anyCalled = false;
        router.onMessageReceived = (_, __, ___) => anyCalled = true;
        router.onAckReceived = (_) => anyCalled = true;
        router.onReadReceiptReceived = (_) => anyCalled = true;
        router.onPeerAnnounced = (_, __,
                {bool isNew = false, String? udpPeerId}) =>
            anyCalled = true;

        // Create packet without signing (zero signature)
        final p = BitchatPacket(
          type: PacketType.message,
          senderPubkey: otherPubkey,
          recipientPubkey: identity.publicKey,
          payload: Uint8List.fromList([1, 2, 3]),
          signature: Uint8List(64),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(anyCalled, isFalse);
      });

      test('drops packet with tampered payload', () async {
        bool anyCalled = false;
        router.onMessageReceived = (_, __, ___) => anyCalled = true;

        // Create and sign a valid packet
        final p = await signedPacket(
          type: PacketType.message,
          recipientPubkey: identity.publicKey,
          payload: Uint8List.fromList([1, 2, 3]),
        );

        // Tamper with the payload after signing
        p.payload[0] = 99;

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(anyCalled, isFalse);
      });
    });

    // =========================================================================
    // BLE Packet Processing - ANNOUNCE
    // =========================================================================

    group('processPacket (BLE) - ANNOUNCE', () {
      test('decodes ANNOUNCE and dispatches PeerAnnounceReceivedAction',
          () async {
        final payload =
            buildAnnouncePayload(pubkey: otherPubkey, nickname: 'Alice');
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -55,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.nickname, equals('Alice'));
        expect(peer.rssi, equals(-55));
        expect(peer.transport, equals(PeerTransport.bleDirect));
      });

      test('includes bleDeviceId in dispatch', () async {
        final payload = buildAnnouncePayload(pubkey: otherPubkey);
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          bleDeviceId: 'ble-device-1',
          bleRole: BleRole.central,
          rssi: -60,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.bleDeviceId, equals('ble-device-1'));
      });

      test('resolves BLE announce from scan-discovered service UUID', () async {
        store.dispatch(BleDeviceDiscoveredAction(
          deviceId: 'scan-device-1',
          serviceUuid: BitchatIdentity.deriveServiceUuid(otherPubkey),
          rssi: -48,
        ));

        final payload = buildAnnouncePayload(pubkey: otherPubkey);
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.bleDeviceId, equals('scan-device-1'));
        expect(peer.rssi, equals(-48));
      });

      test('includes udpAddress from ANNOUNCE payload', () async {
        final payload = buildAnnouncePayload(
          pubkey: otherPubkey,
          address: '[2001:db8::a]:4001',
        );
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -50,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(
          peer!.udpAddress,
          equals('[2001:db8::a]:4001'),
        );
      });

      test('preserves IPv4 udpAddress from ANNOUNCE payload', () async {
        final payload = buildAnnouncePayload(
          pubkey: otherPubkey,
          address: '203.0.113.5:4001',
        );
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -50,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.udpAddress, equals('203.0.113.5:4001'));
      });

      test('preserves UDP address candidates from ANNOUNCE payload', () async {
        final payload = buildAnnouncePayload(
          pubkey: otherPubkey,
          address: '[2606:4700::1]:4001',
          addressCandidates: const {
            '[2606:4700::1]:4001',
            '198.51.100.5:4002',
          },
        );
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -50,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(
          peer!.udpAddressCandidates,
          containsAll(const {
            '[2606:4700::1]:4001',
            '198.51.100.5:4002',
          }),
        );
      });

      test('fires onPeerAnnounced callback', () async {
        AnnounceData? receivedData;
        PeerTransport? receivedTransport;
        router.onPeerAnnounced =
            (data, transport, {bool isNew = false, String? udpPeerId}) {
          receivedData = data;
          receivedTransport = transport;
        };

        final payload =
            buildAnnouncePayload(pubkey: otherPubkey, nickname: 'Bob');
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -45,
        );

        expect(receivedData, isNotNull);
        expect(receivedData!.nickname, equals('Bob'));
        expect(receivedTransport, equals(PeerTransport.bleDirect));
      });

      test('always processes ANNOUNCE even if seen before (no dedup)',
          () async {
        final payload =
            buildAnnouncePayload(pubkey: otherPubkey, nickname: 'Charlie');
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
          packetId: '11111111-1111-1111-1111-111111111111',
        );

        int announceCount = 0;
        router.onPeerAnnounced =
            (_, __, {bool isNew = false, String? udpPeerId}) => announceCount++;

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -55,
        );
        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -50,
        );

        expect(announceCount, equals(2));
      });
    });

    // =========================================================================
    // BLE Packet Processing - MESSAGE
    // =========================================================================

    group('processPacket (BLE) - MESSAGE', () {
      test('delivers message addressed to us', () async {
        String? receivedId;
        Uint8List? receivedPubkey;
        Uint8List? receivedPayload;
        router.onMessageReceived = (id, pubkey, payload) {
          receivedId = id;
          receivedPubkey = pubkey;
          receivedPayload = payload;
        };

        final msgPayload = Uint8List.fromList([1, 2, 3, 4, 5]);
        final p = await signedPacket(
          type: PacketType.message,
          recipientPubkey: identity.publicKey,
          payload: msgPayload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(receivedId, isNotNull);
        expect(receivedPubkey, equals(otherPubkey));
        expect(receivedPayload, equals(msgPayload));
      });

      test('delivers broadcast message (no recipient)', () async {
        bool messageReceived = false;
        router.onMessageReceived = (_, __, ___) => messageReceived = true;

        final p = await signedPacket(
          type: PacketType.message,
          recipientPubkey: null,
          payload: Uint8List.fromList([42]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(messageReceived, isTrue);
      });

      test('drops message addressed to someone else', () async {
        bool messageReceived = false;
        router.onMessageReceived = (_, __, ___) => messageReceived = true;

        // Create a third identity for the intended recipient
        final algorithm = Ed25519();
        final thirdKeyPair = await algorithm.newKeyPair();
        final thirdIdentity = await BitchatIdentity.create(
          keyPair: thirdKeyPair,
          nickname: 'ThirdParty',
        );

        final p = await signedPacket(
          type: PacketType.message,
          recipientPubkey: thirdIdentity.publicKey,
          payload: Uint8List.fromList([42]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(messageReceived, isFalse);
      });
    });

    // =========================================================================
    // BLE Packet Processing - Deduplication
    // =========================================================================

    group('processPacket - deduplication', () {
      test('drops duplicate non-ANNOUNCE packets', () async {
        int messageCount = 0;
        router.onMessageReceived = (_, __, ___) => messageCount++;

        final p = await signedPacket(
          type: PacketType.message,
          packetId: '22222222-2222-2222-2222-222222222222',
          recipientPubkey: identity.publicKey,
          payload: Uint8List.fromList([1]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );
        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );
        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(messageCount, equals(1));
      });

      test('markSeen prevents processing of pre-marked packet', () async {
        int messageCount = 0;
        router.onMessageReceived = (_, __, ___) => messageCount++;

        router.markSeen('33333333-3333-3333-3333-333333333333');

        final p = await signedPacket(
          type: PacketType.message,
          packetId: '33333333-3333-3333-3333-333333333333',
          recipientPubkey: identity.publicKey,
          payload: Uint8List.fromList([1]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(messageCount, equals(0));
      });

      test('isDuplicate returns correct results', () {
        expect(router.isDuplicate('never-seen'), isFalse);

        router.markSeen('seen-id');
        expect(router.isDuplicate('seen-id'), isTrue);
      });
    });

    // =========================================================================
    // BLE Packet Processing - Fragments
    // =========================================================================

    group('processPacket - fragments', () {
      test('reassembles fragmented message and delivers', () async {
        Uint8List? reassembledPayload;
        router.onMessageReceived = (_, __, payload) {
          reassembledPayload = payload;
        };

        final payload = Uint8List(1000);
        for (var i = 0; i < payload.length; i++) {
          payload[i] = i % 256;
        }

        final fragmented = fragmentHandler.fragment(
          payload: payload,
          senderPubkey: otherPubkey,
        );

        for (final fragment in fragmented.fragments) {
          // Sign each fragment with the other peer's key
          await otherProtocolHandler.signPacket(fragment);
          await router.processPacket(
            fragment,
            transport: PeerTransport.bleDirect,
            rssi: -60,
          );
        }

        expect(reassembledPayload, isNotNull);
        expect(reassembledPayload, equals(payload));
      });
    });

    // =========================================================================
    // Packet Processing - ACK/NACK
    // =========================================================================

    group('processPacket - ACK/NACK', () {
      test('routes ACK to onAckReceived callback', () async {
        String? receivedMessageId;
        router.onAckReceived = (messageId) => receivedMessageId = messageId;

        const messageId = 'acked-message-id';
        final p = await signedPacket(
          type: PacketType.ack,
          payload: Uint8List.fromList(messageId.codeUnits),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(receivedMessageId, equals(messageId));
      });

      test('NACK is silently ignored', () async {
        bool anyCalled = false;
        router.onMessageReceived = (_, __, ___) => anyCalled = true;
        router.onAckReceived = (_) => anyCalled = true;
        router.onReadReceiptReceived = (_) => anyCalled = true;

        final p = await signedPacket(
          type: PacketType.nack,
          payload: Uint8List(0),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(anyCalled, isFalse);
      });
    });

    // =========================================================================
    // Packet Processing - ReadReceipt
    // =========================================================================

    group('processPacket - readReceipt', () {
      test('routes read receipt to onReadReceiptReceived callback', () async {
        String? receivedMessageId;
        router.onReadReceiptReceived = (id) => receivedMessageId = id;

        const messageId = 'msg-to-read';
        final p = await signedPacket(
          type: PacketType.readReceipt,
          payload: Uint8List.fromList(messageId.codeUnits),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(receivedMessageId, equals(messageId));
      });

      test('ignores read receipt with empty payload', () async {
        String? receivedMessageId;
        router.onReadReceiptReceived = (id) => receivedMessageId = id;

        final p = await signedPacket(
          type: PacketType.readReceipt,
          payload: Uint8List(0),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(receivedMessageId, isNull);
      });
    });

    // =========================================================================
    // UDP Packet Processing - ANNOUNCE
    // =========================================================================

    group('processPacket (UDP) - ANNOUNCE', () {
      test('decodes ANNOUNCE and dispatches to Redux', () async {
        final payload = buildAnnouncePayload(
          pubkey: otherPubkey,
          nickname: 'UdpPeer',
          address: '[2001:db8::1]:4001',
        );
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-123',
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.nickname, equals('UdpPeer'));
        expect(peer.transport, equals(PeerTransport.udp));
        expect(
          peer.udpAddress,
          equals('[2001:db8::1]:4001'),
        );
      });

      test('does not attach scan-discovered BLE ID to UDP ANNOUNCE', () async {
        store.dispatch(BleDeviceDiscoveredAction(
          deviceId: 'scan-device-1',
          serviceUuid: BitchatIdentity.deriveServiceUuid(otherPubkey),
          rssi: -42,
        ));

        final payload = buildAnnouncePayload(
          pubkey: otherPubkey,
          nickname: 'UdpPeer',
          address: '[2001:db8::1]:4001',
        );
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-123',
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.hasBleConnection, isFalse);
        expect(peer.bleDeviceId, isNull);
        expect(peer.rssi, equals(-100));
        expect(store.state.peers.nearbyBlePeers, isEmpty);
      });

      test('does not use peerId as fallback address when not in payload',
          () async {
        // udpPeerId is a hex pubkey, not an ip:port address — it must not
        // be stored as udpAddress.
        final payload = buildAnnouncePayload(
          pubkey: otherPubkey,
          nickname: 'NoPeer',
        );
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'fallback-peer-id',
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.udpAddress, isNull);
      });

      test('fires onPeerAnnounced callback with UDP transport', () async {
        PeerTransport? receivedTransport;
        router.onPeerAnnounced =
            (_, transport, {bool isNew = false, String? udpPeerId}) {
          receivedTransport = transport;
        };

        final payload = buildAnnouncePayload(pubkey: otherPubkey);
        final p = await signedPacket(
          type: PacketType.announce,
          payload: payload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-456',
        );

        expect(receivedTransport, equals(PeerTransport.udp));
      });
    });

    // =========================================================================
    // UDP Packet Processing - MESSAGE
    // =========================================================================

    group('processPacket (UDP) - MESSAGE', () {
      test('delivers message via onMessageReceived', () async {
        String? receivedId;
        Uint8List? receivedPubkey;
        Uint8List? receivedPayload;
        router.onMessageReceived = (id, pubkey, payload) {
          receivedId = id;
          receivedPubkey = pubkey;
          receivedPayload = payload;
        };

        final msgPayload = Uint8List.fromList([10, 20, 30]);
        final p = await signedPacket(
          type: PacketType.message,
          recipientPubkey: identity.publicKey,
          payload: msgPayload,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-789',
        );

        expect(receivedId, isNotNull);
        expect(receivedPubkey, equals(otherPubkey));
        expect(receivedPayload, equals(msgPayload));
      });

      test('marks existing peer as seen over UDP', () async {
        store.dispatch(FriendEstablishedAction(publicKey: otherPubkey));

        final p = await signedPacket(
          type: PacketType.message,
          recipientPubkey: identity.publicKey,
          payload: Uint8List.fromList([9, 8, 7]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-seen-test',
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.lastUdpSeen, isNotNull);
        expect(peer.lastSeen, isNotNull);
      });

      test('triggers onAckRequested with canonical UDP peer id', () async {
        PeerTransport? ackTransport;
        String? ackPeerId;
        String? ackMessageId;
        router.onMessageReceived = (_, __, ___) {};
        router.onAckRequested = (transport, peerId, messageId) {
          ackTransport = transport;
          ackPeerId = peerId;
          ackMessageId = messageId;
        };

        final p = await signedPacket(
          type: PacketType.message,
          recipientPubkey: identity.publicKey,
          payload: Uint8List.fromList([1, 2, 3]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-ack-test',
        );

        expect(ackTransport, equals(PeerTransport.udp));
        expect(
          ackPeerId,
          equals(
            otherPubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          ),
        );
        expect(ackMessageId, equals(p.packetId));
      });

      test('triggers onAckRequested for BLE messages too', () async {
        PeerTransport? ackTransport;
        String? ackPeerId;
        String? ackMessageId;
        router.onMessageReceived = (_, __, ___) {};
        router.onAckRequested = (transport, peerId, messageId) {
          ackTransport = transport;
          ackPeerId = peerId;
          ackMessageId = messageId;
        };

        final p = await signedPacket(
          type: PacketType.message,
          recipientPubkey: identity.publicKey,
          payload: Uint8List.fromList([1, 2, 3]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(ackTransport, equals(PeerTransport.bleDirect));
        expect(ackPeerId, isNull);
        expect(ackMessageId, equals(p.packetId));
      });
    });

    // =========================================================================
    // UDP Packet Processing - ACK
    // =========================================================================

    group('processPacket (UDP) - ACK', () {
      test('delivers ACK via onAckReceived', () async {
        String? receivedId;
        router.onAckReceived = (id) => receivedId = id;

        const messageId = 'ack-msg1';
        final p = await signedPacket(
          type: PacketType.ack,
          payload: Uint8List.fromList(messageId.codeUnits),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-abc',
        );

        expect(receivedId, equals(messageId));
      });
    });

    // =========================================================================
    // UDP Packet Processing - ReadReceipt
    // =========================================================================

    group('processPacket (UDP) - ReadReceipt', () {
      test('delivers read receipt via onReadReceiptReceived', () async {
        String? receivedId;
        router.onReadReceiptReceived = (id) => receivedId = id;

        const messageId = 'rr-msg-1';
        final p = await signedPacket(
          type: PacketType.readReceipt,
          payload: Uint8List.fromList(messageId.codeUnits),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-def',
        );

        expect(receivedId, equals(messageId));
      });
    });

    // =========================================================================
    // Invalid / Malformed Packets
    // =========================================================================

    group('processPacket - invalid/malformed packets', () {
      test('drops packet with wrong sender pubkey length via construction',
          () async {
        // BitchatPacket constructor enforces 32-byte pubkey,
        // so we verify that invalid construction throws
        expect(
          () => BitchatPacket(
            type: PacketType.message,
            senderPubkey: Uint8List(16), // too short
            recipientPubkey: identity.publicKey,
            payload: Uint8List.fromList([1]),
            signature: Uint8List(64),
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('drops packet with wrong signature length via construction',
          () async {
        expect(
          () => BitchatPacket(
            type: PacketType.message,
            senderPubkey: otherPubkey,
            recipientPubkey: identity.publicKey,
            payload: Uint8List.fromList([1]),
            signature: Uint8List(32), // too short, must be 64
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('deserialize rejects data shorter than header size', () {
        expect(
          () => BitchatPacket.deserialize(Uint8List(40)),
          throwsA(isA<FormatException>()),
        );
      });

      test('deserialize rejects data with unknown packet type', () {
        // Build a buffer with headerSize bytes, but with type=0xFF
        final data = Uint8List(BitchatPacket.headerSize);
        data[0] = 0xFF; // unknown type
        expect(
          () => BitchatPacket.deserialize(data),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    // =========================================================================
    // Dispose
    // =========================================================================

    group('dispose', () {
      test('cleans up without errors', () {
        expect(() => router.dispose(), returnsNormally);
      });

      test('double dispose is safe', () {
        router.dispose();
        expect(() => router.dispose(), returnsNormally);
      });
    });
  });
}
