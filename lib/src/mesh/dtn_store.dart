import '../models/packet.dart';

/// Store-carry-forward (DTN) cache — the second half of opportunistic mesh
/// delivery (see CLAUDE.md → Opportunistic Mesh & Store-Carry-Forward).
///
/// When a relay floods a packet whose recipient is not currently in range, it
/// also caches the sealed packet here and re-floods it when that recipient
/// reappears (on their ANNOUNCE / peer-connected event). The relay only ever
/// holds opaque, recipient-addressed, end-to-end-sealed bytes it cannot read.
///
/// Everything is bounded — number of recipients, depth per recipient, and age —
/// so an intermediary can never be made to hold unbounded traffic. Eviction is
/// oldest-first.
class DtnStore {
  /// Max distinct recipients held at once.
  final int maxRecipients;

  /// Max cached packets per recipient.
  final int maxPerRecipient;

  /// Packets older than this are dropped.
  final Duration maxAge;

  DtnStore({
    this.maxRecipients = 256,
    this.maxPerRecipient = 32,
    this.maxAge = const Duration(hours: 6),
  });

  final Map<String, List<_Entry>> _byRecipient = {};

  int get recipientCount => _byRecipient.length;

  int get totalCount =>
      _byRecipient.values.fold(0, (sum, list) => sum + list.length);

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

    // Bound per-recipient depth (drop oldest).
    while (list.length > maxPerRecipient) {
      list.removeAt(0);
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
      if (evictKey != null) _byRecipient.remove(evictKey);
    }
  }

  /// All (non-expired) packetIds currently carried, across recipients —
  /// the custody summary offered to a newly-connected neighbor during
  /// sync-on-connect. Non-destructive: sync replicates custody, it does not
  /// transfer it.
  List<String> carriedPacketIds({DateTime? now}) {
    _prune(now ?? DateTime.now());
    return [
      for (final list in _byRecipient.values)
        for (final e in list) e.packet.packetId,
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
  /// freshly established session (custody is kept until ACKed or expired).
  List<GrassrootsPacket> packetsFor(String recipientHex, {DateTime? now}) {
    _prune(now ?? DateTime.now());
    final list = _byRecipient[recipientHex];
    if (list == null || list.isEmpty) return const [];
    return list.map((e) => e.packet).toList(growable: false);
  }

  /// Drop the packet with [packetId] wherever it is held — called when the
  /// end-to-end ACK proves delivery, ending our custody of it.
  void removeById(String packetId) {
    _byRecipient.removeWhere((_, list) {
      list.removeWhere((e) => e.packet.packetId == packetId);
      return list.isEmpty;
    });
  }

  void _prune(DateTime now) {
    _byRecipient.removeWhere((_, list) {
      list.removeWhere((e) => now.difference(e.storedAt) > maxAge);
      return list.isEmpty;
    });
  }

  void clear() => _byRecipient.clear();
}

class _Entry {
  final GrassrootsPacket packet;
  final DateTime storedAt;
  _Entry(this.packet, this.storedAt);
}
