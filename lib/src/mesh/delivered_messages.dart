/// Delivery dedup: the messageIds this node has already handed to the
/// application.
///
/// This is NOT a BloomFilter, and the difference is the whole point. A bloom
/// cannot remove one entry, so the only way it can be bounded is a periodic
/// WHOLESALE clear — and delivery dedup was previously a bloom that wiped
/// itself every 10,000 items or 5 minutes. A message delivered just before
/// such a rotation and conveyed to us again just after it looked new, and was
/// delivered to the app a second time: `message re-delivery` came back 604 and
/// 121 on the two arms of the relay-cap A/B, against a stated guarantee of
/// exactly-once delivery.
///
/// The lifetime that actually matters is the DTN buffer's. A copy of a message
/// can only reach us again while some node still holds it, and a held packet
/// leaves its buffer on ACK, on eviction, or at [DtnStore.maxAge]. So dedup
/// state must outlive the buffer, not a wall-clock timer: an entry is kept
/// until it is older than the longest a copy can possibly survive anywhere,
/// and only then dropped — at which point re-delivery is impossible because no
/// copy exists to redeliver.
///
/// There is deliberately NO count cap. A cap on this set would evict ids while
/// copies of those messages are still live in the mesh, re-delivering a
/// message the application has already been handed — the same defect as the
/// bloom rotation, arrived at from the other direction. Age is the only bound
/// that is safe here, and it is a real one: nothing is kept past the point
/// where a copy could still reach us.
class DeliveredMessages {
  /// Keep an id at least as long as a packet can live in a DTN buffer.
  /// Shorter, and a conveyance that arrives at the buffer's age limit is
  /// delivered twice; there is no value in being cleverer than the buffer.
  final Duration maxAge;

  /// Insertion-ordered: the oldest entry is the first key.
  final Map<String, DateTime> _seen = {};

  DeliveredMessages({this.maxAge = const Duration(hours: 6)});

  int get length => _seen.length;

  /// True when [messageId] has already been delivered. Records it either way.
  bool checkAndAdd(String messageId, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _pruneExpired(at);
    final prior = _seen[messageId];
    if (prior != null) {
      // Deliberately NOT refreshed: the clock that matters is when the message
      // was first delivered, because that is what bounds how long a copy of it
      // can still be in someone's buffer. Refreshing on every duplicate would
      // let a chatty duplicate stream pin an entry forever.
      return true;
    }
    _seen[messageId] = at;
    return false;
  }

  void _pruneExpired(DateTime now) {
    // Insertion order is age order, so stop at the first live entry.
    final dead = <String>[];
    for (final e in _seen.entries) {
      if (now.difference(e.value) <= maxAge) break;
      dead.add(e.key);
    }
    for (final k in dead) {
      _seen.remove(k);
    }
  }

  void clear() => _seen.clear();
}
