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
    final f = GcsFilter.build(ids);
    final values = GcsFilter.decode(data: f.data, n: f.n);
    for (final id in ids.take(f.n)) {
      expect(GcsFilter.mightContain(values, f.n, id), isTrue,
          reason: 'a held packet must never look missing: $id');
    }
  });

  test('the false-positive rate is near 2^-p, and that is the whole cost', () {
    final held = List.generate(300, (_) => uuid.v4());
    final f = GcsFilter.build(held);
    final values = GcsFilter.decode(data: f.data, n: f.n);
    var positives = 0;
    const trials = 20000;
    for (var i = 0; i < trials; i++) {
      if (GcsFilter.mightContain(values, f.n, uuid.v4())) positives++;
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
    final f = GcsFilter.build(ids);
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
    final f = GcsFilter.build(ids);
    expect(f.n, GcsFilter.maxElements);
    final values = GcsFilter.decode(data: f.data, n: f.n);
    expect(GcsFilter.mightContain(values, f.n, ids.first), isTrue,
        reason: 'the longest-waiting packet is advertised first');
  });

  test('an empty buffer is an empty filter, and nothing tests present', () {
    final f = GcsFilter.build(const []);
    expect(f.n, 0);
    expect(f.data, isEmpty);
    expect(GcsFilter.mightContain(const [], 0, uuid.v4()), isFalse);
  });

  test('a truncated payload throws rather than decoding short', () {
    // Clean-break rule: a filter that does not fit is malformed, not smaller.
    final ids = List.generate(50, (_) => uuid.v4());
    final f = GcsFilter.build(ids);
    final cut = f.data.sublist(0, f.data.length ~/ 2);
    expect(() => GcsFilter.decode(data: cut, n: f.n), throwsFormatException);
  });

  test('the same ids in a different order produce the same membership', () {
    // Values are sorted before delta-coding, so insertion order cannot change
    // what the filter says — two nodes holding the same set agree.
    final ids = List.generate(60, (_) => uuid.v4());
    final a = GcsFilter.build(ids);
    final b = GcsFilter.build(ids.reversed.toList());
    expect(a.data, equals(b.data));
  });
}
