import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';

/// Transport type identifier
enum TransportType {
  /// Bluetooth Low Energy mesh transport
  ble,

  /// WebRTC-based P2P transport (STUN/TURN/TURNS)
  webrtc,
}

/// Display metadata for a transport service.
/// 
/// Used by UI components to show appropriate icons and labels
/// for each transport type.
class TransportDisplayInfo {
  /// Icon to display for this transport (e.g., Bluetooth, WiFi, Globe)
  final IconData icon;

  /// Human-readable name of the transport
  final String name;

  /// Short description of the transport
  final String description;

  /// Color associated with this transport (optional)
  final Color? color;

  const TransportDisplayInfo({
    required this.icon,
    required this.name,
    required this.description,
    this.color,
  });
}

/// Transport connection state
enum TransportState {
  /// Transport is not initialized
  uninitialized,

  /// Transport is initializing
  initializing,

  /// Transport is ready but not active
  ready,

  /// Transport is actively running (scanning/listening)
  active,

  /// Transport encountered an error
  error,

  /// Transport is disposed
  disposed,
}

/// Represents a discovered peer on a transport layer.
/// 
/// This is transport-agnostic - each transport implementation maps
/// its native peer representation to this common format.
class TransportPeer {
  /// Unique identifier for this peer on this transport.
  /// For BLE: device ID (MAC/UUID)
  /// For WebRTC: peer connection ID
  final String peerId;

  /// Transport type this peer was discovered on
  final TransportType transport;

  /// Public key if known (after handshake/announce)
  Uint8List? publicKey;

  /// Human-readable name if available
  String? displayName;

  /// Signal quality indicator (0.0 - 1.0, if available)
  /// For BLE: derived from RSSI
  /// For WebRTC: derived from connection stats
  double? signalQuality;

  /// Transport-specific metadata
  final Map<String, dynamic> metadata;

  /// When this peer was first discovered
  final DateTime discoveredAt;

  /// When we last heard from this peer
  DateTime lastSeen;

  TransportPeer({
    required this.peerId,
    required this.transport,
    this.publicKey,
    this.displayName,
    this.signalQuality,
    Map<String, dynamic>? metadata,
    DateTime? discoveredAt,
    DateTime? lastSeen,
  })  : metadata = metadata ?? {},
        discoveredAt = discoveredAt ?? DateTime.now(),
        lastSeen = lastSeen ?? DateTime.now();

  /// Whether we know this peer's public key
  bool get isIdentified => publicKey != null;

  @override
  String toString() =>
      'TransportPeer($peerId, $transport, identified: $isIdentified)';
}

/// Event emitted when data is received from a peer
class TransportDataEvent {
  /// The peer that sent the data
  final String peerId;

  /// The transport this data came from
  final TransportType transport;

  /// The raw data received
  final Uint8List data;

  /// Timestamp when received
  final DateTime timestamp;

