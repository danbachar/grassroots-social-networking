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

  /// UDP P2P connection
  udp,
}

/// Holds addresses for all available transports for a peer
class PeerAddresses {
  /// BLE device ID (MAC address on Android, UUID on iOS)
  String? bleDeviceId;
  
  /// UDP address (ip:port)
  String? udpAddress;

  /// When the BLE address was last seen
  DateTime? bleLastSeen;

  /// When the UDP address was last seen
  DateTime? udpLastSeen;
  
  PeerAddresses({
    this.bleDeviceId,
    this.udpAddress,
    this.bleLastSeen,
    this.udpLastSeen,
  });
  
  /// Whether we have a BLE address for this peer
  bool get hasBleAddress => bleDeviceId != null;

  /// Whether we have a UDP address for this peer
  bool get hasUdpAddress => udpAddress != null && udpAddress!.isNotEmpty;

  /// Whether we have any address for this peer
  bool get hasAnyAddress => hasBleAddress || hasUdpAddress;
  
  /// Get the best available transport for this peer
  /// Priority: Bluetooth > UDP (Bluetooth is preferred for proximity)
  PeerTransport? get preferredTransport {
    // Prefer BLE if recently seen (within 30 seconds)
    if (hasBleAddress && bleLastSeen != null) {
      final bleAge = DateTime.now().difference(bleLastSeen!);
      if (bleAge.inSeconds < 30) {
        return PeerTransport.bleDirect;
      }
    }

    // Fall back to UDP if available
    if (hasUdpAddress && udpLastSeen != null) {
      return PeerTransport.udp;
    }

    // If BLE is stale but still available
    if (hasBleAddress) {
      return PeerTransport.bleDirect;
    }

    // Last resort: UDP even if not recently seen
    if (hasUdpAddress) {
      return PeerTransport.udp;
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

  /// Update UDP address
  void updateUdpAddress(String? address) {
    udpAddress = address;
    if (address != null && address.isNotEmpty) {
      udpLastSeen = DateTime.now();
    }
  }

  /// Touch BLE last seen timestamp
  void touchBle() {
    if (hasBleAddress) {
      bleLastSeen = DateTime.now();
    }
  }

  /// Touch UDP last seen timestamp
  void touchUdp() {
    if (hasUdpAddress) {
      udpLastSeen = DateTime.now();
    }
  }
  
  /// Clear all addresses (on disconnect)
  void clear() {
    bleDeviceId = null;
    udpAddress = null;
    bleLastSeen = null;
    udpLastSeen = null;
  }

  /// Clear only the UDP address (used when unfriending)
  void clearUdpAddress() {
    udpAddress = null;
    udpLastSeen = null;
  }

  Map<String, dynamic> toJson() => {
        'bleDeviceId': bleDeviceId,
        'udpAddress': udpAddress,
        'bleLastSeen': bleLastSeen?.toIso8601String(),
        'udpLastSeen': udpLastSeen?.toIso8601String(),
      };

  factory PeerAddresses.fromJson(Map<String, dynamic> json) => PeerAddresses(
        bleDeviceId: json['bleDeviceId'],
        udpAddress: json['udpAddress'] as String?,
        bleLastSeen: json['bleLastSeen'] != null
            ? DateTime.parse(json['bleLastSeen'])
            : null,
        udpLastSeen: json['udpLastSeen'] != null
            ? DateTime.parse(json['udpLastSeen'])
            : null,
      );
  
  @override
  String toString() => 'PeerAddresses(ble: $bleDeviceId, udp: $udpAddress)';
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
      case PeerTransport.udp:
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
      case PeerTransport.udp:
        return 'UDP';
    }
  }

  /// Convert from TransportType
  static PeerTransport fromTransportType(TransportType type, {bool isMesh = false}) {
    switch (type) {
      case TransportType.ble:
        return PeerTransport.bleDirect;
      case TransportType.webrtc:
        return PeerTransport.webrtc;
      case TransportType.udp:
        return PeerTransport.udp;
    }
  }
}

/// Represents a peer in the Bitchat network.
///
/// A peer can be:
/// - Directly connected via BLE
/// - Connected over UDP (Internet)
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

  /// UDP address (ip:port) for this peer
  String? get udpAddress => addresses.udpAddress;
  set udpAddress(String? value) => addresses.updateUdpAddress(value);
  
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

  /// Whether this peer is reachable via UDP
  bool get isReachableViaUdp => addresses.hasUdpAddress;

  /// Whether this peer is reachable via any transport
  bool get isReachableViaAny => isReachableViaBle || isReachableViaUdp;
  
  Peer({
    required this.publicKey,
    this.nickname = '',
    this.connectionState = PeerConnectionState.discovered,
    required this.transport,
    String? bleDeviceId,
    String? udpAddress,
    PeerAddresses? addresses,
    this.lastSeen,
    this.lastSentTo,
    required this.rssi,
    this.protocolVersion = 1,
  }) : addresses = addresses ?? PeerAddresses(
          bleDeviceId: bleDeviceId,
          udpAddress: udpAddress,
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
  /// Priority: Bluetooth > UDP
  PeerTransport? get bestAvailableTransport => addresses.preferredTransport;
  
  /// Update peer state from a received ANNOUNCE
  void updateFromAnnounce({
    required String nickname,
    required int protocolVersion,
    required DateTime receivedAt,
    String? udpAddress,
  }) {
    this.nickname = nickname;
    this.protocolVersion = protocolVersion;
    lastSeen = receivedAt;
    connectionState = PeerConnectionState.connected;

    // Update UDP address if provided
    if (udpAddress != null && udpAddress.isNotEmpty) {
      addresses.updateUdpAddress(udpAddress);
    }
  }
  
  /// Update the peer's transport addresses
  void updateAddresses({
    String? bleDeviceId,
    String? udpAddress,
  }) {
    if (bleDeviceId != null) {
      addresses.updateBleAddress(bleDeviceId);
    }
    if (udpAddress != null) {
      addresses.updateUdpAddress(udpAddress);
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
    if (addresses.hasUdpAddress) {
      transport = PeerTransport.udp;
      // Keep connected state if we have UDP
    } else {
      connectionState = PeerConnectionState.disconnected;
      rssi = -100;
    }
  }

  /// Mark peer as disconnected from UDP
  void markUdpDisconnected() {
    addresses.udpLastSeen = null;

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
