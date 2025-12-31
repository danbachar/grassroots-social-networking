/// Bitchat Transport Layer for GSG Protocol
/// 
/// This package provides a BLE mesh transport layer based on the Bitchat protocol.
/// It handles:
/// - BLE Central/Peripheral dual-mode operation
/// - Packet fragmentation and reassembly
/// - Mesh routing with TTL-based relay
/// - Duplicate detection via Bloom filter
/// - Store-and-forward for offline peers
/// 
/// ## Usage
/// 
/// ```dart
/// import 'package:bitchat_transport/bitchat_transport.dart';
/// 
/// // Create identity (provided by GSG layer)
/// final identity = BitchatIdentity(
///   publicKey: myPubKey,
///   privateKey: myPrivKey,
///   nickname: 'Alice',
/// );
/// 
/// // Create Bitchat instance
/// final bitchat = Bitchat(identity: identity);
/// 
/// // Set up callbacks
/// bitchat.onMessageReceived = (senderPubkey, payload) {
///   // Handle incoming GSG block
/// };
/// 
/// bitchat.onPeerConnected = (peer) {
///   // New peer available
/// };
/// 
/// // Initialize and start
/// await bitchat.initialize();
/// 
/// // Send messages
/// await bitchat.send(recipientPubkey, gsgBlockData);
/// await bitchat.broadcast(gsgBlockData);
/// ```
/// 
/// ## Architecture
/// 
/// The package is structured as follows:
/// 
/// - `Bitchat` - Main API class for GSG integration
/// - `BitchatIdentity` - Ed25519 identity provided by GSG
/// - `Peer` - Represents a connected peer
/// - `MeshRouter` - Handles routing, relay, and fragmentation
/// - `BleManager` - Manages BLE Central and Peripheral roles
/// - `TransportService` - Abstract interface for transport implementations
/// 
/// ## Protocol Compatibility
/// 
/// This implementation follows the Bitchat protocol specification for
/// BLE mesh networking, ensuring compatibility with other Bitchat clients.
/// 
/// ## Transport Abstraction
/// 
/// The transport layer is abstracted via the `TransportService` interface,
/// allowing multiple transport implementations:
/// - `BleTransportService` - Bluetooth Low Energy mesh (default)
/// - Future: WebRTC transport (STUN/TURN/TURNS)
library bitchat_transport;

// Main API
export 'src/bitchat.dart';

// Transport abstraction
export 'src/transport/transport.dart';

// Models
export 'src/models/identity.dart';
export 'src/models/peer.dart';
export 'src/models/packet.dart';

// BLE (for advanced usage)
export 'src/ble/permission_handler.dart' show PermissionHandler, PermissionResult;
