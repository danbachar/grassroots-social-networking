import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/peer.dart';

/// Represents a discovered peer before identity (ANNOUNCE) is exchanged.
/// Immutable version for Redux state.
@immutable
class DiscoveredPeerState {
  /// Transport-specific identifier (BLE device ID, etc.)
  final String transportId;

  /// Human-readable name (from BLE advertising, etc.)
  final String? displayName;

  /// Signal strength indicator
  final int rssi;

  /// When this peer was first discovered
  final DateTime discoveredAt;

  /// When this peer was last seen
  final DateTime lastSeen;

  /// Whether we're currently attempting to connect
  final bool isConnecting;

  /// Whether we're currently connected (transport level)
  final bool isConnected;

  /// Last connection error, if any
  final String? lastError;

  /// Public key if known (after ANNOUNCE exchange)
  final Uint8List? publicKey;

  /// Service UUID (for correlation on iOS)
  final String? serviceUuid;

  /// Number of consecutive failed connection attempts (for backoff)
  final int consecutiveFailures;

  /// Earliest time we can retry connection (null = can retry now)
  final DateTime? nextRetryAfter;

  /// Whether this device was manually disconnected and should not auto-connect
  final bool isBlacklisted;

  const DiscoveredPeerState({
    required this.transportId,
    this.displayName,
    required this.rssi,
    required this.discoveredAt,
    required this.lastSeen,
    this.isConnecting = false,
    this.isConnected = false,
    this.lastError,
    this.publicKey,
    this.serviceUuid,
    this.consecutiveFailures = 0,
    this.nextRetryAfter,
    this.isBlacklisted = false,
  });

  /// Signal quality indicator (0.0 - 1.0), derived from rssi
  double get signalQuality {
    if (rssi >= -50) return 1.0;
    if (rssi <= -100) return 0.0;
    return (rssi + 100) / 50.0;
  }

  /// Whether we know this peer's identity (received ANNOUNCE)
  bool get isIdentified => publicKey != null;

  /// Whether this device is currently in backoff period
  bool get isInBackoff =>
      nextRetryAfter != null && DateTime.now().isBefore(nextRetryAfter!);

