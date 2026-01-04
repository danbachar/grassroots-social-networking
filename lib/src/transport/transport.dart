/// Transport layer abstraction for Bitchat.
/// 
/// This module provides:
/// - [TransportService]: Abstract interface for transport implementations
/// - [BleTransportService]: Bluetooth Low Energy mesh transport
/// 
/// Future implementations may include:
/// - WebRTC transport (STUN/TURN/TURNS)
/// - LibP2P transport
/// - LoRaWAN transport
library;

export 'transport_service.dart';
export 'ble_transport_service.dart';

// Re-export BLE types needed for advanced usage
// TOOD: we should define DiscoveredPeer and ConnectedPeer here
export '../ble/ble_central_service.dart' show DiscoveredDevice, ConnectedPeer;
