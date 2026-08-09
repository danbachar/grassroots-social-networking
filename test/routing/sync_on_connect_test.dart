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
/// request the unseen subset, convey the stored sealed packets. The buffer is
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

  group('DtnStore buffer enumeration', () {
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
      // Enumeration must not consume buffer entries.
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

    test('store-wide total cap evicts the globally-oldest packet', () {
      final store = DtnStore(maxTotal: 3);
      final t0 = DateTime(2026, 1, 1);
      final first = sealed('a');
      store.store('ra', first, now: t0);
      // A busy recipient may hold MORE than any fixed per-recipient share —
      // the old 32-per-recipient depth silently dropped a busy peer's oldest
      // packets while the rest of the store sat empty.
      final busy = [for (var i = 0; i < 3; i++) sealed('b')];
      for (final (i, p) in busy.indexed) {
        store.store('rb', p, now: t0.add(Duration(minutes: i + 1)));
      }
      final at = t0.add(const Duration(minutes: 10));
      expect(store.totalCount, 3);
      expect(store.packetById(first.packetId, now: at), isNull,
          reason: 'globally-oldest evicted, regardless of recipient');
      expect(store.packetsFor('rb', now: at), hasLength(3));
      expect(store.packetsFor('ra', now: at), isEmpty);
    });

    test('expired entries disappear from enumeration and lookup', () {
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

    test('dtnCapacity exposes the store-wide packet ceiling', () {
      // GrassrootsNetwork sizes its messageId -> packetIds ACK index from
      // this. The two bounds must not drift: an index entry is dead the
      // moment its last packet leaves the buffer, so a smaller index silently
      // disables ACK-driven release and leaves packets to age out instead.
      expect(router.dtnCapacity, DtnStore().maxTotal);
    });

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

    test('self-originated packets enter the sync vector and leave on ACK', () {
      final recipient = Uint8List.fromList(List.generate(32, (i) => i + 50));
      final sealed = GrassrootsPacket(
        type: PacketType.secure,
        recipientPubkey: recipient,
        payload: Uint8List.fromList([1, 2, 3]),
      );

      // The sender buffers its own message: its own sealed packet
      // is offered in sync like any relayed packet.
      router.storeInDtnBuffer(recipient, sealed);
      expect(
        decodeSyncIds(router.buildSyncOffers().single),
        contains(sealed.packetId),
      );
      expect(router.dtnBufferFor(recipient).single.packetId, sealed.packetId);
      // Own packets are marked seen — a copy conveyed back is never re-relayed.
      expect(router.isDuplicate(sealed.packetId), isTrue);

      // ACK empties the buffer; nothing left to offer.
      router.dropFromDtnBuffer([sealed.packetId]);
      expect(router.buildSyncOffers(), isEmpty);
    });

    test('buildSyncOffers advertises buffered packets', () async {
      final p = await storeViaRelay();
      final offers = router.buildSyncOffers();
      expect(offers, hasLength(1));
      expect(decodeSyncIds(offers.first), contains(p.packetId));
    });

    test('offer -> requests exactly the unseen subset', () async {
      final seenId = uuid.v4();
      router.markSeen(seenId);
      final unseen1 = uuid.v4(), unseen2 = uuid.v4();

      final frames = <(ContentType, Uint8List, SyncLink)>[];
      router.onSyncFrame = (t, payload, link) =>
          frames.add((t, payload, link));

      await deliverSyncFrame(
          ContentType.syncOffer, [seenId, unseen1, unseen2], 'neighbor-1');

      expect(frames, hasLength(1));
      final (type, payload, link) = frames.single;
      expect(link.bleDeviceId, 'neighbor-1');
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

      final sent = <(GrassrootsPacket, SyncLink)>[];
      router.onSyncSend = (packet, link) => sent.add((packet, link));

      await deliverSyncFrame(
          ContentType.syncRequest, [stored.packetId], 'neighbor-2');

      expect(sent, hasLength(1));
      final (conveyed, link) = sent.single;
      expect(link.bleDeviceId, 'neighbor-2');
      expect(conveyed.type, PacketType.secure);
      expect(conveyed.packetId, stored.packetId);
      // Buffer entry replicated, not transferred.
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

    test('sync over UDP is ignored — the buffer is BLE-only',
        () async {
      // The Internet transport stays direct point-to-point: it neither
      // relays for third parties nor reconciles buffers, so a sync frame
      // arriving over it is never acted on.
      var called = false;
      router.onSyncFrame = (_, __, ___) => called = true;
      router.onSyncSend = (_, __) => called = true;
      final frame = SecureFrame(
        contentType: ContentType.syncOffer,
        messageId: uuid.v4(),
        chunk: encodeSyncIds([uuid.v4()]), // an id we have never seen
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
