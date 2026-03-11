import 'dart:typed_data';
import '../models/peer.dart';

/// Which BLE role our device played in the connection.
/// - central: we scanned and connected to the remote peer
/// - peripheral: the remote peer connected to us
enum BleRole { central, peripheral }

/// Base class for peer-related actions
abstract class PeerAction {}

// ===== BLE Discovery Actions =====

/// A BLE device was discovered during scan
class BleDeviceDiscoveredAction extends PeerAction {
  final String deviceId;
  final String? displayName;
  final int rssi;
  final String? serviceUuid;

  BleDeviceDiscoveredAction({
    required this.deviceId,
    this.displayName,
    required this.rssi,
    this.serviceUuid,
  });
}

/// RSSI updated for a discovered BLE device
class BleDeviceRssiUpdatedAction extends PeerAction {
  final String deviceId;
  final int rssi;

  BleDeviceRssiUpdatedAction({
    required this.deviceId,
    required this.rssi,
  });
}

/// Mark a discovered BLE device as connecting
class BleDeviceConnectingAction extends PeerAction {
  final String deviceId;

  BleDeviceConnectingAction(this.deviceId);
}

/// Mark a discovered BLE device as connected (transport level)
class BleDeviceConnectedAction extends PeerAction {
  final String deviceId;

  BleDeviceConnectedAction(this.deviceId);
}

/// Mark a discovered BLE device connection as failed
class BleDeviceConnectionFailedAction extends PeerAction {
  final String deviceId;
  final String? error;

  BleDeviceConnectionFailedAction(this.deviceId, {this.error});
}

/// Mark a discovered BLE device as disconnected
class BleDeviceDisconnectedAction extends PeerAction {
  final String deviceId;

  BleDeviceDisconnectedAction(this.deviceId);
}

/// Remove a discovered BLE device
class BleDeviceRemovedAction extends PeerAction {
  final String deviceId;

  BleDeviceRemovedAction(this.deviceId);
}

/// Remove stale discovered BLE devices
class StaleDiscoveredBlePeersRemovedAction extends PeerAction {
  final Duration staleThreshold;

  StaleDiscoveredBlePeersRemovedAction(this.staleThreshold);
}

/// Clear all discovered BLE peers
class ClearDiscoveredBlePeersAction extends PeerAction {}

// ===== Libp2p Discovery Actions =====

/// A libp2p peer was discovered
class Libp2pPeerDiscoveredAction extends PeerAction {
  final String peerId;
  final String? displayName;

  Libp2pPeerDiscoveredAction({
    required this.peerId,
    this.displayName,
  });
}

/// Clear all discovered libp2p peers
class ClearDiscoveredLibp2pPeersAction extends PeerAction {}

// ===== Peer Identity Actions (after ANNOUNCE) =====

/// An ANNOUNCE packet was received - add or update peer identity.
///
/// Only one of [bleCentralDeviceId] or [blePeripheralDeviceId] should be set
/// per action, based on which BLE role our device played.
class PeerAnnounceReceivedAction extends PeerAction {
  final Uint8List publicKey;
  final String nickname;
  final int protocolVersion;
  final int rssi;
  final PeerTransport transport;

  /// BLE device ID from our central role (we connected to them)
  final String? bleCentralDeviceId;

  /// BLE device ID from our peripheral role (they connected to us)
  final String? blePeripheralDeviceId;

  final List<String> libp2pAddresses;

  PeerAnnounceReceivedAction({
    required this.publicKey,
    required this.nickname,
    required this.protocolVersion,
    required this.rssi,
    this.transport = PeerTransport.bleDirect,
    this.bleCentralDeviceId,
    this.blePeripheralDeviceId,
    this.libp2pAddresses = const [],
  });
}

/// Update peer RSSI
class PeerRssiUpdatedAction extends PeerAction {
  final Uint8List publicKey;
  final int rssi;

  PeerRssiUpdatedAction({
    required this.publicKey,
    required this.rssi,
  });
}

/// Mark peer as disconnected from BLE.
/// If [role] is provided, only clears the device ID for that role.
/// If [role] is null, clears both BLE device IDs.
class PeerBleDisconnectedAction extends PeerAction {
  final Uint8List publicKey;
  final BleRole? role;

  PeerBleDisconnectedAction(this.publicKey, {this.role});
}

/// Mark peer as disconnected from libp2p
class PeerLibp2pDisconnectedAction extends PeerAction {
  final Uint8List publicKey;

  PeerLibp2pDisconnectedAction(this.publicKey);
}

/// Mark peer as fully disconnected
class PeerDisconnectedAction extends PeerAction {
  final Uint8List publicKey;

  PeerDisconnectedAction(this.publicKey);
}

/// Remove peer completely
class PeerRemovedAction extends PeerAction {
  final Uint8List publicKey;

  PeerRemovedAction(this.publicKey);
}

/// Remove stale peers that haven't been seen
class StalePeersRemovedAction extends PeerAction {
  final Duration staleThreshold;

  StalePeersRemovedAction(this.staleThreshold);
}

/// Clear all peers
class ClearAllPeersAction extends PeerAction {}

// ===== Association Actions =====

/// Associate a BLE device ID with a pubkey for a specific role
class AssociateBleDeviceAction extends PeerAction {
  final Uint8List publicKey;
  final String deviceId;
  final BleRole role;

  AssociateBleDeviceAction({
    required this.publicKey,
    required this.deviceId,
    required this.role,
  });
}

/// Associate a libp2p address with a pubkey
class AssociateLibp2pAddressAction extends PeerAction {
  final Uint8List publicKey;
  final String address;

  AssociateLibp2pAddressAction({
    required this.publicKey,
    required this.address,
  });
}

// ===== Friendship Actions =====

/// A friendship has been established - mark peer as friend
class FriendEstablishedAction extends PeerAction {
  final Uint8List publicKey;
  final String? nickname;

  FriendEstablishedAction({
    required this.publicKey,
    this.nickname,
  });
}

/// A friendship has been removed
class FriendRemovedAction extends PeerAction {
  final Uint8List publicKey;

  FriendRemovedAction(this.publicKey);
}
