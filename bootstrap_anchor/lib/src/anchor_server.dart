import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_udx/dart_udx.dart';

import 'address_table.dart';
import 'identity.dart';
import 'packet.dart';
import 'peer_table.dart';
import 'protocol.dart';
import 'signaling_codec.dart';
import 'signaling_handler.dart';

/// The bootstrap anchor server — a personal cloud peer.
///
/// Belongs to a specific user (the owner) and only serves the owner's
/// friends. The server's Ed25519 identity is separate from the owner's —
/// the owner friends the server, and the server friends whoever the owner
/// tells it to (via a friends.json file).
///
/// Responsibilities:
///
/// 1. **Bootstrap anchor** — peers hardcode its address; provides a
///    starting point for address discovery.
/// 2. **Address reflection** — reflects observed public address back to
///    friends (STUN-equivalent via ADDR_REFLECT).
/// 3. **Address table** — maintains a volatile table of friend addresses,
///    answers ADDR_QUERY from friends only.
/// 4. **Hole-punch coordination** — orchestrates simultaneous hole-punches
///    between friends via PUNCH_REQUEST/PUNCH_INITIATE/PUNCH_READY.
///
/// The anchor never relays message content. Only signaling metadata
/// flows through it. Strangers are ignored completely.
class AnchorServer {
  final int port;
  final String nickname;
  final String seedHex;
  final String friendsPath;
  final String ownerPubkeyHex;
  final int announceIntervalSeconds;

  late AnchorIdentity _identity;
  late Protocol _protocol;
  late PeerTable _peerTable;
  late AddressTable _addressTable;
  late SignalingHandler _signalingHandler;
  late SignalingCodec _codec;

  RawDatagramSocket? _rawSocket;
  UDX? _udx;
  UDXMultiplexer? _multiplexer;

  /// Active UDX connections per peer, keyed by pubkey hex.
  final Map<String, _PeerConnection> _peerConnections = {};

  /// Reverse map: tempKey → pubkey hex.
  final Map<String, String> _tempKeyToPubkey = {};

  /// Reverse map: "ip:port" → pubkey hex.
  final Map<String, String> _addressToPubkey = {};

  /// Pending incoming connections not yet mapped to a pubkey.
  final Map<String, _PeerConnection> _pendingIncoming = {};

  Timer? _announceTimer;
  Timer? _staleCleanupTimer;
  Timer? _statsTimer;

  String? _publicAddress;

  StreamSubscription? _multiplexerConnectionsSub;

  AnchorServer({
    required this.port,
    required this.nickname,
    required this.seedHex,
    required this.friendsPath,
    required this.ownerPubkeyHex,
    this.announceIntervalSeconds = 30,
  });

  Future<void> start() async {
    _log('Starting Bitchat Bootstrap Anchor...');
    _log('Owner: ${ownerPubkeyHex.substring(0, 16)}...');

    // Derive identity from the anchor seed (subkey of the owner's key)
    _identity = await AnchorIdentity.fromSeedHex(
      seedHex: seedHex,
      nickname: nickname,
    );
    _log('Identity pubkey: ${_identity.pubkeyHex}');

    _protocol = Protocol(identity: _identity);
    _peerTable = PeerTable(ownerPubkeyHex: ownerPubkeyHex);
    _addressTable = AddressTable();
    _codec = const SignalingCodec();

    // The owner is always a friend
    _peerTable.addFriend(ownerPubkeyHex, nickname: 'owner');

    // Load persisted friend list from last sync (for restart recovery).
    // The owner's device is the source of truth — on next connect it sends
    // a fresh FRIENDS_SYNC that replaces this entirely.
    final friendSpecs = await PeerTable.loadFriendList(friendsPath);
    for (final spec in friendSpecs) {
      _peerTable.addFriend(spec.pubkeyHex, nickname: spec.nickname);
    }
    if (friendSpecs.isNotEmpty) {
      _log('Restored ${friendSpecs.length} friends from last sync');
    }
    for (final hex in _peerTable.friendPubkeyHexes) {
      final entry = _peerTable.lookupFriend(hex);
      _log('  Friend: ${entry?.nickname ?? "?"} (${hex.substring(0, 12)}...)');
    }

    _signalingHandler = SignalingHandler(
      protocol: _protocol,
      peerTable: _peerTable,
      addressTable: _addressTable,
      codec: _codec,
    );
    _signalingHandler.sendSignaling = _sendSignaling;
    _signalingHandler.onFriendsSynced = () {
      // Persist the updated friend list for restart recovery
      _peerTable.saveFriendList(friendsPath);
      _log('Friend list persisted to $friendsPath');
    };

    // Bind UDP socket (IPv6)
    _rawSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv6, port);
    _log('UDP socket bound on port $port');

