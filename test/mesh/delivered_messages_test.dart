import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/mesh/delivered_messages.dart';

void main() {
  group('DeliveredMessages', () {
    final t0 = DateTime(2026, 1, 1, 12, 0, 0);

    test('a duplicate is recognised, however long after — up to the buffer age',
        () {
      final d = DeliveredMessages(maxAge: const Duration(hours: 6));
      expect(d.checkAndAdd('m1', now: t0), isFalse);
      // The bloom this replaces wiped itself every 5 minutes, so this is the
      // case that produced re-delivery: a conveyance arriving well after the
      // first copy but while the buffer could still hold one.
      expect(d.checkAndAdd('m1', now: t0.add(const Duration(minutes: 5, seconds: 1))),
          isTrue);
      expect(d.checkAndAdd('m1', now: t0.add(const Duration(hours: 5, minutes: 59))),
          isTrue);
    });

    test('volume alone never wipes state', () {
      // The old filter cleared everything at 10,000 items. Delivering other
      // messages must not make an earlier one deliverable again.
      final d = DeliveredMessages();
      d.checkAndAdd('first', now: t0);
      for (var i = 0; i < 20000; i++) {
        d.checkAndAdd('f$i', now: t0.add(Duration(milliseconds: i)));
      }
      expect(d.checkAndAdd('first', now: t0.add(const Duration(minutes: 1))),
          isTrue, reason: '20k later deliveries must not forget the first');
    });

    test('an id is dropped only once no copy can exist', () {
      // Past the DTN buffer's own max age nothing can still hold the packet,
      // so forgetting it cannot cause a re-delivery.
      final d = DeliveredMessages(maxAge: const Duration(hours: 6));
      d.checkAndAdd('old', now: t0);
      expect(d.checkAndAdd('old', now: t0.add(const Duration(hours: 6, seconds: 1))),
          isFalse);
      expect(d.length, 1, reason: 'the expired entry is pruned, not kept');
    });

    test('the first delivery sets the clock; duplicates do not extend it', () {
      // Otherwise a stream of duplicates pins an entry indefinitely.
      final d = DeliveredMessages(maxAge: const Duration(hours: 1));
      d.checkAndAdd('m', now: t0);
      for (var i = 1; i <= 50; i++) {
        d.checkAndAdd('m', now: t0.add(Duration(minutes: i)));
      }
      expect(d.checkAndAdd('m', now: t0.add(const Duration(hours: 1, minutes: 1))),
          isFalse, reason: 'aged out one hour after FIRST delivery');
    });

    test('no count cap: state is dropped by age alone', () {
      // A cap would evict ids while copies are still live in the mesh and
      // re-deliver a message the app already has — the bloom's defect from the
      // other direction. Growth is bounded by maxAge, not by a ceiling.
      final d = DeliveredMessages(maxAge: const Duration(hours: 6));
      for (var i = 0; i < 200000; i++) {
        d.checkAndAdd('m$i', now: t0.add(Duration(milliseconds: i)));
      }
      expect(d.length, 200000, reason: 'nothing evicted while still live');
      expect(d.checkAndAdd('m0', now: t0.add(const Duration(minutes: 1))),
          isTrue, reason: 'the very first id is still remembered');
      // And they all go once no copy can exist.
      d.checkAndAdd('later', now: t0.add(const Duration(hours: 7)));
      expect(d.length, 1);
    });
  });
}
