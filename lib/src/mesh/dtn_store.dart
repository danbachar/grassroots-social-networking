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
  /// Adjustable, because the testbed needs the store to be FULL. The default
  /// is three orders of magnitude above anything the fleet has ever held ---
  /// the highest occupancy on record is 482 KiB, 0.09% of it --- so eviction
  /// has never once run in a recorded experiment, and an outage measured
  /// under an empty buffer is measured under a condition the field will not
  /// meet. Lowering it is how a run exercises the loss path that a deployed
  /// mesh actually lives on.
  int maxBytes;

  /// Packets older than this are dropped.
  final Duration maxAge;

  /// Fired for every packet that leaves the buffer WITHOUT an ACK — age
  /// expiry ('expired'), store-wide cap eviction ('evictedTotal'),
  /// recipient-cap eviction ('evictedRecipients'), or retirement on the
  /// recipient's own seen-filter ('retiredSeen', see [retireSeenFor]).
  /// ACK-driven removal goes
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

  /// Set the byte cap and apply it NOW.
  ///
  /// Applied immediately rather than at the next store: a cap lowered below
  /// current occupancy would otherwise sit un-enforced until the next packet
  /// arrives, so the store would be over its own bound for as long as the
  /// node stayed quiet — which on a testbed is exactly the interval being
  /// measured.
  void setMaxBytes(int bytes) {
    maxBytes = bytes;
    _evictToFit();
  }

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
  void store(String recipientHex, GrassrootsPacket packet,
      {DateTime? now, bool retirableOnSeen = false}) {
    final at = now ?? DateTime.now();
    _prune(at);

    final list = _byRecipient.putIfAbsent(recipientHex, () => <_Entry>[]);
    if (list.any((e) => e.packet.packetId == packet.packetId)) {
      return; // already carrying this exact packet
    }
    list.add(_Entry(packet, at, retirableOnSeen: retirableOnSeen));
    _totalBytes += packet.payload.length;

    _evictToFit();

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

  /// The packets this node holds whose ORIGINATOR-stamped creation time is at
  /// or after [fromMs], oldest first, capped at [limit].
  ///
  /// Sorted by the packet's own `createdAtMs`, never by our `storedAt`: two
  /// nodes reconciling a window have to agree on which packets are in it, and
  /// receipt time is local to each of them. Oldest first because the sync
  /// sweep advances a cursor through the buffer, and the packets below the
  /// cursor are the ones that have been waiting longest.
  List<GrassrootsPacket> windowFrom(int fromMs,
      {required int limit, DateTime? now}) {
    _prune(now ?? DateTime.now());
    final all = <GrassrootsPacket>[
      for (final list in _byRecipient.values)
        for (final e in list)
          if (e.packet.createdAtMs >= fromMs) e.packet,
    ]..sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));
    if (all.length <= limit) return all;

    // Cut on a whole-millisecond boundary. The window's upper bound is the
    // creation stamp of the last packet that fits, and the responder answers
    // with anything in `[from, to]` the filter does not cover — so a boundary
    // that falls INSIDE a group sharing one stamp makes the packets we had to
    // leave out look missing, and they come straight back at us. Dropping the
    // partial trailing millisecond costs a few slots and removes that.
    var end = limit;
    final boundary = all[limit - 1].createdAtMs;
    while (end > 0 && all[end - 1].createdAtMs == boundary) {
      end--;
    }
    // Unless the whole window is one millisecond: then there is nothing to cut
    // back to and refusing to advance would stall the sweep forever. Advertise
    // what fits and accept that this one stamp may be re-sent — bounded, and
    // far cheaper than a cursor that never moves.
    return all.sublist(0, end == 0 ? limit : end);
  }

  /// Packets held whose creation time falls inside `[fromMs, toMs]` — what
  /// a responder considers when answering a filter. Bounded by the window, so
  /// a packet outside it is never sent in reply to that filter.
  List<GrassrootsPacket> windowBetween(int fromMs, int toMs,
      {DateTime? now}) {
    _prune(now ?? DateTime.now());
    return [
      for (final list in _byRecipient.values)
        for (final e in list)
          if (e.packet.createdAtMs >= fromMs &&
              e.packet.createdAtMs <= toMs)
            e.packet,
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

  /// Drop packets held FOR [recipientHex] that [seen] reports it already has.
  ///
  /// The sync exchange has the peer advertise what it has SEEN, and a holder
  /// currently answers by withholding those and conveying the rest --- so the
  /// packet stays in custody forever even though its journey is over. That is
  /// the buffer's largest resting population on a relaying node: transit
  /// packets have no end-to-end acknowledgement a carrier can observe, and a
  /// confirmation is never itself acknowledged, so neither has any retirement
  /// signal at all besides age.
  ///
  /// Two votes are required, under DIFFERENT SALTS --- see
  /// [_Entry.seenVoteSalt]. Only entries marked [_Entry.retirableOnSeen] go,
  /// only from the asking peer's OWN bucket --- this is the peer telling us about its own traffic,
  /// not an inference about a third party --- and only within the window the
  /// filter declared. Our own undelivered data is never retired this way; see
  /// [_Entry.retirableOnSeen].
  int retireSeenFor(String recipientHex, bool Function(String packetId) seen,
      {required int fromMs, required int toMs, required int voteSalt}) {
    // Every other entry point prunes first; without it an age-expired entry
    // is deleted here and reported as `retiredSeen`, mislabelling a loss in
    // the records a run is read from.
    _prune(DateTime.now());
    final list = _byRecipient[recipientHex];
    if (list == null || list.isEmpty) return 0;
    final retired = <_Entry>[];
    list.removeWhere((e) {
      // ONLY inside the window the filter declared. A GCS filter asserts
      // membership for the ids it was built from, which is the asker's
      // seen-set over [fromMs, toMs] and nothing else; outside that range a
      // hit is a hash collision, not evidence. The asker sweeps a cursor
      // across its history, so a packet the filter does not cover this round
      // is covered on a later one and retirement is delayed, never skipped.
      final created = e.packet.createdAtMs;
      // Says nothing about this packet: leave any standing vote alone.
      if (created < fromMs || created > toMs) return false;
      if (!e.retirableOnSeen) return false;
      if (!seen(e.packet.packetId)) {
        // A filter that COVERS this packet and does not name it contradicts
        // the standing vote, so the vote is spent. This is what makes the
        // rule "two CONSECUTIVE confirmations" rather than "two ever": a
        // vote that never expires accumulates independent rolls across the
        // entry's whole six-hour life, and over a ten-minute step the chance
        // that some two of them land is ~24%, against ~0.7% for two in a
        // row.
        e.seenVoteSalt = null;
        return false;
      }
      final prior = e.seenVoteSalt;
      if (prior == null || prior == voteSalt) {
        // First vote, or another frame hashed under the salt that already
        // voted — the same draw, so it carries no new information. Record and
        // wait for one under a different salt.
        e.seenVoteSalt = voteSalt;
        return false;
      }
      _totalBytes -= _entryBytes(e);
      retired.add(e);
      return true;
    });
    if (list.isEmpty) _byRecipient.remove(recipientHex);
    // Reported only once the store is settled. `removeWhere` does not shrink
    // the list as it runs, so a callback fired from inside it reads a count
    // that still includes every entry the pass is about to delete — including
    // the one being reported — against a byte total that has already been
    // charged for them.
    for (final e in retired) {
      onDrop?.call('retiredSeen', recipientHex, e.packet);
    }
    return retired.length;
  }

  /// Fraction of [maxBytes] at which eviction starts, and the fraction it
  /// stops at.
  ///
  /// Hysteresis rather than a single line, because a store pinned AT its cap
  /// evicts on every subsequent packet: one arrival, one eviction, forever.
  /// That makes the loss path a property of the arrival rate instead of of
  /// the buffer, and it leaves no headroom, so a burst is shed the instant it
  /// lands. Draining to a low-water mark instead sheds a batch and then runs
  /// free until the next high-water crossing, which is how a bounded cache is
  /// normally worked and what lets occupancy sit in a band rather than on a
  /// line.
  static const double evictHighWater = 0.99;
  static const double evictLowWater = 0.80;

  /// Evict the globally-oldest packets when occupancy crosses
  /// [evictHighWater], down to [evictLowWater].
  ///
  /// Each per-recipient list is append-ordered, so the oldest entry overall is
  /// the oldest list head. Shared by [store] and [setMaxBytes]: a cap lowered
  /// below current occupancy has to shed the excess with the same policy a
  /// full store sheds it, or the two paths would disagree about which packet
  /// dies first.
  void _evictToFit() {
    if (_totalBytes <= maxBytes * evictHighWater) return;
    final target = maxBytes * evictLowWater;
    while (_totalBytes > target) {
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

  /// May this entry be retired when its RECIPIENT says it has seen it?
  ///
  /// True for packets we carry for somebody else, and for our own
  /// confirmations. False for our own undelivered data, which is the one
  /// case where we may be the last holder: a false positive from the sync
  /// filter would lose the message outright, whereas a wrongly-retired
  /// transit copy is still held by its originator and a wrongly-retired
  /// confirmation costs only a receipt for data that already arrived.
  final bool retirableOnSeen;

  /// Salt of the filter that last voted to retire this entry, or null.
  ///
  /// Retirement needs TWO CONSECUTIVE votes under DIFFERENT SALTS --- any
  /// covering filter that does not name the packet clears the standing vote.
  /// That is what turns 1-in-128 into 1-in-16384, and the salt is the only
  /// part of a filter that guarantees the second roll is a fresh one: under
  /// one salt a packet's hash target is fixed, so two filters that share it
  /// put the same value against whatever slots they happen to occupy and
  /// agree with each other far more often than two draws would.
  ///
  /// A changed id set is NOT enough on its own, and neither is a changed
  /// window. The prefix frame's set stands still on a node that has seen
  /// nothing new; a sweep frame's window is historical, so its set does not
  /// change between one pass of the cursor and the next; and the prefix's
  /// `toMs` advances every round regardless, so keying on the window would
  /// score an unchanged draw as a fresh one.
  ///
  /// A salt recurring against a standing vote is refused rather than counted,
  /// so the failure is a packet that ages out instead of retiring --- the
  /// direction this rule is allowed to fail in.
  ///
  /// It matters because the rolls compound: a packet starved behind the
  /// convey cap, or whose write keeps being refused, is re-rolled every
  /// round, and over a ten-minute step a single-vote rule is more likely
  /// than not to retire it by mistake.
  int? seenVoteSalt;
  _Entry(this.packet, this.storedAt, {this.retirableOnSeen = false});
}
