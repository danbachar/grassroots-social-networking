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
        // The bound that matters is the SEALED PACKET on the wire, not the
        // payload: the old assertion checked the payload against 180 and so
        // passed while every full chunk went out 37 bytes over the MTU and
        // was truncated. Budget the three layers the packet actually carries.
        expect(payload.length + syncPacketOverhead,
            lessThanOrEqualTo(syncUsableWrite),
            reason: 'a sealed sync chunk must fit one GATT write');
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

    test('store-wide byte cap evicts the globally-oldest packet', () {
      // Payloads are 3 bytes each, so 9 bytes holds exactly three packets.
      final store = DtnStore(maxBytes: 9);
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

    test('a non-ACK buffer exit is reported so the ACK index can forget it',
        () {
      // GrassrootsNetwork's messageId -> packetIds index is keyed by message
      // while the store evicts by packet, and the index used to drain on ACK
      // ALONE. Every expiry and eviction then left a dead entry behind until
      // the index filled and started throwing out LIVE ones — which is what
      // turns ACK-driven release off. The store must report every non-ACK
      // exit, and it must do so whether or not tracing is on.
      final seen = <String>[];
      router.onBufferedPacketDropped = seen.add;
      final p = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 5,
        recipientPubkey: Uint8List(32),
        payload: Uint8List.fromList([1, 2, 3]),
      );
      router.storeInDtnBuffer(Uint8List(32), p);
      router.clearDtnBuffer();
      expect(seen, isEmpty,
          reason: 'a wholesale clear is not a per-packet exit');

      router.storeInDtnBuffer(Uint8List(32), p);
      router.dropFromDtnBuffer([p.packetId]);
      expect(seen, isEmpty,
          reason: 'an ACK release is reported by the caller, not here');
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
      expect(router.buildSyncOffers(neighbourPubkey), isEmpty);
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
        decodeSyncIds(router.buildSyncOffers(neighbourPubkey).single),
        contains(sealed.packetId),
      );
      expect(router.dtnBufferFor(recipient).single.packetId, sealed.packetId);
      // Own packets are marked seen — a copy conveyed back is never re-relayed.
      expect(router.isDuplicate(sealed.packetId), isTrue);

      // ACK empties the buffer; nothing left to offer.
      router.dropFromDtnBuffer([sealed.packetId]);
      expect(router.buildSyncOffers(neighbourPubkey), isEmpty);
    });

    test('buildSyncOffers advertises buffered packets', () async {
      final p = await storeViaRelay();
      final offers = router.buildSyncOffers(neighbourPubkey);
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

    test('offer with only seen ids -> an EMPTY request, not silence', () async {
      // Silence and "I have all of these" are indistinguishable to the
      // offerer, and only the second one lets it stop re-offering. One packet
      // ends a round that would otherwise repeat every announce cycle.
      final id = uuid.v4();
      router.markSeen(id);
      final frames = <(ContentType, Uint8List, SyncLink)>[];
      router.onSyncFrame = (t, p, l) => frames.add((t, p, l));

      await deliverSyncFrame(ContentType.syncOffer, [id], 'neighbor-1');
      expect(frames, hasLength(1));
      expect(frames.single.$1, ContentType.syncRequest);
      expect(decodeSyncIds(frames.single.$2), isEmpty);
    });

    /// Offer to the neighbour the way the coordinator does: build the chunks,
    /// then report each one that actually reached the link. A chunk that is
    /// built but never reported was never written, and opens no round.
    List<Uint8List> offerAndSend(Uint8List peer, {int? sendOnly}) {
      final payloads = router.buildSyncOffers(peer);
      for (final p in payloads.take(sendOnly ?? payloads.length)) {
        router.noteSyncOfferSent(peer, p);
      }
      return payloads;
    }

    test('a declined id is not offered to that peer again', () async {
      final p = await storeViaRelay();
      expect(offerAndSend(neighbourPubkey), hasLength(1));

      // The peer answers "I have it" — an empty request against our open
      // offer. The decline is taken when the next round opens.
      await deliverSyncFrame(ContentType.syncRequest, const [], 'neighbor-1');
      expect(router.buildSyncOffers(neighbourPubkey), isEmpty,
          reason: 'still carrying it, but this peer has said it does not want '
              'it — re-offering is pure repetition');

      // Another peer has said nothing, so it is still offered everything.
      final stranger = Uint8List.fromList(List.generate(32, (i) => i + 7));
      expect(
        decodeSyncIds(router.buildSyncOffers(stranger).single),
        contains(p.packetId),
      );
    });

    test('an UNANSWERED offer declines nothing — silence is not a decline',
        () async {
      // The peer walked out of range (or the notify was lost on the air)
      // before its reply was written. Reading that as "it has them all"
      // removes the ids from every future offer to that peer, and because
      // Noise sessions survive link loss, nothing ever clears the decline —
      // the packets would sit in the buffer until age expiry with their only
      // way out suppressed.
      final p = await storeViaRelay();
      expect(offerAndSend(neighbourPubkey), hasLength(1));

      expect(
        decodeSyncIds(offerAndSend(neighbourPubkey).single),
        contains(p.packetId),
        reason: 'no reply arrived, so nothing was learned and everything is '
            'offered again',
      );
      expect(router.declinedCountFor(neighbourPubkey), 0);
    });

    test('a PARTIALLY answered offer declines nothing', () async {
      // Two chunks on the link, one reply back: the peer never spoke for the
      // ids in the chunk it did not answer, so none of the round is settled.
      final recipient = Uint8List.fromList(List.generate(32, (i) => i + 50));
      for (var i = 0; i < maxSyncIdsPerPacket + 1; i++) {
        router.storeInDtnBuffer(
            recipient,
            GrassrootsPacket(
              type: PacketType.secure,
              recipientPubkey: recipient,
              payload: Uint8List.fromList([i]),
            ));
      }
      expect(offerAndSend(neighbourPubkey), hasLength(2));

      // One empty reply for one of the two chunks.
      await deliverSyncFrame(ContentType.syncRequest, const [], 'neighbor-1');

      final reoffered = offerAndSend(neighbourPubkey);
      expect(reoffered, hasLength(2),
          reason: 'an incomplete exchange settles nothing at all — a partial '
              'decline would strand exactly the ids whose chunk went missing');
      expect(router.declinedCountFor(neighbourPubkey), 0);
    });

    test('a chunk that never went out is not part of the round', () async {
      // Built but not written — a dead session, a refused write on both legs.
      // The peer cannot answer what it never received.
      final p = await storeViaRelay();
      offerAndSend(neighbourPubkey, sendOnly: 0);
      await deliverSyncFrame(ContentType.syncRequest, const [], 'neighbor-1');
      expect(
        decodeSyncIds(offerAndSend(neighbourPubkey).single),
        contains(p.packetId),
      );
    });

    test('a REQUESTED id stays offerable — conveyance can be cut short',
        () async {
      final p = await storeViaRelay();
      router.onSyncSend = (_, __) {};
      offerAndSend(neighbourPubkey);
      await deliverSyncFrame(
          ContentType.syncRequest, [p.packetId], 'neighbor-1');
      expect(
        decodeSyncIds(router.buildSyncOffers(neighbourPubkey).single),
        contains(p.packetId),
        reason: 'a conveyance can still be lost on the air; a peer that '
            'already has it declines on the next round at a cost of one id',
      );
    });

    test('a new session with the peer clears its declines', () async {
      final p = await storeViaRelay();
      offerAndSend(neighbourPubkey);
      await deliverSyncFrame(ContentType.syncRequest, const [], 'neighbor-1');
      expect(router.buildSyncOffers(neighbourPubkey), isEmpty);

      // A restart drops the peer's seen-set along with its session, so the
      // declines it made stop being trustworthy.
      router.clearSyncDeclines(neighbourPubkey);
      expect(
        decodeSyncIds(router.buildSyncOffers(neighbourPubkey).single),
        contains(p.packetId),
      );
    });

    test('an id that leaves the buffer leaves the decline set with it',
        () async {
      final recipient = Uint8List.fromList(List.generate(32, (i) => i + 50));
      final sealed = GrassrootsPacket(
        type: PacketType.secure,
        recipientPubkey: recipient,
        payload: Uint8List.fromList([1, 2, 3]),
      );
      router.storeInDtnBuffer(recipient, sealed);
      offerAndSend(neighbourPubkey);
      await deliverSyncFrame(ContentType.syncRequest, const [], 'neighbor-1');
      expect(router.buildSyncOffers(neighbourPubkey), isEmpty);

      // ACKed: the id can never be offered again, so holding its decline
      // would only grow the set for the life of the session.
      router.dropFromDtnBuffer([sealed.packetId]);
      expect(router.buildSyncOffers(neighbourPubkey), isEmpty);
      expect(router.declinedCountFor(neighbourPubkey), 0);
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

    test('conveyance pays TTL — a carried hop is still a hop', () async {
      // Sending the stored packet untouched put the sync path outside the hop
      // bound: a packet could be carried buffer to buffer indefinitely, and
      // every carried delivery reported zero hops.
      final p = await storeViaRelay(); // stored with ttl 5, not for us
      final sent = <GrassrootsPacket>[];
      router.onSyncSend = (packet, _) => sent.add(packet);
      await deliverSyncFrame(
          ContentType.syncRequest, [p.packetId], 'neighbor-2');
      expect(sent.single.ttl, p.ttl - 1);
      // And a delivery carried through a buffer must report the hop it took:
      // the receiver computes hops as defaultTtl - ttl, so skipping the
      // decrement here would under-count every carried delivery by one.
      expect(sent.single.packetId, p.packetId,
          reason: 'the id must survive: it is the dedup key on every hop');
    });

    test('a spent packet in TRANSIT is dropped on arrival', () async {
      // Nothing can be done with it: it cannot be forwarded, and carrying it
      // one buffer further would only make the next node refuse it too.
      var relayed = false;
      router.onRelay = (_, {String? excludeBlePeerId}) => relayed = true;
      final spent = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 0,
        recipientPubkey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
        payload: Uint8List.fromList([9]),
      );
      await router.processPacket(spent,
          transport: PeerTransport.bleDirect, bleDeviceId: 'inbound-leg');
      expect(relayed, isFalse);
      expect(router.dtnBufferedCount, 0,
          reason: 'a packet with no budget is not worth carrying either');
    });

    test('a spent packet still reaches the peer it is ADDRESSED to', () async {
      // TTL bounds travel, not arrival. The exemption keys on the packet's
      // recipientPubkey — the node it is addressed to — never on whoever
      // originated it.
      final recipient = neighbourPubkey;
      final spent = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 1,
        recipientPubkey: recipient,
        payload: Uint8List.fromList([7, 7]),
      );
      router.storeInDtnBuffer(recipient, spent);
      final sent = <GrassrootsPacket>[];
      router.onSyncSend = (packet, _) => sent.add(packet);
      await deliverSyncFrame(
          ContentType.syncRequest, [spent.packetId], 'neighbor-1');
      expect(sent, hasLength(1));
      expect(sent.single.ttl, 1,
          reason: 'conveyed exactly as held — the hop is charged by the node '
              'that receives it, not twice by the one holding it');
    });

    test('a packet arriving at 0 IS delivered when it is addressed to us',
        () async {
      // Delivering is not a hop, so it is judged on the arriving value: >= 0
      // is enough. Only forwarding subtracts.
      var delivered = false;
      router.onMessageReceived = (_, __, ___, ____) => delivered = true;
      final frame = SecureFrame(
        contentType: ContentType.message,
        messageId: uuid.v4(),
        chunk: Uint8List.fromList([1, 2, 3]),
      );
      final spent = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 0,
        recipientPubkey: identity.publicKey,
        payload: Uint8List.fromList([0xE0]),
      );
      router.trialDecrypt =
          (p) async => (p.copyWith(payload: frame.encode()), neighbourPubkey);
      await router.processPacket(spent,
          transport: PeerTransport.bleDirect, bleDeviceId: 'inbound-leg');
      expect(delivered, isTrue);
    });

    test('arriving at 2 forwards at 1 — a hop still remains', () async {
      final relayed = <GrassrootsPacket>[];
      router.onRelay = (p, {String? excludeBlePeerId}) => relayed.add(p);
      await router.processPacket(
        thirdPartySealed(ttl: 2),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(relayed.single.ttl, 1);
    });

    test('arriving at 1 is forwarded once, at 0', () async {
      // The last hop is still worth taking: the destination is exempt from the
      // refusal, so a neighbour who is the recipient still accepts it.
      final relayed = <GrassrootsPacket>[];
      router.onRelay = (p, {String? excludeBlePeerId}) => relayed.add(p);
      await router.processPacket(
        thirdPartySealed(ttl: 1),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(relayed.single.ttl, 0);
      expect(router.dtnBufferedCount, 1,
          reason: 'exhaustion does not delete it — it stays in custody and is '
              're-offered whenever a link to the recipient forms');
    });

    test('a relay already at 0 is refused', () async {
      var relayed = false;
      router.onRelay = (_, {String? excludeBlePeerId}) => relayed = true;
      await router.processPacket(
        thirdPartySealed(ttl: 0),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(relayed, isFalse);
      expect(router.dtnBufferedCount, 0);
    });

    test('arriving at 3 still forwards, at 2', () async {
      final relayed = <GrassrootsPacket>[];
      router.onRelay = (p, {String? excludeBlePeerId}) => relayed.add(p);
      await router.processPacket(
        thirdPartySealed(ttl: 3),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(relayed.single.ttl, 2);
    });

    test('conveyance sends the held packet unchanged', () async {
      // The buffered copy already paid for its arrival. Decrementing again at
      // conveyance would charge one hop twice and retire packets early.
      final other = Uint8List.fromList(List.generate(32, (i) => i + 90));
      final p = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 2,
        recipientPubkey: other,
        payload: Uint8List.fromList([1]),
      );
      router.storeInDtnBuffer(other, p);
      final sent = <GrassrootsPacket>[];
      router.onSyncSend = (packet, _) => sent.add(packet);
      await deliverSyncFrame(
          ContentType.syncRequest, [p.packetId], 'neighbor-1');
      expect(sent.single.ttl, 2);
      expect(sent.single.packetId, p.packetId);
    });

    test('an unforwardable packet never enters the buffer at all', () async {
      // The gate is at ARRIVAL: a packet that cannot be forwarded is dropped
      // rather than stored, which is why conveyance needs no gate of its own.
      router.onRelay = (_, {String? excludeBlePeerId}) {};
      await router.processPacket(
        thirdPartySealed(ttl: 0),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(router.dtnBufferedCount, 0);
    });

    test('what IS buffered is the hopped copy, not the one received',
        () async {
      // Storing the packet as received would make the held copy a hop richer
      // than the forwarded one, and the next carrier would inherit the error.
      final p = await storeViaRelay(); // arrives at ttl 5
      final sent = <GrassrootsPacket>[];
      router.onSyncSend = (packet, _) => sent.add(packet);
      await deliverSyncFrame(
          ContentType.syncRequest, [p.packetId], 'neighbor-2');
      expect(sent.single.ttl, p.ttl - 1,
          reason: 'held at the post-arrival value, conveyed unchanged');
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
