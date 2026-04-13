/// In-memory address table for friend addresses.
///
/// Identical to the client-side AddressTable. The anchor maintains this
/// to answer ADDR_QUERY requests from friends.
class AddressTable {
  final Map<String, AddressEntry> _entries = {};

  void register(String pubkeyHex, String ip, int port) {
    _entries[pubkeyHex] = AddressEntry(
      ip: ip,
      port: port,
      registeredAt: DateTime.now(),
    );
  }

  AddressEntry? lookup(String pubkeyHex) => _entries[pubkeyHex];

  void remove(String pubkeyHex) => _entries.remove(pubkeyHex);

  void removeStale(Duration maxAge) {
    final cutoff = DateTime.now().subtract(maxAge);
    _entries.removeWhere((_, entry) => entry.registeredAt.isBefore(cutoff));
  }

  int get length => _entries.length;
  Iterable<String> get registeredPubkeys => _entries.keys;
  void clear() => _entries.clear();
}

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
  String toString() => 'AddressEntry($ip:$port)';
}
