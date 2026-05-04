/// Transport layer abstraction for Bitchat.
///
/// This module provides:
/// - [TransportService]: Abstract interface for transport implementations
/// - [BleTransportService]: Bluetooth Low Energy direct transport
/// - [UdpTransportService]: UDP peer-to-peer transport
///
/// NOTE: This is a direct peer-to-peer transport layer.
/// There is NO mesh routing, NO forwarding, NO store-and-forward.
/// All messages go directly from sender to recipient.
/// The application layer (GSG) handles any forwarding needs.
library;

export 'transport_service.dart';
export 'ble_transport_service.dart';
export 'udp_transport_service.dart';
export 'hole_punch_service.dart';
export 'public_address_discovery.dart';
export 'address_utils.dart';
export 'connection_service.dart';

// Re-export BLE types needed for advanced usage
export '../ble/ble_central_service.dart' show DiscoveredDevice, ConnectedPeer;
