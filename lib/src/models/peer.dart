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
    }
  }
  
  /// Get the display name for this transport
  String get displayName {
    switch (this) {
      case PeerTransport.bleDirect:
        return 'Bluetooth';
      case PeerTransport.webrtc:
        return 'Internet';
    }
  }
  
  /// Convert from TransportType
  static PeerTransport fromTransportType(TransportType type, {bool isMesh = false}) {
    switch (type) {
      case TransportType.ble:
        return PeerTransport.bleDirect;
      case TransportType.webrtc:
        return PeerTransport.webrtc;
    }
  }
}

/// Represents a peer in the Bitchat network.
/// 
/// A peer can be:
/// - Directly connected via BLE
/// - Connected over WebRTC
/// - Known but currently unreachable
class Peer {
  /// Ed25519 public key (32 bytes) - primary identifier
  final Uint8List publicKey;
  
  /// Human-readable nickname from ANNOUNCE (may be empty)
  String nickname;
  
  /// Current connection state
  PeerConnectionState connectionState;
  
  /// How we can reach this peer
  PeerTransport transport;
  
  /// BLE device ID (platform-specific, used for connection management)
  /// On iOS: UUID string
  /// On Android: MAC address
  String? bleDeviceId;
  
  /// Last time we received data from this peer
  DateTime? lastSeen;
  
  /// Last time we successfully sent data to this peer
  DateTime? lastSentTo;
  
  /// Signal strength (RSSI) if available, for BLE connections
  int? rssi;
  
  /// Protocol version from ANNOUNCE
  int protocolVersion;
  
  Peer({
    required this.publicKey,
    this.nickname = '',
    this.connectionState = PeerConnectionState.discovered,
    required this.transport,
    this.bleDeviceId,
    this.lastSeen,
    this.lastSentTo,
    this.rssi,
    this.protocolVersion = 1,
  }) {
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
  
  /// Update peer state from a received ANNOUNCE
  void updateFromAnnounce({
    required String nickname,
    required int protocolVersion,
    required DateTime receivedAt,
  }) {
    this.nickname = nickname;
    this.protocolVersion = protocolVersion;
    lastSeen = receivedAt;
    connectionState = PeerConnectionState.connected;
  }
  
  /// Mark peer as disconnected
  void markDisconnected() {
    connectionState = PeerConnectionState.disconnected;
    bleDeviceId = null;
    rssi = null;
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