  DiscoveredPeerState copyWith({
    String? transportId,
    String? displayName,
    int? rssi,
    DateTime? discoveredAt,
    DateTime? lastSeen,
    bool? isConnecting,
    bool? isConnected,
    String? lastError,
    Uint8List? publicKey,
    String? serviceUuid,
    int? consecutiveFailures,
    DateTime? nextRetryAfter,
    bool? isBlacklisted,
  }) {
    return DiscoveredPeerState(
      transportId: transportId ?? this.transportId,
      displayName: displayName ?? this.displayName,
      rssi: rssi ?? this.rssi,
      discoveredAt: discoveredAt ?? this.discoveredAt,
      lastSeen: lastSeen ?? this.lastSeen,
      isConnecting: isConnecting ?? this.isConnecting,
      isConnected: isConnected ?? this.isConnected,
      lastError: lastError ?? this.lastError,
      publicKey: publicKey ?? this.publicKey,
      serviceUuid: serviceUuid ?? this.serviceUuid,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      nextRetryAfter: nextRetryAfter ?? this.nextRetryAfter,
      isBlacklisted: isBlacklisted ?? this.isBlacklisted,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredPeerState &&
          runtimeType == other.runtimeType &&
          transportId == other.transportId &&
          rssi == other.rssi &&
          isConnecting == other.isConnecting &&
          isConnected == other.isConnected &&
          lastError == other.lastError &&
          serviceUuid == other.serviceUuid &&
          consecutiveFailures == other.consecutiveFailures &&
          nextRetryAfter == other.nextRetryAfter &&
          isBlacklisted == other.isBlacklisted;

  @override
  int get hashCode => Object.hash(
    transportId,
    rssi,
    isConnecting,
    isConnected,
    lastError,
    serviceUuid,
    consecutiveFailures,
    nextRetryAfter,
    isBlacklisted,
  );

  @override
  String toString() => 'DiscoveredPeerState($transportId, rssi: $rssi, connected: $isConnected, failures: $consecutiveFailures)';
}

/// Immutable peer state for identified peers (after ANNOUNCE)
@immutable
class PeerState {
  final Uint8List publicKey;
  final String nickname;
  final PeerConnectionState connectionState;
  final PeerTransport transport;
  final int rssi;
  final int protocolVersion;
  final DateTime? lastSeen;

  /// BLE device ID when our device is the central (we scanned and connected to them)
  final String? bleCentralDeviceId;

  /// BLE device ID when our device is the peripheral (they connected to us)
  final String? blePeripheralDeviceId;

  /// When the last BLE ANNOUNCE was received from this peer.
  /// Used to detect stale BLE IDs (peer left BLE range but still on UDP).
  final DateTime? lastBleSeen;

  /// UDP address if connected via UDP (ip:port format)
  final String? udpAddress;

  /// Link-local IPv6 address (fe80::...:port) for same-LAN fallback.
  /// Only available from BLE-nearby peers. Tried before global address.
  final String? linkLocalAddress;

  /// Whether this peer is a friend (friendship established)
  final bool isFriend;

  /// Whether this peer is well-connected and can serve as a signaling node
  final bool isWellConnected;

  /// Whether there is a live UDX connection to this peer.
  /// Set true when UDX handshake completes, false when the stream closes.
  /// Unlike [udpAddress] (which is preserved for reconnection), this reflects
  /// the actual transport-level connection state right now.
  final bool hasLiveUdpConnection;

  const PeerState({
    required this.publicKey,
    required this.nickname,
    this.connectionState = PeerConnectionState.discovered,
    this.transport = PeerTransport.bleDirect,
    this.rssi = -100,
    this.protocolVersion = 1,
    this.lastSeen,
    this.bleCentralDeviceId,
    this.blePeripheralDeviceId,
    this.lastBleSeen,
    this.udpAddress,
    this.linkLocalAddress,
    this.isFriend = false,
    this.isWellConnected = false,
    this.hasLiveUdpConnection = false,
  });

  /// Hex representation of public key (for map keys)
  String get pubkeyHex => publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Display name (nickname or truncated pubkey)
  String get displayName => nickname.isNotEmpty ? nickname : '${pubkeyHex.substring(0, 8)}...';

  /// Whether this peer is currently connected
  bool get isConnected => connectionState == PeerConnectionState.connected;

  /// Whether this peer has any BLE connection (central or peripheral)
  bool get hasBleConnection => bleCentralDeviceId != null || blePeripheralDeviceId != null;

  /// Convenience getter: preferred BLE device ID for sending.
  /// Prefers central (we initiated) since sendToPeer tries central service first.
  String? get bleDeviceId => bleCentralDeviceId ?? blePeripheralDeviceId;

  /// Whether this peer is potentially reachable via any transport.
  /// For UDP, a stored address is sufficient (we can attempt to connect).
  /// See [isLiveReachable] for actual live connection status.
  bool get isReachable => hasBleConnection || udpAddress != null;

  /// Whether this peer has a live, active connection right now.
  /// Use this for UI "online" status — not for signaling/discovery.
  bool get isLiveReachable => hasBleConnection || hasLiveUdpConnection;

  /// The currently active transport based on available connections.
  /// BLE is preferred when available; falls back to UDP, then stored value.
  PeerTransport get activeTransport {
    if (hasBleConnection) return PeerTransport.bleDirect;
    if (udpAddress != null) return PeerTransport.udp;
    return transport;
  }

  /// Signal quality (0.0 - 1.0)
  double get signalQuality {
    if (rssi >= -50) return 1.0;
    if (rssi <= -100) return 0.0;
    return (rssi + 100) / 50.0;
  }

  PeerState copyWith({
    Uint8List? publicKey,
    String? nickname,
    PeerConnectionState? connectionState,
    PeerTransport? transport,
    int? rssi,
    int? protocolVersion,
    DateTime? lastSeen,
    String? bleCentralDeviceId,
    String? blePeripheralDeviceId,
    DateTime? lastBleSeen,
    String? udpAddress,
    String? linkLocalAddress,
    bool? isFriend,
    bool? isWellConnected,
    bool? hasLiveUdpConnection,
  }) {
    return PeerState(
      publicKey: publicKey ?? this.publicKey,
      nickname: nickname ?? this.nickname,
      connectionState: connectionState ?? this.connectionState,
      transport: transport ?? this.transport,
      rssi: rssi ?? this.rssi,
      protocolVersion: protocolVersion ?? this.protocolVersion,
      lastSeen: lastSeen ?? this.lastSeen,
      bleCentralDeviceId: bleCentralDeviceId ?? this.bleCentralDeviceId,
      blePeripheralDeviceId: blePeripheralDeviceId ?? this.blePeripheralDeviceId,
      lastBleSeen: lastBleSeen ?? this.lastBleSeen,
      udpAddress: udpAddress ?? this.udpAddress,
      linkLocalAddress: linkLocalAddress ?? this.linkLocalAddress,
      isFriend: isFriend ?? this.isFriend,
      isWellConnected: isWellConnected ?? this.isWellConnected,
      hasLiveUdpConnection: hasLiveUdpConnection ?? this.hasLiveUdpConnection,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerState &&
          runtimeType == other.runtimeType &&
          pubkeyHex == other.pubkeyHex &&
          nickname == other.nickname &&
          connectionState == other.connectionState &&
          transport == other.transport &&
          rssi == other.rssi &&
          bleCentralDeviceId == other.bleCentralDeviceId &&
          blePeripheralDeviceId == other.blePeripheralDeviceId &&
          udpAddress == other.udpAddress &&
          linkLocalAddress == other.linkLocalAddress &&
          isFriend == other.isFriend &&
          isWellConnected == other.isWellConnected &&
          hasLiveUdpConnection == other.hasLiveUdpConnection;

  @override
  int get hashCode => Object.hash(
    pubkeyHex,
    nickname,
    connectionState,
    transport,
    rssi,
    bleCentralDeviceId,
    blePeripheralDeviceId,
    udpAddress,
    linkLocalAddress,
    isFriend,
    isWellConnected,
    hasLiveUdpConnection,
  );
}

/// Complete peers state for Redux store
@immutable
class PeersState {
  /// Discovered BLE peers (before ANNOUNCE), keyed by device ID
  final Map<String, DiscoveredPeerState> discoveredBlePeers;

  /// Identified peers (after ANNOUNCE), keyed by pubkey hex
  final Map<String, PeerState> peers;

  const PeersState({
    this.discoveredBlePeers = const {},
    this.peers = const {},
  });

  static const PeersState initial = PeersState();

  // ===== Getters =====

  /// All discovered BLE peers as list
  List<DiscoveredPeerState> get discoveredBlePeersList => discoveredBlePeers.values.toList();

  /// All identified peers as list
  List<PeerState> get peersList => peers.values.toList();

  /// Connected peers only
  List<PeerState> get connectedPeers =>
      peers.values.where((p) => p.isConnected).toList();

  /// Peers reachable via BLE
  List<PeerState> get blePeers =>
      peers.values.where((p) => p.hasBleConnection).toList();

  /// Nearby peers - connected peers reachable via BLE (in physical proximity)
  /// Use this for the "Nearby" section in UI.
  List<PeerState> get nearbyBlePeers =>
      peers.values.where((p) => p.isConnected && p.hasBleConnection).toList();

  /// Peers with a live UDP connection
  List<PeerState> get udpPeers =>
      peers.values.where((p) => p.hasLiveUdpConnection).toList();

  /// All friends
  List<PeerState> get friends =>
      peers.values.where((p) => p.isFriend).toList();

  /// Online friends - friends with a live UDP connection (not nearby via BLE).
  /// Use this for the "Friends Online" section in UI.
  List<PeerState> get onlineFriends =>
      peers.values.where((p) => p.isFriend && p.isConnected && p.hasLiveUdpConnection).toList();

  /// Well-connected friends that can serve as signaling nodes
  List<PeerState> get wellConnectedFriends =>
      peers.values.where((p) => p.isFriend && p.isWellConnected && p.isReachable).toList();

  /// Count of connected peers
  int get connectedCount => connectedPeers.length;

  /// Count of all discovered BLE devices
  int get discoveredBleCount => discoveredBlePeers.length;

  /// Get peer by pubkey hex
  PeerState? getPeerByPubkeyHex(String pubkeyHex) => peers[pubkeyHex];

  /// Get peer by pubkey bytes
  PeerState? getPeerByPubkey(Uint8List pubkey) {
    final hex = pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return peers[hex];
  }

  /// Get discovered BLE peer by device ID
  DiscoveredPeerState? getDiscoveredBlePeer(String deviceId) =>
      discoveredBlePeers[deviceId];

  /// Find discovered BLE peer by service UUID
  DiscoveredPeerState? findDiscoveredBlePeerByServiceUuid(String serviceUuid) {
    final lowerUuid = serviceUuid.toLowerCase();
    for (final peer in discoveredBlePeers.values) {
      if (peer.serviceUuid?.toLowerCase() == lowerUuid) {
        return peer;
      }
    }
    return null;
  }

  /// Check if a peer is reachable by pubkey
  bool isPeerReachable(Uint8List pubkey) {
    final peer = getPeerByPubkey(pubkey);
    return peer?.isReachable ?? false;
  }

  // ===== Copy With =====

  PeersState copyWith({
    Map<String, DiscoveredPeerState>? discoveredBlePeers,
    Map<String, PeerState>? peers,
  }) {
    return PeersState(
      discoveredBlePeers: discoveredBlePeers ?? this.discoveredBlePeers,
      peers: peers ?? this.peers,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeersState &&
          runtimeType == other.runtimeType &&
          mapEquals(discoveredBlePeers, other.discoveredBlePeers) &&
          mapEquals(peers, other.peers);

  @override
  int get hashCode => Object.hash(
    discoveredBlePeers.length,
    peers.length,
  );
}
