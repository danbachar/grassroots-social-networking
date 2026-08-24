/// Wire-packet dedup: the packetIds this node has already processed, for loop
/// and relay prevention — and the set it ADVERTISES in the sync exchange.
///
/// This is NOT a BloomFilter, and — as with [DeliveredMessages] for delivery
/// dedup — the difference is the whole point. A bloom cannot remove one entry,
/// so the only way it stays bounded is a periodic WHOLESALE clear: the old
/// `_seenPackets` bloom wiped itself every 10,000 items or 5 minutes. Under
/// load that clear forgets everything, and a re-conveyed copy of a packet this
/// node already relayed then looks new — so the node re-admits it, re-stores it
/// in the DTN buffer, and re-circulates it.
///
/// It is ALSO what a node advertises as its GCS sync filter. Advertising what a
/// node still HOLDS re-pushes the backlog to a node that already delivered and
/// dropped it — measured 12.76 copies/msg on the air. Advertising what it has
/// SEEN says "do not resend me these," which is what actually suppresses the
/// re-conveyance. That is why every entry keeps the packet's own [createdAtMs]:
/// the sync window is scoped by originator creation time so two nodes agree on
/// what a windowed filter covers (see [windowFrom]).
///
/// The lifetime that matters is the DTN buffer's, not a wall-clock timer. A
/// copy of a packet can reach us again only while some node still holds it, and
/// a held packet leaves its buffer on ACK, on eviction, or at [DtnStore.maxAge]
/// — so a seen id must OUTLIVE the buffer: keep it until it is older than the
/// longest a copy can survive anywhere, then drop it, at which point re-admission
/// is harmless because no copy exists. Age is pruned on FIRST-seen time; there
/// is deliberately NO count cap, which would evict live ids and re-admit them —
/// the bloom rotation by another name.
class SeenPackets {
  /// Keep an id at least as long as a packet can live in a DTN buffer.
  final Duration maxAge;

  /// Insertion-ordered by first-seen (so age-pruning stops at the first live
  /// entry). Value carries the packet's own creation stamp for windowing.
  final Map<String, _Seen> _seen = {};

  SeenPackets({this.maxAge = const Duration(hours: 6)});

  int get length => _seen.length;

  /// True when [packetId] has already been seen. Records it (with its
  /// [createdAtMs]) either way.
  bool checkAndAdd(String packetId, int createdAtMs, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _pruneExpired(at);
    if (_seen.containsKey(packetId)) {
      // Deliberately NOT refreshed: the clock that matters is when we FIRST saw
      // it, which bounds how long a copy can still be in a buffer.
      return true;
    }
    _seen[packetId] = _Seen(at, createdAtMs);
    return false;
  }

  /// Record [packetId] as seen without reporting prior state.
  void add(String packetId, int createdAtMs, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _pruneExpired(at);
    _seen.putIfAbsent(packetId, () => _Seen(at, createdAtMs));
  }

  /// Whether [packetId] has been seen (and is not yet aged out).
  bool contains(String packetId, {DateTime? now}) {
    _pruneExpired(now ?? DateTime.now());
    return _seen.containsKey(packetId);
  }

  /// The seen packetIds whose ORIGINATOR-stamped creation time is at or after
  /// [fromMs], oldest first, capped at [limit] — the slice advertised in one
  /// GCS sync filter. Scoped by creation time, and cut on a whole-millisecond
  /// boundary, identically to [DtnStore.windowFrom], so the advertiser and the
  /// responder agree on exactly which ids a windowed filter covers.
  List<({String id, int createdAtMs})> windowFrom(int fromMs,
      {required int limit, DateTime? now}) {
    _pruneExpired(now ?? DateTime.now());
    final all = <({String id, int createdAtMs})>[
      for (final e in _seen.entries)
        if (e.value.createdAtMs >= fromMs)
          (id: e.key, createdAtMs: e.value.createdAtMs),
    ]..sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    if (all.length <= limit) return all;

    // Cut on a whole-millisecond boundary: a boundary inside a group sharing
    // one stamp would make the packets left out look missing and pull them
    // straight back. Drop the partial trailing millisecond.
    var end = limit;
    final boundary = all[limit - 1].createdAtMs;
    while (end > 0 && all[end - 1].createdAtMs == boundary) {
      end--;
    }
    // Unless the whole window is one millisecond: advertise what fits and
    // accept that one stamp may re-list, rather than stall the sweep forever.
    return all.sublist(0, end == 0 ? limit : end);
  }

  void _pruneExpired(DateTime now) {
    // Insertion order is first-seen order, so stop at the first live entry.
    final dead = <String>[];
    for (final e in _seen.entries) {
      if (now.difference(e.value.firstSeen) <= maxAge) break;
      dead.add(e.key);
    }
    for (final k in dead) {
      _seen.remove(k);
    }
  }

  void clear() => _seen.clear();
}

class _Seen {
  final DateTime firstSeen;
  final int createdAtMs;
  _Seen(this.firstSeen, this.createdAtMs);
}
