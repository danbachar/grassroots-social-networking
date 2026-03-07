import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../transport/transport_service.dart';

/// Connection state of a peer
enum PeerConnectionState {
  /// Discovered via BLE scan but not connected
  discovered,
  
  /// BLE connection established, awaiting ANNOUNCE
  connecting,
  
  /// ANNOUNCE exchanged, peer identity known
  connected,
  
  /// Connection lost, may still have cached identity
  disconnected,
}

/// Transport type for peer communication
enum PeerTransport {
  /// Direct BLE connection (Central or Peripheral role)
  bleDirect,
  
  /// WebRTC P2P connection
  webrtc,
  
  /// LibP2P P2P connection
  libp2p,
}

/// Holds addresses for all available transports for a peer
class PeerAddresses {
  /// BLE device ID (MAC address on Android, UUID on iOS)
  String? bleDeviceId;
  
  /// libp2p multiaddress (e.g., /ip4/192.168.1.1/tcp/4001/p2p/QmHash...)
  String? libp2pAddress;
  
  /// When the BLE address was last seen
  DateTime? bleLastSeen;
  
  /// When the libp2p address was last seen
  DateTime? libp2pLastSeen;
  
  PeerAddresses({
    this.bleDeviceId,
    this.libp2pAddress,
    this.bleLastSeen,
    this.libp2pLastSeen,
  });
  
  /// Whether we have a BLE address for this peer
  bool get hasBleAddress => bleDeviceId != null;
  
  /// Whether we have a libp2p address for this peer
  bool get hasLibp2pAddress => libp2pAddress != null && libp2pAddress!.isNotEmpty;
  
  /// Whether we have any address for this peer
  bool get hasAnyAddress => hasBleAddress || hasLibp2pAddress;
  
  /// Get the best available transport for this peer
  /// Priority: Bluetooth > libp2p (Bluetooth is preferred for proximity)
  PeerTransport? get preferredTransport {
    // Prefer BLE if recently seen (within 30 seconds)
    if (hasBleAddress && bleLastSeen != null) {
      final bleAge = DateTime.now().difference(bleLastSeen!);
      if (bleAge.inSeconds < 30) {
        return PeerTransport.bleDirect;
      }
    }
    
    // Fall back to libp2p if available
    if (hasLibp2pAddress && libp2pLastSeen != null) {
      return PeerTransport.libp2p;
    }
    
    // If BLE is stale but still available
    if (hasBleAddress) {
      return PeerTransport.bleDirect;
    }
    
    // Last resort: libp2p even if not recently seen
    if (hasLibp2pAddress) {
      return PeerTransport.libp2p;
    }
    
    return null;
  }
  
  /// Update BLE address
  void updateBleAddress(String? deviceId) {
    bleDeviceId = deviceId;
    if (deviceId != null) {
      bleLastSeen = DateTime.now();
    }
  }
  
  /// Update libp2p address
  void updateLibp2pAddress(String? address) {
    libp2pAddress = address;
    if (address != null && address.isNotEmpty) {
      libp2pLastSeen = DateTime.now();
    }
  }
  
  /// Touch BLE last seen timestamp
  void touchBle() {
    if (hasBleAddress) {
      bleLastSeen = DateTime.now();
    }
  }
  
  /// Touch libp2p last seen timestamp
  void touchLibp2p() {
    if (hasLibp2pAddress) {
      libp2pLastSeen = DateTime.now();
    }
  }
  
  /// Clear all addresses (on disconnect)
  void clear() {
    bleDeviceId = null;
    libp2pAddress = null;
    bleLastSeen = null;
    libp2pLastSeen = null;
  }
  
  /// Clear only the libp2p address (used when unfriending)
  void clearLibp2pAddress() {
    libp2pAddress = null;
    libp2pLastSeen = null;
  }

  Map<String, dynamic> toJson() => {
        'bleDeviceId': bleDeviceId,
        'libp2pAddress': libp2pAddress,
        'bleLastSeen': bleLastSeen?.toIso8601String(),
        'libp2pLastSeen': libp2pLastSeen?.toIso8601String(),
      };

  factory PeerAddresses.fromJson(Map<String, dynamic> json) => PeerAddresses(
        bleDeviceId: json['bleDeviceId'],
        libp2pAddress: json['libp2pAddress'],
        bleLastSeen: json['bleLastSeen'] != null
            ? DateTime.parse(json['bleLastSeen'])
            : null,
        libp2pLastSeen: json['libp2pLastSeen'] != null
            ? DateTime.parse(json['libp2pLastSeen'])
            : null,
      );
  
  @override
  String toString() => 'PeerAddresses(ble: $bleDeviceId, libp2p: $libp2pAddress)';
}

/// Extension to get display info for peer transport
extension PeerTransportDisplay on PeerTransport {
  /// Get the icon for this transport type
  Icon get icon {
    switch (this) {
      case PeerTransport.bleDirect:
        return const Icon(Icons.bluetooth_connected, size: 16, color: Colors.blue);
      case PeerTransport.webrtc:
        return const Icon(Icons.public, size: 16, color: Colors.blue);
      case PeerTransport.libp2p:
        return const Icon(Icons.public, size: 16, color: Colors.green);
    }
  }
  
  /// Get the display name for this transport
  String get displayName {
    switch (this) {
      case PeerTransport.bleDirect:
        return 'Bluetooth';
      case PeerTransport.webrtc:
        return 'WebRTC';
      case PeerTransport.libp2p:
        return 'LibP2P';
    }
  }
  
