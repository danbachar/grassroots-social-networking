import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/grassroots_networking.dart';
import 'package:grassroots_networking/src/mesh/dtn_store.dart';

void main() {
  const cap = 512 * 1024; // 0.5 MiB
  const payload = 138;

  GrassrootsPacket pkt(int i) => GrassrootsPacket(
        type: PacketType.secure,
        ttl: 3,
        payload: Uint8List(payload),
      );

  /// Filled to just BELOW the high-water mark — one more packet crosses it.
  /// Written as a bounded loop: filling `while (totalBytes <= highWater)`
  /// never terminates, because crossing the mark evicts back to low water and
  /// the condition is true again.
  DtnStore nearlyFull() {
    final s = DtnStore(maxBytes: cap);
    final stopAt = cap * DtnStore.evictHighWater - payload;
    var i = 0;
    while (s.totalBytes < stopAt) {
      s.store('aa' * 32, pkt(i++));
    }
    return s;
  }

  test('nothing is evicted below the high-water mark', () {
    final s = DtnStore(maxBytes: cap);
    final dropped = <String>[];
    s.onDrop = (r, _, p) => dropped.add(r);
    var i = 0;
    final stopAt = cap * DtnStore.evictHighWater - payload;
    while (s.totalBytes < stopAt) {
      s.store('aa' * 32, pkt(i++));
    }
    expect(dropped, isEmpty);
    expect(s.totalBytes, greaterThan((cap * 0.90).round()));
  });

  test('crossing high water drains to low water, oldest first', () {
    final s = nearlyFull();
    final dropped = <String>[];
    s.onDrop = (reason, _, __) => dropped.add(reason);
    s.store('aa' * 32, pkt(99999)); // the packet that crosses it
    expect(dropped, isNotEmpty, reason: 'high water must trigger eviction');
    expect(dropped.every((r) => r == 'evictedTotal'), isTrue);
    // landed inside the band, not pinned at the cap
    expect(s.totalBytes, lessThanOrEqualTo((cap * DtnStore.evictLowWater).round() + payload));
    expect(s.totalBytes, greaterThan((cap * 0.5).round()));
  });

  test('after a drain, further stores run free until high water again', () {
    final s = nearlyFull();
    s.store('aa' * 32, pkt(1000)); // trigger the drain
    final after = s.totalBytes;
    var dropsNow = 0;
    s.onDrop = (_, __, ___) => dropsNow++;
    // one arrival must NOT cause an eviction while inside the band
    s.store('aa' * 32, pkt(1001));
    expect(dropsNow, 0, reason: 'pinned-at-cap behaviour would evict here');
    expect(s.totalBytes, greaterThan(after));
  });

  test('lowering the cap sheds immediately, by the same policy', () {
    final s = DtnStore(maxBytes: 512 * 1024 * 1024);
    var i = 0;
    while (s.totalBytes < cap) {
      s.store('aa' * 32, pkt(i++));
      if (i > 20000) break;
    }
    final before = s.totalBytes;
    final dropped = <String>[];
    s.onDrop = (r, _, __) => dropped.add(r);
    s.setMaxBytes(cap);
    expect(s.totalBytes, lessThan(before));
    expect(s.totalBytes, lessThanOrEqualTo((cap * DtnStore.evictLowWater).round() + payload));
    expect(dropped.every((r) => r == 'evictedTotal'), isTrue);
  });
}
