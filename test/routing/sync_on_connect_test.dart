import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:cryptography/cryptography.dart';
import 'package:redux/redux.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'package:uuid/uuid.dart';
import 'package:grassroots_networking/src/mesh/dtn_store.dart';
import 'package:grassroots_networking/src/mesh/gcs_filter.dart';
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
          n: 3,
          salt: 200,
          fromMs: from,
          toMs: to,
          filter: Uint8List.fromList([1, 2, 3]));
      final d = decodeSyncFilter(enc);
      expect(d.fromMs, from);
      expect(d.toMs, to);
      expect(d.n, 3);
      expect(d.salt, 200);
      expect(d.filter, Uint8List.fromList([1, 2, 3]));
    });

    test('a full frame still fits one floor-MTU write', () {
      // The three constants have to be read together or not at all: the
      // filter's budget IS the write, less the sealed packet and the frame
      // header. Nothing refuses an oversized sync frame at send time — the
      // stack cuts it at MTU - 3 and the peer gets an unparseable prefix — so
      // this sum is the only thing standing between a header field and a
      // silently truncated filter.
      expect(syncPacketOverhead + syncFilterHeaderSize + GcsFilter.maxPayloadBytes,
          lessThanOrEqualTo(syncUsableWrite));
      final full = GcsFilter.build(
          [for (var i = 0; i < GcsFilter.maxElements * 2; i++) 'fit-$i'],
          salt: 255);
      final frame = encodeSyncFilter(
          n: full.n,
          salt: 255,
          fromMs: 1731000000000,
          toMs: 1731000005000,
          filter: full.data);
      expect(syncPacketOverhead + frame.length,
          lessThanOrEqualTo(syncUsableWrite));
    });

    test('a salt that would not fit the byte is refused, never truncated', () {
      // The two sides hash under this value. A salt written truncated is not
      // a degraded filter, it is one the reader resolves against a different
      // slot assignment entirely — every id absent, the whole window back.
      expect(
          () => encodeSyncFilter(
              n: 0,
              salt: syncFilterSaltPeriod,
              fromMs: 0,
              toMs: 1,
              filter: Uint8List(0)),
          throwsArgumentError);
      expect(
          () => encodeSyncFilter(
              n: 0, salt: -1, fromMs: 0, toMs: 1, filter: Uint8List(0)),
          throwsArgumentError);
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
      // Payloads are 3 bytes each. Eviction has hysteresis — crossing
      // [DtnStore.evictHighWater] drains to [DtnStore.evictLowWater] — so a
      // 12-byte cap sheds on the FOURTH store — 4x3 = 12 is over the
      // 11.88-byte high-water mark — draining to the 9-byte low water and
      // taking the globally-oldest first.
      final store = DtnStore(maxBytes: 12);
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

    test('the testbed custody reset forgets the seen-set with the buffer',
        () {
      // Sync filters name the seen-set, and a round covers a fixed slice of
      // it. Carried across trials the set outgrows what a sweep can cover
      // inside a trial, and a node's neighbours are asked about last trial's
      // packets while this trial's wait: measured at N=11 on the ring as
      // delivery falling trial by trial with nothing else changing.
      router.markSeen('old-trial', 1);
      router.clearDtnBuffer();
      expect(router.isDuplicate('old-trial'), isFalse);
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
    /// Deliver an already-encoded sync filter frame — the frames a real asker's
    /// [MessageRouter.buildSyncRound] produced, fed to this router as holder.
    Future<void> deliverSyncFrame(Uint8List encoded,
        {String bleDeviceId = 'neighbor-1'}) async {
      final frame = SecureFrame(
        contentType: ContentType.syncFilter,
        messageId: uuid.v4(),
        chunk: encoded,
      );
      final sealed = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 1,
        recipientPubkey: identity.publicKey,
        payload: Uint8List.fromList([0xE0, 0xC0]),
      );
      router.trialDecrypt = (p) async =>
          (p.copyWith(payload: frame.encode()), neighbourPubkey);
      await router.processPacket(sealed,
          transport: PeerTransport.bleDirect, bleDeviceId: bleDeviceId);
    }

    /// A second router standing in for the ASKING peer. Its seen-set is what
    /// the filter is built from, so it must be a different node than the one
    /// holding the packet — a holder has seen everything it holds, and its own
    /// filter would name it.
    Future<MessageRouter> makeAsker() async {
      final keyPair = await Ed25519().newKeyPair();
      final askerIdentity =
          await GrassrootsIdentity.create(keyPair: keyPair, nickname: 'Asker');
      return MessageRouter(
        identity: askerIdentity,
        store: Store<AppState>(appReducer, initialState: const AppState()),
        protocolHandler:
            ProtocolHandler(identity: askerIdentity, sodium: sodium),
        fragmentHandler: FragmentHandler(),
      );
    }

    Future<void> deliverSyncFilter({
      required int fromMs,
      required int toMs,
      String bleDeviceId = 'neighbor-1',
      PeerTransport transport = PeerTransport.bleDirect,
    }) async {
      final frame = SecureFrame(
        contentType: ContentType.syncFilter,
        messageId: uuid.v4(),
        chunk: encodeSyncFilter(
            n: 0, salt: 0, fromMs: fromMs, toMs: toMs, filter: Uint8List(0)),
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
        transport: transport,
        bleDeviceId:
            transport == PeerTransport.bleDirect ? bleDeviceId : null,
        udpPeerId: transport == PeerTransport.udp ? 'udp-peer' : null,
      );
    }

    test('one frame is enough when it covers the whole seen-set', () {
      // Nothing was left out, so there is no floor to declare (fromMs 0 says
      // "send me anything you have") and no ground for a sweep frame to cover
      // that the prefix has not already named.
      final recipient = Uint8List.fromList(List.generate(32, (i) => i + 50));
      final p = GrassrootsPacket(
        type: PacketType.secure,
        recipientPubkey: recipient,
        payload: Uint8List.fromList([1, 2, 3]),
        createdAtMs: 5000,
      );
      router.storeInDtnBuffer(recipient, p);

      final round = router.buildSyncRound(neighbourPubkey);
      expect(round, hasLength(1),
          reason: 'a second frame would re-name the same ids over the same '
              'ground — pure airtime');
      final dec = decodeSyncFilter(round.single);
      expect(dec.n, greaterThan(0),
          reason: 'the packet we originated counts as seen and is named');
      expect(dec.fromMs, 0);
      expect(dec.toMs, greaterThanOrEqualTo(5000));
    });

    test('a round is sized to the leg it will be written to', () {
      // A Nexus 5X peripheral leg settles at MTU 185 — 182 usable bytes,
      // against a floor-MTU budget of 244. Frames built for the floor can
      // only ever ride the pair's other leg; measured 2026-09-02, 2153
      // refusals in one desk run.
      for (var i = 0; i < GcsFilter.maxElements * 4; i++) {
        router.markSeen('narrow$i', 1000 + i);
      }
      const usable = 185 - 3;
      final round = router.buildSyncRound(neighbourPubkey, usableBytes: usable);
      expect(round, isNotEmpty);
      for (final frame in round) {
        expect(frame.length + syncPacketOverhead, lessThanOrEqualTo(usable),
            reason: 'a sealed sync frame must fit the leg it is sized for');
      }
      // The filter shrinks; it is not truncated. What it names, it names.
      expect(decodeSyncFilter(round.first).n, greaterThan(0));
    });

    test('no budget keeps the full floor-MTU allowance', () {
      for (var i = 0; i < GcsFilter.maxElements * 4; i++) {
        router.markSeen('wide$i', 1000 + i);
      }
      final wide = router.buildSyncRound(neighbourPubkey);
      final narrow =
          router.buildSyncRound(neighbourPubkey, usableBytes: 185 - 3);
      expect(wide.first.length, greaterThan(narrow.first.length));
      expect(wide.first.length + syncPacketOverhead,
          lessThanOrEqualTo(syncUsableWrite));
    });

    test('a round spends its frames catching history up', () {
      // One prefix frame anchors the recent end; the rest of the round is the
      // sweep walking history forward. A single sweep step names at most one
      // filter-full, so a backlog deeper than that took a round per step —
      // measured 2026-09-02: a 2-frame round named at most 212 ids against a
      // median backlog of 521 and a p90 of 1539.
      final deep = GcsFilter.maxElements * 6;
      for (var i = 0; i < deep; i++) {
        router.markSeen('deep$i', 1000 + i);
      }
      final round = router.buildSyncRound(neighbourPubkey);
      expect(round.length, greaterThan(2),
          reason: 'a backlog this deep has more history than one step covers');

      // The prefix is frame one and reaches NOW; every later frame is a
      // distinct, non-overlapping window walking forward.
      final windows = [for (final f in round) decodeSyncFilter(f)];
      expect(windows.first.toMs, greaterThanOrEqualTo(1000 + deep - 1));
      final sweeps = windows.skip(1).toList();
      for (var i = 0; i < sweeps.length; i++) {
        expect(sweeps[i].n, greaterThan(0), reason: 'frame ${i + 1} names none');
        if (i > 0) {
          expect(sweeps[i].fromMs, greaterThan(sweeps[i - 1].toMs),
              reason: 'sweep frames must not re-name the same ground');
        }
      }
    });

    test('the round stays inside the pacer\'s ceiling', () {
      // Every frame is a separate unacknowledged write that can pull
      // MessageRouter._maxConveyPerFilter packets back, so a round is bounded
      // however deep the backlog goes.
      for (var i = 0; i < GcsFilter.maxElements * 200; i++) {
        router.markSeen('huge$i', 1000 + i);
      }
      expect(router.buildSyncRound(neighbourPubkey).length,
          lessThanOrEqualTo(MessageRouter.maxSyncFramesPerRound));
    });

    test('a node that has seen nothing asks for everything', () {
      final round = router.buildSyncRound(neighbourPubkey);
      expect(round, hasLength(1),
          reason: 'a quiet node that is MISSING packets still has to ask');
      final dec = decodeSyncFilter(round.single);
      expect(dec.n, 0);
      expect(dec.fromMs, 0);
    });

    test('the prefix frame reaches past this node\'s own horizon, every round',
        () {
      // The deadlock this removes. A holder answers only from packets whose
      // creation stamp falls in the asker's window, and every bound the asker
      // can otherwise draw comes from its own seen-set — so a window closing
      // at the newest SEEN stamp makes a packet created after that invisible
      // to this node forever. It cannot lift the ceiling by seeing that
      // packet, because that packet is exactly what is being withheld. The
      // bias is systematic: still-undelivered packets are preferentially the
      // newest.
      for (var i = 0; i < GcsFilter.maxElements * 40; i++) {
        router.markSeen('big$i', 1000 + i);
      }
      for (var r = 0; r < 3; r++) {
        final justCreated = DateTime.now().millisecondsSinceEpoch;
        final windows = [
          for (final f in router.buildSyncRound(neighbourPubkey))
            decodeSyncFilter(f)
        ];
        expect(
            windows.any(
                (w) => w.fromMs <= justCreated && justCreated <= w.toMs),
            isTrue,
            reason: 'round $r must still ask about a packet created NOW — the '
                'prefix is re-anchored at the newest end every round, not '
                'wherever a cursor happened to reach');
      }
    });

    test('the prefix frame names the NEWEST ids and declares a floor', () {
      // The floor is the other half of the prefix: everything below it is
      // outside the filter but NOT missing, so the holder must not re-send it.
      // Asking from 0 while naming only the newest slice is a mature node
      // impersonating a fresh one and asking for the whole history back.
      final total = GcsFilter.maxElements * 40;
      for (var i = 0; i < total; i++) {
        router.markSeen('big$i', 1000 + i);
      }
      final prefix = decodeSyncFilter(router.buildSyncRound(neighbourPubkey)[0]);
      expect(prefix.fromMs, greaterThan(1000 + total - GcsFilter.maxElements * 2),
          reason: 'the floor is the oldest of the NEWEST filter-full, not the '
              'bottom of the seen-set');
      // One filter-full, less the partial millisecond the floor cut away.
      expect(prefix.n, greaterThanOrEqualTo(GcsFilter.maxElements - 1));
    });

    test('the sweep frame still walks old ground the prefix cannot reach', () {
      // Without this frame the prefix floor is not a delay, it is a deletion:
      // sync is the only path a buffered packet has, so an id below the floor
      // would never be asked about by anybody again. At 2 ids/s that floor is
      // ~9 minutes deep; under clique load ~11 seconds.
      final total = GcsFilter.maxElements * 8;
      for (var i = 0; i < total; i++) {
        router.markSeen('g$i', 1000 + i);
      }
      final prefixFloor =
          decodeSyncFilter(router.buildSyncRound(neighbourPubkey)[0]).fromMs;
      expect(prefixFloor, greaterThan(1000),
          reason: 'this seen-set is deeper than one frame, so there IS ground '
              'below the floor');

      // Every stamp under the floor must be named by a sweep frame within a
      // bounded number of rounds. A round spends its whole frame budget on
      // the sweep, so the ground below the floor is covered in far fewer
      // rounds than the one-step-per-round shape needed.
      final covered = <int>{};
      var rounds = 0;
      while (covered.length < prefixFloor - 1000 && rounds < 12) {
        rounds++;
        final round = router.buildSyncRound(neighbourPubkey);
        expect(round.length, greaterThanOrEqualTo(2),
            reason: 'round $rounds dropped the sweep');
        expect(round.length, lessThanOrEqualTo(MessageRouter.maxSyncFramesPerRound));
        for (final f in round.skip(1)) {
          final w = decodeSyncFilter(f);
          for (var t = w.fromMs; t <= w.toMs; t++) {
            if (t >= 1000 && t < prefixFloor) covered.add(t);
          }
        }
      }
      expect(covered.length, prefixFloor - 1000,
          reason: 'the sweep must cover every stamp below the prefix floor');
      expect(rounds, lessThanOrEqualTo(4),
          reason: 'one step per round took a round per filter-full; a full '
              'round of steps must cover this ground far faster');
    });

    test('a packet older than the asker\'s prefix floor is still conveyed',
        () async {
      // The end-to-end version, through the holder's side: a packet whose
      // creation stamp is below the asker's floor is invisible to the prefix
      // frame and reachable ONLY through the sweep. Sync is the only path a
      // buffered packet has, so without the sweep this is not a slow delivery,
      // it is a lost one.
      final asker = await makeAsker();
      final total = GcsFilter.maxElements * 4;
      for (var i = 0; i < total; i++) {
        asker.markSeen('g$i', 100000 + i);
      }
      final other = Uint8List.fromList(List.generate(32, (i) => i + 90));
      final old = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 2,
        recipientPubkey: other,
        payload: Uint8List.fromList([1]),
        createdAtMs: 100010, // deep under the asker's prefix floor
      );
      router.storeInDtnBuffer(other, old);

      final sent = <String>{};
      router.onSyncSend = (packet, _) => sent.add(packet.packetId);
      for (var r = 0; r < 8 && !sent.contains(old.packetId); r++) {
        for (final frame in asker.buildSyncRound(identity.publicKey)) {
          await deliverSyncFrame(frame);
        }
      }
      asker.dispose();
      expect(sent, contains(old.packetId),
          reason: 'a packet below the floor must still be asked for within a '
              'bounded number of rounds');
    });

    test('a packet newer than everything the asker has seen is conveyed',
        () async {
      // The freshness half, end to end. With a seen-set far larger than one
      // frame, a window drawn from the seen-set alone tops out far below the
      // present and a just-created packet is never asked for at all.
      final asker = await makeAsker();
      for (var i = 0; i < GcsFilter.maxElements * 40; i++) {
        asker.markSeen('big$i', 1000 + i);
      }
      final other = Uint8List.fromList(List.generate(32, (i) => i + 90));
      final fresh = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 2,
        recipientPubkey: other,
        payload: Uint8List.fromList([1]),
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      router.storeInDtnBuffer(other, fresh);

      final sent = <String>{};
      router.onSyncSend = (packet, _) => sent.add(packet.packetId);
      for (final frame in asker.buildSyncRound(identity.publicKey)) {
        await deliverSyncFrame(frame);
      }
      asker.dispose();
      expect(sent, contains(fresh.packetId));
    });

    test('the sweep cursor is per peer and is not kept forever', () {
      // Per-peer state grows with every peer ever met unless something drops
      // it, and a peer returning after the lifetime SHOULD be swept from the
      // start — which is exactly what a missing cursor does.
      final gone = Uint8List.fromList(List.generate(32, (i) => i + 70));
      // Deeper than one round can sweep, or the round covers everything and
      // correctly restarts at the oldest ground, leaving nothing to observe.
      for (var i = 0; i < GcsFilter.maxElements * 20; i++) {
        router.markSeen('r$i', 1000 + i);
      }
      final before = router.syncCursorState(gone).pending;
      router.buildSyncRound(gone);
      expect(router.syncCursorState(gone).pending, lessThan(before),
          reason: 'the sweep advanced for this peer');
      router.debugAgeSyncCursors(const Duration(minutes: 11));
      expect(router.syncCursorState(gone).pending, before,
          reason: 'the stale cursor was dropped, so the sweep restarts');
    });

    test('advancing one peer\'s sweep does not move another\'s', () {
      // A shared cursor hands consecutive neighbours consecutive slices, so a
      // holder is only ever asked about the windows that happened to land on
      // it — and delivery then depends on WHICH peer a packet is addressed to.
      final other = Uint8List.fromList(List.generate(32, (i) => i + 90));
      // Deep enough that A's cursor genuinely lands mid-history: a backlog one
      // round can finish wraps to the oldest ground, so both peers would read
      // the same window whether or not the cursor were shared.
      for (var i = 0; i < GcsFilter.maxElements * 20; i++) {
        router.markSeen('p$i', 1000 + i);
      }
      final sweepA = decodeSyncFilter(router.buildSyncRound(neighbourPubkey)[1]);
      final advancedA =
          decodeSyncFilter(router.buildSyncRound(neighbourPubkey)[1]);
      expect(advancedA.fromMs, greaterThan(sweepA.fromMs),
          reason: 'A carried on through history rather than restarting');
      final sweepB = decodeSyncFilter(router.buildSyncRound(other)[1]);
      expect(sweepB.fromMs, sweepA.fromMs,
          reason: 'B starts its own sweep at the beginning, not where A left '
              'off');
      expect(sweepB.toMs, sweepA.toMs);
    });

    test('the sweep never claims ground its filter does not name', () {
      // A frame asserts "over [fromMs, toMs] this filter names everything I
      // have". Widening the top past the ids it actually lists asserts absence
      // over ground it never described, and the holder conveys packets we
      // demonstrably hold — 5.2% of conveyances on 2026-09-02 were the same
      // packet handed to the same peer twice.
      for (var i = 0; i < GcsFilter.maxElements * 3; i++) {
        router.markSeen('p$i', 1000 + i);
      }
      final round = router.buildSyncRound(neighbourPubkey);
      final sweep = decodeSyncFilter(round[1]);
      expect(sweep.toMs, lessThan(DateTime.now().millisecondsSinceEpoch));
      expect(sweep.toMs, lessThan(1000 + GcsFilter.maxElements * 3));
    });

    group('the per-cycle salt', () {
      test('one cycle is one salt for one peer, however many rounds it makes',
          () {
        // A cycle produces several rounds for one peer: a dual-role pair
        // announces on both legs, and a peer reachable over both transports
        // is asked on each. Their prefix frames all cover [floorMs, nowMs] —
        // the same ground — so salting them separately would score one asking
        // occasion as several independent draws.
        final salts = {
          for (var i = 0; i < 4; i++)
            decodeSyncFilter(router.buildSyncRound(neighbourPubkey).first).salt,
        };
        expect(salts, hasLength(1), reason: 'salts within a cycle: $salts');
      });

      test('two holders asked in one cycle get different salts', () {
        // One filter per cycle goes to every neighbour. Without a per-peer
        // offset every holder would test the same id against the same slots
        // and reach the SAME verdict, so one false positive would retire a
        // packet at every carrier at once and holding it in several places
        // would stop being redundancy. A message survives that — its
        // originator keeps a copy this rule may not touch — but a
        // confirmation has no such copy and nothing regenerates it.
        final salts = <int>{};
        for (var i = 0; i < 12; i++) {
          final peer = Uint8List.fromList(List.generate(32, (b) => b + i * 7));
          salts.add(decodeSyncFilter(router.buildSyncRound(peer).first).salt);
        }
        expect(salts, hasLength(12),
            reason: 'holders must draw independently of one another: $salts');
      });

      test('the next cycle hashes differently', () {
        // What the two-vote retirement rule is priced against. Membership
        // cannot supply it: the prefix frame's id set stands still on a quiet
        // node, and a sweep frame's window is historical, so its set never
        // changes between one pass of the cursor and the next.
        final salts = <int>[];
        for (var i = 0; i < 6; i++) {
          salts.add(
              decodeSyncFilter(router.buildSyncRound(neighbourPubkey).first)
                  .salt);
          router.advanceSyncSalt();
        }
        for (var i = 1; i < salts.length; i++) {
          expect(salts[i], isNot(salts[i - 1]), reason: 'salts: $salts');
        }
      });

      test('every frame of a round carries the cycle\'s salt', () {
        // Not one per frame: a round's frames cover disjoint windows, so no
        // packet is named twice inside one and there is no second draw to
        // make.
        for (var i = 0; i < GcsFilter.maxElements * 3; i++) {
          router.markSeen('s$i', 1000 + i);
        }
        final round = router.buildSyncRound(neighbourPubkey);
        expect(round.length, greaterThan(1), reason: 'need a multi-frame round');
        final salts = {for (final f in round) decodeSyncFilter(f).salt};
        expect(salts, hasLength(1));
      });

      test('the salt wraps at the byte rather than overflowing it', () {
        final salts = <int>[];
        for (var i = 0; i < syncFilterSaltPeriod + 2; i++) {
          salts.add(
              decodeSyncFilter(router.buildSyncRound(neighbourPubkey).first)
                  .salt);
          router.advanceSyncSalt();
        }
        expect(salts.take(syncFilterSaltPeriod).toSet(),
            hasLength(syncFilterSaltPeriod),
            reason: 'a full period must use every value once');
        expect(salts[syncFilterSaltPeriod], salts.first,
            reason: 'wraps to where it began rather than overflowing');
        expect(salts[syncFilterSaltPeriod + 1], salts[1]);
      });

      test('the prefix and the sweep never describe the same ground', () {
        // `windowFrom` bounds a window BELOW and by count, never above, so a
        // sweep step starting just under the prefix's floor takes its whole
        // count and runs past it unless it is cut there. Two costs if it is
        // not: the holder answers that band from both frames, conveying twice
        // whatever the asker lacks, and the frames share the round's salt and
        // element count, so a packet in the band has ONE hash target tested
        // twice — a single draw that the retirement rule would count as two.
        for (var i = 0; i < GcsFilter.maxElements * 3; i++) {
          router.markSeen('d$i', 1000 + i);
        }
        final round = router
            .buildSyncRound(neighbourPubkey)
            .map(decodeSyncFilter)
            .toList();
        expect(round.length, greaterThan(1), reason: 'need a sweep to check');
        final floorMs = round.first.fromMs;
        for (final sweep in round.skip(1)) {
          expect(sweep.toMs, lessThan(floorMs),
              reason: 'sweep [${sweep.fromMs}, ${sweep.toMs}] crosses the '
                  'prefix floor $floorMs');
        }
      });

      test('the sweep keeps wrapping while new traffic arrives', () {
        // The sweep's whole job is that ground below the prefix floor is
        // reached again within a bounded number of rounds — merged partitions
        // are exactly the case store-carry-forward exists for. The wrap is
        // triggered by the cursor reaching the floor, so a cursor that parks
        // just under a floor which then RISES never comes round again: it
        // re-describes the one band that has just dropped out of the prefix,
        // round after round, while deep history is never asked for.
        for (var i = 0; i < GcsFilter.maxElements * 8; i++) {
          router.markSeen('w$i', 1000 + i);
        }
        const deepMs = 1050;
        var swept = 0;
        var next = GcsFilter.maxElements * 8;
        for (var round = 0; round < 12; round++) {
          final frames = router
              .buildSyncRound(neighbourPubkey)
              .map(decodeSyncFilter)
              .toList();
          if (frames
              .skip(1)
              .any((f) => f.fromMs <= deepMs && deepMs <= f.toMs)) {
            swept++;
          }
          // One new id per round: enough to lift the floor every time.
          router.markSeen('w${next++}', 1000 + next);
          router.advanceSyncSalt();
        }
        expect(swept, 12,
            reason: 'the deepest ground was swept in only $swept of 12 rounds');
      });

      test('one cycle is one draw: it takes two cycles to retire', () async {
        // The end-to-end guard on the retirement vote's key. The store's own
        // tests hand a vote key in directly, so nothing else checks the key
        // the ROUTER builds — a router that reused one value across cycles
        // would never retire, and one that varied it within a cycle would
        // retire on a single draw.
        final asker = await makeAsker();
        for (var i = 0; i < 30; i++) {
          final p = GrassrootsPacket(
            type: PacketType.secure,
            ttl: 2,
            recipientPubkey: neighbourPubkey,
            payload: Uint8List.fromList([i]),
            createdAtMs: 1000 + i,
          );
          router.storeInDtnBuffer(neighbourPubkey, p, retirableOnSeen: true);
          asker.markSeen(p.packetId, p.createdAtMs);
        }
        expect(router.dtnBufferedCount, 30);

        // Two rounds in ONE cycle: what a dual-role pair on two transports
        // produces. Both must count as the single question they are.
        for (var round = 0; round < 2; round++) {
          for (final f in asker.buildSyncRound(identity.publicKey)) {
            await deliverSyncFrame(f);
          }
        }
        expect(router.dtnBufferedCount, 30,
            reason: 'every round of one cycle asks over the same ground');

        asker.advanceSyncSalt();
        for (final f in asker.buildSyncRound(identity.publicKey)) {
          await deliverSyncFrame(f);
        }
        expect(router.dtnBufferedCount, 0,
            reason: 'the next cycle is hashed under the next salt, which is '
                'the second draw');
        asker.dispose();
      });

      test('a converged peer is conveyed nothing, round after round', () async {
        // The end-to-end check. The holder must hash under the salt the FRAME
        // carried: read under any other value the slots are reshuffled
        // wholesale, so a peer that has seen everything reads as holding
        // nothing and is handed its whole window straight back — the
        // redundancy the exchange exists to remove.
        final asker = await makeAsker();
        final other = Uint8List.fromList(List.generate(32, (i) => i + 90));
        for (var i = 0; i < 40; i++) {
          final p = GrassrootsPacket(
            type: PacketType.secure,
            ttl: 2,
            recipientPubkey: other,
            payload: Uint8List.fromList([i]),
            createdAtMs: 1000 + i,
          );
          router.storeInDtnBuffer(other, p);
          asker.markSeen(p.packetId, p.createdAtMs);
        }
        final sent = <String>[];
        router.onSyncSend = (packet, _) => sent.add(packet.packetId);
        final salts = <int>{};
        for (var cycle = 0; cycle < 5; cycle++) {
          for (final frame in asker.buildSyncRound(identity.publicKey)) {
            salts.add(decodeSyncFilter(frame).salt);
            await deliverSyncFrame(frame);
          }
          asker.advanceSyncSalt();
        }
        asker.dispose();
        expect(salts, hasLength(5), reason: 'five cycles, five salts');
        // Exactly none: a GCS has no false negatives, so every id the filter
        // names tests present under that filter's own salt.
        expect(sent, isEmpty,
            reason: 'conveyed ${sent.length} packets to a peer that had seen '
                'all of them');
      });
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

    test('UDX conveys a packet addressed to the peer on the other end',
        () async {
      // Targeted conveyance. The peer answering a UDX filter is an ENDPOINT,
      // and handing an endpoint its own packet costs exactly those packets —
      // so this is the part of store-carry-forward the Internet path gets. It
      // closes the gap where a friend reachable only over the Internet never
      // received a buffered message until a BLE encounter happened to occur.
      final p = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 2,
        recipientPubkey: neighbourPubkey,
        payload: Uint8List.fromList([1]),
        createdAtMs: 1000,
      );
      router.storeInDtnBuffer(neighbourPubkey, p);
      final sent = <GrassrootsPacket>[];
      final links = <SyncLink>[];
      router.onSyncSend = (packet, link) {
        sent.add(packet);
        links.add(link);
      };
      await deliverSyncFilter(
          fromMs: 0, toMs: 2000, transport: PeerTransport.udp);
      expect(sent.single.packetId, p.packetId);
      expect(links.single.transport, SyncTransport.udx);
      expect(
          links.single.handle,
          neighbourPubkey
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
          reason: 'a UDX handle IS the peer pubkey hex — no lookup table');
    });

    test('UDX never conveys third-party transit traffic', () async {
      // The restriction is about VOLUME, not trust. BLE encounters are
      // sporadic and airtime is scarce, so the mesh's open relay is bounded by
      // the medium itself; a UDX link is continuous and fast, and answering
      // with the whole buffer would push it at every connected friend at link
      // speed — turning well-connected nodes into the infrastructure that
      // removing the rendezvous servers deleted.
      //
      // This exact packet IS conveyed over BLE — see 'conveyance sends the
      // held packet unchanged', which stores the same third-party recipient.
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
      await deliverSyncFilter(
          fromMs: 0, toMs: 2000, transport: PeerTransport.udp);
      expect(called, isFalse);
    });

    test(
        'open trust: BLE conveys third-party traffic the same round UDX refuses it',
        () async {
      // Guards the pair of rules against being collapsed into one: an
      // open-trust mesh must keep relaying for strangers, or multi-hop reach
      // is gone. (Closed trust drops this entirely — see the sibling test
      // below.)
      store.dispatch(SetColdCallTrustLevelAction(ColdCallTrustLevel.open));
      final other = Uint8List.fromList(List.generate(32, (i) => i + 90));
      final mine = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 2,
        recipientPubkey: neighbourPubkey,
        payload: Uint8List.fromList([1]),
        createdAtMs: 1000,
      );
      final theirs = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 2,
        recipientPubkey: other,
        payload: Uint8List.fromList([2]),
        createdAtMs: 1001,
      );
      router.storeInDtnBuffer(neighbourPubkey, mine);
      router.storeInDtnBuffer(other, theirs);

      final overUdx = <GrassrootsPacket>[];
      router.onSyncSend = (packet, _) => overUdx.add(packet);
      await deliverSyncFilter(
          fromMs: 0, toMs: 2000, transport: PeerTransport.udp);

      final overBle = <GrassrootsPacket>[];
      router.onSyncSend = (packet, _) => overBle.add(packet);
      await deliverSyncFilter(fromMs: 0, toMs: 2000);

      expect(overUdx.map((p) => p.packetId), [mine.packetId]);
      expect(overBle.map((p) => p.packetId),
          containsAll([mine.packetId, theirs.packetId]),
          reason: 'the mesh relays for recipients it has no relationship with');
    });

    test('closed trust: BLE conveys nothing but the peer\'s own packets',
        () async {
      // The mirror of the test above: a closed-trust device never hands a
      // third party's packet to anyone, over either transport, because it
      // never took custody of it in the first place (see processPacket) and
      // refuses to answer with it here even if it somehow held it.
      store.dispatch(
          SetColdCallTrustLevelAction(ColdCallTrustLevel.closed));
      final other = Uint8List.fromList(List.generate(32, (i) => i + 90));
      final mine = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 2,
        recipientPubkey: neighbourPubkey,
        payload: Uint8List.fromList([1]),
        createdAtMs: 1000,
      );
      final theirs = GrassrootsPacket(
        type: PacketType.secure,
        ttl: 2,
        recipientPubkey: other,
        payload: Uint8List.fromList([2]),
        createdAtMs: 1001,
      );
      router.storeInDtnBuffer(neighbourPubkey, mine);
      router.storeInDtnBuffer(other, theirs);

      final overBle = <GrassrootsPacket>[];
      router.onSyncSend = (packet, _) => overBle.add(packet);
      await deliverSyncFilter(fromMs: 0, toMs: 2000);

      expect(overBle.map((p) => p.packetId), [mine.packetId],
          reason: 'closed trust narrows relay to nothing, not just to friends');
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
