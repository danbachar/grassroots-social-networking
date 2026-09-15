import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/testbed/ring_topology.dart';

/// Sixteen-hex-char stand-ins for pubkeys. Deliberately NOT in sorted order in
/// the literals, so every test that relies on ring order proves the sort is
/// doing the work rather than the declaration order.
const _a = 'aa11';
const _b = 'bb22';
const _c = 'cc33';
const _d = 'dd44';

void main() {
  group('ringDistance', () {
    test('wraps: on a ring of 11, position 0 and 10 are adjacent', () {
      expect(ringDistance(0, 10, 11), 1);
      expect(ringDistance(10, 0, 11), 1);
    });

    test('is the shorter way round, so it never exceeds n ~/ 2', () {
      const n = 11;
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
          expect(ringDistance(i, j, n), lessThanOrEqualTo(n ~/ 2));
        }
      }
      // The far side of an 11-ring: 0 and 5/6 are both 5 hops away.
      expect(ringDistance(0, 5, 11), 5);
      expect(ringDistance(0, 6, 11), 5);
    });

    test('is symmetric, and zero to itself', () {
      const n = 11;
      for (var i = 0; i < n; i++) {
        expect(ringDistance(i, i, n), 0);
        for (var j = 0; j < n; j++) {
          expect(ringDistance(i, j, n), ringDistance(j, i, n));
        }
      }
    });

    test('the 4-ring used by the smoke run has diameter 2', () {
      // p0-p1-p2-p3-p0: adjacent pairs at 1, opposite pairs at 2. The opposite
      // pairs are the ones that must be CONVEYED at r=1, which is the whole
      // reason the smoke run needs four phones and not three.
      expect(ringDistance(0, 1, 4), 1);
      expect(ringDistance(1, 2, 4), 1);
      expect(ringDistance(2, 3, 4), 1);
      expect(ringDistance(3, 0, 4), 1);
      expect(ringDistance(0, 2, 4), 2);
      expect(ringDistance(1, 3, 4), 2);
    });

    test('a 3-ring is useless for this experiment: every pair is adjacent', () {
      // Recorded as a test because it is the reason the smoke run cannot use
      // three phones: at n=3 there is no pair at distance 2, so r=1 is already
      // the complete graph and no message can require a relay.
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          if (i != j) expect(ringDistance(i, j, 3), 1);
        }
      }
    });
  });

  group('ringOrder', () {
    test('sorts, so declaration order does not change the ring', () {
      expect(ringOrder([_c, _a, _d, _b]), [_a, _b, _c, _d]);
      expect(ringOrder([_d, _c, _b, _a]), ringOrder([_a, _b, _c, _d]));
    });

    test('lowercases, so a roster typed in caps gives the same ring', () {
      expect(ringOrder(['BB22', 'Aa11']), [_a, _b]);
    });

    test('drops duplicates, which would otherwise shift every distance', () {
      expect(ringOrder([_a, _b, _a, _b, _c]), [_a, _b, _c]);
    });

    test('ignores blank entries and trims', () {
      expect(ringOrder([' aa11 ', '', '   ', _b]), [_a, _b]);
    });
  });

  group('ringVerdict', () {
    final ring = ringOrder([_a, _b, _c, _d]); // a-b-c-d-a

    test('is inactive with no radius, so a normal build is never gated', () {
      expect(
        ringVerdict(ring: ring, selfHex: _a, peerHex: _c, radius: null),
        RingVerdict.inactive,
      );
      expect(
        ringAllows(ring: ring, selfHex: _a, peerHex: _c, radius: null),
        isTrue,
      );
    });

    test('at r=1 allows the two neighbours and refuses the opposite peer', () {
      expect(
        ringVerdict(ring: ring, selfHex: _a, peerHex: _b, radius: 1),
        RingVerdict.withinRadius,
      );
      expect(
        // wrap-around neighbour
        ringVerdict(ring: ring, selfHex: _a, peerHex: _d, radius: 1),
        RingVerdict.withinRadius,
      );
      expect(
        ringVerdict(ring: ring, selfHex: _a, peerHex: _c, radius: 1),
        RingVerdict.outOfRadius,
      );
    });

    test('at r=2 the 4-ring is complete', () {
      for (final peer in [_b, _c, _d]) {
        expect(
          ringVerdict(ring: ring, selfHex: _a, peerHex: peer, radius: 2),
          RingVerdict.withinRadius,
          reason: 'r=2 on a 4-ring allows every peer',
        );
      }
    });

    test('allows exactly min(2r, n-1) peers at each radius', () {
      final big = ringOrder([
        for (var i = 0; i < 11; i++) 'p${i.toString().padLeft(2, '0')}',
      ]);
      for (var r = 1; r <= 5; r++) {
        final allowed = big
            .where((p) =>
                p != big.first &&
                ringAllows(
                    ring: big, selfHex: big.first, peerHex: p, radius: r))
            .length;
        expect(allowed, r * 2 < 10 ? r * 2 : 10,
            reason: 'radius $r should allow min(2r, n-1) peers');
      }
    });

    test('refuses an off-roster peer while armed, with its own reason', () {
      final v =
          ringVerdict(ring: ring, selfHex: _a, peerHex: 'ffff', radius: 2);
      expect(v, RingVerdict.offRoster);
      expect(v.allowsLink, isFalse);
      // Separable in the trace from an ordinary radius refusal, so a
      // misdeployed roster does not look like the gate working.
      expect(v.traceReason, 'ringOffRoster');
      expect(RingVerdict.outOfRadius.traceReason, 'ringRadius');
    });

    test('leaves a device that is not itself on the roster unconstrained', () {
      final v =
          ringVerdict(ring: ring, selfHex: 'ffff', peerHex: _a, radius: 1);
      expect(v, RingVerdict.selfOffRoster);
      expect(v.allowsLink, isTrue);
    });

    test('is inactive when the roster cannot describe a pair', () {
      expect(
        ringVerdict(ring: ringOrder([_a]), selfHex: _a, peerHex: _b, radius: 1),
        RingVerdict.inactive,
      );
    });

    test('is symmetric: both ends of a pair agree', () {
      for (final x in ring) {
        for (final y in ring) {
          for (var r = 1; r <= 2; r++) {
            expect(
              ringAllows(ring: ring, selfHex: x, peerHex: y, radius: r),
              ringAllows(ring: ring, selfHex: y, peerHex: x, radius: r),
              reason: 'the gate must not be one-sided for $x/$y at r=$r',
            );
          }
        }
      }
    });
  });

  group('ringDisallowedPeers', () {
    final ring = ringOrder([_a, _b, _c, _d]);

    test('names exactly the peers to prune when the radius shrinks', () {
      expect(ringDisallowedPeers(ring: ring, selfHex: _a, radius: 2), isEmpty);
      expect(ringDisallowedPeers(ring: ring, selfHex: _a, radius: 1), [_c]);
      expect(ringDisallowedPeers(ring: ring, selfHex: _b, radius: 1), [_d]);
    });

    test('never names self, and is empty when the gate is inactive', () {
      expect(ringDisallowedPeers(ring: ring, selfHex: _a, radius: 1),
          isNot(contains(_a)));
      expect(
          ringDisallowedPeers(ring: ring, selfHex: _a, radius: null), isEmpty);
      expect(ringDisallowedPeers(ring: ring, selfHex: 'ffff', radius: 1),
          isEmpty);
    });
  });
}