  /// Convert from TransportType
  static PeerTransport fromTransportType(TransportType type, {bool isMesh = false}) {
    switch (type) {
      case TransportType.ble:
        return PeerTransport.bleDirect;
      case TransportType.webrtc:
        return PeerTransport.webrtc;
      case TransportType.libp2p:
        return PeerTransport.libp2p;
    }
  }
}

/// Represents a peer in the Bitchat network.
/// 
/// A peer can be:
/// - Directly connected via BLE
/// - Connected over libp2p (Internet)
/// - Connected via both transports
/// - Known but currently unreachable
class Peer {
  /// Ed25519 public key (32 bytes) - primary identifier
  final Uint8List publicKey;
  
  /// Human-readable nickname from ANNOUNCE (may be empty)
  String nickname;
  
  /// Current connection state
  PeerConnectionState connectionState;
  
  /// How we are currently reaching this peer (best available)
  PeerTransport transport;
  
  /// All known addresses for this peer
  final PeerAddresses addresses;
  
  /// BLE device ID (platform-specific, used for connection management)
  /// On iOS: UUID string
  /// On Android: MAC address
  /// @deprecated Use addresses.bleDeviceId instead
  String? get bleDeviceId => addresses.bleDeviceId;
  set bleDeviceId(String? value) => addresses.updateBleAddress(value);
  
  /// libp2p multiaddress for this peer
  String? get libp2pAddress => addresses.libp2pAddress;
  set libp2pAddress(String? value) => addresses.updateLibp2pAddress(value);
  
  /// Last time we received data from this peer
  DateTime? lastSeen;
  
  /// Last time we successfully sent data to this peer
  DateTime? lastSentTo;
  
  /// Signal strength (RSSI) if available, for BLE connections
  int rssi;
  
  /// Protocol version from ANNOUNCE
  int protocolVersion;
  
  /// Whether this peer is reachable via BLE
  bool get isReachableViaBle => addresses.hasBleAddress && 
      (connectionState == PeerConnectionState.connected || 
       connectionState == PeerConnectionState.connecting);
  
  /// Whether this peer is reachable via libp2p
  bool get isReachableViaLibp2p => addresses.hasLibp2pAddress;
  
  /// Whether this peer is reachable via any transport
  bool get isReachableViaAny => isReachableViaBle || isReachableViaLibp2p;
  
  Peer({
    required this.publicKey,
    this.nickname = '',
    this.connectionState = PeerConnectionState.discovered,
    required this.transport,
    String? bleDeviceId,
    String? libp2pAddress,
    PeerAddresses? addresses,
    this.lastSeen,
    this.lastSentTo,
    required this.rssi,
    this.protocolVersion = 1,
  }) : addresses = addresses ?? PeerAddresses(
          bleDeviceId: bleDeviceId,
          libp2pAddress: libp2pAddress,
        ) {
    if (publicKey.length != 32) {
      throw ArgumentError('Public key must be 32 bytes');
    }
  }
  
  /// Unique identifier string from public key (hex encoded)
  String get id => publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  
  /// Short fingerprint for display (first 8 bytes, colon-separated)
  String get shortFingerprint {
    return publicKey.sublist(0, 8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(':')
        .toUpperCase();
  }
  
  /// Display name: nickname if available, otherwise short fingerprint
  String get displayName => nickname.isNotEmpty ? nickname : shortFingerprint;
  
  /// Whether this peer is currently reachable
  bool get isReachable => 
      connectionState == PeerConnectionState.connected ||
      connectionState == PeerConnectionState.connecting;
  
  /// Get the best transport to use for sending to this peer
  /// Priority: Bluetooth > libp2p
  PeerTransport? get bestAvailableTransport => addresses.preferredTransport;
  
  /// Update peer state from a received ANNOUNCE
  void updateFromAnnounce({
    required String nickname,
    required int protocolVersion,
    required DateTime receivedAt,
    String? libp2pAddress,
  }) {
    this.nickname = nickname;
    this.protocolVersion = protocolVersion;
    lastSeen = receivedAt;
    connectionState = PeerConnectionState.connected;
    
    // Update libp2p address if provided
    if (libp2pAddress != null && libp2pAddress.isNotEmpty) {
      addresses.updateLibp2pAddress(libp2pAddress);
    }
  }
  
  /// Update the peer's transport addresses
  void updateAddresses({
    String? bleDeviceId,
    String? libp2pAddress,
  }) {
    if (bleDeviceId != null) {
      addresses.updateBleAddress(bleDeviceId);
    }
    if (libp2pAddress != null) {
      addresses.updateLibp2pAddress(libp2pAddress);
    }
    
    // Update current transport to best available
    final best = addresses.preferredTransport;
    if (best != null) {
      transport = best;
    }
  }
  
  /// Mark peer as disconnected from BLE
  void markBleDisconnected() {
    addresses.bleDeviceId = null;
    addresses.bleLastSeen = null;
    
    // Update connection state and transport
    if (addresses.hasLibp2pAddress) {
      transport = PeerTransport.libp2p;
      // Keep connected state if we have libp2p
    } else {
      connectionState = PeerConnectionState.disconnected;
      rssi = -100;
    }
  }
  
  /// Mark peer as disconnected from libp2p
  void markLibp2pDisconnected() {
    addresses.libp2pLastSeen = null;
    
    // Update transport if we have BLE
    if (addresses.hasBleAddress) {
      transport = PeerTransport.bleDirect;
    } else {
      connectionState = PeerConnectionState.disconnected;
    }
  }
  
  /// Mark peer as disconnected
  void markDisconnected() {
    connectionState = PeerConnectionState.disconnected;
    addresses.clear();
    rssi = -100;
  }
  
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Peer &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
  
  @override
  String toString() => 'Peer($displayName, $connectionState, $transport)';
}
