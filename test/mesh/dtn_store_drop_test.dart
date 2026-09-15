import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/mesh/dtn_store.dart';
import 'package:grassroots_networking/src/models/packet.dart';

GrassrootsPacket _packet(int payloadLen) => GrassrootsPacket(
      type: PacketType.secure,
      ttl: 5,
      recipientPubkey: Uint8List(32),
      payload: Uint8List(payloadLen),
    );

void main() {
  test('age expiry reports every dropped packet with reason expired', () {
    final store = DtnStore(maxAge: const Duration(minutes: 1));
    final drops = <(String, String)>[];
    store.onDrop =
        (reason, recipient, packet) => drops.add((reason, packet.packetId));

    final t0 = DateTime(2026, 1, 1);
    final p = _packet(100);
    store.store('aa', p, now: t0);
    expect(store.totalBytes, 100);

    // Any access past maxAge prunes — and must SAY so.
    store.carriedPacketIds(now: t0.add(const Duration(minutes: 2)));

    expect(drops, [('expired', p.packetId)]);
    expect(store.totalCount, 0);
    expect(store.totalBytes, 0, reason: 'byte ledger follows the eviction');
  });

  test('store-wide cap eviction reports evictedTotal, oldest first', () {
    // The bound is BYTES, and eviction has hysteresis: crossing
    // [DtnStore.evictHighWater] drains to [DtnStore.evictLowWater] rather
    // than shedding one packet to land on the ceiling. So 10 + 20 + 30
    // against a 50-byte cap shed BOTH older packets to reach the 40-byte
    // low-water mark, oldest first.
    final store = DtnStore(maxBytes: 50);
    final drops = <(String, String)>[];
    store.onDrop =
        (reason, recipient, packet) => drops.add((reason, packet.packetId));

    final t0 = DateTime(2026, 1, 1);
    final first = _packet(10);
    final second = _packet(20);
    store.store('aa', first, now: t0);
    store.store('bb', second, now: t0.add(const Duration(seconds: 1)));
    store.store('cc', _packet(30), now: t0.add(const Duration(seconds: 2)));

    expect(drops, [
      ('evictedTotal', first.packetId),
      ('evictedTotal', second.packetId),
    ]);
    expect(store.totalCount, 1);
    expect(store.totalBytes, 30,
        reason: 'drained to at or below the low-water mark');
  });

  test('recipient-cap eviction reports every packet of the evicted recipient',
      () {
    final store = DtnStore(maxRecipients: 1);
    final drops = <(String, String)>[];
    store.onDrop =
        (reason, recipient, packet) => drops.add((reason, recipient));

    final t0 = DateTime(2026, 1, 1);
    store.store('aa', _packet(10), now: t0);
    store.store('aa', _packet(10), now: t0);
    store.store('bb', _packet(10), now: t0.add(const Duration(seconds: 1)));

    expect(drops.map((d) => d.$1).toSet(), {'evictedRecipients'});
    expect(drops.map((d) => d.$2).toSet(), {'aa'},
        reason: 'the whole oldest recipient goes at once');
    expect(drops, hasLength(2));
    expect(store.totalBytes, 10);
  });

  test('ACK removal (removeById) is NOT reported — the caller narrates it',
      () {
    final store = DtnStore();
    final drops = <String>[];
    store.onDrop = (reason, _, __) => drops.add(reason);

    final p = _packet(40);
    store.store('aa', p);
    store.removeById(p.packetId);

    expect(drops, isEmpty);
    expect(store.totalBytes, 0);
  });
}
