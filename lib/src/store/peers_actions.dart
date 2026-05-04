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

/// Blacklist a discovered BLE device to prevent auto-reconnection
class BleDeviceBlacklistedAction extends PeerAction {
  final String deviceId;

  BleDeviceBlacklistedAction(this.deviceId);
}

/// Unblacklist a discovered BLE device so it can be reconnected
class BleDeviceUnblacklistedAction extends PeerAction {
  final String deviceId;

  BleDeviceUnblacklistedAction(this.deviceId);
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

  final String? udpAddress;
  final String? linkLocalAddress;
  final Set<String> udpAddressCandidates;

  PeerAnnounceReceivedAction({
    required this.publicKey,
    required this.nickname,
    required this.protocolVersion,
    required this.rssi,
    this.transport = PeerTransport.bleDirect,
    this.bleCentralDeviceId,
    this.blePeripheralDeviceId,
    this.udpAddress,
    this.linkLocalAddress,
    this.udpAddressCandidates = const {},
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

/// A UDX connection to a peer was established or closed.
/// Updates [PeerState.hasLiveUdpConnection].
class PeerUdpConnectionChangedAction extends PeerAction {
  final String pubkeyHex;
  final bool connected;

  PeerUdpConnectionChangedAction({
    required this.pubkeyHex,
    required this.connected,
  });
}

/// A verified UDP packet was received from a peer.
///
/// Updates UDP-specific freshness so stale UDX sessions can be aged out even
/// when the peer is still nearby over BLE.
class PeerUdpSeenAction extends PeerAction {
  final Uint8List publicKey;

  PeerUdpSeenAction(this.publicKey);
}

/// Mark peer as disconnected from UDP
class PeerUdpDisconnectedAction extends PeerAction {
  final Uint8List publicKey;

  PeerUdpDisconnectedAction(this.publicKey);
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

/// Associate a UDP address with a pubkey
class AssociateUdpAddressAction extends PeerAction {
  final Uint8List publicKey;
  final String address;

  AssociateUdpAddressAction({
    required this.publicKey,
    required this.address,
  });
}

/// Update the set of rendezvous servers a peer reaches its peers through.
/// Map keys are lowercase pubkey hexes; values are "ip:port" addresses.
/// Driven by the RV_LIST signaling message.
class PeerRvServersUpdatedAction extends PeerAction {
  final Uint8List publicKey;
  final Map<String, String> rvServers;

  PeerRvServersUpdatedAction({
    required this.publicKey,
    required this.rvServers,
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

// ===== Reachability Verification Actions =====

/// We successfully reached a peer at their UDP address without coordinating
/// a hole-punch — empirical proof that they accept unsolicited inbound.
/// Promotes the peer from "candidate" (publicly routable address) to
/// "verified well-connected".
class PeerDirectReachObservedAction extends PeerAction {
  final Uint8List publicKey;
  final DateTime observedAt;

  PeerDirectReachObservedAction(this.publicKey, {DateTime? observedAt})
      : observedAt = observedAt ?? DateTime.now();
}
