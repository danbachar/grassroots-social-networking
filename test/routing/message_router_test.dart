import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:redux/redux.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:uuid/uuid.dart';
import 'package:grassroots_networking/src/routing/message_router.dart';
import 'package:grassroots_networking/src/protocol/protocol_handler.dart';
import 'package:grassroots_networking/src/protocol/fragment_handler.dart';
import 'package:grassroots_networking/src/session/noise_session_manager.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:grassroots_networking/src/models/secure_frame.dart';
import 'package:grassroots_networking/src/models/peer.dart';
import 'package:grassroots_networking/src/store/store.dart';

import '../helpers/sodium_test_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SodiumSumo sodium;
  setUpAll(() async {
    sodium = await initTestSodium();
  });

  group('MessageRouter', () {
    late MessageRouter router;
    late Store<AppState> store;
    late GrassrootsIdentity identity;
    late GrassrootsIdentity otherIdentity;
    late ProtocolHandler protocolHandler;
    late ProtocolHandler otherProtocolHandler;
    late FragmentHandler fragmentHandler;
    late Uint8List otherPubkey;

    // Noise session managers for the two endpoints. The mesh envelope is
    // sender-anonymous, so a message addressed to us must arrive as a
    // session-encrypted `PacketType.secure` packet (whose plaintext is a
    // SecureFrame) and be opened by trial-decrypt. We wire [router.trialDecrypt]
    // to our own manager and seal packets with the other peer's manager after a
    // real handshake.
    late NoiseSessionManager sessions;
    late NoiseSessionManager otherSessions;

    setUp(() async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      identity = await GrassrootsIdentity.create(
        keyPair: keyPair,
        nickname: 'TestUser',
      );

      final otherKeyPair = await algorithm.newKeyPair();
      otherIdentity = await GrassrootsIdentity.create(
        keyPair: otherKeyPair,
        nickname: 'OtherPeer',
      );

      store = Store<AppState>(
        appReducer,
        initialState: const AppState(),
      );

      protocolHandler = ProtocolHandler(identity: identity, sodium: sodium);
      otherProtocolHandler =
          ProtocolHandler(identity: otherIdentity, sodium: sodium);
      fragmentHandler = FragmentHandler();

      router = MessageRouter(
        identity: identity,
        store: store,
        protocolHandler: protocolHandler,
        fragmentHandler: fragmentHandler,
      );

      otherPubkey = otherIdentity.publicKey;

      sessions = NoiseSessionManager(identity: identity, sodium: sodium);
      otherSessions = NoiseSessionManager(identity: otherIdentity, sodium: sodium);
      // The router opens inbound sealed packets via trial-decrypt against our
      // live sessions — exactly how the coordinator wires it in production.
      router.trialDecrypt = sessions.trialDecrypt;
    });

    tearDown(() {
      router.dispose();
      sessions.dispose();
      otherSessions.dispose();
    });

    /// Build a (verified) ANNOUNCE packet for [handler]'s own identity. The
    /// payload is self-signed by [createAnnouncePayload]; the router verifies it
    /// in [decodeAnnounce].
    GrassrootsPacket announcePacket(
      ProtocolHandler handler, {
      String? address,
      String? linkLocalAddress,
      Iterable<String> addressCandidates = const [],
      String? packetId,
    }) {
      return GrassrootsPacket(
        type: PacketType.announce,
        packetId: packetId,
        payload: handler.createAnnouncePayload(
          address: address,
          linkLocalAddress: linkLocalAddress,
          addressCandidates: addressCandidates,
        ),
      );
    }

    /// Drive a full Noise XX handshake so [otherSessions] (initiator, sender)
    /// and [sessions] (responder, us) share a session keyed by each other's
    /// pubkey. After this, [otherSessions.encryptPacket] produces a sealed
    /// packet that [router.trialDecrypt] (our [sessions]) can open.
    Future<void> establishSession() async {
      final m1 = await otherSessions.startHandshake(identity.publicKey);
      final r1 = await sessions.handleHandshakePacket(
        GrassrootsPacket(type: PacketType.noiseHandshake, payload: m1!),
        remotePubkey: otherPubkey,
      );
      final r2 = await otherSessions.handleHandshakePacket(
        GrassrootsPacket(
            type: PacketType.noiseHandshake, payload: r1.responsePayload!),
        remotePubkey: identity.publicKey,
      );
      await sessions.handleHandshakePacket(
        GrassrootsPacket(
            type: PacketType.noiseHandshake, payload: r2.responsePayload!),
        remotePubkey: otherPubkey,
      );
      expect(sessions.hasSession(otherPubkey), isTrue);
      expect(otherSessions.hasSession(identity.publicKey), isTrue);
    }

    /// Seal a content frame from the other peer to us. Requires a prior
    /// [establishSession].
    ///
    /// Content type + fragmentation now live *inside* the sealed payload as a
    /// [SecureFrame]; the wire packet is always [PacketType.secure]. [chunk] is
    /// the frame's chunk bytes (e.g. the message body, or the UTF-8 acked
    /// messageId for ack/readReceipt). [frameMessageId] is the logical id echoed
    /// in ACKs and must be a valid UUID.
    Future<GrassrootsPacket> sealedFromOther({
      ContentType contentType = ContentType.message,
      required Uint8List chunk,
      String? frameMessageId,
      String? packetId,
      Uint8List? recipientPubkey,
    }) {
      final frame = SecureFrame(
        contentType: contentType,
        messageId: frameMessageId ?? const Uuid().v4(),
        chunk: chunk,
      );
      final clear = GrassrootsPacket(
        type: PacketType.secure,
        packetId: packetId,
        recipientPubkey: recipientPubkey ?? identity.publicKey,
        payload: frame.encode(),
      );
      return otherSessions.encryptPacket(clear, remotePubkey: identity.publicKey);
    }

    // =========================================================================
    // ANNOUNCE authentication (self-signed payload)
    // =========================================================================
    //
    // Whole-packet sign/verify is gone — the only signed thing left is the
    // ANNOUNCE payload. These replace the old "drops unsigned/tampered packet"
    // tests with the new analog: a forged or tampered ANNOUNCE fails the
    // embedded-signature check in decodeAnnounce and is dropped.

    group('ANNOUNCE authentication', () {
      test('drops ANNOUNCE whose self-signature does not verify', () async {
        bool announced = false;
        router.onPeerAnnounced =
            (_, __, {bool isNew = false, String? udpPeerId}) =>
                announced = true;

        // Tamper the trailing signature bytes of a valid payload.
        final payload = otherProtocolHandler.createAnnouncePayload();
        payload[payload.length - 1] ^= 0xFF;
        final p = GrassrootsPacket(type: PacketType.announce, payload: payload);

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(announced, isFalse);
        expect(store.state.peers.getPeerByPubkey(otherPubkey), isNull);
      });

      test('drops ANNOUNCE whose body was tampered after signing', () async {
        bool announced = false;
        router.onPeerAnnounced =
            (_, __, {bool isNew = false, String? udpPeerId}) =>
                announced = true;

        // Flip a body byte (the protocol version) — the signature no longer
        // matches.
        final payload = otherProtocolHandler.createAnnouncePayload();
        payload[33] ^= 0xFF;
        final p = GrassrootsPacket(type: PacketType.announce, payload: payload);

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(announced, isFalse);
      });
    });

    // =========================================================================
    // BLE Packet Processing - ANNOUNCE
    // =========================================================================

    group('processPacket (BLE) - ANNOUNCE', () {
      test('can reject verified BLE ANNOUNCE before peer state is created',
          () async {
        String? rejectedDeviceId;
        router.shouldAcceptBleAnnounce =
            (_, {String? bleDeviceId, BleRole? bleRole}) => false;
        router.onBleAnnounceRejected = (_, bleDeviceId) {
          rejectedDeviceId = bleDeviceId;
        };

        final p = announcePacket(otherProtocolHandler);

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          bleDeviceId: 'central:test',
          rssi: -55,
        );

        expect(store.state.peers.getPeerByPubkey(otherPubkey), isNull);
        expect(rejectedDeviceId, equals('central:test'));
      });

      test('decodes ANNOUNCE and dispatches PeerAnnounceReceivedAction',
          () async {
        final p = announcePacket(otherProtocolHandler);

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -55,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.nickname, equals('OtherPeer'));
        expect(peer.rssi, equals(-55));
        expect(peer.transport, equals(PeerTransport.bleDirect));
      });

      test('includes bleDeviceId in dispatch', () async {
        final p = announcePacket(otherProtocolHandler);

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

      test('uses scan RSSI when BLE announce arrives without payload RSSI',
          () async {
        store.dispatch(BleDeviceDiscoveredAction(
          deviceId: 'scan-device-1',
          rssi: -42,
        ));

        final p = announcePacket(otherProtocolHandler);

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          bleDeviceId: 'scan-device-1',
          bleRole: BleRole.central,
          rssi: null,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.bleDeviceId, equals('scan-device-1'));
        expect(peer.rssi, equals(-42));
      });

      test('keeps peripheral-only RSSI as null', () async {
        final p = announcePacket(otherProtocolHandler);

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          bleDeviceId: 'peripheral:central-1',
          bleRole: BleRole.peripheral,
          rssi: null,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.hasBleConnection, isTrue);
        expect(peer.blePeripheralDeviceId, equals('peripheral:central-1'));
        expect(peer.rssi, isNull);
      });

      test('includes udpAddress from ANNOUNCE payload', () async {
        final p = announcePacket(
          otherProtocolHandler,
          address: '[2001:db8::a]:4001',
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
        final p = announcePacket(
          otherProtocolHandler,
          address: '203.0.113.5:4001',
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
        final p = announcePacket(
          otherProtocolHandler,
          address: '[2606:4700::1]:4001',
          addressCandidates: const [
            '[2606:4700::1]:4001',
            '198.51.100.5:4002',
          ],
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

        final p = announcePacket(otherProtocolHandler);

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          rssi: -45,
        );

        expect(receivedData, isNotNull);
        expect(receivedData!.nickname, equals('OtherPeer'));
        expect(receivedTransport, equals(PeerTransport.bleDirect));
      });

      test('always processes ANNOUNCE even if seen before (no dedup)',
          () async {
        final p = announcePacket(
          otherProtocolHandler,
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
    // BLE Packet Processing - MESSAGE (session-encrypted, sender-anonymous)
    // =========================================================================

    group('processPacket (BLE) - MESSAGE', () {
      test('delivers message addressed to us', () async {
        await establishSession();

        String? receivedId;
        Uint8List? receivedPubkey;
        Uint8List? receivedPayload;
        PeerTransport? receivedTransport;
        router.onMessageReceived = (id, pubkey, payload, transport) {
          receivedId = id;
          receivedPubkey = pubkey;
          receivedPayload = payload;
          receivedTransport = transport;
        };

        const messageId = '00000000-0000-4000-8000-000000000001';
        final msgPayload = Uint8List.fromList([1, 2, 3, 4, 5]);
        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          frameMessageId: messageId,
          chunk: msgPayload,
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(receivedId, equals(messageId));
        expect(receivedPubkey, equals(otherPubkey));
        expect(receivedPayload, equals(msgPayload));
        expect(receivedTransport, equals(PeerTransport.bleDirect));
      });

      test(
          'delivers a single-packet message whose outer packetId EQUALS its '
          'frame messageId (production wire shape)', () async {
        // Regression: ProtocolHandler.createMessagePacket sets the outer
        // packetId equal to the frame's messageId for a non-fragmented message.
        // The router deduplicates wire packets (packetId) and message delivery
        // (messageId) in SEPARATE bloom filters; if they shared one, the
        // relay/loop insert of packetId would poison the delivery check and the
        // message would be dropped as a "duplicate" on first receipt — ACKed
        // but never delivered. This asserts the first receipt is delivered.
        await establishSession();

        int deliveries = 0;
        String? receivedId;
        router.onMessageReceived = (id, _, __, ___) {
          deliveries++;
          receivedId = id;
        };
        final ackRequests = <String>[];
        router.onAckRequested =
            (_, messageId, __) => ackRequests.add(messageId);

        const messageId = '00000000-0000-4000-8000-0000000000aa';
        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          frameMessageId: messageId,
          packetId: messageId, // production: packetId == messageId
          chunk: Uint8List.fromList([9, 9, 9]),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(deliveries, equals(1),
            reason: 'first receipt must be delivered, not treated as duplicate');
        expect(receivedId, equals(messageId));
        expect(ackRequests, equals([messageId]));
      });

      test('a relay-mutated ttl still trial-decrypts (AAD excludes ttl)',
          () async {
        await establishSession();

        Uint8List? receivedPayload;
        router.onMessageReceived = (_, __, payload, ___) {
          receivedPayload = payload;
        };

        final msgPayload = Uint8List.fromList([7, 7, 7]);
        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          chunk: msgPayload,
        );

        // A relay on the path decremented the TTL before it reached us. AAD
        // excludes ttl, so the AEAD tag must still verify.
        await router.processPacket(
          sealed.decrementTtl(),
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(receivedPayload, equals(msgPayload));
      });

      test('reports the authoritative arrival transport (UDP)', () async {
        await establishSession();

        PeerTransport? receivedTransport;
        router.onMessageReceived = (_, __, ___, transport) {
          receivedTransport = transport;
        };

        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          chunk: Uint8List.fromList([9, 9, 9]),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-xyz',
        );

        expect(receivedTransport, equals(PeerTransport.udp));
      });

      test('does not overwrite known RSSI when payload RSSI is null', () async {
        await establishSession();

        store.dispatch(PeerAnnounceReceivedAction(
          publicKey: otherPubkey,
          nickname: 'Alice',
          rssi: -44,
          bleCentralDeviceId: 'central:peer-1',
        ));

        router.onMessageReceived = (_, __, ___, ____) {};

        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          chunk: Uint8List.fromList([42]),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: null,
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.rssi, equals(-44));
      });

      test('drops sealed message we have no session to open', () async {
        // No session established and trialDecrypt finds nothing — the packet is
        // addressed to us but unreadable, so it is dropped (no delivery).
        await establishSession();

        bool messageReceived = false;
        router.onMessageReceived = (_, __, ___, ____) => messageReceived = true;

        // Seal toward a third party using a *different* manager whose session we
        // don't hold: build a foreign session that we cannot open.
        final algorithm = Ed25519();
        final strangerKeyPair = await algorithm.newKeyPair();
        final stranger = await GrassrootsIdentity.create(
          keyPair: strangerKeyPair,
          nickname: 'Stranger',
        );
        final strangerSessions =
            NoiseSessionManager(identity: stranger, sodium: sodium);
        // Stranger handshakes with the *other* peer, not us.
        final m1 = await strangerSessions.startHandshake(otherPubkey);
        final r1 = await otherSessions.handleHandshakePacket(
          GrassrootsPacket(type: PacketType.noiseHandshake, payload: m1!),
          remotePubkey: stranger.publicKey,
        );
        final r2 = await strangerSessions.handleHandshakePacket(
          GrassrootsPacket(
              type: PacketType.noiseHandshake, payload: r1.responsePayload!),
          remotePubkey: otherPubkey,
        );
        await otherSessions.handleHandshakePacket(
          GrassrootsPacket(
              type: PacketType.noiseHandshake, payload: r2.responsePayload!),
          remotePubkey: stranger.publicKey,
        );

        // Stranger seals a message to us — but we share no session with the
        // stranger, so our trial-decrypt cannot open it.
        final frame = SecureFrame(
          contentType: ContentType.message,
          messageId: const Uuid().v4(),
          chunk: Uint8List.fromList([1, 2, 3]),
        );
        final clear = GrassrootsPacket(
          type: PacketType.secure,
          recipientPubkey: identity.publicKey,
          payload: frame.encode(),
        );
        final sealed = await strangerSessions.encryptPacket(
          clear,
          remotePubkey: otherPubkey,
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(messageReceived, isFalse);
        strangerSessions.dispose();
      });

      test('drops unsealed (unauthenticated) secure packet addressed to us',
          () async {
        // A `secure` packet whose payload is a plaintext SecureFrame that was
        // never sealed under a Noise session is unauthenticated — trial-decrypt
        // finds no session that opens it, so the router refuses to deliver it.
        await establishSession();

        bool messageReceived = false;
        router.onMessageReceived = (_, __, ___, ____) => messageReceived = true;

        final frame = SecureFrame(
          contentType: ContentType.message,
          messageId: const Uuid().v4(),
          chunk: Uint8List.fromList([42]),
        );
        final p = GrassrootsPacket(
          type: PacketType.secure,
          recipientPubkey: identity.publicKey,
          payload: frame.encode(),
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
    // Managed flooding (relay) + DTN
    // =========================================================================

    group('processPacket - managed flooding (relay)', () {
      test('relays a sealed packet not addressed to us with ttl>1', () async {
        GrassrootsPacket? relayed;
        String? excluded;
        router.onRelay = (packet, {String? excludeBlePeerId}) {
          relayed = packet;
          excluded = excludeBlePeerId;
        };
        // We hold no session, so even if it were addressed to us we couldn't
        // open it — but it isn't ours, so it must be forwarded blindly.
        router.onMessageReceived = (_, __, ___, ____) =>
            fail('a packet not addressed to us must not be delivered');

        final thirdParty = Uint8List.fromList(List.generate(32, (i) => i + 1));
        final p = GrassrootsPacket(
          type: PacketType.secure,
          ttl: 5,
          recipientPubkey: thirdParty,
          payload: Uint8List.fromList([9, 9, 9]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          bleDeviceId: 'inbound-leg',
          rssi: -60,
        );

        expect(relayed, isNotNull);
        // TTL decremented for the next hop.
        expect(relayed!.ttl, equals(4));
        expect(relayed!.packetId, equals(p.packetId));
        // The inbound BLE leg is excluded from the rebroadcast.
        expect(excluded, equals('inbound-leg'));
      });

      test('does not relay a packet whose ttl has reached 1', () async {
        bool relayed = false;
        router.onRelay = (_, {String? excludeBlePeerId}) => relayed = true;

        final thirdParty = Uint8List.fromList(List.generate(32, (i) => i + 1));
        final p = GrassrootsPacket(
          type: PacketType.secure,
          ttl: 1,
          recipientPubkey: thirdParty,
          payload: Uint8List.fromList([1]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          bleDeviceId: 'inbound-leg',
          rssi: -60,
        );

        expect(relayed, isFalse);
      });

      test('relays a packet only on first sighting (dedup prevents loops)',
          () async {
        int relayCount = 0;
        router.onRelay = (_, {String? excludeBlePeerId}) => relayCount++;

        final thirdParty = Uint8List.fromList(List.generate(32, (i) => i + 1));
        final p = GrassrootsPacket(
          type: PacketType.secure,
          ttl: 5,
          recipientPubkey: thirdParty,
          payload: Uint8List.fromList([2]),
        );

        await router.processPacket(p,
            transport: PeerTransport.bleDirect, bleDeviceId: 'leg', rssi: -60);
        await router.processPacket(p,
            transport: PeerTransport.bleDirect, bleDeviceId: 'leg', rssi: -60);

        expect(relayCount, equals(1));
      });

      test('custody is kept per recipient and ends on removeCustody',
          () async {
        router.onRelay = (packet, {String? excludeBlePeerId}) {};

        final thirdParty = Uint8List.fromList(List.generate(32, (i) => i + 7));
        final p = GrassrootsPacket(
          type: PacketType.secure,
          ttl: 5,
          recipientPubkey: thirdParty,
          payload: Uint8List.fromList([3]),
        );

        // Recipient is not a reachable peer -> first sighting relays AND the
        // sealed packet enters custody, retrievable per recipient.
        await router.processPacket(p,
            transport: PeerTransport.bleDirect, bleDeviceId: 'leg', rssi: -60);
        expect(router.custodyFor(thirdParty).map((c) => c.packetId),
            contains(p.packetId));

        // The end-to-end ACK ends custody.
        router.removeCustody([p.packetId]);
        expect(router.custodyFor(thirdParty), isEmpty);
      });
    });

    // =========================================================================
    // BLE Packet Processing - Deduplication
    // =========================================================================

    group('processPacket - deduplication', () {
      test('drops duplicate messages (delivers once)', () async {
        await establishSession();

        int messageCount = 0;
        router.onMessageReceived = (_, __, ___, ____) => messageCount++;

        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          packetId: '22222222-2222-2222-2222-222222222222',
          chunk: Uint8List.fromList([1]),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );
        // A second copy of the *same* sealed bytes is rejected by the session
        // (nonce replay) — trial-decrypt returns null, so no second delivery.
        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(messageCount, equals(1));
      });

      test('markSeen prevents relay of a pre-marked packet', () async {
        bool relayed = false;
        router.onRelay = (_, {String? excludeBlePeerId}) => relayed = true;

        router.markSeen('33333333-3333-3333-3333-333333333333');

        final thirdParty = Uint8List.fromList(List.generate(32, (i) => i + 3));
        final p = GrassrootsPacket(
          type: PacketType.secure,
          ttl: 5,
          packetId: '33333333-3333-3333-3333-333333333333',
          recipientPubkey: thirdParty,
          payload: Uint8List.fromList([1]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          bleDeviceId: 'leg',
          rssi: -60,
        );

        expect(relayed, isFalse);
      });

      test('isDuplicate returns correct results', () {
        expect(router.isDuplicate('never-seen'), isFalse);

        router.markSeen('seen-id');
        expect(router.isDuplicate('seen-id'), isTrue);
      });

      test(
          'duplicate MESSAGE re-ACKs without re-firing onMessageReceived. '
          'This is what stops the sender\'s watchdog from looping forever '
          'when its original ACK was lost.', () async {
        await establishSession();

        int deliveries = 0;
        final ackRequests = <String>[];
        router.onMessageReceived = (_, __, ___, ____) => deliveries++;
        // onAckRequested(senderPubkey, messageId, transport)
        router.onAckRequested =
            (senderPubkey, messageId, _) => ackRequests.add(messageId);

        const messageId = '44444444-4444-4444-4444-444444444444';
        // The recipient dedups deliveries on the logical message id (the frame's
        // messageId). Three *distinct wire copies* (distinct outer packetIds)
        // carry the same logical frame.messageId — modelling one message
        // re-flooded via three relay paths. Each is a fresh AEAD seal (distinct
        // nonce) so all three trial-decrypt, but only the first is delivered.
        final first = await sealedFromOther(
          contentType: ContentType.message,
          frameMessageId: messageId,
          chunk: Uint8List.fromList([1]),
        );
        final second = await sealedFromOther(
          contentType: ContentType.message,
          frameMessageId: messageId,
          chunk: Uint8List.fromList([1]),
        );
        final third = await sealedFromOther(
          contentType: ContentType.message,
          frameMessageId: messageId,
          chunk: Uint8List.fromList([1]),
        );

        await router.processPacket(first,
            transport: PeerTransport.bleDirect, rssi: -60);
        await router.processPacket(second,
            transport: PeerTransport.bleDirect, rssi: -60);
        await router.processPacket(third,
            transport: PeerTransport.bleDirect, rssi: -60);

        expect(deliveries, equals(1),
            reason: 'Recipient must not double-deliver to the app.');
        expect(ackRequests, hasLength(3),
            reason:
                'Recipient must re-ACK every duplicate so the sender can stop '
                'retrying.');
        expect(ackRequests, everyElement(messageId));
      });
    });

    // =========================================================================
    // BLE Packet Processing - Fragments
    // =========================================================================

    group('processPacket - fragments', () {
      test('reassembles fragmented message and delivers', () async {
        await establishSession();

        Uint8List? reassembledPayload;
        Uint8List? reassembledSender;
        router.onMessageReceived = (_, sender, payload, ___) {
          reassembledSender = sender;
          reassembledPayload = payload;
        };

        final payload = Uint8List(1000);
        for (var i = 0; i < payload.length; i++) {
          payload[i] = i % 256;
        }

        const messageId = '55555555-5555-4555-8555-555555555555';
        // A >320-byte payload fragments into several SecureFrames sharing one
        // logical messageId. Each is sealed into its own secure packet and
        // trial-decrypted on our side before the router reassembles by
        // frame.messageId.
        final frames = fragmentHandler.framesFor(
          payload: payload,
          messageId: messageId,
        );
        expect(frames.length, greaterThan(1),
            reason: 'A 1000-byte payload must span multiple fragments.');

        for (final frame in frames) {
          final clear = GrassrootsPacket(
            type: PacketType.secure,
            recipientPubkey: identity.publicKey,
            payload: frame.encode(),
          );
          final sealed = await otherSessions.encryptPacket(
            clear,
            remotePubkey: identity.publicKey,
          );
          await router.processPacket(
            sealed,
            transport: PeerTransport.bleDirect,
            rssi: -60,
          );
        }

        expect(reassembledPayload, isNotNull);
        expect(reassembledPayload, equals(payload));
        expect(reassembledSender, equals(otherPubkey));
      });
    });

    // =========================================================================
    // Packet Processing - ACK / non-message content demux
    // =========================================================================

    group('processPacket - ACK', () {
      test('routes ACK to onAckReceived callback', () async {
        await establishSession();

        String? receivedMessageId;
        router.onAckReceived = (messageId) => receivedMessageId = messageId;

        const messageId = 'acked-message-id';
        final sealed = await sealedFromOther(
          contentType: ContentType.ack,
          chunk: Uint8List.fromList(utf8.encode(messageId)),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(receivedMessageId, equals(messageId));
      });

      // NACK was removed from ContentType; the surviving non-message/non-ack/
      // non-readReceipt content type is `signaling`. A signaling frame must be
      // demuxed to onSignalingReceived only — it must NOT spuriously fire the
      // message / ack / read-receipt handlers.
      test('signaling content does not fire message/ack/readReceipt handlers',
          () async {
        await establishSession();

        bool wrongHandlerCalled = false;
        router.onMessageReceived = (_, __, ___, ____) =>
            wrongHandlerCalled = true;
        router.onAckReceived = (_) => wrongHandlerCalled = true;
        router.onReadReceiptReceived = (_) => wrongHandlerCalled = true;

        Uint8List? signalingChunk;
        router.onSignalingReceived =
            (_, chunk, {String? observedIp, int? observedPort}) =>
                signalingChunk = chunk;

        final sig = Uint8List.fromList([0xAA, 0xBB, 0xCC]);
        final sealed = await sealedFromOther(
          contentType: ContentType.signaling,
          chunk: sig,
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(wrongHandlerCalled, isFalse);
        expect(signalingChunk, equals(sig));
      });
    });

    // =========================================================================
    // Packet Processing - ReadReceipt
    // =========================================================================

    group('processPacket - readReceipt', () {
      test('routes read receipt to onReadReceiptReceived callback', () async {
        await establishSession();

        String? receivedMessageId;
        router.onReadReceiptReceived = (id) => receivedMessageId = id;

        const messageId = 'msg-to-read';
        final sealed = await sealedFromOther(
          contentType: ContentType.readReceipt,
          chunk: Uint8List.fromList(utf8.encode(messageId)),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(receivedMessageId, equals(messageId));
      });

      test('ignores read receipt with empty payload', () async {
        await establishSession();

        String? receivedMessageId;
        router.onReadReceiptReceived = (id) => receivedMessageId = id;

        final sealed = await sealedFromOther(
          contentType: ContentType.readReceipt,
          chunk: Uint8List(0),
        );

        await router.processPacket(
          sealed,
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
        final p = announcePacket(
          otherProtocolHandler,
          address: '[2001:db8::1]:4001',
        );

        await router.processPacket(
          p,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-123',
        );

        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.nickname, equals('OtherPeer'));
        expect(peer.transport, equals(PeerTransport.udp));
        expect(
          peer.udpAddress,
          equals('[2001:db8::1]:4001'),
        );
      });

      test('does not attach scan-discovered BLE ID to UDP ANNOUNCE', () async {
        store.dispatch(BleDeviceDiscoveredAction(
          deviceId: 'scan-device-1',
          rssi: -42,
        ));

        final p = announcePacket(
          otherProtocolHandler,
          address: '[2001:db8::1]:4001',
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
        // UDP-only peer has no BLE link, so rssi is null.
        expect(peer.rssi, isNull);
        expect(store.state.peers.nearbyBlePeers, isEmpty);
      });

      test('does not use peerId as fallback address when not in payload',
          () async {
        // udpPeerId is a hex pubkey, not an ip:port address — it must not
        // be stored as udpAddress.
        final p = announcePacket(otherProtocolHandler);

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

        final p = announcePacket(otherProtocolHandler);

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
        await establishSession();

        String? receivedId;
        Uint8List? receivedPubkey;
        Uint8List? receivedPayload;
        router.onMessageReceived = (id, pubkey, payload, _) {
          receivedId = id;
          receivedPubkey = pubkey;
          receivedPayload = payload;
        };

        const messageId = '66666666-6666-4666-8666-666666666666';
        final msgPayload = Uint8List.fromList([10, 20, 30]);
        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          frameMessageId: messageId,
          chunk: msgPayload,
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-789',
        );

        expect(receivedId, equals(messageId));
        expect(receivedPubkey, equals(otherPubkey));
        expect(receivedPayload, equals(msgPayload));
      });

      test('identifies UDP peer and marks it seen on a verified message',
          () async {
        await establishSession();

        // The peer must already exist in the store for its UDP freshness to be
        // bumped (PeerUdpSeenAction is a no-op for unknown peers).
        store.dispatch(FriendEstablishedAction(publicKey: otherPubkey));

        Uint8List? identifiedPubkey;
        String? identifiedPeerId;
        router.onMessageReceived = (_, __, ___, ____) {};
        router.onUdpPeerIdentified = (pubkey, peerId) {
          identifiedPubkey = pubkey;
          identifiedPeerId = peerId;
        };

        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          chunk: Uint8List.fromList([9, 8, 7]),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-seen-test',
        );

        // Sender recovered by trial-decrypt is surfaced to the coordinator and
        // the peer's UDP freshness is bumped in Redux.
        expect(identifiedPubkey, equals(otherPubkey));
        expect(identifiedPeerId, equals('peer-seen-test'));
        final peer = store.state.peers.getPeerByPubkey(otherPubkey);
        expect(peer, isNotNull);
        expect(peer!.lastUdpSeen, isNotNull);
      });

      test('triggers onAckRequested with the recovered sender over UDP',
          () async {
        await establishSession();

        Uint8List? ackSender;
        String? ackMessageId;
        PeerTransport? ackTransport;
        router.onMessageReceived = (_, __, ___, ____) {};
        router.onAckRequested = (senderPubkey, messageId, transport) {
          ackSender = senderPubkey;
          ackMessageId = messageId;
          ackTransport = transport;
        };

        const messageId = '77777777-7777-4777-8777-777777777777';
        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          frameMessageId: messageId,
          chunk: Uint8List.fromList([1, 2, 3]),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-ack-test',
        );

        // The ACK is addressed back to the recovered sender (recipient-anonymous
        // mesh: there is no inbound path to reply on), not to a transport peer
        // id. The acked id is the frame's logical messageId, recovered on
        // decrypt.
        expect(ackSender, equals(otherPubkey));
        expect(ackMessageId, equals(messageId));
        expect(ackTransport, equals(PeerTransport.udp));
      });

      test('triggers onAckRequested for BLE messages too', () async {
        await establishSession();

        Uint8List? ackSender;
        String? ackMessageId;
        PeerTransport? ackTransport;
        router.onMessageReceived = (_, __, ___, ____) {};
        router.onAckRequested = (senderPubkey, messageId, transport) {
          ackSender = senderPubkey;
          ackMessageId = messageId;
          ackTransport = transport;
        };

        const messageId = '88888888-8888-4888-8888-888888888888';
        final sealed = await sealedFromOther(
          contentType: ContentType.message,
          frameMessageId: messageId,
          chunk: Uint8List.fromList([1, 2, 3]),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.bleDirect,
          rssi: -60,
        );

        expect(ackSender, equals(otherPubkey));
        expect(ackMessageId, equals(messageId));
        expect(ackTransport, equals(PeerTransport.bleDirect));
      });
    });

    // =========================================================================
    // UDP Packet Processing - ACK
    // =========================================================================

    group('processPacket (UDP) - ACK', () {
      test('delivers ACK via onAckReceived', () async {
        await establishSession();

        String? receivedId;
        router.onAckReceived = (id) => receivedId = id;

        const messageId = 'ack-msg1';
        final sealed = await sealedFromOther(
          contentType: ContentType.ack,
          chunk: Uint8List.fromList(utf8.encode(messageId)),
        );

        await router.processPacket(
          sealed,
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
        await establishSession();

        String? receivedId;
        router.onReadReceiptReceived = (id) => receivedId = id;

        const messageId = 'rr-msg-1';
        final sealed = await sealedFromOther(
          contentType: ContentType.readReceipt,
          chunk: Uint8List.fromList(utf8.encode(messageId)),
        );

        await router.processPacket(
          sealed,
          transport: PeerTransport.udp,
          udpPeerId: 'peer-def',
        );

        expect(receivedId, equals(messageId));
      });
    });

    // =========================================================================
    // Noise handshake routing
    // =========================================================================

    group('processPacket - noise handshake', () {
      test('routes a handshake addressed to us to onNoiseHandshakeReceived',
          () async {
        GrassrootsPacket? forwarded;
        PeerTransport? forwardedTransport;
        String? forwardedPeerId;
        router.onNoiseHandshakeReceived =
            (packet, transport, {String? peerId}) async {
          forwarded = packet;
          forwardedTransport = transport;
          forwardedPeerId = peerId;
        };

        final m1 = await otherSessions.startHandshake(identity.publicKey);
        final p = GrassrootsPacket(
          type: PacketType.noiseHandshake,
          recipientPubkey: identity.publicKey,
          payload: m1!,
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          bleDeviceId: 'dialing-leg',
          rssi: -50,
        );

        expect(forwarded, isNotNull);
        expect(forwardedTransport, equals(PeerTransport.bleDirect));
        expect(forwardedPeerId, equals('dialing-leg'));
      });

      test('ignores a handshake not addressed to us', () async {
        bool forwarded = false;
        router.onNoiseHandshakeReceived =
            (_, __, {String? peerId}) async => forwarded = true;

        final thirdParty = Uint8List.fromList(List.generate(32, (i) => i + 5));
        final p = GrassrootsPacket(
          type: PacketType.noiseHandshake,
          recipientPubkey: thirdParty,
          payload: Uint8List.fromList([1, 2, 3]),
        );

        await router.processPacket(
          p,
          transport: PeerTransport.bleDirect,
          bleDeviceId: 'leg',
          rssi: -50,
        );

        expect(forwarded, isFalse);
      });
    });

    // =========================================================================
    // Invalid / Malformed Packets
    // =========================================================================

    group('processPacket - invalid/malformed packets', () {
      test('rejects construction with wrong recipient pubkey length', () {
        // The sender-anonymous header has no sender/signature fields; the one
        // length invariant left is the 32-byte recipient pubkey.
        expect(
          () => GrassrootsPacket(
            type: PacketType.secure,
            recipientPubkey: Uint8List(16), // too short
            payload: Uint8List.fromList([1]),
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('deserialize rejects data shorter than header size', () {
        expect(
          () => GrassrootsPacket.deserialize(Uint8List(40)),
          throwsA(isA<FormatException>()),
        );
      });

      test('deserialize rejects data with unknown packet type', () {
        // Build a buffer with headerSize bytes, but with type=0xFF
        final data = Uint8List(GrassrootsPacket.headerSize);
        data[0] = 0xFF; // unknown type
        expect(
          () => GrassrootsPacket.deserialize(data),
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
