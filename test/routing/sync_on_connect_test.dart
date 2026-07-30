import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:redux/redux.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:uuid/uuid.dart';
import 'package:grassroots_networking/src/mesh/dtn_store.dart';
import 'package:grassroots_networking/src/mesh/sync_codec.dart';
import 'package:grassroots_networking/src/models/identity.dart';
import 'package:grassroots_networking/src/models/packet.dart';
import 'package:grassroots_networking/src/models/peer.dart';
import 'package:grassroots_networking/src/models/secure_frame.dart';
import 'package:grassroots_networking/src/protocol/fragment_handler.dart';
import 'package:grassroots_networking/src/protocol/protocol_handler.dart';
import 'package:grassroots_networking/src/routing/message_router.dart';
import 'package:grassroots_networking/src/store/store.dart';

import '../helpers/sodium_test_bootstrap.dart';

/// Sync-on-connect (DTN anti-entropy): offer carried packetIds on connect,
/// request the unseen subset, convey the stored sealed packets. Custody is
/// replicated, never transferred. The offer/request frames are SEALED to the
/// neighbour's Noise session (ContentType.syncOffer/syncRequest) — packetIds
/// never travel in the clear.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const uuid = Uuid();

  late SodiumSumo sodium;
  setUpAll(() async {
    sodium = await initTestSodium();
  });

  group('sync codec', () {
    test('round-trips a list of ids', () {
      final ids = List.generate(5, (_) => uuid.v4());
      expect(decodeSyncIds(encodeSyncIds(ids)), ids);
    });

    test('round-trips the empty list', () {
      expect(decodeSyncIds(encodeSyncIds([])), isEmpty);
    });

    test('encode rejects oversized chunks', () {
      final ids = List.generate(maxSyncIdsPerPacket + 1, (_) => uuid.v4());
      expect(() => encodeSyncIds(ids), throwsArgumentError);
    });

    test('decode throws on malformed payloads (clean-break rule)', () {
      expect(() => decodeSyncIds(Uint8List(0)), throwsFormatException);
      // Count byte says 2, but only one id present.
      final short = encodeSyncIds([uuid.v4()]);
      short[0] = 2;
      expect(() => decodeSyncIds(short), throwsFormatException);
      // Trailing garbage.
      final long = Uint8List.fromList([...encodeSyncIds([uuid.v4()]), 0xFF]);
      expect(() => decodeSyncIds(long), throwsFormatException);
    });

    test('buildSyncPayloads chunks ids to fit a single BLE write', () {
      final ids = List.generate(maxSyncIdsPerPacket * 2 + 3, (_) => uuid.v4());
      final payloads = buildSyncPayloads(ids);
      expect(payloads, hasLength(3));
      for (final payload in payloads) {
        // header + sealed frame overhead must still fit a 244-byte write.
        expect(payload.length, lessThanOrEqualTo(180));
      }
      expect(payloads.expand(decodeSyncIds), ids);
    });
  });

  group('DtnStore custody enumeration', () {
    GrassrootsPacket sealed(String recipientSeed) => GrassrootsPacket(
          type: PacketType.secure,
          ttl: 5,
          recipientPubkey:
              Uint8List.fromList(List.filled(32, recipientSeed.codeUnitAt(0))),
          payload: Uint8List.fromList([1, 2, 3]),
        );

    test('carriedPacketIds is non-destructive and spans recipients', () {
      final store = DtnStore();
      final a = sealed('a'), b = sealed('b');
      store.store('ra', a);
      store.store('rb', b);
      expect(store.carriedPacketIds(), unorderedEquals([a.packetId, b.packetId]));
      // Enumeration must not consume custody.
      expect(store.totalCount, 2);
      expect(store.carriedPacketIds(), hasLength(2));
    });

    test('packetById finds without removing; unknown id is null', () {
      final store = DtnStore();
      final a = sealed('a');
      store.store('ra', a);
      expect(store.packetById(a.packetId)?.packetId, a.packetId);
      expect(store.totalCount, 1);
      expect(store.packetById(uuid.v4()), isNull);
    });

    test('expired custody disappears from enumeration and lookup', () {
      final store = DtnStore(maxAge: const Duration(hours: 6));
      final a = sealed('a');
      final t0 = DateTime(2026, 1, 1);
      store.store('ra', a, now: t0);
      final later = t0.add(const Duration(hours: 7));
      expect(store.carriedPacketIds(now: later), isEmpty);
      expect(store.packetById(a.packetId, now: later), isNull);
    });
  });

  group('MessageRouter sync handlers', () {
    late MessageRouter router;
    late Store<AppState> store;
    late GrassrootsIdentity identity;

    setUp(() async {
      final keyPair = await Ed25519().newKeyPair();
      identity = await GrassrootsIdentity.create(
        keyPair: keyPair,
        nickname: 'SyncTester',
      );
      store = Store<AppState>(appReducer, initialState: const AppState());
      router = MessageRouter(
        identity: identity,
        store: store,
        protocolHandler:
            ProtocolHandler(identity: identity, sodium: sodium),
        fragmentHandler: FragmentHandler(),
      );
    });

    tearDown(() => router.dispose());

    GrassrootsPacket thirdPartySealed({int ttl = 5}) => GrassrootsPacket(
          type: PacketType.secure,
          ttl: ttl,
          recipientPubkey:
              Uint8List.fromList(List.generate(32, (i) => i + 1)),
          payload: Uint8List.fromList([9, 9, 9]),
        );

    /// Deliver a sync control frame the way the wire does now: as a `secure`
    /// packet whose trial-decrypt yields the sealed SecureFrame. The stub
    /// stands in for the Noise session with the neighbour.
    final neighbourPubkey =
        Uint8List.fromList(List.generate(32, (i) => 200 + i % 50));
    Future<void> deliverSyncFrame(
        ContentType type, List<String> ids, String bleDeviceId) async {
      final frame = SecureFrame(
        contentType: type,
        messageId: uuid.v4(),
        chunk: encodeSyncIds(ids),
      );
      final sealed = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 1,
        recipientPubkey: identity.publicKey, // sync is addressed to us
        payload: Uint8List.fromList([0xE0, 0xC0]), // opaque on the wire
      );
      router.trialDecrypt = (p) async =>
          (p.copyWith(payload: frame.encode()), neighbourPubkey);
      await router.processPacket(
        sealed,
        transport: PeerTransport.bleDirect,
        bleDeviceId: bleDeviceId,
      );
    }

    /// Relay a third-party sealed packet through the router so it lands in
    /// the DTN store (recipient unreachable in the empty peers state).
    Future<GrassrootsPacket> storeViaRelay() async {
      final p = thirdPartySealed();
      router.onRelay = (_, {String? excludeBlePeerId}) {};
      await router.processPacket(
        p,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(router.dtnBufferedCount, greaterThan(0));
      return p;
    }

    test('buildSyncOffers is empty when carrying nothing', () {
      expect(router.buildSyncOffers(), isEmpty);
    });

    test('originated custody enters the sync vector and ends on ACK', () {
      final recipient = Uint8List.fromList(List.generate(32, (i) => i + 50));
      final sealed = GrassrootsPacket(
        type: PacketType.secure,
        recipientPubkey: recipient,
        payload: Uint8List.fromList([1, 2, 3]),
      );

      // The sender is the message's first custodian: its own sealed packet
      // is offered in sync like any relayed custody.
      router.storeCustody(recipient, sealed);
      expect(
        decodeSyncIds(router.buildSyncOffers().single),
        contains(sealed.packetId),
      );
      expect(router.custodyFor(recipient).single.packetId, sealed.packetId);
      // Own packets are marked seen — a copy conveyed back is never re-relayed.
      expect(router.isDuplicate(sealed.packetId), isTrue);

      // ACK ends custody; nothing left to offer.
      router.removeCustody([sealed.packetId]);
      expect(router.buildSyncOffers(), isEmpty);
    });

    test('buildSyncOffers advertises stored custody', () async {
      final p = await storeViaRelay();
      final offers = router.buildSyncOffers();
      expect(offers, hasLength(1));
      expect(decodeSyncIds(offers.first), contains(p.packetId));
    });

    test('offer -> requests exactly the unseen subset', () async {
      final seenId = uuid.v4();
      router.markSeen(seenId);
      final unseen1 = uuid.v4(), unseen2 = uuid.v4();

      final frames = <(ContentType, Uint8List, String)>[];
      router.onSyncFrame = (t, payload, device) =>
          frames.add((t, payload, device));

      await deliverSyncFrame(
          ContentType.syncOffer, [seenId, unseen1, unseen2], 'neighbor-1');

      expect(frames, hasLength(1));
      final (type, payload, device) = frames.single;
      expect(device, 'neighbor-1');
      expect(type, ContentType.syncRequest,
          reason: 'the reply is sealed, not a cleartext packet type');
      expect(decodeSyncIds(payload), unorderedEquals([unseen1, unseen2]));
    });

    test('offer with only seen ids -> no request', () async {
      final id = uuid.v4();
      router.markSeen(id);
      var called = false;
      router.onSyncFrame = (_, __, ___) => called = true;

      await deliverSyncFrame(ContentType.syncOffer, [id], 'neighbor-1');
      expect(called, isFalse);
    });

    test('request -> conveys the stored sealed packet to the requester',
        () async {
      final stored = await storeViaRelay();

      final sent = <(GrassrootsPacket, String)>[];
      router.onSyncSend = (packet, device) => sent.add((packet, device));

      await deliverSyncFrame(
          ContentType.syncRequest, [stored.packetId], 'neighbor-2');

      expect(sent, hasLength(1));
      final (conveyed, device) = sent.single;
      expect(device, 'neighbor-2');
      expect(conveyed.type, PacketType.secure);
      expect(conveyed.packetId, stored.packetId);
      // Custody replicated, not transferred.
      expect(router.dtnBufferedCount, greaterThan(0));
    });

    test('request for unknown/expired ids conveys nothing', () async {
      var called = false;
      router.onSyncSend = (_, __) => called = true;
      await deliverSyncFrame(
          ContentType.syncRequest, [uuid.v4()], 'neighbor-2');
      expect(called, isFalse);
    });

    test('sync packets are never relayed and never delivered', () async {
      var relayed = false;
      router.onRelay = (_, {String? excludeBlePeerId}) => relayed = true;
      router.onMessageReceived =
          (_, __, ___, ____) => fail('sync must not deliver');

      await deliverSyncFrame(ContentType.syncOffer, [uuid.v4()], 'neighbor-1');
      expect(relayed, isFalse);
    });

    test('sync over non-BLE transports is ignored (UDP carries no custody)',
        () async {
      var called = false;
      router.onSyncFrame = (_, __, ___) => called = true;
      final frame = SecureFrame(
        contentType: ContentType.syncOffer,
        messageId: uuid.v4(),
        chunk: encodeSyncIds([uuid.v4()]),
      );
      router.trialDecrypt = (p) async =>
          (p.copyWith(payload: frame.encode()), neighbourPubkey);
      await router.processPacket(
        GrassrootsPacket(
          type: PacketType.secure,
          ttl: 1,
          recipientPubkey: identity.publicKey,
          payload: Uint8List.fromList([1, 2]),
        ),
        transport: PeerTransport.udp,
        udpPeerId: 'udp-peer',
      );
      expect(called, isFalse);
    });

    test('malformed sync payload is dropped without side effects', () async {
      var called = false;
      router.onSyncFrame = (_, __, ___) => called = true;
      final frame = SecureFrame(
        contentType: ContentType.syncOffer,
        messageId: uuid.v4(),
        chunk: Uint8List.fromList([7]), // count=7, no ids
      );
      router.trialDecrypt = (p) async =>
          (p.copyWith(payload: frame.encode()), neighbourPubkey);
      await router.processPacket(
        GrassrootsPacket(
          type: PacketType.secure,
          ttl: 1,
          recipientPubkey: identity.publicKey,
          payload: Uint8List.fromList([1, 2]),
        ),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'neighbor-1',
      );
      expect(called, isFalse);
    });
  });
}
