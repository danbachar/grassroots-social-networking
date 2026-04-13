/// In-memory address table for well-connected friends.
///
/// When this device is well-connected, it maintains a table of friend
/// addresses received via ADDR_REGISTER signaling messages. Other friends
/// can query this table via ADDR_QUERY to discover each other's addresses
/// for hole-punching.
///
/// The table is volatile — entries are lost on restart. Friends re-register
/// their addresses on startup, so this is fine.
class AddressTable {
  final Map<String, AddressEntry> _entries = {};

  /// Register (or update) a friend's address.
  void register(String pubkeyHex, String ip, int port) {
    _entries[pubkeyHex] = AddressEntry(
      ip: ip,
      port: port,
      registeredAt: DateTime.now(),
    );
  }

  /// Look up a friend's address by pubkey hex.
  ///
  /// Returns null if the friend hasn't registered or was removed.
  AddressEntry? lookup(String pubkeyHex) => _entries[pubkeyHex];

  /// Remove a specific entry.
  void remove(String pubkeyHex) => _entries.remove(pubkeyHex);

  /// Remove entries older than [maxAge].
  ///
  /// Call this periodically (e.g. every 60s) to evict stale entries
  /// from friends that went offline without deregistering.
  void removeStale(Duration maxAge) {
    final cutoff = DateTime.now().subtract(maxAge);
    _entries.removeWhere((_, entry) => entry.registeredAt.isBefore(cutoff));
  }

  /// Number of registered entries.
  int get length => _entries.length;

  /// All registered pubkey hexes.
  Iterable<String> get registeredPubkeys => _entries.keys;

  /// Clear all entries.
  void clear() => _entries.clear();
}

/// A registered address entry in the [AddressTable].
class AddressEntry {
  final String ip;
  final int port;
  final DateTime registeredAt;

  const AddressEntry({
    required this.ip,
    required this.port,
    required this.registeredAt,
  });

  @override
  String toString() => 'AddressEntry($ip:$port, registered: $registeredAt)';
}
