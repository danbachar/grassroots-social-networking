import '../models/packet.dart';

/// Store-carry-forward (DTN) cache — the second half of opportunistic mesh
/// delivery (see CLAUDE.md → Opportunistic Mesh & Store-Carry-Forward).
///
/// When a relay floods a packet whose recipient is not currently in range, it
/// also caches the sealed packet here and re-floods it when that recipient
/// reappears (on their ANNOUNCE / peer-connected event). The relay only ever
/// holds opaque, recipient-addressed, end-to-end-sealed bytes it cannot read.
///
/// Everything is bounded — number of recipients, total packets across the
/// store, and age — so an intermediary can never be made to hold unbounded
/// traffic. Eviction is oldest-first. The bound is deliberately store-wide
/// rather than per-recipient: a per-recipient depth silently dropped a busy
/// peer's oldest undelivered packets while the rest of the store sat empty,
/// and pinned held confirmations (which only age-expires) at exactly the
/// cap on every reconnection.
class DtnStore {
  /// Max distinct recipients held at once.
  final int maxRecipients;

  /// Max cached BYTES across ALL recipients (globally-oldest evicted first).
  ///
  /// The size bound is bytes, not a packet count. A count says nothing about
  /// memory unless every packet is the same size, and they are not: a
  /// fragmented message is several packets of whatever the MTU left over.
  /// Bytes are the thing actually being bounded, so bytes are what the bound
  /// is written in.
  ///
  /// This counts sealed PAYLOAD bytes, which is what [totalBytes] reports and
  /// what the `buf` trace record carries — not the Dart object overhead
  /// around each entry, so real process memory sits above this figure.
  final int maxBytes;

  /// Packets older than this are dropped.
  final Duration maxAge;

  /// Fired for every packet that leaves the buffer WITHOUT an ACK — age
  /// expiry ('expired'), store-wide cap eviction ('evictedTotal'), or
  /// recipient-cap eviction ('evictedRecipients'). ACK-driven removal goes
  /// through [removeById] and is reported by the caller, not here. Without
  /// this, a `custody store` record with no `end` is ambiguous between
  /// "still held" and "silently expired" — which is exactly the packet-loss
  /// evidence the testbed needs.
  void Function(String reason, String recipientHex, GrassrootsPacket packet)?
      onDrop;

  DtnStore({
    this.maxRecipients = 256,
    this.maxBytes = 512 * 1024 * 1024, // 512 MiB
    this.maxAge = const Duration(hours: 6),
  });

  final Map<String, List<_Entry>> _byRecipient = {};

  int get recipientCount => _byRecipient.length;

  int get totalCount =>
      _byRecipient.values.fold(0, (sum, list) => sum + list.length);

  /// Total payload bytes currently buffered — the memory-utilization figure
  /// for the periodic `buf` trace record. Maintained incrementally: the
  /// store is consulted on every sync round and a fold over 8k packets per
  /// query would be wasted work.
  int get totalBytes => _totalBytes;
  int _totalBytes = 0;

  int _entryBytes(_Entry e) => e.packet.payload.length;

  /// Cache [packet] for later delivery to [recipientHex]. Idempotent per
  /// packetId. [now] defaults to wall-clock; injectable for tests.
  void store(String recipientHex, GrassrootsPacket packet, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _prune(at);

    final list = _byRecipient.putIfAbsent(recipientHex, () => <_Entry>[]);
    if (list.any((e) => e.packet.packetId == packet.packetId)) {
      return; // already carrying this exact packet
    }
    list.add(_Entry(packet, at));
    _totalBytes += packet.payload.length;

    // Bound the store as a whole: evict the globally-oldest packet until the
    // buffer is inside its byte ceiling. Each per-recipient list is
    // append-ordered, so the oldest entry overall is the oldest list head.
    while (_totalBytes > maxBytes) {
      String? evictKey;
      DateTime? oldestHead;
      for (final entry in _byRecipient.entries) {
        if (entry.value.isEmpty) continue;
        final head = entry.value.first.storedAt;
        if (oldestHead == null || head.isBefore(oldestHead)) {
          oldestHead = head;
          evictKey = entry.key;
        }
      }
      if (evictKey == null) break;
      final evictList = _byRecipient[evictKey]!;
      final evicted = evictList.removeAt(0);
      _totalBytes -= _entryBytes(evicted);
      onDrop?.call('evictedTotal', evictKey, evicted.packet);
      if (evictList.isEmpty) _byRecipient.remove(evictKey);
    }

    // Bound number of recipients (evict the one whose oldest packet is oldest).
    if (_byRecipient.length > maxRecipients) {
      String? evictKey;
      DateTime? oldestHead;
      for (final entry in _byRecipient.entries) {
        if (entry.value.isEmpty) continue;
        final head = entry.value.first.storedAt;
        if (oldestHead == null || head.isBefore(oldestHead)) {
          oldestHead = head;
          evictKey = entry.key;
        }
      }
      if (evictKey != null) {
        final evictedList = _byRecipient.remove(evictKey)!;
        for (final e in evictedList) {
          _totalBytes -= _entryBytes(e);
          onDrop?.call('evictedRecipients', evictKey, e.packet);
        }
      }
    }
  }

