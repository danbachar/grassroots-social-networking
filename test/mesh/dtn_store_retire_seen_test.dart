import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/grassroots_networking.dart';
import 'package:grassroots_networking/src/mesh/dtn_store.dart';

void main() {
  GrassrootsPacket pkt() => GrassrootsPacket(
      type: PacketType.secure, ttl: 3, payload: Uint8List(20));

  test('retires what the recipient says it has seen, but only if retirable',
      () {
    final s = DtnStore();
    final transit = pkt(); // carried for someone else
    final ownAck = pkt(); // our confirmation
    final ownData = pkt(); // our undelivered message
    s.store('peer', transit, retirableOnSeen: true);
    s.store('peer', ownAck, retirableOnSeen: true);
    s.store('peer', ownData); // default: NOT retirable
    final drops = <(String, String)>[];
    s.onDrop = (r, _, p) => drops.add((r, p.packetId));

    // two votes, different windows
    expect(s.retireSeenFor('peer', (_) => true, fromMs: 0, toMs: 1 << 62, voteSalt: 1), 0,
        reason: 'one vote must never retire');
    final n = s.retireSeenFor('peer', (_) => true, fromMs: 1, toMs: 1 << 62, voteSalt: 2);

    expect(n, 2, reason: 'own undelivered data must survive');
    expect(drops.map((d) => d.$1).toSet(), {'retiredSeen'});
    expect(drops.map((d) => d.$2).toSet(), {transit.packetId, ownAck.packetId});
    expect(s.packetsFor('peer').map((p) => p.packetId), [ownData.packetId]);
  });

  test('only the asking peer\'s own bucket is touched', () {
    final s = DtnStore();
    final mine = pkt();
    final theirs = pkt();
    s.store('peer', mine, retirableOnSeen: true);
    s.store('other', theirs, retirableOnSeen: true);

    s.retireSeenFor('peer', (_) => true, fromMs: 0, toMs: 1 << 62, voteSalt: 1);
    s.retireSeenFor('peer', (_) => true, fromMs: 1, toMs: 1 << 62, voteSalt: 2);

    expect(s.packetsFor('peer'), isEmpty);
    expect(s.packetsFor('other').map((p) => p.packetId), [theirs.packetId],
        reason: 'a peer speaks only for its own traffic');
  });

  test('nothing is retired for a packet the filter does not report', () {
    final s = DtnStore();
    final held = pkt();
    s.store('peer', held, retirableOnSeen: true);
    final n = s.retireSeenFor('peer', (_) => false, fromMs: 0, toMs: 1 << 62, voteSalt: 1);
    expect(n, 0);
    expect(s.packetsFor('peer'), hasLength(1));
  });

  test('the byte ledger follows a retirement', () {
    final s = DtnStore();
    s.store('peer', pkt(), retirableOnSeen: true);
    final before = s.totalBytes;
    expect(before, greaterThan(0));
    s.retireSeenFor('peer', (_) => true, fromMs: 0, toMs: 1 << 62, voteSalt: 1);
    s.retireSeenFor('peer', (_) => true, fromMs: 1, toMs: 1 << 62, voteSalt: 2);
    expect(s.totalBytes, 0, reason: 'ledger must not drift');
    expect(s.totalCount, 0);
  });

  test('a packet OUTSIDE the declared window is never retired', () {
    // The filter asserts membership only over [fromMs, toMs]; outside it a
    // hit is a hash collision, not evidence. A packet missed this round is
    // covered when the asker's cursor sweeps back over it.
    final s = DtnStore();
    final p = pkt();
    s.store('peer', p, retirableOnSeen: true);
    final created = s.packetsFor('peer').single.createdAtMs;
    expect(s.retireSeenFor('peer', (_) => true,
            fromMs: created + 1000, toMs: created + 2000, voteSalt: 1),
        0, reason: 'window starts after the packet was created');
    expect(s.retireSeenFor('peer', (_) => true,
            fromMs: created - 2000, toMs: created - 1000, voteSalt: 1),
        0, reason: 'window ends before the packet was created');
    expect(s.packetsFor('peer'), hasLength(1));
    // and it IS retired once a window covers it
    expect(s.retireSeenFor('peer', (_) => true,
            fromMs: created - 10, toMs: created + 10, voteSalt: 1),
        0, reason: 'first vote');
    expect(s.retireSeenFor('peer', (_) => true,
            fromMs: created - 11, toMs: created + 10, voteSalt: 2),
        1, reason: 'second vote, different window');
  });

  test('a CHANGED window under ONE salt never retires', () {
    // The prefix frame is built over [floorMs, nowMs], so `toMs` advances
    // every round even on a node that has seen nothing new. Keying the vote
    // on the window would score an unchanged draw as a fresh one and let a
    // collision confirm itself.
    final s = DtnStore();
    s.store('peer', pkt(), retirableOnSeen: true);
    final c = s.packetsFor('peer').single.createdAtMs;
    for (var i = 0; i < 20; i++) {
      expect(
          s.retireSeenFor('peer', (_) => true,
              fromMs: c - 5, toMs: c + 5 + i, voteSalt: 7),
          0,
          reason: 'the window moved but the hash did not');
    }
    expect(s.packetsFor('peer'), hasLength(1));
    expect(
        s.retireSeenFor('peer', (_) => true,
            fromMs: c - 5, toMs: c + 5, voteSalt: 8),
        1,
        reason: 'another salt is a fresh draw');
  });

  test('two frames of ONE round cannot retire between them', () {
    // Every frame of a round is hashed under that round's salt, so a packet
    // named by two of them --- which is what an overlap between the prefix
    // and the sweep produces --- has one hash target tested twice, not two
    // draws. Keying the vote on anything the frames differ in (their windows,
    // their id sets) would count that pair and retire on a single roll.
    final s = DtnStore();
    s.store('peer', pkt(), retirableOnSeen: true);
    final c = s.packetsFor('peer').single.createdAtMs;
    expect(
        s.retireSeenFor('peer', (_) => true,
            fromMs: c - 500, toMs: c + 5, voteSalt: 3),
        0);
    expect(
        s.retireSeenFor('peer', (_) => true,
            fromMs: c - 5, toMs: c + 500, voteSalt: 3),
        0,
        reason: 'a second frame of the same round is the same draw');
    expect(s.packetsFor('peer'), hasLength(1));
    expect(
        s.retireSeenFor('peer', (_) => true,
            fromMs: c - 5, toMs: c + 5, voteSalt: 4),
        1,
        reason: 'the next ROUND is what supplies the second draw');
  });

  test('a covering filter that does not name it CLEARS the standing vote', () {
    // Otherwise the rule is "two confirmations ever" rather than two in a
    // row, and independent rolls accumulate over the entry's whole life.
    final s = DtnStore();
    s.store('peer', pkt(), retirableOnSeen: true);
    final c = s.packetsFor('peer').single.createdAtMs;
    // vote 1
    expect(s.retireSeenFor('peer', (_) => true,
        fromMs: c - 5, toMs: c + 5, voteSalt: 1), 0);
    // a covering filter that says NOT seen -> vote spent
    expect(s.retireSeenFor('peer', (_) => false,
        fromMs: c - 5, toMs: c + 5, voteSalt: 2), 0);
    // so this is vote 1 again, not vote 2
    expect(s.retireSeenFor('peer', (_) => true,
        fromMs: c - 5, toMs: c + 5, voteSalt: 3), 0);
    expect(s.packetsFor('peer'), hasLength(1));
    // and the one after it is vote 2
    expect(s.retireSeenFor('peer', (_) => true,
        fromMs: c - 5, toMs: c + 5, voteSalt: 4), 1);
  });

  test('a filter that does not COVER the packet leaves the vote standing', () {
    // Out of window says nothing either way, so it must not spend the vote.
    final s = DtnStore();
    s.store('peer', pkt(), retirableOnSeen: true);
    final c = s.packetsFor('peer').single.createdAtMs;
    expect(s.retireSeenFor('peer', (_) => true,
        fromMs: c - 5, toMs: c + 5, voteSalt: 1), 0);
    expect(s.retireSeenFor('peer', (_) => false,
        fromMs: c + 1000, toMs: c + 2000, voteSalt: 2), 0);
    expect(s.retireSeenFor('peer', (_) => true,
        fromMs: c - 5, toMs: c + 5, voteSalt: 3), 1,
        reason: 'the out-of-window round must not have spent the vote');
  });

  test('a vote that does not repeat leaves the packet in place', () {
    // The collision was transient: the next filter says nothing about it.
    final s = DtnStore();
    s.store('peer', pkt(), retirableOnSeen: true);
    final c = s.packetsFor('peer').single.createdAtMs;
    expect(s.retireSeenFor('peer', (_) => true, fromMs: c - 5, toMs: c + 5, voteSalt: 1), 0);
    expect(
        s.retireSeenFor('peer', (_) => false, fromMs: c - 6, toMs: c + 5, voteSalt: 2), 0);
    expect(s.packetsFor('peer'), hasLength(1),
        reason: 'a single stray vote must not be enough');
  });

  test('an empty or unknown bucket is a no-op', () {
    final s = DtnStore();
    expect(s.retireSeenFor('nobody', (_) => true, fromMs: 0, toMs: 1 << 62, voteSalt: 1), 0);
  });
}