    // Discover our public address
    await _discoverPublicAddress();

    // Start UDX multiplexer
    _udx = UDX();
    _multiplexer = UDXMultiplexer(_rawSocket!);
    _multiplexer!.onRawPacket = _handleRawPacket;
    _multiplexerConnectionsSub =
        _multiplexer!.connections.listen(_handleIncomingConnection);
    _log('UDX multiplexer started');

    // Periodic ANNOUNCE to all connected friends
    _announceTimer = Timer.periodic(
      Duration(seconds: announceIntervalSeconds),
      (_) => _broadcastAnnounce(),
    );

    // Periodic stale entry cleanup
    _staleCleanupTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) {
        _addressTable.removeStale(const Duration(minutes: 5));
        _peerTable.removeStale(const Duration(minutes: 30));
      },
    );

    // Periodic stats
    _statsTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _printStats(),
    );

    _log('Bootstrap anchor ready');
    _log('  Address:  $_publicAddress');
    _log('  Pubkey:   ${_identity.pubkeyHex}');
    _log('  Owner:    ${ownerPubkeyHex.substring(0, 16)}...');
    _log('  Friends:  ${_peerTable.friendCount}');
    _log('Waiting for connections...');
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _staleCleanupTimer?.cancel();
    _statsTimer?.cancel();
    await _multiplexerConnectionsSub?.cancel();

    for (final conn in _peerConnections.values) {
      try {
        await conn.stream?.close();
      } catch (_) {}
    }
    _peerConnections.clear();

    _rawSocket?.close();
    _rawSocket = null;
    _multiplexer = null;
    _udx = null;

    _log('Anchor stopped');
  }

  /// Add a friend at runtime (e.g. via admin command).
  void addFriend(String pubkeyHex, {String? nickname}) {
    _peerTable.addFriend(pubkeyHex, nickname: nickname);
    _log('Friend added: ${nickname ?? pubkeyHex.substring(0, 8)}');
    // Persist
    _peerTable.saveFriendList(friendsPath);
  }

  /// Remove a friend at runtime.
  void removeFriend(String pubkeyHex) {
    _peerTable.removeFriend(pubkeyHex);
    _addressTable.remove(pubkeyHex);
    _log('Friend removed: ${pubkeyHex.substring(0, 8)}...');
    _peerTable.saveFriendList(friendsPath);
  }

  // ===== Public Address Discovery =====

  Future<void> _discoverPublicAddress() async {
    // On a GCP VM with a public IPv6, enumerate interfaces.
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv6,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.isLinkLocal) {
            _publicAddress = '[${addr.address}]:$port';
            _log('Discovered public address: $_publicAddress');
            return;
          }
        }
      }
    } catch (e) {
      _log('Failed to enumerate interfaces: $e');
    }

    // Fallback: try seeip.org
    try {
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('https://ip6.seeip.org'));
      final response = await request.close();
      final body =
          await response.transform(const SystemEncoding().decoder).join();
      final ip = body.trim();
      if (ip.isNotEmpty && ip.contains(':')) {
        _publicAddress = '[$ip]:$port';
        _log('Discovered public address via seeip.org: $_publicAddress');
      }
      client.close();
    } catch (e) {
      _log('Failed to discover public address via seeip: $e');
      _publicAddress = '[::]:$port';
    }
  }

  // ===== Connection Handling =====

  void _handleIncomingConnection(UDPSocket socket) {
    final remoteAddr =
        '${socket.remoteAddress.address}:${socket.remotePort}';
    _log('Incoming UDX connection from $remoteAddr');

    final knownPubkey = _addressToPubkey[remoteAddr];
    if (knownPubkey != null) {
      _log('Known peer $knownPubkey at $remoteAddr');
      socket.on('stream').listen((UDXEvent event) {
        final stream = event.data as UDXStream;
        _listenToStream(knownPubkey, stream);
      });
      socket.flushStreamBuffer();
      return;
    }

    // Unknown — use tempKey until ANNOUNCE reveals identity
    socket.on('stream').listen((UDXEvent event) {
      final stream = event.data as UDXStream;
      _handleIncomingStream(socket, stream);
    });
    socket.flushStreamBuffer();
  }

  void _handleIncomingStream(UDPSocket socket, UDXStream stream) {
    final tempKey =
        '${socket.remoteAddress}:${socket.remotePort}:${stream.id}';

    _pendingIncoming[tempKey] = _PeerConnection(
      pubkeyHex: '',
      udpSocket: socket,
      stream: stream,
      addr: socket.remoteAddress,
      port: socket.remotePort,
    );

    stream.data.listen(
      (Uint8List data) {
        if (data.isEmpty) return;
        final effectiveId = _tempKeyToPubkey[tempKey] ?? tempKey;
        _processIncomingData(effectiveId, data,
            observedIp: socket.remoteAddress.address,
            observedPort: socket.remotePort);
      },
      onError: (e) {
        _log('UDX stream error from $tempKey: $e');
      },
      onDone: () {
        _log('UDX stream closed from $tempKey');
        final pubkeyHex = _tempKeyToPubkey.remove(tempKey);
        if (pubkeyHex != null) {
          _peerConnections.remove(pubkeyHex);
          _log('Peer disconnected: ${pubkeyHex.substring(0, 8)}...');
        }
        _pendingIncoming.remove(tempKey);
      },
    );
  }

  void _listenToStream(String pubkeyHex, UDXStream stream) {
    final conn = _peerConnections[pubkeyHex];
    stream.data.listen(
      (Uint8List data) {
        if (data.isEmpty) return;
        _processIncomingData(pubkeyHex, data,
            observedIp: conn?.addr.address, observedPort: conn?.port);
      },
      onError: (e) {
        _log('UDX stream error from $pubkeyHex: $e');
      },
      onDone: () {
        _log('UDX stream closed from ${pubkeyHex.substring(0, 8)}...');
        _peerConnections.remove(pubkeyHex);
      },
    );
  }

  void _handleRawPacket(Uint8List data, InternetAddress address, int port) {
    // Skip punch packets
    if (data.length == 36 &&
        data[0] == 0x42 &&
        data[1] == 0x43 &&
        data[2] == 0x50 &&
        data[3] == 0x55) {
      return;
    }
    if (data.length < 50) return;

    _log('Raw UDP packet: ${data.length} bytes from ${address.address}:$port');
    _processIncomingData('${address.address}:$port', data,
        observedIp: address.address, observedPort: port);
  }

  // ===== Packet Processing =====

  Future<void> _processIncomingData(
    String peerId,
    Uint8List data, {
    String? observedIp,
    int? observedPort,
  }) async {
    BitchatPacket packet;
    try {
      packet = BitchatPacket.deserialize(data);
    } catch (e) {
      _log('Failed to deserialize packet from $peerId: $e');
      return;
    }

    // Verify signature
    final isValid = await _protocol.verifyPacket(packet);
    if (!isValid) {
      _log('Dropping packet with invalid signature from $peerId');
      return;
    }

    final senderHex = _pubkeyToHex(packet.senderPubkey);

    // Map incoming connection to pubkey
    if (peerId.contains(':') && !_peerConnections.containsKey(senderHex)) {
      _tempKeyToPubkey[peerId] = senderHex;
      _mapIncomingConnectionToPubkey(peerId, senderHex);
    }

    switch (packet.type) {
      case PacketType.announce:
        _handleAnnounce(packet,
            observedIp: observedIp, observedPort: observedPort);
      case PacketType.signaling:
        _signalingHandler.processSignaling(
            packet.senderPubkey, packet.payload);
      case PacketType.message:
      case PacketType.fragmentStart:
      case PacketType.fragmentContinue:
      case PacketType.fragmentEnd:
        // The anchor never relays message content.
        _log('Dropping ${packet.type} from ${senderHex.substring(0, 8)}... '
            '(anchor does not relay messages)');
      case PacketType.ack:
      case PacketType.nack:
      case PacketType.readReceipt:
        break;
    }
  }

  void _handleAnnounce(
    BitchatPacket packet, {
    String? observedIp,
    int? observedPort,
  }) {
    final data = _protocol.decodeAnnounce(packet.payload);
    final senderHex = data.pubkeyHex;
    final isFriend = _peerTable.isFriend(senderHex);

    _signalingHandler.processAnnounce(
      data,
      observedIp: observedIp,
      observedPort: observedPort,
    );

    if (isFriend) {
      _log('Friend ANNOUNCE: ${data.nickname} (${senderHex.substring(0, 8)}...)');
      // Send our ANNOUNCE back so they know who we are
      _sendAnnounceTo(packet.senderPubkey);
    } else {
      _log('Stranger ANNOUNCE: ${data.nickname} (${senderHex.substring(0, 8)}...) — no service');
    }
  }

  void _mapIncomingConnectionToPubkey(String tempKey, String pubkeyHex) {
    final pending = _pendingIncoming.remove(tempKey);
    if (pending != null && !_peerConnections.containsKey(pubkeyHex)) {
      _peerConnections[pubkeyHex] = _PeerConnection(
        pubkeyHex: pubkeyHex,
        udpSocket: pending.udpSocket,
        stream: pending.stream,
        addr: pending.addr,
        port: pending.port,
      );
      _addressToPubkey['${pending.addr.address}:${pending.port}'] = pubkeyHex;
      _log('Mapped connection → ${pubkeyHex.substring(0, 8)}...');
    }
  }

  // ===== Sending =====

  Future<bool> _sendSignaling(
      Uint8List recipientPubkey, Uint8List signalingPayload) async {
    final packet = _protocol.createSignalingPacket(
      recipientPubkey: recipientPubkey,
      signalingPayload: signalingPayload,
    );
    await _protocol.signPacket(packet);
    return _sendPacket(_pubkeyToHex(recipientPubkey), packet);
  }

  Future<void> _sendAnnounceTo(Uint8List recipientPubkey) async {
    final packet = _protocol.createAnnouncePacket(address: _publicAddress);
    await _protocol.signPacket(packet);
    _sendPacket(_pubkeyToHex(recipientPubkey), packet);
  }

  Future<void> _broadcastAnnounce() async {
    if (_peerConnections.isEmpty) return;

    final packet = _protocol.createAnnouncePacket(address: _publicAddress);
    await _protocol.signPacket(packet);
    final data = packet.serialize();

    // Only send ANNOUNCE to connected friends
    for (final entry in _peerConnections.entries) {
      if (!_peerTable.isFriend(entry.key)) continue;
      try {
        await entry.value.stream?.add(data);
      } catch (e) {
        _log('Failed to send ANNOUNCE to ${entry.key.substring(0, 8)}...: $e');
      }
    }
  }

  bool _sendPacket(String pubkeyHex, BitchatPacket packet) {
    final conn = _peerConnections[pubkeyHex];
    if (conn == null || conn.stream == null) {
      _log('Cannot send to ${pubkeyHex.substring(0, 8)}...: not connected');
      return false;
    }

    try {
      final data = packet.serialize();
      conn.stream!.add(data);
      return true;
    } catch (e) {
      _log('Failed to send to ${pubkeyHex.substring(0, 8)}...: $e');
      return false;
    }
  }

  // ===== Stats =====

  void _printStats() {
    _log('--- Stats ---');
    _log('  Connected: ${_peerConnections.length} '
        '(friends: ${_peerTable.friendCount}, '
        'strangers seen: ${_peerTable.strangerCount})');
    _log('  Address table: ${_addressTable.length} entries');
    for (final friend in _peerTable.friends) {
      final addr = _addressTable.lookup(friend.pubkeyHex);
      final connected = _peerConnections.containsKey(friend.pubkeyHex);
      _log('  ${friend.nickname} (${friend.pubkeyHex.substring(0, 8)}...) '
          '${connected ? "LIVE" : "offline"}'
          '${addr != null ? " addr=${addr.ip}:${addr.port}" : ""}');
    }
  }

  // ===== Helpers =====

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    print('[$ts] $message');
  }
}

class _PeerConnection {
  final String pubkeyHex;
  final UDPSocket udpSocket;
  final UDXStream? stream;
  final InternetAddress addr;
  final int port;

  _PeerConnection({
    required this.pubkeyHex,
    required this.udpSocket,
    this.stream,
    required this.addr,
    required this.port,
  });
}
