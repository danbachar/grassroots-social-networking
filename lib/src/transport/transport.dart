/// Transport layer abstraction for Grassroots.
///
/// This module provides:
/// - [TransportService]: Abstract interface for transport implementations
/// - [BleTransportService]: Bluetooth Low Energy direct transport
/// - [UdpTransportService]: UDP peer-to-peer transport
///
/// NOTE: The BLE transport is an opportunistic mesh — packets are relayed by
/// managed flooding (TTL-bounded, bloom-deduplicated) and store-carried for
/// recipients that are temporarily out of range. The UDP transport is direct
/// point-to-point. Relays forward sealed, recipient-addressed packets; only the
/// recipient can decrypt the content (see CLAUDE.md → Mesh Envelope & Trust).
library;

export 'transport_service.dart';
export 'ble_transport_service.dart';
export 'udp_transport_service.dart';
export 'hole_punch_service.dart';
export 'public_address_discovery.dart';
export 'address_utils.dart';
export 'connection_service.dart';
