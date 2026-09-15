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
/// what a windowed filter covers (see [newest]).
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

  /// How many seen ids sit at or after [fromMs] — the ground the forward sync
  /// cursor still has to cover. Counted rather than materialised: the caller
  /// only wants the size, and building the slice to measure it is the
  /// expensive half of [windowFrom].
  int countFrom(int fromMs, {DateTime? now}) {
    _pruneExpired(now ?? DateTime.now());
    var n = 0;
    for (final e in _seen.values) {
      if (e.createdAtMs >= fromMs) n++;
    }
    return n;
  }

  /// The NEWEST [limit] seen ids by originator-stamped creation time, oldest
  /// first — the prefix frame of a sync round, which is anchored at the top of
  /// the seen-set every round rather than walking up from a cursor.
  ///
  /// Its floor is what makes a packet newer than anything this node has seen
  /// askable at all. Measured 2026-09-02: the cursor's band was a median
  /// 11.5 s wide on a 940 s run, and 95.6% of the mail a holder was carrying
  /// FOR the asking peer sat below that peer's advertised `fromMs`.
  ///
  /// When the set is larger than [limit] the result is cut back to a whole
  /// millisecond at its OLDEST end — the mirror of [windowFrom]'s cut, applied
  /// to the START of the window because that is the end being truncated here.
  /// The caller turns that oldest stamp into the frame's floor, and a floor
  /// landing inside a group sharing one stamp would leave the excluded ids
  /// inside the window with none of them named, which reads as absence and
  /// pulls them straight back. A selection that is entirely one stamp has
  /// nothing to cut back to and is advertised as-is.
  List<({String id, int createdAtMs})> newest(int limit, {DateTime? now}) {
    _pruneExpired(now ?? DateTime.now());
    if (limit <= 0 || _seen.isEmpty) return const [];
    final picked = _selectBounded(_seen, limit, _keepNewest, null);
    if (picked.eligible <= limit) return picked.ids;

    final ids = picked.ids;
    final floor = ids.first.createdAtMs;
    var start = 0;
    while (start < ids.length && ids[start].createdAtMs == floor) {
      start++;
    }
    return start >= ids.length ? ids : ids.sublist(start);
  }

  /// The seen packetIds whose ORIGINATOR-stamped creation time is at or after
  /// [fromMs], oldest first, capped at [limit] — the slice the per-peer
  /// forward cursor advertises. Scoped by creation time and cut on a whole
  /// millisecond so the advertiser and the responder agree on exactly which
  /// ids a windowed filter covers.
  List<({String id, int createdAtMs})> windowFrom(int fromMs,
      {required int limit, DateTime? now}) {
    _pruneExpired(now ?? DateTime.now());
    if (limit <= 0) return const [];
    final picked = _selectBounded(_seen, limit, _keepOldest, fromMs);
    final all = picked.ids;
    if (picked.eligible <= limit) return all;

    // Cut on a whole-millisecond boundary: a boundary inside a group sharing
    // one stamp would make the packets left out look missing and pull them
    // straight back. Drop the partial trailing millisecond.
    var end = all.length;
    final boundary = all[end - 1].createdAtMs;
    while (end > 0 && all[end - 1].createdAtMs == boundary) {
      end--;
    }
    // Unless the whole window is one millisecond: advertise what fits and
    // accept that one stamp may re-list, rather than stall the sweep forever.
    return end == 0 ? all : all.sublist(0, end);
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

/// Keep the newest ids: a MIN-heap, whose root is the oldest one kept and so
/// the entry a newer candidate displaces.
const int _keepNewest = 1;

/// Keep the oldest ids: a MAX-heap, whose root is the newest one kept.
const int _keepOldest = -1;

/// Take at most [limit] entries out of [seen] — the newest or the oldest per
/// [keep], restricted to stamps at or after [atOrAfter] when given — sorted
/// oldest-first, along with how many entries were ELIGIBLE (so the caller can
/// tell a full selection from a truncated one, which is what decides whether a
/// whole-millisecond cut is needed at all).
///
/// A bounded partial selection, NOT a sort of the whole set. At six hours of
/// retention and ~2 ids/s this map holds tens of thousands of entries while a
/// frame names 106 of them, and a round is built per peer every 10 s on a
/// Nexus 5X — materialising every entry as a record and sorting it, which is
/// what both selections used to do, is O(N log N) plus an allocation per entry
/// to throw away all but [limit]. A heap capped at [limit] is O(N log limit)
/// and allocates [limit] records.
///
/// Keeping the map ordered by stamp on insert was the alternative and is worse
/// here: createdAtMs is the ORIGINATOR's stamp, so a carried backlog arrives
/// long out of creation order and every such arrival is an insertion into the
/// middle. Insertion order is first-seen order, which is what [_pruneExpired]
/// needs and is a different order entirely.
({List<({String id, int createdAtMs})> ids, int eligible}) _selectBounded(
    Map<String, _Seen> seen, int limit, int keep, int? atOrAfter) {
  final heap = <({String id, int createdAtMs})>[];
  var eligible = 0;
  for (final e in seen.entries) {
    final stamp = e.value.createdAtMs;
    if (atOrAfter != null && stamp < atOrAfter) continue;
    eligible++;
    if (heap.length < limit) {
      heap.add((id: e.key, createdAtMs: stamp));
      _siftUp(heap, heap.length - 1, keep);
    } else if (keep * stamp > keep * heap[0].createdAtMs) {
      heap[0] = (id: e.key, createdAtMs: stamp);
      _siftDown(heap, 0, keep);
    }
  }
  heap.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
  return (ids: heap, eligible: eligible);
}

void _siftUp(List<({String id, int createdAtMs})> heap, int i, int keep) {
  while (i > 0) {
    final parent = (i - 1) >> 1;
    if (keep * heap[parent].createdAtMs <= keep * heap[i].createdAtMs) break;
    final tmp = heap[parent];
    heap[parent] = heap[i];
    heap[i] = tmp;
    i = parent;
  }
}

void _siftDown(List<({String id, int createdAtMs})> heap, int i, int keep) {
  final n = heap.length;
  while (true) {
    final left = i * 2 + 1;
    if (left >= n) break;
    final right = left + 1;
    var root = left;
    if (right < n &&
        keep * heap[right].createdAtMs < keep * heap[left].createdAtMs) {
      root = right;
    }
    if (keep * heap[i].createdAtMs <= keep * heap[root].createdAtMs) break;
    final tmp = heap[root];
    heap[root] = heap[i];
    heap[i] = tmp;
    i = root;
  }
}

class _Seen {
  final DateTime firstSeen;
  final int createdAtMs;
  _Seen(this.firstSeen, this.createdAtMs);
}