  TransportDataEvent({
    required this.peerId,
    required this.transport,
    required this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Event emitted when a peer connects or disconnects
class TransportConnectionEvent {
  /// The peer ID
  final String peerId;

  /// The transport type
  final TransportType transport;

  /// Whether this is a connection (true) or disconnection (false)
  final bool connected;

  /// Additional info about the connection/disconnection
  final String? reason;

  TransportConnectionEvent({
    required this.peerId,
    required this.transport,
    required this.connected,
    this.reason,
  });
}

/// Event emitted when a new peer is discovered
class TransportDiscoveryEvent {
  /// The discovered peer
  final TransportPeer peer;

  /// Whether this is a new discovery or an update
  final bool isNew;

  TransportDiscoveryEvent({
    required this.peer,
    this.isNew = true,
  });
}

/// Abstract interface for transport services.
/// 
/// This interface defines the contract that all transport implementations
/// must fulfill, allowing the application layer to switch between
/// different transport protocols (BLE, WebRTC, etc.) seamlessly.
/// 
/// ## Implementation Requirements
/// 
/// Implementations must:
/// 1. Handle peer discovery appropriate to the transport
/// 2. Manage connections to discovered peers
/// 3. Provide reliable data transmission (or indicate unreliability)
/// 4. Map transport-specific peer IDs to the common format
/// 
/// ## Lifecycle
/// 
/// ```
/// create → initialize() → start() → [active use] → stop() → dispose()
/// ```
abstract class TransportService {
  /// The type of transport this service provides
  TransportType get type;

  /// Display information for this transport (icon, name, description)
  /// Used by UI to show transport indicators next to peers
  TransportDisplayInfo get displayInfo;

  /// Current state of the transport
  TransportState get state;

  /// Stream of state changes
  Stream<TransportState> get stateStream;

  /// Stream of received data events
  Stream<TransportDataEvent> get dataStream;

  /// Stream of connection events
  Stream<TransportConnectionEvent> get connectionStream;

  /// Stream of peer discovery events
  Stream<TransportDiscoveryEvent> get discoveryStream;

  /// All currently known peers on this transport
  List<TransportPeer> get peers;

  /// All currently connected peers
  List<TransportPeer> get connectedPeers;

  /// Number of connected peers
  int get connectedCount;

  /// Whether the transport is currently active
  bool get isActive;

  /// Initialize the transport service.
  /// 
  /// This should:
  /// - Set up any required resources
  /// - Check permissions
  /// - Prepare for [start] to be called
  /// 
  /// Returns true if initialization succeeded.
  Future<bool> initialize();

  /// Start the transport (begin discovery/listening).
  /// 
  /// After this call, the transport should:
  /// - Begin discovering peers (if applicable)
  /// - Accept incoming connections
  /// - Emit events through the streams
  Future<void> start();

  /// Stop the transport (stop discovery/listening).
  /// 
  /// This should:
  /// - Stop discovering new peers
  /// - Optionally maintain existing connections
  /// - Can be restarted with [start]
  Future<void> stop();

  /// Connect to a specific peer by their transport-specific ID.
  /// 
  /// Returns true if connection was initiated successfully.
  /// The actual connection result will come through [connectionStream].
  Future<bool> connectToPeer(String peerId);

  /// Disconnect from a specific peer.
  Future<void> disconnectFromPeer(String peerId);

  /// Send data to a specific peer.
  /// 
  /// Returns true if the data was sent (or queued) successfully.
  /// Note: This doesn't guarantee delivery for unreliable transports.
  Future<bool> sendToPeer(String peerId, Uint8List data);

  /// Broadcast data to all connected peers.
  /// 
  /// [excludePeerId] can be used to exclude a specific peer
  /// (useful for avoiding echo when relaying).
  Future<void> broadcast(Uint8List data, {String? excludePeerId});

  /// Associate a peer with a public key.
  /// 
  /// Called after identity exchange (e.g., ANNOUNCE packet).
  /// This allows higher layers to address peers by pubkey.
  void associatePeerWithPubkey(String peerId, Uint8List pubkey);

  /// Get peer ID for a public key (if known).
  String? getPeerIdForPubkey(Uint8List pubkey);

  /// Get public key for a peer ID (if known).
  Uint8List? getPubkeyForPeerId(String peerId);

  /// Clean up resources.
  /// 
  /// After this call, the transport cannot be used again.
  Future<void> dispose();
}

/// Mixin providing common functionality for transport implementations
mixin TransportServiceMixin {
  final Map<String, Uint8List> _peerToPubkey = {};
  final Map<String, String> _pubkeyToPeer = {};

  /// Associate a peer with a public key
  void associatePeerWithPubkeyImpl(String peerId, Uint8List pubkey) {
    final hex = _pubkeyToHex(pubkey);
    _peerToPubkey[peerId] = pubkey;
    _pubkeyToPeer[hex] = peerId;
  }

  /// Get peer ID for a public key
  String? getPeerIdForPubkeyImpl(Uint8List pubkey) {
    return _pubkeyToPeer[_pubkeyToHex(pubkey)];
  }

  /// Get public key for a peer ID
  Uint8List? getPubkeyForPeerIdImpl(String peerId) {
    return _peerToPubkey[peerId];
  }

  /// Remove a peer's pubkey association
  void removePeerPubkeyAssociation(String peerId) {
    final pubkey = _peerToPubkey.remove(peerId);
    if (pubkey != null) {
      _pubkeyToPeer.remove(_pubkeyToHex(pubkey));
    }
  }

  /// Clear all pubkey associations
  void clearPubkeyAssociations() {
    _peerToPubkey.clear();
    _pubkeyToPeer.clear();
  }

  String _pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
