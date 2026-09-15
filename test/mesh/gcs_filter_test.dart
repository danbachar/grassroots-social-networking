import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:grassroots_networking/src/mesh/gcs_filter.dart';

/// The compact "what I already hold" advertisement. The property that must
/// hold absolutely is NO FALSE NEGATIVES: a packet the advertiser holds must
/// never test absent, because the peer sends exactly what the filter says is
/// missing, and a false negative would mean re-sending something forever.
/// False POSITIVES are allowed and bounded — they withhold a packet for one
/// round.
void main() {
  const uuid = Uuid();

  test('every id in the filter tests present — no false negatives', () {
    final ids = List.generate(200, (_) => uuid.v4());
    for (final salt in [0, 1, 7, 255]) {
      final f = GcsFilter.build(ids, salt: salt);
      final values = GcsFilter.decode(data: f.data, n: f.n);
      for (final id in ids.take(f.n)) {
        expect(GcsFilter.mightContain(values, f.n, id, salt: salt), isTrue,
            reason: 'a held packet must never look missing at salt $salt: $id');
      }
    }
  });

  test('the false-positive rate is near 2^-p, and that is the whole cost', () {
    final held = List.generate(300, (_) => uuid.v4());
    final f = GcsFilter.build(held, salt: 0);
    final values = GcsFilter.decode(data: f.data, n: f.n);
    var positives = 0;
    const trials = 20000;
    for (var i = 0; i < trials; i++) {
      if (GcsFilter.mightContain(values, f.n, uuid.v4(), salt: 0)) positives++;
    }
    final rate = positives / trials;
    // p = 7 targets 1/128 = 0.0078. Allow generous slack: this asserts the
    // ORDER of the rate, not a tuned constant, so it cannot fail on hash luck.
    expect(rate, lessThan(0.03),
        reason: 'measured $rate, expected about ${1 / GcsFilter.fprOneIn}');
  });

  test('it is far denser than the id list it replaces', () {
    // The comparison that motivated the change: 16 bytes per id, 8 per sealed
    // BLE write, against p+2 bits per id in one filter.
    final ids = List.generate(GcsFilter.maxElements, (_) => uuid.v4());
    final f = GcsFilter.build(ids, salt: 0);
    expect(f.n, GcsFilter.maxElements);
    expect(f.data.length, lessThanOrEqualTo(GcsFilter.maxPayloadBytes));
    final asIdList = ids.length * 16;
    expect(f.data.length * 4, lessThan(asIdList),
        reason: 'a filter must be several times smaller than the ids: '
            '${f.data.length} B vs $asIdList B for ${ids.length} ids');
  });

  test('a window larger than one filter advertises its OLDEST slice', () {
    // Not a silent drop: the caller advances the window and the rest ride a
    // later round. Oldest first because a window pinned to the recent tail
    // would never reconcile anything below its lower bound, and those are the
    // longest-waiting packets — the backlog store-carry-forward exists for.
    final ids = List.generate(GcsFilter.maxElements + 500, (i) => uuid.v4());
    final f = GcsFilter.build(ids, salt: 0);
    expect(f.n, GcsFilter.maxElements);
    final values = GcsFilter.decode(data: f.data, n: f.n);
    expect(GcsFilter.mightContain(values, f.n, ids.first, salt: 0), isTrue,
        reason: 'the longest-waiting packet is advertised first');
  });

  test('an empty buffer is an empty filter, and nothing tests present', () {
    final f = GcsFilter.build(const [], salt: 0);
    expect(f.n, 0);
    expect(f.data, isEmpty);
    expect(GcsFilter.mightContain(const [], 0, uuid.v4(), salt: 0), isFalse);
  });

  test('a truncated payload throws rather than decoding short', () {
    // Clean-break rule: a filter that does not fit is malformed, not smaller.
    final ids = List.generate(50, (_) => uuid.v4());
    final f = GcsFilter.build(ids, salt: 0);
    final cut = f.data.sublist(0, f.data.length ~/ 2);
    expect(() => GcsFilter.decode(data: cut, n: f.n), throwsFormatException);
  });

  test('the same ids in a different order produce the same membership', () {
    // Values are sorted before delta-coding, so insertion order cannot change
    // what the filter says — two nodes holding the same set agree.
    final ids = List.generate(60, (_) => uuid.v4());
    final a = GcsFilter.build(ids, salt: 3);
    final b = GcsFilter.build(ids.reversed.toList(), salt: 3);
    expect(a.data, equals(b.data));
  });

  group('GcsFilter — a narrow leg\'s budget', () {
    test('build honours a payload budget smaller than the default', () {
      final ids = List.generate(300, (i) => 'id-$i');
      // A leg that settled at MTU 185 leaves far less than the 119-byte
      // default: the filter must shrink to fit rather than be truncated on
      // the air.
      final narrow = GcsFilter.build(ids, salt: 0, maxPayloadBytes: 40);
      expect(narrow.data.length, lessThanOrEqualTo(40));
      expect(narrow.n, GcsFilter.maxElementsFor(40));
      expect(narrow.n, lessThan(GcsFilter.maxElements));
      // What it does name, it names correctly.
      final values = GcsFilter.decode(data: narrow.data, n: narrow.n);
      expect(
          GcsFilter.mightContain(values, narrow.n, 'id-0', salt: 0), isTrue);
    });
  });

  group('GcsFilter — the per-round salt', () {
    // Deterministic ids: these assert a property of the hash, so a run that
    // fails must fail every time rather than on the draw.
    final held = List.generate(300, (i) => 'held-$i');

    test('the same ids under two salts are two different filters', () {
      final a = GcsFilter.build(held, salt: 0);
      final b = GcsFilter.build(held, salt: 1);
      expect(a.n, b.n, reason: 'the salt changes slots, never membership');
      expect(a.data, isNot(equals(b.data)));
    });

    test('a false positive at one salt is redrawn at the next, not repeated',
        () {
      // The property the whole salt exists for. Without it a sweep frame's
      // window is historical, its id set never changes, and the cursor's wrap
      // rebuilds the identical filter — so the same packet is withheld on
      // every pass and is not delayed but permanently invisible to that peer.
      //
      // Salts 0 and 1 on purpose: consecutive rounds differ in the low bit,
      // which is FNV's parity bit and one of the bits the modulus reads, so
      // it is the salt step most exposed to the hash's own structure.
      final f0 = GcsFilter.build(held, salt: 0);
      final f1 = GcsFilter.build(held, salt: 1);
      final v0 = GcsFilter.decode(data: f0.data, n: f0.n);
      final v1 = GcsFilter.decode(data: f1.data, n: f1.n);

      final collided = <String>[];
      for (var i = 0; i < 40000; i++) {
        final id = 'probe-$i';
        if (GcsFilter.mightContain(v0, f0.n, id, salt: 0)) collided.add(id);
      }
      expect(collided.length, greaterThan(50),
          reason: 'too few collisions to say anything — the test would pass '
              'vacuously');
      final again = [
        for (final id in collided)
          if (GcsFilter.mightContain(v1, f1.n, id, salt: 1)) id,
      ];
      // Independent draws put the survivors at collided/128. Eight times that
      // is a wide margin and still nowhere near the "carried through
      // unchanged" outcome, which would keep all of them.
      expect(again.length, lessThan(collided.length / 8),
          reason: '${again.length} of ${collided.length} collisions survived '
              'the salt change — the rounds are not independent draws');
    });

    test('a lookup under the wrong salt loses the ids the filter names', () {
      // Why the salt rides the frame and not the announce. It is not a
      // slightly degraded answer: the slots are reshuffled wholesale, so a
      // peer that holds everything reads as holding nothing and is conveyed
      // its entire window back.
      final f = GcsFilter.build(held, salt: 9);
      final values = GcsFilter.decode(data: f.data, n: f.n);
      final named = held.take(f.n).toList();
      final stillFound = [
        for (final id in named)
          if (GcsFilter.mightContain(values, f.n, id, salt: 10)) id,
      ];
      expect(stillFound.length, lessThan(named.length / 10),
          reason: 'the wrong salt must not read as a working filter');
    });

    test('the rate itself does not move with the salt', () {
      // The salt decides WHICH id pays, never how often: 2^-p is structural,
      // n ids over n * 2^p slots, and no entropy in the hash input moves it.
      const trials = 40000;
      final rates = <double>[];
      for (final salt in [0, 1, 128, 255]) {
        final f = GcsFilter.build(held, salt: salt);
        final values = GcsFilter.decode(data: f.data, n: f.n);
        var positives = 0;
        for (var i = 0; i < trials; i++) {
          if (GcsFilter.mightContain(values, f.n, 'probe-$i', salt: salt)) {
            positives++;
          }
        }
        rates.add(positives / trials);
      }
      for (final r in rates) {
        expect(r, lessThan(0.03), reason: 'rates: $rates');
        expect(r, greaterThan(0.001), reason: 'rates: $rates');
      }
    });
  });
}
