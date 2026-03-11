import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/peer.dart';

/// Represents a discovered peer before identity (ANNOUNCE) is exchanged.
/// Immutable version for Redux state.
@immutable
class DiscoveredPeerState {
  /// Transport-specific identifier (BLE device ID, libp2p peer ID, etc.)
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

  /// Number of connection attempts
  final int connectionAttempts;

  /// Number of consecutive failed connection attempts (for backoff)
  final int consecutiveFailures;

  /// Earliest time we can retry connection (null = can retry now)
  final DateTime? nextRetryAfter;

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
    this.connectionAttempts = 0,
    this.consecutiveFailures = 0,
    this.nextRetryAfter,
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
    int? connectionAttempts,
    int? consecutiveFailures,
    DateTime? nextRetryAfter,
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
      connectionAttempts: connectionAttempts ?? this.connectionAttempts,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      nextRetryAfter: nextRetryAfter ?? this.nextRetryAfter,
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
          connectionAttempts == other.connectionAttempts &&
          consecutiveFailures == other.consecutiveFailures &&
          nextRetryAfter == other.nextRetryAfter;

  @override
  int get hashCode => Object.hash(
    transportId,
    rssi,
    isConnecting,
    isConnected,
    lastError,
    serviceUuid,
    connectionAttempts,
    consecutiveFailures,
    nextRetryAfter,
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
  /// Used to detect stale BLE IDs (peer left BLE range but still on libp2p).
  final DateTime? lastBleSeen;

  /// Libp2p address if connected via libp2p
  final String? libp2pAddress;

  /// Whether this peer is a friend (friendship established)
  final bool isFriend;

  /// Libp2p host ID (PeerId string) for transport-level addressing
  final String? libp2pHostId;

  /// Libp2p host addresses (multiaddrs) for reconnection
  final List<String>? libp2pHostAddrs;

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
    this.libp2pAddress,
    this.isFriend = false,
    this.libp2pHostId,
    this.libp2pHostAddrs,
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

  /// Whether this peer is reachable via any transport
  bool get isReachable => hasBleConnection || libp2pAddress != null;

  /// The currently active transport based on available connections.
  /// BLE is preferred when available; falls back to libp2p, then stored value.
  PeerTransport get activeTransport {
    if (hasBleConnection) return PeerTransport.bleDirect;
    if (libp2pAddress != null) return PeerTransport.libp2p;
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
    String? libp2pAddress,
    bool? isFriend,
    String? libp2pHostId,
    List<String>? libp2pHostAddrs,
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
      libp2pAddress: libp2pAddress ?? this.libp2pAddress,
      isFriend: isFriend ?? this.isFriend,
      libp2pHostId: libp2pHostId ?? this.libp2pHostId,
      libp2pHostAddrs: libp2pHostAddrs ?? this.libp2pHostAddrs,
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
          libp2pAddress == other.libp2pAddress &&
          isFriend == other.isFriend &&
          libp2pHostId == other.libp2pHostId;

  @override
  int get hashCode => Object.hash(
    pubkeyHex,
    nickname,
    connectionState,
    transport,
    rssi,
    bleCentralDeviceId,
    blePeripheralDeviceId,
    libp2pAddress,
    isFriend,
    libp2pHostId,
  );
}

/// Complete peers state for Redux store
@immutable
class PeersState {
  /// Discovered BLE peers (before ANNOUNCE), keyed by device ID
  final Map<String, DiscoveredPeerState> discoveredBlePeers;

  /// Discovered libp2p peers (before ANNOUNCE), keyed by peer ID
  final Map<String, DiscoveredPeerState> discoveredLibp2pPeers;

  /// Identified peers (after ANNOUNCE), keyed by pubkey hex
  final Map<String, PeerState> peers;

  const PeersState({
    this.discoveredBlePeers = const {},
    this.discoveredLibp2pPeers = const {},
    this.peers = const {},
  });

  static const PeersState initial = PeersState();

  // ===== Getters =====

  /// All discovered BLE peers as list
  List<DiscoveredPeerState> get discoveredBlePeersList => discoveredBlePeers.values.toList();

  /// All discovered libp2p peers as list
  List<DiscoveredPeerState> get discoveredLibp2pPeersList => discoveredLibp2pPeers.values.toList();

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

  /// Peers reachable via libp2p
  List<PeerState> get libp2pPeers =>
      peers.values.where((p) => p.libp2pAddress != null).toList();

  /// All friends
  List<PeerState> get friends =>
      peers.values.where((p) => p.isFriend).toList();

  /// Online friends - friends connected via libp2p only (not nearby via BLE).
  /// Use this for the "Friends Online" section in UI.
  List<PeerState> get onlineFriends =>
      peers.values.where((p) => p.isFriend && p.isConnected && !p.hasBleConnection && p.libp2pAddress != null).toList();

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
    Map<String, DiscoveredPeerState>? discoveredLibp2pPeers,
    Map<String, PeerState>? peers,
  }) {
    return PeersState(
      discoveredBlePeers: discoveredBlePeers ?? this.discoveredBlePeers,
      discoveredLibp2pPeers: discoveredLibp2pPeers ?? this.discoveredLibp2pPeers,
      peers: peers ?? this.peers,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeersState &&
          runtimeType == other.runtimeType &&
          mapEquals(discoveredBlePeers, other.discoveredBlePeers) &&
          mapEquals(discoveredLibp2pPeers, other.discoveredLibp2pPeers) &&
          mapEquals(peers, other.peers);

  @override
  int get hashCode => Object.hash(
    discoveredBlePeers.length,
    discoveredLibp2pPeers.length,
    peers.length,
  );
}
