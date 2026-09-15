import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/mesh/seen_packets.dart';

/// The wire-dedup set must remember a seen packetId until no copy of it can
/// still be in any DTN buffer — never a wholesale clear that forgets under
/// load. It also carries each packet's own createdAtMs so it can be windowed
/// by creation time and advertised as the GCS sync filter (what we have SEEN,
/// so a peer does not resend it).
void main() {
  test('checkAndAdd reports first-seen then duplicate', () {
    final seen = SeenPackets();
    expect(seen.checkAndAdd('p1', 1000), isFalse);
    expect(seen.checkAndAdd('p1', 1000), isTrue);
    expect(seen.contains('p1'), isTrue);
  });

  test('does NOT rotate under load — an early id survives 20k later ids', () {
    // The old bloom cleared at 10,000 items; a persistent set must not.
    final seen = SeenPackets();
    seen.add('early', 1000);
    for (var i = 0; i < 20000; i++) {
      seen.add('bulk-$i', 2000 + i);
    }
    expect(seen.contains('early'), isTrue,
        reason: 'a seen id must survive past the old 10k rotation threshold');
    expect(seen.length, 20001);
  });

  test('an id ages out only after maxAge (matched to the buffer)', () {
    final seen = SeenPackets(maxAge: const Duration(hours: 6));
    final t0 = DateTime(2026, 1, 1);
    seen.add('p', 1000, now: t0);
    expect(seen.contains('p', now: t0.add(const Duration(hours: 5))), isTrue);
    expect(seen.contains('p', now: t0.add(const Duration(hours: 7))), isFalse);
  });

  test('first-seen timestamp is not refreshed by a duplicate', () {
    final seen = SeenPackets(maxAge: const Duration(hours: 6));
    final t0 = DateTime(2026, 1, 1);
    seen.checkAndAdd('p', 1000, now: t0);
    seen.checkAndAdd('p', 1000, now: t0.add(const Duration(hours: 5)));
    expect(seen.contains('p', now: t0.add(const Duration(hours: 7))), isFalse,
        reason: 'a chatty duplicate stream must not pin an entry forever');
  });

  test('newest returns seen ids by creation time, oldest first', () {
    final seen = SeenPackets();
    // Insert out of creation order; the selection must sort by createdAtMs.
    seen.add('c', 3000);
    seen.add('a', 1000);
    seen.add('b', 2000);
    expect([for (final e in seen.newest(10)) e.id], ['a', 'b', 'c']);
  });

  test('newest keeps the NEWEST ids when the set is larger than the limit', () {
    // The measured defect this replaces: a window walking forward from a
    // cursor left 95.6% of the mail a holder carried for the asker BELOW the
    // asker's advertised floor, never asked about. A prefix is anchored at the
    // newest end instead, so what a peer asks for is the traffic still in
    // flight — the oldest ids are what falls off, not the newest.
    final seen = SeenPackets();
    for (var i = 0; i < 500; i++) {
      seen.add('p$i', 1000 + i);
    }
    final w = seen.newest(100);
    // 99, not 100: the oldest stamp in a truncated selection is cut away, so
    // the floor the caller derives from it cannot land inside a stamp group.
    expect(w, hasLength(99));
    expect(w.first.createdAtMs, 1401);
    expect(w.last.createdAtMs, 1499);
    expect([for (final e in w) e.createdAtMs], isNot(contains(1000)));
  });

  test('newest is oldest-first even when arrival order is not creation order',
      () {
    // createdAtMs is the ORIGINATOR's stamp, so a carried backlog arrives long
    // out of creation order — the selection cannot lean on insertion order.
    final seen = SeenPackets();
    for (var i = 0; i < 200; i++) {
      seen.add('late$i', 9000 - i); // descending stamps
    }
    final w = seen.newest(50);
    expect([for (final e in w) e.createdAtMs],
        List.generate(49, (i) => 8952 + i),
        reason: 'the newest stamps, ascending, less the cut floor');
  });

  test('a truncated selection is cut back to a whole millisecond at its floor',
      () {
    // The caller turns the oldest included stamp into the round's floor. A
    // floor landing inside a group sharing one stamp puts the ids left out
    // INSIDE the advertised window while naming none of them, which reads as
    // absence and pulls them straight back.
    final seen = SeenPackets();
    seen.add('x1', 5000);
    seen.add('x2', 5000);
    seen.add('x3', 5000);
    seen.add('newer', 6000);
    final w = seen.newest(2);
    // limit 2 would take one of the 5000 group plus 'newer'; the partial group
    // goes, leaving only the id above it.
    expect([for (final e in w) e.id], ['newer']);
  });

  test('a selection that is entirely one millisecond is advertised as-is', () {
    // Nothing to cut back to. Refusing to advertise would stall the exchange
    // forever; the bounded cost is that one stamp may re-list.
    final seen = SeenPackets();
    for (var i = 0; i < 5; i++) {
      seen.add('same$i', 5000);
    }
    expect(seen.newest(3), hasLength(3));
  });

  test('windowFrom returns seen ids by creation time, oldest first, capped',
      () {
    final seen = SeenPackets();
    // Insert out of creation order; the window must sort by createdAtMs.
    seen.add('c', 3000);
    seen.add('a', 1000);
    seen.add('b', 2000);
    expect([for (final e in seen.windowFrom(0, limit: 10)) e.id],
        ['a', 'b', 'c']);
    // A cursor advanced past 'a' excludes it.
    expect([for (final e in seen.windowFrom(2000, limit: 10)) e.id],
        ['b', 'c']);
  });

  test('windowFrom cuts on a whole-millisecond boundary', () {
    final seen = SeenPackets();
    // Three ids share stamp 5000; the limit lands mid-group, so the whole
    // group is dropped rather than split (else the left-out ones look missing).
    seen.add('x1', 5000);
    seen.add('x2', 5000);
    seen.add('x3', 5000);
    seen.add('older', 1000);
    // limit 2 lands inside the 5000 group -> only the 1000 id survives the cut.
    expect([for (final e in seen.windowFrom(0, limit: 2)) e.id], ['older']);
  });

  test('windowFrom keeps the OLDEST eligible ids, not an arbitrary slice', () {
    // The sweep serves the longest waiters first, so a bounded selection has
    // to keep the bottom of the range it is given — the mirror of [newest].
    final seen = SeenPackets();
    for (var i = 0; i < 500; i++) {
      seen.add('p$i', 1000 + i);
    }
    final w = seen.windowFrom(1200, limit: 50);
    expect(w.first.createdAtMs, 1200);
    expect(w, hasLength(49), reason: 'less the partial trailing millisecond');
  });

  test('newest excludes aged-out ids', () {
    final seen = SeenPackets(maxAge: const Duration(hours: 6));
    final t0 = DateTime(2026, 1, 1);
    seen.add('old', 1000, now: t0);
    seen.add('fresh', 2000, now: t0.add(const Duration(hours: 5)));
    final w = seen.newest(10, now: t0.add(const Duration(hours: 7)));
    expect([for (final e in w) e.id], ['fresh']);
  });
}
