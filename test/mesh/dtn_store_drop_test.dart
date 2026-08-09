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
    final store = DtnStore(maxTotal: 2);
    final drops = <(String, String)>[];
    store.onDrop =
        (reason, recipient, packet) => drops.add((reason, packet.packetId));

    final t0 = DateTime(2026, 1, 1);
    final first = _packet(10);
    store.store('aa', first, now: t0);
    store.store('bb', _packet(20), now: t0.add(const Duration(seconds: 1)));
    store.store('cc', _packet(30), now: t0.add(const Duration(seconds: 2)));

    expect(drops, [('evictedTotal', first.packetId)]);
    expect(store.totalCount, 2);
    expect(store.totalBytes, 50);
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
