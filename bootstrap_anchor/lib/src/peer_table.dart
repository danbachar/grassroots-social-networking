import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Tracks the owner and their explicit friend list.
///
/// The anchor is a personal server — it belongs to one user (the owner)
/// and only serves the owner's friends. Strangers are ignored.
class PeerTable {
  /// The owner's public key hex. The anchor acts on behalf of this user.
  final String ownerPubkeyHex;

  /// Explicit friend list: pubkey hex → PeerEntry.
  /// Only friends get signaling, address registration, and hole-punch coordination.
  final Map<String, PeerEntry> _friends = {};

  /// Peers that have connected and sent a valid ANNOUNCE but aren't friends.
  /// Kept briefly for diagnostics — they get no service.
  final Map<String, PeerEntry> _strangers = {};

  PeerTable({required this.ownerPubkeyHex});

  /// Add a friend by pubkey hex. The nickname and address will be filled
  /// when they first ANNOUNCE.
  void addFriend(String pubkeyHex, {String? nickname}) {
    _friends.putIfAbsent(
      pubkeyHex,
      () => PeerEntry(
        publicKey: _hexDecode(pubkeyHex),
        nickname: nickname ?? pubkeyHex.substring(0, 8),
        pubkeyHex: pubkeyHex,
        lastSeen: DateTime.fromMillisecondsSinceEpoch(0),
        firstSeen: DateTime.now(),
      ),
    );
  }

  /// Remove a friend.
  void removeFriend(String pubkeyHex) {
    _friends.remove(pubkeyHex);
  }

  /// Whether a pubkey hex is the owner or a friend — i.e. someone we serve.
  bool isFriend(String pubkeyHex) =>
      pubkeyHex == ownerPubkeyHex || _friends.containsKey(pubkeyHex);

  /// Update a peer's info from an ANNOUNCE.
  void upsert({
    required Uint8List publicKey,
    required String nickname,
    required String pubkeyHex,
    String? udpAddress,
  }) {
    if (isFriend(pubkeyHex)) {
      final existing = _friends[pubkeyHex];
      _friends[pubkeyHex] = PeerEntry(
        publicKey: publicKey,
        nickname: nickname,
        pubkeyHex: pubkeyHex,
        udpAddress: udpAddress ?? existing?.udpAddress,
        lastSeen: DateTime.now(),
        firstSeen: existing?.firstSeen ?? DateTime.now(),
      );
    } else {
      // Track stranger briefly for logging, but give them no service.
      _strangers[pubkeyHex] = PeerEntry(
        publicKey: publicKey,
        nickname: nickname,
        pubkeyHex: pubkeyHex,
        udpAddress: udpAddress,
        lastSeen: DateTime.now(),
        firstSeen: DateTime.now(),
      );
    }
  }

  PeerEntry? lookupFriend(String pubkeyHex) => _friends[pubkeyHex];

  /// Remove friends not seen for [maxAge].
  void removeStale(Duration maxAge) {
    final cutoff = DateTime.now().subtract(maxAge);
    _strangers.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
    // Don't remove friends from the list — they may reconnect. Just let
    // their lastSeen go stale for diagnostics.
  }

  int get friendCount => _friends.length;
  int get strangerCount => _strangers.length;
  Iterable<PeerEntry> get friends => _friends.values;
  Iterable<String> get friendPubkeyHexes => _friends.keys;

  /// Load the friend list from a JSON file.
  ///
  /// Format: `{ "friends": ["pubkeyHex1", "pubkeyHex2", ...] }`
  /// or: `{ "friends": [{"pubkey": "hex", "nickname": "name"}, ...] }`
  static Future<List<FriendSpec>> loadFriendList(String path) async {
    final file = File(path);
    if (!await file.exists()) return [];

    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final friendsList = json['friends'] as List<dynamic>? ?? [];
    final specs = <FriendSpec>[];

    for (final entry in friendsList) {
      if (entry is String) {
        specs.add(FriendSpec(pubkeyHex: entry));
      } else if (entry is Map<String, dynamic>) {
        specs.add(FriendSpec(
          pubkeyHex: entry['pubkey'] as String,
          nickname: entry['nickname'] as String?,
        ));
      }
    }
    return specs;
  }

  /// Save the current friend list to a JSON file.
  Future<void> saveFriendList(String path) async {
    final friends = _friends.values.map((f) => {
      'pubkey': f.pubkeyHex,
      'nickname': f.nickname,
    }).toList();
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert({'friends': friends}),
    );
  }

  static Uint8List _hexDecode(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }
}

class FriendSpec {
  final String pubkeyHex;
  final String? nickname;
  const FriendSpec({required this.pubkeyHex, this.nickname});
}

class PeerEntry {
  final Uint8List publicKey;
  final String nickname;
  final String pubkeyHex;
  final String? udpAddress;
  final DateTime lastSeen;
  final DateTime firstSeen;

  const PeerEntry({
    required this.publicKey,
    required this.nickname,
    required this.pubkeyHex,
    this.udpAddress,
    required this.lastSeen,
    required this.firstSeen,
  });

  @override
  String toString() => 'PeerEntry($nickname, $pubkeyHex'
      '${udpAddress != null ? ", addr: $udpAddress" : ""})';
}
