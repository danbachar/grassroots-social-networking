/// Ring topology for the ring-radius conveyance experiment.
///
/// DEBUG/TESTBED ONLY. Nothing here runs in a normal build: every entry point
/// is inert unless a radius has been set, and a radius is only ever set by the
/// testbed runner.
///
/// The experiment manufactures network DIAMETER on a desk. No experiment in the
/// dataset exercises multi-hop conveyance as the necessary delivery path — the
/// line sweep has two devices and no third party to relay, and the diluting
/// clique is a complete graph whose diameter stayed 1, so only 0.06% of
/// arrivals came via a third party. Here the N devices are ordered into a ring
/// by sorted pubkey, and at radius `r` a node may hold links only to peers
/// within ring distance `r`. That is a circulant graph: connected by
/// construction at every radius, with a known diameter that shrinks as r grows
/// (at N=11: 5 at r=1, 3 at r=2, 2 at r=3, 1 at r=5).
///
/// A circulant ring rather than a numeric "at most k links" cap, which was
/// considered and rejected: at k=2 the emergent 2-regular graph is frequently
/// two disjoint cycles — a permanent partition — and arrival then measures
/// partition luck instead of conveyance.
///
/// The functions are pure and the file imports nothing, because four callers
/// share them and must agree exactly: the transport's link gate, the settings
/// reducer that normalises the roster, the field runner, and the preset.
library;

/// Hops between ring positions [i] and [j] on a ring of [n] nodes.
///
/// The ring wraps, so the distance is the shorter of the two ways round. On a
/// ring of 11, positions 0 and 10 are ADJACENT (distance 1), not ten apart —
/// getting that wrong would make the gate refuse exactly one pair of every
/// ring, silently turning the cycle into a path and changing the diameter.
///
/// Returns 0 for [i] == [j]. Both indices are assumed in range; callers get
/// them from [ringOrder], which is the only sanctioned source.
int ringDistance(int i, int j, int n) {
  if (n <= 0) return 0;
  final direct = (i - j).abs();
  final around = n - direct;
  return direct < around ? direct : around;
}

/// The ring order for [rosterHex]: lowercased, de-duplicated, sorted ascending.
///
/// **The sort IS the ring.** Ordering by pubkey is what lets every device
/// derive the same ring independently, with no coordination and no assigned
/// positions — each phone sorts the roster it was given and finds itself in it.
/// So the ordering has to be canonical: it is applied here (and in the reducer
/// that stores the roster) rather than trusted from whoever supplied the list,
/// because a roster that reached two phones in different orders would give them
/// different neighbours and the topology would not be a ring at all.
///
/// Duplicates are dropped rather than tolerated: a repeated pubkey would occupy
/// two ring positions, so every distance past it would be wrong.
List<String> ringOrder(Iterable<String> rosterHex) {
  final seen = <String>{};
  for (final hex in rosterHex) {
    final normalised = hex.trim().toLowerCase();
    if (normalised.isNotEmpty) seen.add(normalised);
  }
  final ordered = seen.toList()..sort();
  return List<String>.unmodifiable(ordered);
}

/// Why a link to a peer is or is not allowed at the current radius.
///
/// Distinct reasons rather than a bare bool because they are diagnosed
/// differently in the trace: [outOfRadius] is the gate working as intended,
/// while [offRoster] on a device that should be in the experiment means the
/// roster was deployed wrong — which would otherwise present as a phone that
/// mysteriously refuses every link.
enum RingVerdict {
  /// No radius set, or nothing to constrain: the gate is not in force.
  inactive,

  /// This device is not on the roster, so it has no ring position and is not
  /// part of the experiment. Its links are its own business.
  selfOffRoster,

  /// Within [ringDistance] <= radius of us. Allowed.
  withinRadius,

  /// A roster peer, but further around the ring than the radius allows.
  outOfRadius,

  /// Not on the roster at all, while the gate is in force.
  offRoster,
}

extension RingVerdictAllowed on RingVerdict {
  /// Whether a link may form. Only the two refusal verdicts deny it.
  bool get allowsLink =>
      this != RingVerdict.outOfRadius && this != RingVerdict.offRoster;

  /// The trace `reason` for a refusal, or null where the link is allowed.
  String? get traceReason => switch (this) {
        RingVerdict.outOfRadius => 'ringRadius',
        RingVerdict.offRoster => 'ringOffRoster',
        _ => null,
      };
}

/// Whether [peerHex] may hold a link with [selfHex] at [radius], on the ring
/// [ring] (which must already be in [ringOrder] form).
///
/// A null [radius] means the gate is not armed and everything is allowed —
/// that is the normal-build state and also the state the operator warms the
/// mesh up in, where every pair must be able to handshake.
///
/// **Off-roster peers are REFUSED while the gate is armed.** A device that is
/// not in the experiment is not part of the ring, and letting it link would let
/// it relay: it would collapse the diameter the experiment exists to create.
/// This is not hypothetical — a stray iPhone joined the line-200 sweep at d=20,
/// took 36 messages addressed to it, and accounted for that whole distance's
/// apparent packet loss (2000/2036 became 2000/2000 once purged), which is why
/// `EXCLUDED_PEERS` exists in `trace_server/analyze.py`. Refusing the link
/// structurally is better than subtracting the contamination afterwards.
///
/// A device that cannot find ITSELF in the roster is left unconstrained: it is
/// not in the experiment either, and gating a bystander's radio on a roster it
/// is not in would be a testbed knob leaking into ordinary use.
RingVerdict ringVerdict({
  required List<String> ring,
  required String selfHex,
  required String peerHex,
  required int? radius,
}) {
  if (radius == null) return RingVerdict.inactive;
  final n = ring.length;
  // A roster of one has no pairs to constrain, so there is nothing to enforce.
  if (n < 2) return RingVerdict.inactive;

  final self = selfHex.trim().toLowerCase();
  final peer = peerHex.trim().toLowerCase();
  final i = ring.indexOf(self);
  if (i < 0) return RingVerdict.selfOffRoster;
  final j = ring.indexOf(peer);
  if (j < 0) return RingVerdict.offRoster;
  if (i == j) return RingVerdict.withinRadius;

  return ringDistance(i, j, n) <= radius
      ? RingVerdict.withinRadius
      : RingVerdict.outOfRadius;
}

/// Convenience over [ringVerdict] for callers that only need the decision.
bool ringAllows({
  required List<String> ring,
  required String selfHex,
  required String peerHex,
  required int? radius,
}) =>
    ringVerdict(
      ring: ring,
      selfHex: selfHex,
      peerHex: peerHex,
      radius: radius,
    ).allowsLink;

/// The roster peers [selfHex] may NOT hold a link with at [radius].
///
/// This is what the prune iterates when the radius shrinks. It never contains
/// [selfHex], and it is empty whenever the gate is inactive — so a caller can
/// run it unconditionally and prune nothing in a normal build.
List<String> ringDisallowedPeers({
  required List<String> ring,
  required String selfHex,
  required int? radius,
}) {
  if (radius == null) return const [];
  final self = selfHex.trim().toLowerCase();
  if (!ring.contains(self)) return const [];
  return [
    for (final peer in ring)
      if (peer != self &&
          !ringAllows(
            ring: ring,
            selfHex: self,
            peerHex: peer,
            radius: radius,
          ))
        peer,
  ];
}
