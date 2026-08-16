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

/// Sync-on-connect (DTN anti-entropy): a node advertises what it holds as a
/// GCS compact filter over a time window (ContentType.syncFilter, SEALED to
/// the neighbour's Noise session), and the neighbour conveys back every stored
/// sealed packet the filter proves it lacks. The buffer is replicated, never
/// transferred. PacketIds never travel in the clear.
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

    test('sync filter window round-trips real epoch-ms (no uint32 overflow)',
        () {
      // The window bounds are the SAME clock as a packet's createdAtMs — real
      // epoch-ms (~1.7e12), which overflow a uint32 (~4.29e9). A 4-byte field
      // truncated every bound to its low 32 bits, so the responder's full-ms
      // windowBetween matched nothing and delivered nothing. The bounds are
      // 8-byte; assert a real timestamp survives the round-trip.
      const from = 1731000000000; // > 2^32
      const to = 1731000005000;
      final enc = encodeSyncFilter(
          n: 3, fromMs: from, toMs: to, filter: Uint8List.fromList([1, 2, 3]));
      final d = decodeSyncFilter(enc);
      expect(d.fromMs, from);
      expect(d.toMs, to);
      expect(d.n, 3);
      expect(d.filter, Uint8List.fromList([1, 2, 3]));
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

    final neighbourPubkey =
        Uint8List.fromList(List.generate(32, (i) => 200 + i % 50));

    /// Deliver a sync FILTER frame the way the wire does now: a `secure` packet
    /// addressed to us whose trial-decrypt yields the sealed SecureFrame
    /// carrying a GCS filter over a time window. An EMPTY filter over
    /// [fromMs, toMs] names nothing, so the router conveys back every held
    /// packet whose creation stamp falls in the window. The stub stands in for
    /// the Noise session with the neighbour.
    Future<void> deliverSyncFilter({
      required int fromMs,
      required int toMs,
      required String bleDeviceId,
    }) async {
      final frame = SecureFrame(
        contentType: ContentType.syncFilter,
        messageId: uuid.v4(),
        chunk: encodeSyncFilter(
            n: 0, fromMs: fromMs, toMs: toMs, filter: Uint8List(0)),
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

    test('buildSyncFilter advertises what the buffer holds and round-trips',
        () {
      // The replacement for the id-list offer: a node advertises a GCS filter
      // over the window it holds, and the codec round-trips through the wire.
      final recipient = Uint8List.fromList(List.generate(32, (i) => i + 50));
      final p = GrassrootsPacket(
        type: PacketType.secure,
        recipientPubkey: recipient,
        payload: Uint8List.fromList([1, 2, 3]),
        createdAtMs: 5000,
      );
      router.storeInDtnBuffer(recipient, p);

      final payload = router.buildSyncFilter(neighbourPubkey);
      expect(payload, isNotNull,
          reason: 'a non-empty buffer advertises a filter');
      final dec = decodeSyncFilter(payload!);
      expect(dec.n, greaterThan(0),
          reason: 'the held packet contributes an element to the filter');
      expect(dec.fromMs, lessThanOrEqualTo(dec.toMs));
      expect(dec.toMs, greaterThan(0));
      expect(dec.toMs, 5000,
          reason: 'the window closes at the newest held creation stamp');
    });

    test('a spent packet in TRANSIT is dropped on arrival', () async {
      // Nothing can be done with it: it cannot be forwarded, and carrying it
      // one buffer further would only make the next node refuse it too.
      final spent = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 0,
        recipientPubkey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
        payload: Uint8List.fromList([9]),
      );
      await router.processPacket(spent,
          transport: PeerTransport.bleDirect, bleDeviceId: 'inbound-leg');
      expect(router.dtnBufferedCount, 0);
      expect(router.dtnBufferedCount, 0,
          reason: 'a packet with no budget is not worth carrying either');
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
      await router.processPacket(
        thirdPartySealed(ttl: 2),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(router.dtnBufferedPackets.single.ttl, 1);
    });

    test('arriving at 1 is forwarded once, at 0', () async {
      // The last hop is still worth taking: the destination is exempt from the
      // refusal, so a neighbour who is the recipient still accepts it.
      await router.processPacket(
        thirdPartySealed(ttl: 1),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(router.dtnBufferedPackets.single.ttl, 0);
      expect(router.dtnBufferedCount, 1,
          reason: 'exhaustion does not delete it — it stays in custody and is '
              're-offered whenever a link to the recipient forms');
    });

    test('a relay already at 0 is refused', () async {
      await router.processPacket(
        thirdPartySealed(ttl: 0),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(router.dtnBufferedCount, 0);
      expect(router.dtnBufferedCount, 0);
    });

    test('arriving at 3 still forwards, at 2', () async {
      await router.processPacket(
        thirdPartySealed(ttl: 3),
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(router.dtnBufferedPackets.single.ttl, 2);
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
        createdAtMs: 1000,
      );
      router.storeInDtnBuffer(other, p);
      final sent = <GrassrootsPacket>[];
      router.onSyncSend = (packet, _) => sent.add(packet);
      // Empty filter over the packet's window: the neighbour lacks it.
      await deliverSyncFilter(fromMs: 0, toMs: 2000, bleDeviceId: 'neighbor-1');
      expect(sent.single.ttl, 2);
      expect(sent.single.packetId, p.packetId);
    });

    test('an unforwardable packet never enters the buffer at all', () async {
      // The gate is at ARRIVAL: a packet that cannot be forwarded is dropped
      // rather than stored, which is why conveyance needs no gate of its own.
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
      final p = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 5,
        recipientPubkey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
        payload: Uint8List.fromList([9, 9, 9]),
        createdAtMs: 1000,
      );
      await router.processPacket(
        p,
        transport: PeerTransport.bleDirect,
        bleDeviceId: 'inbound-leg',
      );
      expect(router.dtnBufferedCount, greaterThan(0));
      final sent = <GrassrootsPacket>[];
      router.onSyncSend = (packet, _) => sent.add(packet);
      await deliverSyncFilter(fromMs: 0, toMs: 2000, bleDeviceId: 'neighbor-2');
      expect(sent.single.ttl, p.ttl - 1,
          reason: 'held at the post-arrival value, conveyed unchanged');
    });

    test('sync over UDP is ignored — the buffer is BLE-only', () async {
      // The Internet transport stays direct point-to-point: it neither relays
      // for third parties nor reconciles buffers, so a sync filter arriving
      // over it is never acted on. A held packet the peer lacks is NOT
      // conveyed back over UDP.
      final other = Uint8List.fromList(List.generate(32, (i) => i + 90));
      final p = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 2,
        recipientPubkey: other,
        payload: Uint8List.fromList([1]),
        createdAtMs: 1000,
      );
      router.storeInDtnBuffer(other, p);
      var called = false;
      router.onSyncSend = (_, __) => called = true;
      final frame = SecureFrame(
        contentType: ContentType.syncFilter,
        messageId: uuid.v4(),
        chunk: encodeSyncFilter(
            n: 0, fromMs: 0, toMs: 2000, filter: Uint8List(0)),
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

    test('malformed sync filter is dropped without side effects', () async {
      var called = false;
      router.onSyncSend = (_, __) => called = true;
      final frame = SecureFrame(
        contentType: ContentType.syncFilter,
        messageId: uuid.v4(),
        chunk: Uint8List.fromList([7]), // shorter than a filter header
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
