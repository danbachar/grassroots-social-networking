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

  test('windowFrom returns seen ids by creation time, oldest first, capped',
      () {
    final seen = SeenPackets();
    // Insert out of creation order; the window must sort by createdAtMs.
    seen.add('c', 3000);
    seen.add('a', 1000);
    seen.add('b', 2000);
    final w = seen.windowFrom(0, limit: 10);
    expect([for (final e in w) e.id], ['a', 'b', 'c']);
    // A cursor advanced past 'a' excludes it.
    final w2 = seen.windowFrom(2000, limit: 10);
    expect([for (final e in w2) e.id], ['b', 'c']);
  });

  test('windowFrom cuts on a whole-millisecond boundary', () {
    final seen = SeenPackets();
    // Three ids share stamp 5000; the limit lands mid-group, so the whole
    // group is dropped rather than split (else the left-out ones look missing).
    seen.add('x1', 5000);
    seen.add('x2', 5000);
    seen.add('x3', 5000);
    seen.add('older', 1000);
    final w = seen.windowFrom(0, limit: 2);
    // limit 2 lands inside the 5000 group -> only the 1000 id survives the cut.
    expect([for (final e in w) e.id], ['older']);
  });
}