  /// All (non-expired) packetIds currently carried, across recipients —
  /// the buffer summary offered to a newly-connected neighbor during
  /// sync-on-connect. Non-destructive: sync replicates buffer entries, it
  /// does not
  /// transfer it.
  List<String> carriedPacketIds({DateTime? now}) {
    _prune(now ?? DateTime.now());
    return [
      for (final list in _byRecipient.values)
        for (final e in list) e.packet.packetId,
    ];
  }

  /// The same carried packetIds, but with those held FOR [recipientHex]
  /// emitted FIRST — the direct-delivery set for the peer we are offering to,
  /// ahead of the mesh-relay backlog (packets addressed to everyone else).
  ///
  /// Ordering is load-bearing, not cosmetic. The offer is chunked and a
  /// neighbour requests per chunk, so whatever leads the list is requested
  /// and conveyed first. When the buffer is large and the BLE window short
  /// and unstable, a flat ordering interleaves a peer's own packets (its
  /// pending message, its friend request/acceptance — all addressed to it)
  /// behind hundreds of relay packets for other recipients, and the link
  /// drops before they are reached: the direct delivery is starved by the
  /// relay it should outrank. Leading with the direct set puts it in the
  /// first chunk, so it lands before anything else can crowd it out.
  List<String> carriedPacketIdsFor(String recipientHex, {DateTime? now}) {
    _prune(now ?? DateTime.now());
    return [
      for (final e in _byRecipient[recipientHex] ?? const <_Entry>[])
        e.packet.packetId,
      for (final entry in _byRecipient.entries)
        if (entry.key != recipientHex)
          for (final e in entry.value) e.packet.packetId,
    ];
  }

  /// Look up a carried packet by [packetId] without removing it — used to
  /// convey a copy to a neighbor that requested it from our sync offer.
  /// Returns null if expired/evicted since the offer.
  GrassrootsPacket? packetById(String packetId, {DateTime? now}) {
    _prune(now ?? DateTime.now());
    for (final list in _byRecipient.values) {
      for (final e in list) {
        if (e.packet.packetId == packetId) return e.packet;
      }
    }
    return null;
  }

  /// All (non-expired) packets held for [recipientHex] — non-destructive.
  /// Used to convey a reconnecting recipient's messages directly over a
  /// freshly established session (the entry is kept until ACKed or expired).
  List<GrassrootsPacket> packetsFor(String recipientHex, {DateTime? now}) {
    _prune(now ?? DateTime.now());
    final list = _byRecipient[recipientHex];
    if (list == null || list.isEmpty) return const [];
    return list.map((e) => e.packet).toList(growable: false);
  }

  /// Drop the packet with [packetId] wherever it is held — called when the
  /// end-to-end ACK proves delivery, dropping it from our buffer.
  void removeById(String packetId) {
    _byRecipient.removeWhere((_, list) {
      list.removeWhere((e) {
        if (e.packet.packetId != packetId) return false;
        _totalBytes -= _entryBytes(e);
        return true;
      });
      return list.isEmpty;
    });
  }

  void _prune(DateTime now) {
    _byRecipient.removeWhere((recipientHex, list) {
      list.removeWhere((e) {
        if (now.difference(e.storedAt) <= maxAge) return false;
        _totalBytes -= _entryBytes(e);
        onDrop?.call('expired', recipientHex, e.packet);
        return true;
      });
      return list.isEmpty;
    });
  }

  void clear() {
    _byRecipient.clear();
    _totalBytes = 0;
  }
}

class _Entry {
  final GrassrootsPacket packet;
  final DateTime storedAt;
  _Entry(this.packet, this.storedAt);
}
